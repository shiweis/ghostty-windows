//! Install the pinned iTerm2 Ghostty themes under portable Windows filenames.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 3 and args.len != 4) return error.InvalidArguments;
    var output = try std.Io.Dir.cwd().createDirPathOpen(init.io, args[args.len - 1], .{});
    defer output.close(init.io);

    // Cross builds can reuse Zig's unpacked and hash-verified package.
    if (args.len == 3) {
        var source = try std.Io.Dir.cwd().openDir(init.io, args[1], .{ .iterate = true });
        defer source.close(init.io);
        var iter = source.iterate();
        while (try iter.next(init.io)) |entry| {
            if (entry.kind != .file) return error.UnexpectedThemeEntry;
            const name = try portableName(alloc, entry.name);
            try source.copyFile(entry.name, output, name, init.io, .{ .replace = false });
        }
        return;
    }

    // Run the download and checksum check in the same cached build step so
    // retrying after a bad response fetches a fresh copy.
    const download = try std.process.run(alloc, init.io, .{
        .argv = &.{ "curl.exe", "--fail", "--silent", "--show-error", "--location", args[1] },
    });
    if (download.term != .exited or download.term.exited != 0) {
        std.log.err("fetching {s} failed: {s}", .{ args[1], download.stderr });
        return error.ThemeDownloadFailed;
    }
    const archive = download.stdout;
    const expected = std.mem.cutPrefix(u8, args[2], "sha256-") orelse return error.InvalidChecksum;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &hash, .{});
    var base64: [std.base64.standard.Encoder.calcSize(hash.len)]u8 = undefined;
    if (!std.mem.eql(u8, expected, std.base64.standard.Encoder.encode(&base64, &hash))) {
        std.log.err("incorrect archive checksum for {s}", .{args[1]});
        return error.ThemeChecksumMismatch;
    }

    var reader: std.Io.Reader = .fixed(archive);
    var inflate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var gunzip: std.compress.flate.Decompress = .init(&reader, .gzip, &inflate_buffer);
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var tar: std.tar.Iterator = .init(&gunzip.reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
    });
    while (try tar.next()) |entry| {
        if (entry.kind == .directory) continue;
        if (entry.kind != .file) return error.UnexpectedThemeEntry;
        const name = std.mem.cutPrefix(u8, entry.name, "ghostty/") orelse return error.InvalidThemeName;
        const portable = try portableName(alloc, name);
        const file = try output.createFile(init.io, portable, .{ .exclusive = true });
        defer file.close(init.io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(init.io, &buffer);
        try tar.streamRemaining(entry, &writer.interface);
        try writer.end();
    }
}

fn portableName(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    // For example, "Neon Raincheck: After Hours" installs as
    // "Neon Raincheck After Hours". Both copy paths reject collisions.
    const result = try std.mem.replaceOwned(u8, alloc, name, ":", "");
    if (result.len == 0 or std.mem.findAny(u8, result, "/\\<>\"|?*") != null or
        result[result.len - 1] == '.' or result[result.len - 1] == ' ') return error.InvalidThemeName;
    return result;
}
