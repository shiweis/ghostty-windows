//! Prune an idle project's cache, then hold its maintenance lock through the
//! following build. Never invoke this collector as a parallel Zig build step.
const std = @import("std");
const builtin = @import("builtin");
const guard = @import("cache_guard.zig");
const Io = std.Io;
const Cache = std.Build.Cache;
const Allocator = std.mem.Allocator;
const retention_ns = 30 * std.time.ns_per_day;
// The compiler's z/ IR cache has a separate lifetime contract. Leave it and
// fetched packages alone; compiled outputs account for the substantial growth.
const groups = [_][]const u8{ "h", "o", "c" };

pub fn main(init: std.process.Init) void {
    const status = run(init) catch |err| {
        std.debug.print("Development build failed: {t}\n", .{err});
        std.process.exit(1);
    };
    std.process.exit(status);
}

fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) return error.ExpectedCacheAndBuildCommand;
    var lock = try guard.acquire(init.io, .cwd());
    defer lock.release(init.io);

    const help = for (args[3..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) break true;
    } else false;
    if (!help) maintain(init.io, init.gpa, args[1]) catch |err| {
        // An unrecognized manifest, an active compiler, or filesystem trouble
        // must leave the cache alone and still allow ordinary development.
        std.debug.print("Cache pruning skipped: {t}.\n", .{err});
    };

    var child = try std.process.spawn(init.io, .{ .argv = args[2..] });
    const term = try child.wait(init.io);
    return switch (term) {
        .exited => |code| @intCast(@min(code, 255)),
        else => 1,
    };
}

fn maintain(io: Io, allocator: Allocator, cache_path: []const u8) !void {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.1"))
        return error.UnsupportedCacheCompilerVersion;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Only the repository's own default cache is managed. A custom cache can
    // be shared with another checkout or project, so it remains read-only.
    const repo = try Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    const expected = try std.fs.path.resolve(a, &.{ repo, ".zig-cache" });
    const selected = try std.fs.path.resolve(a, &.{ repo, cache_path });
    const owned = if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(expected, selected)
    else
        std.mem.eql(u8, expected, selected);
    if (!owned) return;
    const stat = Io.Dir.cwd().statFile(io, ".zig-cache", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .directory) return;
    if (try guard.isOtherZigRunning(io, a)) return error.AnotherZigProcess;
    var dir = try Io.Dir.cwd().openDir(io, ".zig-cache", .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    var plan = try Plan.init(io, a, dir, Io.Clock.real.now(io).nanoseconds - retention_ns);
    // Check again after planning, before making any destructive changes.
    if (try guard.isOtherZigRunning(io, a)) return error.AnotherZigProcess;
    const result = try plan.apply(io, dir);
    if (result.entries != 0) std.debug.print(
        "Pruned {d} stale cache entries ({d} MiB); retained recent and referenced artifacts.\n",
        .{ result.entries, result.bytes / (1024 * 1024) },
    );
}

const Entry = struct {
    path: []const u8,
    kind: Io.File.Kind,
    size: u64 = 0,
    activity: i96 = 0,
    modified: i96 = 0,
    keep: bool = false,
    artifacts: std.ArrayList([]const u8) = .empty,
    references: std.ArrayList(usize) = .empty,

    fn observe(self: *Entry, stat: Io.File.Stat) void {
        self.modified = @max(self.modified, stat.mtime.nanoseconds);
        self.activity = @max(self.activity, stat.mtime.nanoseconds);
        if (stat.kind == .file) {
            self.size +|= stat.size;
            if (stat.atime) |time| self.activity = @max(self.activity, time.nanoseconds);
        }
    }
};

const Plan = struct {
    entries: std.ArrayList(Entry) = .empty,
    paths: std.StringHashMapUnmanaged(usize) = .empty,

    fn init(io: Io, a: Allocator, dir: Io.Dir, cutoff: i96) !Plan {
        var self: Plan = .{};
        for (groups) |group| {
            var sub = dir.openDir(io, group, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer sub.close(io);
            var iterator = sub.iterate();
            while (try iterator.next(io)) |item| {
                // Unknown files, package downloads, temporary directories, and
                // symlinks are never candidates for automatic removal.
                if (item.kind != .file and item.kind != .directory) continue;
                const stem = if (std.mem.eql(u8, group, "h"))
                    std.mem.cutSuffix(u8, item.name, ".txt") orelse item.name
                else
                    item.name;
                if (!isDigest(stem)) continue;
                // Use the same map keys on Windows and POSIX; both accept '/'.
                const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ group, item.name });
                var entry: Entry = .{ .path = path, .kind = item.kind };
                entry.observe(try sub.statFile(io, item.name, .{ .follow_symlinks = false }));
                if (item.kind == .directory) {
                    var artifact = try sub.openDir(io, item.name, .{ .iterate = true, .follow_symlinks = false });
                    defer artifact.close(io);
                    var walker = try artifact.walk(a);
                    defer walker.deinit();
                    while (try walker.next(io)) |file| {
                        if (file.kind != .file and file.kind != .directory) continue;
                        entry.observe(try file.dir.statFile(io, file.basename, .{ .follow_symlinks = false }));
                        if (file.kind == .file) try entry.artifacts.append(a, try a.dupe(u8, file.basename));
                    }
                }
                entry.keep = entry.activity >= cutoff;
                try self.paths.put(a, path, self.entries.items.len);
                try self.entries.append(a, entry);
            }
        }

        // Access times can be disabled or stale, especially on Windows. Always
        // retain the newest producer of each artifact name as an extra root,
        // even when the working build has been unchanged for over a month.
        var newest: std.StringHashMapUnmanaged(usize) = .empty;
        for (self.entries.items, 0..) |entry, index| {
            for (entry.artifacts.items) |name| {
                const value = try newest.getOrPut(a, name);
                if (!value.found_existing or entry.modified > self.entries.items[value.value_ptr.*].modified)
                    value.value_ptr.* = index;
            }
        }
        var newest_indices = newest.valueIterator();
        while (newest_indices.next()) |index| self.entries.items[index.*].keep = true;

        for (self.entries.items, 0..) |entry, index| {
            if (entry.path[0] != 'h' or entry.kind != .file) continue;
            const data = try readManifest(io, a, dir, entry.path);
            if (data.len == 0) continue; // An incomplete producer is a cache miss.
            const name = std.fs.path.basename(entry.path);
            const digest = try manifestOutput(name, data);
            for ([_][]const u8{ "o", "c" }) |group| {
                const output = try std.fmt.allocPrint(a, "{s}/{s}", .{ group, Cache.binToHex(digest) });
                if (self.paths.get(output)) |output_index| {
                    try self.entries.items[index].references.append(a, output_index);
                    try self.entries.items[output_index].references.append(a, index);
                }
            }
            // Both manifest formats store paths verbatim. Match local cache
            // references conservatively; an extra retained entry is harmless.
            for (data, 0..) |byte, offset| {
                if (byte != 'o' and byte != 'c' and byte != 'z') continue;
                if (offset + 34 > data.len) continue;
                if (data[offset + 1] != '/' and data[offset + 1] != '\\') continue;
                const hash = data[offset + 2 ..][0..32];
                if (!isDigest(hash)) continue;
                const key = try std.fmt.allocPrint(a, "{c}/{s}", .{ byte, hash });
                if (self.paths.get(key)) |dependency| try self.entries.items[index].references.append(a, dependency);
            }
        }

        var pending: std.ArrayList(usize) = .empty;
        for (self.entries.items, 0..) |entry, index| if (entry.keep) try pending.append(a, index);
        while (pending.pop()) |index| {
            for (self.entries.items[index].references.items) |dependency| {
                if (self.entries.items[dependency].keep) continue;
                self.entries.items[dependency].keep = true;
                try pending.append(a, dependency);
            }
        }
        return self;
    }

    fn apply(self: *Plan, io: Io, dir: Io.Dir) !struct { entries: usize, bytes: u64 } {
        var count: usize = 0;
        var bytes: u64 = 0;
        // Remove expired manifests first. If cleanup is interrupted, remaining
        // objects cause cache misses instead of false hits to missing output.
        for (groups) |group| {
            for (self.entries.items) |entry| {
                if (entry.keep or entry.path[0] != group[0]) continue;
                if (entry.kind == .directory) {
                    try dir.deleteTree(io, entry.path);
                } else {
                    try dir.deleteFile(io, entry.path);
                }
                count += 1;
                bytes +|= entry.size;
            }
        }
        return .{ .entries = count, .bytes = bytes };
    }
};

fn isDigest(text: []const u8) bool {
    if (text.len != 32) return false;
    for (text) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return false;
    return true;
}

fn readManifest(io: Io, a: Allocator, dir: Io.Dir, path: []const u8) ![]const u8 {
    const file = try dir.openFile(io, path, .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .follow_symlinks = false,
    });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > 100 * 1024 * 1024) return error.ManifestTooLarge;
    const data = try a.alloc(u8, @intCast(stat.size));
    const count = try file.readPositionalAll(io, data, 0);
    // Inspecting every manifest must not make obsolete artifacts appear used.
    try file.setTimestamps(io, .{ .access_timestamp = .init(stat.atime) });
    if (count != data.len) return error.ManifestChanged;
    return data;
}

fn manifestOutput(name: []const u8, data: []const u8) !Cache.BinDigest {
    const legacy = std.mem.endsWith(u8, name, ".txt");
    const stem = if (legacy) name[0 .. name.len - 4] else name;
    var input: Cache.BinDigest = undefined;
    _ = try std.fmt.hexToBytes(&input, stem);
    // The legacy key and text format are from Zig 0.15; the current format and
    // key come directly from the compiler's std.Build.Cache implementation.
    var hasher = if (legacy) Cache.Hasher.init(&.{
        0x33, 0x52, 0xa2, 0x84, 0xcf, 0x17, 0x56, 0x57,
        0x01, 0xbb, 0xcd, 0xe4, 0x77, 0xd6, 0xf0, 0x60,
    }) else Cache.hasher_init;
    hasher.update(&input);
    if (legacy) {
        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        if (!std.mem.eql(u8, lines.next() orelse return error.UnknownManifest, "0"))
            return error.UnknownManifest;
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, ' ');
            for (0..3) |_| _ = fields.next() orelse return error.UnknownManifest;
            var digest: Cache.BinDigest = undefined;
            _ = std.fmt.hexToBytes(&digest, fields.next() orelse return error.UnknownManifest) catch return error.UnknownManifest;
            if (fields.next() == null or fields.next() == null) return error.UnknownManifest;
            hasher.update(&digest);
        }
    } else {
        var offset: usize = 0;
        while (offset + 1 < data.len) {
            const off: Cache.Manifest.File.Offset = @fromBackingInt(@intCast(offset));
            const file = off.getFallibleConst(data) catch return error.UnknownManifest;
            const path = off.pathFallible(data) catch return error.UnknownManifest;
            if (path.len == 0 or file.flags.prefix > 4) return error.UnknownManifest;
            hasher.update(&file.digest);
            offset += Cache.Manifest.File.sizeOf(path.len);
        }
        if (offset + 1 != data.len or data[offset] != 0) return error.UnknownManifest;
    }
    var output: Cache.BinDigest = undefined;
    hasher.final(&output);
    return output;
}

fn testWrite(io: Io, dir: Io.Dir, path: []const u8, data: []const u8, timestamp: i96) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
    const file = try dir.openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    try file.setTimestamps(io, .{
        .access_timestamp = .{ .new = .{ .nanoseconds = timestamp } },
        .modify_timestamp = .{ .new = .{ .nanoseconds = timestamp } },
    });
}

fn testBinaryManifest(a: Allocator, paths: []const []const u8) ![]const u8 {
    var data: std.ArrayList(u8) = .empty;
    for (paths, 0..) |path, index| {
        const header: Cache.Manifest.File = .{
            .size = 1,
            .inode = 2,
            .mtime = 3,
            .digest = @splat(@intCast(0x22 + index * 0x11)),
            .flags = .{ .is_directory = false, .metadata_only = false, .prefix = 2 },
            .path_start = .{},
        };
        try data.appendSlice(a, std.mem.asBytes(&header));
        try data.appendSlice(a, path);
        try data.appendNTimes(a, 0, Cache.Manifest.File.sizeOf(path.len) - @sizeOf(Cache.Manifest.File) - path.len);
    }
    try data.append(a, 0);
    return data.items;
}

test "cache prune recognizes Zig 0.15 and 0.17 manifest output hashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const name = "11111111111111111111111111111111";
    const legacy = "0\n" ++
        "1 2 3 22222222222222222222222222222222 2 first.zig\n" ++
        "4 5 6 33333333333333333333333333333333 2 second.zig\n";
    const current = try testBinaryManifest(arena.allocator(), &.{ "first.zig", "second.zig" });
    // Vectors independently generated with each compiler's std.Build.Cache
    // using input digest 0x11... and file digests 0x22..., 0x33....
    try std.testing.expectEqualStrings("657f95b627d91e757e500e70b5954a98", &Cache.binToHex(try manifestOutput(name ++ ".txt", legacy)));
    try std.testing.expectEqualStrings("ba4407361da0f9ccb66a2241f79efb53", &Cache.binToHex(try manifestOutput(name, current)));
    try std.testing.expectError(error.UnknownManifest, manifestOutput(name, current[0 .. current.len - 1]));
    try std.testing.expectError(error.UnknownManifest, manifestOutput(name ++ ".txt", "future-header\n"));
}

test "cache prune preserves transitive manifest and output dependencies" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = Io.Clock.real.now(io).nanoseconds;
    const old = now + 10 * std.time.ns_per_min;
    const newer = now + 20 * std.time.ns_per_min;
    const cutoff = now + std.time.ns_per_hour;
    const recent = now + 2 * std.time.ns_per_hour;
    const first_name = "11111111111111111111111111111111";
    const second_name = "22222222222222222222222222222222";
    const leaf = "o/33333333333333333333333333333333/leaf.h";
    const second_data = try testBinaryManifest(a, &.{leaf});
    const second_output = try std.fmt.allocPrint(a, "o/{s}/header.h", .{Cache.binToHex(try manifestOutput(second_name, second_data))});
    const second_reference = try a.dupe(u8, second_output);
    for (second_reference) |*byte| {
        if (byte.* == '/') byte.* = '\\';
    }
    const first_data = try testBinaryManifest(a, &.{second_reference});
    const first_output = try std.fmt.allocPrint(a, "o/{s}/ghostty.exe", .{Cache.binToHex(try manifestOutput(first_name, first_data))});
    try testWrite(io, tmp.dir, first_output, "exe", old);
    try testWrite(io, tmp.dir, second_output, "header", old);
    try testWrite(io, tmp.dir, leaf, "leaf", old);
    try testWrite(io, tmp.dir, "h/" ++ first_name, first_data, recent);
    try testWrite(io, tmp.dir, "h/" ++ second_name, second_data, old);
    // Newer producers keep the old dependency chain from becoming a root solely
    // through the artifact-name safeguard; only references can preserve it.
    try testWrite(io, tmp.dir, "o/44444444444444444444444444444444/ghostty.exe", "newer", newer);
    try testWrite(io, tmp.dir, "o/55555555555555555555555555555555/header.h", "newer", newer);
    try testWrite(io, tmp.dir, "o/66666666666666666666666666666666/leaf.h", "newer", newer);
    var plan = try Plan.init(io, a, tmp.dir, cutoff);
    for (plan.entries.items) |entry| try std.testing.expect(entry.keep);
    try std.testing.expectEqual(@as(usize, 0), (try plan.apply(io, tmp.dir)).entries);
}

test "cache prune preserves cached configuration outputs" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = Io.Clock.real.now(io).nanoseconds;
    const name = "11111111111111111111111111111111";
    const output = try std.fmt.allocPrint(a, "c/{s}", .{Cache.binToHex(try manifestOutput(name, "\x00"))});
    try testWrite(io, tmp.dir, output, "configuration", now);
    try testWrite(io, tmp.dir, "h/" ++ name, "\x00", now + 2 * std.time.ns_per_hour);
    var plan = try Plan.init(io, a, tmp.dir, now + std.time.ns_per_hour);
    try std.testing.expect(plan.entries.items[plan.paths.get(output).?].keep);
    try std.testing.expectEqual(@as(usize, 0), (try plan.apply(io, tmp.dir)).entries);
}

test "cache prune removes old variants while retaining the latest producer and downloads" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = Io.Clock.real.now(io).nanoseconds;
    const old = now + 10 * std.time.ns_per_min;
    const newer = now + 20 * std.time.ns_per_min;
    const name = "11111111111111111111111111111111";
    const old_dir = try std.fmt.allocPrint(a, "o/{s}", .{Cache.binToHex(try manifestOutput(name, "\x00"))});
    try testWrite(io, tmp.dir, try std.fmt.allocPrint(a, "{s}/ghostty.exe", .{old_dir}), "old", old);
    try testWrite(io, tmp.dir, "h/" ++ name, "\x00", old);
    const latest = "o/22222222222222222222222222222222/ghostty.exe";
    try testWrite(io, tmp.dir, latest, "newest", newer);
    const unmanaged = [_][]const u8{
        "p/33333333333333333333333333333333/download",
        "tmp/44444444444444444444444444444444/download",
        "z/55555555555555555555555555555555",
        "o/unrecognized-entry/ghostty.exe",
    };
    for (unmanaged) |path| try testWrite(io, tmp.dir, path, "preserve", old);
    var plan = try Plan.init(io, a, tmp.dir, now + std.time.ns_per_hour);
    try std.testing.expectEqual(@as(usize, 2), (try plan.apply(io, tmp.dir)).entries);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, old_dir, .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "h/" ++ name, .{}));
    _ = try tmp.dir.statFile(io, latest, .{});
    for (unmanaged) |path| _ = try tmp.dir.statFile(io, path, .{});
}

test "cache prune fails closed for unknown manifests and restores inspected timestamps" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const timestamp = 1700000000 * std.time.ns_per_s;
    const manifest = "h/11111111111111111111111111111111";
    const artifact = "o/22222222222222222222222222222222/ghostty.exe";
    try testWrite(io, tmp.dir, artifact, "preserve", timestamp);
    try testWrite(io, tmp.dir, manifest, "unrecognized future manifest", timestamp);
    const before = try tmp.dir.statFile(io, manifest, .{});
    try std.testing.expectError(error.UnknownManifest, Plan.init(io, a, tmp.dir, Io.Clock.real.now(io).nanoseconds));
    const after = try tmp.dir.statFile(io, manifest, .{});
    try std.testing.expectEqual(before.atime, after.atime);
    try std.testing.expectEqual(before.mtime, after.mtime);
    _ = try tmp.dir.statFile(io, artifact, .{});
}
