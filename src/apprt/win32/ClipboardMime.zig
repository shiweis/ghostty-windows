//! The Win32 clipboard rounds HGLOBAL allocations. A single registered index
//! records the byte extent of each MIME-named format we publish.
const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("win32.zig");

pub const max_parts = 128;
pub const max_bytes = 256 * 1024 * 1024;
pub const registered_first = 0xc000;
const name_limit = 255;
const registry_ceiling = 4096; // The station has 16,384 registered-format IDs.
const new_names_per_process = 64;
var registered_here: usize = 0; // All writes run on the app thread.

pub extern "user32" fn RegisterClipboardFormatW([*:0]const u16) callconv(.winapi) u32;
extern "user32" fn GetClipboardFormatNameW(u32, [*]u16, i32) callconv(.winapi) i32;
pub extern "user32" fn EnumClipboardFormats(u32) callconv(.winapi) u32;
pub extern "user32" fn GetClipboardSequenceNumber() callconv(.winapi) u32;
pub extern fn ghostty_clipboard_stream_read(u32, usize, *?*anyopaque, *usize) i32;

fn token(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_" ++ "\x60" ++ "|~", c) != null;
}
fn validToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| if (!token(c)) return false;
    return true;
}

/// Kitty lists targets separated by whitespace. Windows registered names are
/// case-insensitive and limited to 255 UTF-16 units.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > name_limit) return false;
    var fields = std.mem.splitScalar(u8, name, ';');
    const format = fields.next().?;
    const slash = std.mem.indexOfScalar(u8, format, '/') orelse return false;
    if (!validToken(format[0..slash]) or !validToken(format[slash + 1 ..])) return false;
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse return false;
        if (!validToken(field[0..equals])) return false;
        const value = field[equals + 1 ..];
        if (validToken(value)) continue;
        if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return false;
        for (value[1 .. value.len - 1]) |c| if (c < 0x21 or c > 0x7e or c == '"' or c == '\\') return false;
    }
    return true;
}

pub fn nameOf(id: u32, buffer: *[name_limit]u8) ?[]const u8 {
    var wide: [name_limit + 1]u16 = undefined;
    const len = GetClipboardFormatNameW(id, &wide, wide.len);
    if (len <= 0) return null;
    for (wide[0..@intCast(len)], buffer[0..@intCast(len)]) |ch, *out| {
        if (ch > 0x7f) return null;
        out.* = @intCast(ch);
    }
    const name = buffer[0..@intCast(len)];
    return if (validName(name)) name else null;
}

pub const Entry = struct { name: []const u8, size: usize, id: u32 = 0, data: []const u8 = "" };

pub fn indexId() !u32 {
    const id = RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("Ghostty MIME lengths v1"));
    if (id == 0) return error.ClipboardUnavailable;
    return id;
}

/// Look up existing registrations before allocating any new ones. There is
/// no Win32 lookup-by-name API that does not also create an atom.
pub fn register(entries: []Entry) !void {
    if (entries.len == 0) return;
    var capacity_used: usize = 0;
    var missing: usize = entries.len;
    var wide: [name_limit + 1]u16 = undefined;
    for (registered_first..0x10000) |n| {
        const id: u32 = @intCast(n);
        const len = GetClipboardFormatNameW(id, &wide, wide.len);
        if (len <= 0) continue;
        capacity_used += 1;
        for (entries) |*item| {
            if (item.id != 0 or item.name.len != len) continue;
            for (item.name, wide[0..@intCast(len)]) |a, b| {
                if (b > 0x7f or std.ascii.toLower(a) != std.ascii.toLower(@intCast(b))) break;
            } else {
                item.id = id;
                missing -= 1;
            }
        }
        if (missing == 0) return;
    }
    if (registered_here + missing > new_names_per_process or capacity_used + missing > registry_ceiling)
        return error.ClipboardFormatLimit;
    for (entries) |*item| {
        if (item.id != 0) continue;
        for (item.name, wide[0..item.name.len]) |c, *dst| dst.* = c;
        wide[item.name.len] = 0;
        item.id = RegisterClipboardFormatW(@ptrCast(&wide));
        if (item.id == 0) return error.ClipboardUnavailable;
        registered_here += 1;
    }
}

pub fn encode(arena: Allocator, entries: []const Entry) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("GCM1");
    try out.writer.writeInt(u16, @intCast(entries.len), .little);
    for (entries) |entry| {
        try out.writer.writeByte(@intCast(entry.name.len));
        try out.writer.writeAll(entry.name);
        try out.writer.writeInt(u64, entry.size, .little);
    }
    return out.toOwnedSlice();
}

/// Native clipboard producers can supply malformed private data. Trust this
/// index only if every bounded record is valid and the name appears once.
pub fn decode(arena: Allocator, bytes: []const u8) ![]const Entry {
    if (bytes.len < 6 or !std.mem.startsWith(u8, bytes, "GCM1")) return &.{};
    const count = std.mem.readInt(u16, bytes[4..6], .little);
    if (count > max_parts) return &.{};
    const entries = try arena.alloc(Entry, count);
    var i: usize = 6;
    for (entries, 0..) |*entry, pos| {
        if (i == bytes.len) return &.{};
        const len: usize = bytes[i];
        i += 1;
        if (bytes.len - i < len + 8) return &.{};
        const name = bytes[i..][0..len];
        i += len;
        const size = std.mem.readInt(u64, bytes[i..][0..8], .little);
        i += 8;
        if (!validName(name) or size > max_bytes or lookup(entries[0..pos], name) != null) return &.{};
        entry.* = .{ .name = try arena.dupe(u8, name), .size = @intCast(size) };
    }
    return entries;
}

pub fn lookup(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |item| if (std.ascii.eqlIgnoreCase(item.name, name)) return item;
    return null;
}

pub fn getIndex(arena: Allocator) ![]const Entry {
    const handle = w32.GetClipboardData(try indexId()) orelse return &.{};
    const n = w32.GlobalSize(handle);
    if (n == 0 or n > 6 + max_parts * (1 + name_limit + 8) + 16) return &.{};
    const ptr = w32.GlobalLock(handle) orelse return &.{};
    defer _ = w32.GlobalUnlock(handle);
    return decode(arena, ptr[0..n]);
}

/// Return the exact supplied size when known. A native HGLOBAL without a
/// logical extent defines only the bytes returned by GlobalSize.
pub fn copy(arena: Allocator, handle: *anyopaque, logical: ?usize, budget: usize) !?[]const u8 {
    const allocation = w32.GlobalSize(handle);
    const size = logical orelse allocation;
    if (size > allocation or size > budget) return error.ClipboardDataTooLarge;
    if (size == 0) return "";
    const ptr = w32.GlobalLock(handle) orelse return null;
    defer _ = w32.GlobalUnlock(handle);
    return try arena.dupe(u8, ptr[0..size]);
}

test "Windows clipboard MIME names and custom payload extent index" {
    const alloc = std.testing.allocator;
    try std.testing.expect(validName("application/vnd.example+json;charset=utf-8"));
    try std.testing.expect(!validName("a/b/c"));
    try std.testing.expect(!validName("image/png\ntext/plain"));
    try std.testing.expect(!validName("Windows application format"));
    var pool: std.heap.ArenaAllocator = .init(alloc);
    defer pool.deinit();
    const entries = [_]Entry{ .{ .name = "application/json", .size = 3 }, .{ .name = "image/jpeg", .size = 0 } };
    const encoded = try encode(pool.allocator(), &entries);
    const decoded = try decode(pool.allocator(), encoded);
    try std.testing.expectEqual(@as(usize, 3), lookup(decoded, "application/json").?.size);
    try std.testing.expectEqual(@as(usize, 0), lookup(decoded, "image/jpeg").?.size);
    try std.testing.expectEqual(@as(usize, 0), (try decode(pool.allocator(), encoded[0 .. encoded.len - 1])).len);
}
