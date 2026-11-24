const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const terminal = @import("../../terminal/main.zig");
const LimitedAllocator = @import("../../datastruct/main.zig").LimitedAllocator;
const custom = @import("ClipboardMime.zig");
const w32 = @import("win32.zig");

/// Normalize the newline convention required by CF_UNICODETEXT before the
/// shared paste encoder sees it. Windows clipboard producers conventionally
/// use CRLF, while the non-bracketed encoder turns LF into CR. Passing CRLF
/// through unchanged would therefore produce CRCR and submit an extra blank
/// line for every pasted line. Preserve lone CR and LF bytes as supplied.
fn normalizeWindowsClipboardNewlines(data: []u8) []u8 {
    var read_idx: usize = 0;
    var write_idx: usize = 0;

    while (read_idx < data.len) {
        if (data[read_idx] == '\r' and
            read_idx + 1 < data.len and
            data[read_idx + 1] == '\n')
        {
            data[write_idx] = '\n';
            read_idx += 2;
        } else {
            data[write_idx] = data[read_idx];
            read_idx += 1;
        }
        write_idx += 1;
    }

    return data[0..write_idx];
}

test "normalize Windows clipboard newlines" {
    var data = "one\r\ntwo\r\n\r\nthree\rfour\n".*;
    const normalized = normalizeWindowsClipboardNewlines(data[0..]);
    try std.testing.expectEqualStrings("one\ntwo\n\nthree\rfour\n", normalized);
}

/// CF_UNICODETEXT is supplied by another process. A malformed producer may
/// omit the terminator; only inspect complete UTF-16 units within GlobalSize.
fn boundedWindowsClipboardText(data: []align(@alignOf(u16)) const u8) ?[]const u16 {
    if (data.len < @sizeOf(u16) or data.len % @sizeOf(u16) != 0) return null;
    const text = std.mem.bytesAsSlice(u16, data);
    const end = std.mem.indexOfScalar(u16, text, 0) orelse return null;
    return text[0..end];
}

test "Windows clipboard read bounds malformed and Unicode text" {
    const testing = std.testing;
    const unterminated = [_]u16{ 'a', 'b' };
    const bytes = std.mem.sliceAsBytes(&unterminated);
    try testing.expect(boundedWindowsClipboardText(bytes) == null);
    try testing.expect(boundedWindowsClipboardText(bytes[0..3]) == null);
    try testing.expect(boundedWindowsClipboardText(bytes[0..1]) == null);
    try testing.expect(boundedWindowsClipboardText(bytes[0..0]) == null);
    const empty = [_]u16{0};
    try testing.expectEqual(@as(usize, 0), boundedWindowsClipboardText(std.mem.sliceAsBytes(&empty)).?.len);

    const unicode = std.unicode.utf8ToUtf16LeStringLiteral("one\r\n\u{4e2d}\u{1f600}");
    const text = boundedWindowsClipboardText(std.mem.sliceAsBytes(unicode[0 .. unicode.len + 1])).?;
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(testing.allocator, text);
    defer testing.allocator.free(utf8);
    try testing.expectEqualStrings("one\n\u{4e2d}\u{1f600}", normalizeWindowsClipboardNewlines(utf8));
}

const Format = enum {
    text,
    html,
    png,

    const all = std.enums.values(Format);
    fn forMime(name: []const u8) ?Format {
        if (terminal.clipboard.isTextMime(name)) return .text;
        if (std.mem.eql(u8, name, "text/html")) return .html;
        if (std.mem.eql(u8, name, "image/png")) return .png;
        return null;
    }
    fn mime(self: Format) []const u8 {
        return switch (self) {
            .text => "text/plain",
            .html => "text/html",
            .png => "image/png",
        };
    }
    fn id(self: Format) !u32 {
        const value = switch (self) {
            .text => w32.CF_UNICODETEXT,
            .html => RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("HTML Format")),
            .png => RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("PNG")),
        };
        if (value == 0) return error.ClipboardUnavailable;
        return value;
    }
    fn available(self: Format) !bool {
        if (IsClipboardFormatAvailable(try self.id()) != 0) return true;
        return switch (self) {
            .text => IsClipboardFormatAvailable(w32.CF_HDROP) != 0,
            .html => false,
            .png => IsClipboardFormatAvailable(cf_dib_v5) != 0 or IsClipboardFormatAvailable(cf_dib) != 0 or IsClipboardFormatAvailable(cf_bitmap) != 0,
        };
    }
};
const cf_bitmap = 2;
const cf_dib = 8;
const cf_dib_v5 = 17;
const image_limit = 256 * 1024 * 1024;

extern "user32" fn RegisterClipboardFormatW([*:0]const u16) callconv(.winapi) u32;
extern "user32" fn IsClipboardFormatAvailable(u32) callconv(.winapi) i32;
extern fn ghostty_clipboard_bitmap_png(u32, *anyopaque, *?*anyopaque, *usize) i32;
extern fn ghostty_clipboard_publish([*]const Part, usize) i32;
extern fn ghostty_clipboard_confirm(?w32.HWND, [*:0]const u16, [*:0]const u16, ?[*:0]const u16, i32, ?[*]const u8, i32, i32, *i32) i32;

const Part = extern struct {
    format: u32,
    bytes: [*]const u8,
    size: usize,
    fn init(format: u32, data: []const u8) Part {
        return .{ .format = format, .bytes = data.ptr, .size = data.len };
    }
};

fn validText(data: []const u8) bool {
    return std.unicode.utf8ValidateSlice(data) and std.mem.indexOfScalar(u8, data, 0) == null;
}

fn encodeHtml(arena: Allocator, fragment: []const u8) ![]const u8 {
    const header = "Version:1.0\r\nStartHTML:{d:0>10}\r\nEndHTML:{d:0>10}\r\n" ++
        "StartFragment:{d:0>10}\r\nEndFragment:{d:0>10}\r\n";
    const start = std.fmt.count(header, .{ 0, 0, 0, 0 });
    const before = "<html><body><!--StartFragment-->";
    const after = "<!--EndFragment--></body></html>";
    const begin = start + before.len;
    const end = begin + fragment.len;
    return std.fmt.allocPrint(arena, header ++ before ++ "{s}" ++ after ++ "\x00", .{
        start, end + after.len, begin, end, fragment,
    });
}

fn htmlFragment(data: []const u8) ?[]const u8 {
    var begin: ?usize = null;
    var end: ?usize = null;
    // The header ends before the context starts. Never interpret HTML text
    // as an offset, including on malformed native input.
    const header_end = std.mem.indexOfScalar(u8, data, '<') orelse data.len;
    var lines = std.mem.tokenizeAny(u8, data[0..header_end], "\r\n");
    while (lines.next()) |line| {
        const sep = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..sep];
        const field = if (std.ascii.eqlIgnoreCase(key, "StartFragment"))
            &begin
        else if (std.ascii.eqlIgnoreCase(key, "EndFragment"))
            &end
        else
            continue;
        field.* = std.fmt.parseInt(usize, std.mem.trim(u8, line[sep + 1 ..], " \t"), 10) catch return null;
    }
    const from = begin orelse return null;
    const to = end orelse return null;
    if (from > to or to > data.len or !validText(data[from..to])) return null;
    return data[from..to];
}

/// GlobalSize may include alignment padding. Stop at the declared IEND chunk.
fn pngBytes(data: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) return null;
    var pos: usize = 8;
    while (data.len - pos >= 12) {
        const len = std.mem.readInt(u32, data[pos..][0..4], .big);
        if (len > data.len - pos - 12) return null;
        const tag = data[pos + 4 ..][0..4];
        pos += 12 + @as(usize, len);
        if (std.mem.eql(u8, tag, "IEND")) return if (len == 0) data[0..pos] else null;
    }
    return null;
}

fn pngDib(arena: Allocator, data: []const u8) ![]const u8 {
    const bytes = pngBytes(data) orelse return error.InvalidClipboardImage;
    const decode = terminal.sys.decode_png orelse return error.UnsupportedClipboardFormat;
    var limit: LimitedAllocator = .init(arena, image_limit);
    const image = try decode(limit.allocator(), bytes);
    defer limit.allocator().free(image.data);
    const header: w32.BITMAPINFOHEADER = .{
        .biWidth = @intCast(image.width),
        .biHeight = -@as(i32, @intCast(image.height)), // top-down BGRA rows
        .biSizeImage = @intCast(image.data.len),
    };
    const data_offset = @sizeOf(w32.BITMAPINFOHEADER);
    const dib = try arena.alloc(u8, data_offset + image.data.len);
    @memcpy(dib[0..data_offset], std.mem.asBytes(&header));
    const pixels = dib[data_offset..];
    for (0..image.data.len / 4) |i| {
        const rgba = image.data[i * 4 ..][0..4];
        pixels[i * 4 ..][0..4].* = .{ rgba[2], rgba[1], rgba[0], rgba[3] };
    }
    return dib;
}

pub fn supported(contents: []const apprt.ClipboardContent) bool {
    if (contents.len > custom.max_parts) return false;
    var total: usize = 0;
    for (contents, 0..) |c, i| {
        if (c.data.len > custom.max_bytes - total) return false;
        total += c.data.len;
        const format = Format.forMime(c.mime);
        if (format) |f| {
            switch (f) {
                .text, .html => if (!validText(c.data)) return false,
                .png => if (pngBytes(c.data) == null) return false,
            }
        } else if (!custom.validName(c.mime)) return false;
        // Native names are case-insensitive. Reject conflicting aliases
        // before any native transaction can replace the previous clipboard.
        for (contents[0..i]) |previous| {
            const same = if (format) |f| Format.forMime(previous.mime) == f else std.ascii.eqlIgnoreCase(previous.mime, c.mime);
            if (same and !std.mem.eql(u8, previous.data, c.data)) return false;
        }
    }
    return true;
}

pub fn write(alloc: Allocator, contents: []const apprt.ClipboardContent) !void {
    if (!supported(contents)) return error.UnsupportedClipboardFormat;
    var pool: std.heap.ArenaAllocator = .init(alloc);
    defer pool.deinit();
    const arena = pool.allocator();
    var parts: std.ArrayList(Part) = .empty;
    var entries: std.ArrayList(custom.Entry) = .empty;
    var seen: std.EnumSet(Format) = .empty;
    for (contents) |c| {
        const format = Format.forMime(c.mime) orelse {
            if (custom.lookup(entries.items, c.mime) == null)
                try entries.append(arena, .{ .name = c.mime, .size = c.data.len, .data = c.data });
            continue;
        };
        if (seen.contains(format)) continue;
        seen.insert(format);
        const data: []const u8 = switch (format) {
            .text => text: {
                const wide = try std.unicode.utf8ToUtf16LeAllocZ(arena, c.data);
                break :text std.mem.sliceAsBytes(wide[0 .. wide.len + 1]);
            },
            .html => try encodeHtml(arena, c.data),
            .png => c.data,
        };
        try parts.append(arena, .init(try format.id(), data));
        if (format == .png)
            try parts.append(arena, .init(cf_dib, try pngDib(arena, data)));
    }
    if (entries.items.len > 0) {
        try custom.register(entries.items);
        for (entries.items) |entry| try parts.append(arena, .init(entry.id, entry.data));
        try parts.append(arena, .init(try custom.indexId(), try custom.encode(arena, entries.items)));
    }
    if (ghostty_clipboard_publish(parts.items.ptr, parts.items.len) < 0) return error.ClipboardWriteFailed;
}

pub const Read = struct {
    contents: std.ArrayList(terminal.clipboard.Content) = .empty,
    available: std.ArrayList([]const u8) = .empty,
};

/// Shared by all panes and windows in this application. Selection changes
/// never register Windows formats or publish data to the system clipboard.
pub const Selection = struct {
    pool: ?std.heap.ArenaAllocator = null,
    contents: []const terminal.clipboard.Content = &.{},

    pub fn deinit(self: *Selection) void {
        if (self.pool) |*pool| pool.deinit();
        self.* = .{};
    }

    pub fn supported(parts: []const apprt.ClipboardContent) bool {
        if (parts.len > custom.max_parts) return false;
        var total: usize = 0;
        for (parts, 0..) |part, i| {
            if (!terminal.clipboard.isTextMime(part.mime) and !custom.validName(part.mime)) return false;
            if (part.data.len > custom.max_bytes - total) return false;
            total += part.data.len;
            for (parts[0..i]) |prev| {
                if (std.mem.eql(u8, canonicalMime(prev.mime), canonicalMime(part.mime)) and
                    !std.mem.eql(u8, prev.data, part.data)) return false;
            }
        }
        return true;
    }

    fn canonicalMime(name: []const u8) []const u8 {
        return if (terminal.clipboard.isTextMime(name)) "text/plain" else name;
    }

    pub fn write(self: *Selection, alloc: Allocator, parts: []const apprt.ClipboardContent) !void {
        if (!Selection.supported(parts)) return error.UnsupportedClipboardFormat;
        var pool: std.heap.ArenaAllocator = .init(alloc);
        errdefer pool.deinit();
        const arena = pool.allocator();
        var contents: std.ArrayList(terminal.clipboard.Content) = .empty;
        try contents.ensureTotalCapacity(arena, parts.len);
        for (parts) |part| {
            const mime = canonicalMime(part.mime);
            for (contents.items) |prev| {
                if (std.mem.eql(u8, prev.mime, mime)) break;
            } else contents.appendAssumeCapacity(.{
                .mime = try arena.dupe(u8, mime),
                .data = try arena.dupe(u8, part.data),
            });
        }
        self.deinit();
        self.* = .{ .pool = pool, .contents = contents.items };
    }

    /// A second pane can replace the selection while a permission dialog is
    /// open. Return owned copies of the requested representations.
    pub fn read(self: *const Selection, arena: Allocator, state: apprt.ClipboardRequest) !Read {
        var result: Read = .{};
        for (self.contents) |part| {
            const mime = try arena.dupe(u8, part.mime);
            try result.available.append(arena, mime);
            const text = terminal.clipboard.isTextMime(mime);
            switch (state) {
                .list => continue,
                .paste, .osc_52_read => if (!text or result.contents.items.len != 0) continue,
                .kitty_read => |req| {
                    for (req.mimes) |requested| {
                        if (std.mem.eql(u8, requested, mime) or
                            (text and terminal.clipboard.isTextMime(requested))) break;
                    } else continue;
                },
                .osc_52_write, .kitty_write => unreachable,
            }
            if (state == .paste and !validText(part.data)) continue;
            const data = try arena.dupe(u8, part.data);
            try result.contents.append(arena, .{
                .mime = mime,
                .data = if (state == .paste) normalizeWindowsClipboardNewlines(data) else data,
            });
        }
        return result;
    }
};

test {
    _ = @import("SelectionClipboard_test.zig");
}

/// The caller owns the arena. Its contents remain valid after closing the
/// clipboard, including while a permission prompt pumps messages.
pub fn read(arena: Allocator, owner: ?w32.HWND, state: apprt.ClipboardRequest, comptime paths: anytype) !Read {
    var result: Read = .{};
    var foreign: std.ArrayList(custom.Entry) = .empty;
    var remaining: usize = custom.max_bytes;
    const sequence = snapshot: {
        if (w32.OpenClipboard(owner) == 0) return error.ClipboardUnavailable;
        defer _ = w32.CloseClipboard();
        for (Format.all) |format| {
            if (!try format.available()) continue;
            try result.available.append(arena, format.mime());
            const wanted = switch (state) {
                .list => false,
                .kitty_read => |req| wanted: {
                    for (req.mimes) |m| if (Format.forMime(m) == format) break :wanted true;
                    break :wanted false;
                },
                else => format == .text,
            };
            if (!wanted) continue;
            const data = try readData(arena, format, state != .kitty_read, remaining, paths) orelse continue;
            if (data.len > remaining) return error.ClipboardDataTooLarge;
            remaining -= data.len;
            try result.contents.append(arena, .{ .mime = format.mime(), .data = data });
        }
        const ordinary = state == .paste or state == .osc_52_read;
        if (ordinary and result.contents.items.len > 0) return result;
        const requested_mimes: []const [:0]const u8 = switch (state) {
            .kitty_read => |req| req.mimes,
            .list => &.{},
            else => &.{ "text/plain", "text/plain;charset=utf-8" },
        };
        const index: []const custom.Entry = if (requested_mimes.len > 0) try custom.getIndex(arena) else &.{};
        var id: u32 = 0;
        for (0..256) |_| {
            id = custom.EnumClipboardFormats(id);
            if (id == 0) break;
            if (id < custom.registered_first) continue;
            var buffer: [255]u8 = undefined;
            const found = custom.nameOf(id, &buffer) orelse continue;
            const stored = custom.lookup(index, found);
            const name = try arena.dupe(u8, if (stored) |s| s.name else found);
            const listed = for (result.available.items) |known| {
                if (std.ascii.eqlIgnoreCase(known, name)) break true;
            } else false;
            if (!listed) try result.available.append(arena, name);
            for (requested_mimes) |requested| {
                if (!std.ascii.eqlIgnoreCase(name, requested)) continue;
                const served = for (result.contents.items) |c| {
                    if (std.mem.eql(u8, c.mime, requested)) break true;
                } else false;
                if (served) continue;
                if (stored) |entry| {
                    const handle = w32.GetClipboardData(id) orelse continue;
                    const data = try custom.copy(arena, handle, entry.size, remaining) orelse continue;
                    remaining -= data.len;
                    try result.contents.append(arena, .{ .mime = requested, .data = data });
                } else try foreign.append(arena, .{ .id = id, .name = requested, .size = 0 });
            }
        }
        break :snapshot custom.GetClipboardSequenceNumber();
    };
    // OLE may need to open the clipboard. Drop our lock first and verify
    // the snapshot still belongs to the same clipboard generation.
    for (foreign.items) |entry| {
        if (sequence != custom.GetClipboardSequenceNumber()) return error.ClipboardUnavailable;
        var memory: ?*anyopaque = null;
        var size: usize = 0;
        const data = native: {
            if (custom.ghostty_clipboard_stream_read(entry.id, remaining, &memory, &size) >= 0) {
                const handle = memory orelse continue;
                defer _ = w32.GlobalFree(handle);
                break :native try custom.copy(arena, handle, size, remaining) orelse continue;
            }
            if (w32.OpenClipboard(owner) == 0) return error.ClipboardUnavailable;
            defer _ = w32.CloseClipboard();
            const handle = w32.GetClipboardData(entry.id) orelse continue;
            break :native try custom.copy(arena, handle, null, remaining) orelse continue;
        };
        remaining -= data.len;
        try result.contents.append(arena, .{ .mime = entry.name, .data = data });
    }
    if (foreign.items.len > 0 and sequence != custom.GetClipboardSequenceNumber()) return error.ClipboardUnavailable;
    if (state == .paste or state == .osc_52_read) {
        for (result.contents.items) |*content| {
            const text = std.mem.sliceTo(content.data, 0);
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidClipboardText;
            content.data = normalizeWindowsClipboardNewlines(try arena.dupe(u8, text));
        }
    }
    return result;
}

fn readData(arena: Allocator, format: Format, normalize: bool, budget: usize, comptime paths: anytype) !?[]const u8 {
    if (format == .text) {
        if (w32.GetClipboardData(w32.CF_HDROP)) |drop| {
            if (try paths(arena, @as(w32.HDROP, @ptrCast(drop)))) |data| return data;
        }
    }
    var owned: ?*anyopaque = null;
    defer if (owned) |mem| {
        _ = w32.GlobalFree(mem);
    };
    var length: usize = 0;
    const mem = w32.GetClipboardData(try format.id()) orelse fallback: {
        if (format != .png) return null;
        for ([_]u32{ cf_dib_v5, cf_dib, cf_bitmap }) |id| {
            const bitmap = w32.GetClipboardData(id) orelse continue;
            if (ghostty_clipboard_bitmap_png(id, bitmap, &owned, &length) >= 0)
                break :fallback owned orelse return null;
        }
        return null;
    };
    const size = w32.GlobalSize(mem);
    if (size == 0 or length > size) return null;
    if ((if (length > 0) length else size) > budget) return error.ClipboardDataTooLarge;
    const ptr = w32.GlobalLock(mem) orelse return null;
    defer _ = w32.GlobalUnlock(mem);
    const data = ptr[0..if (length > 0) length else size];
    return switch (format) {
        .text => text: {
            const wide = boundedWindowsClipboardText(@alignCast(data)) orelse return null;
            const utf8 = std.unicode.utf16LeToUtf8Alloc(arena, wide) catch return null;
            break :text if (normalize) normalizeWindowsClipboardNewlines(utf8) else utf8;
        },
        .html => try arena.dupe(u8, htmlFragment(data) orelse return null),
        .png => try arena.dupe(u8, pngBytes(data) orelse return null),
    };
}

pub const Decision = struct {
    button: enum { allow, deny, cancel } = .cancel,
    remember: bool = false,
};

/// Render names and text as inert, bounded UI text. Show line breaks and
/// terminal control characters explicitly so they cannot hide a command.
fn preview(out: *std.Io.Writer, text: []const u8, limit: usize) !void {
    const view = std.unicode.Utf8View.init(text) catch {
        try out.writeAll("(binary data)");
        return;
    };
    var iter = view.iterator();
    var count: usize = 0;
    while (iter.nextCodepointSlice()) |bytes| : (count += 1) {
        if (count == limit) {
            try out.writeAll("...");
            break;
        }
        const cp = std.unicode.utf8Decode(bytes) catch unreachable;
        switch (cp) {
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            0...8, 11...12, 14...31, 127...159, 0x202a...0x202e, 0x2066...0x2069 => try out.print("\\u{{{x}}}", .{cp}),
            else => try out.writeAll(bytes),
        }
    }
}

fn details(alloc: Allocator, state: apprt.ClipboardRequest, contents: anytype) ![:0]u16 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    const out = &buf.writer;
    const name: []const u8 = switch (state) {
        inline .kitty_read, .kitty_write => |req| req.name,
        else => "",
    };
    if (name.len > 0) {
        try out.writeAll("Requested by ");
        try preview(out, name, 80);
        try out.writeAll("\n\n");
    }
    if (contents.len == 0) try out.writeAll("(empty)");
    for (contents, 0..) |c, i| {
        if (i != 0) try out.writeAll("\n\n");
        if (i >= 4) {
            try out.print("and {d} more formats", .{contents.len - i});
            break;
        }
        try preview(out, c.mime, 80);
        try out.print(" ({d} bytes)\n", .{c.data.len});
        if (Format.forMime(c.mime) == .png and c.data.len >= 24) {
            try out.print("{d} x {d} pixels", .{
                std.mem.readInt(u32, c.data[16..20], .big),
                std.mem.readInt(u32, c.data[20..24], .big),
            });
        } else if (Format.forMime(c.mime) == .text or
            std.mem.startsWith(u8, c.mime, "text/") or
            std.mem.eql(u8, c.mime, "application/json") or std.mem.endsWith(u8, c.mime, "+json") or
            std.mem.eql(u8, c.mime, "application/xml") or std.mem.endsWith(u8, c.mime, "+xml"))
        {
            try preview(out, c.data, 240);
        } else {
            for (c.data[0..@min(16, c.data.len)], 0..) |byte, pos| {
                if (pos != 0) try out.writeByte(' ');
                try out.print("{x:0>2}", .{byte});
            }
            if (c.data.len > 16) try out.writeAll(" ...");
        }
    }
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, buf.written());
}

fn extraFormats(alloc: Allocator, contents: anytype) !?[:0]u16 {
    if (contents.len <= 4) return null;
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    for (contents[4..], 0..) |c, i| {
        if (i > 0) try buf.writer.writeByte('\n');
        try preview(&buf.writer, c.mime, 255);
        try buf.writer.print(" ({d} bytes)", .{c.data.len});
    }
    return try std.unicode.utf8ToUtf16LeAllocZ(alloc, buf.written());
}

const Thumbnail = struct {
    bgra: [64 * 64 * 4]u8 = undefined,
    width: u32 = 0,
    height: u32 = 0,

    fn fromImage(self: *@This(), alloc: Allocator, mime: []const u8, bytes: []const u8) void {
        var bounded: LimitedAllocator = .init(alloc, image_limit);
        const image = if (std.ascii.eqlIgnoreCase(mime, "image/jpeg")) jpeg: {
            const jpg = @import("wuffs").jpeg.decode(bounded.allocator(), bytes) catch return;
            break :jpeg terminal.sys.Image{ .width = jpg.width, .height = jpg.height, .data = jpg.data };
        } else png: {
            const decode = terminal.sys.decode_png orelse return;
            break :png decode(bounded.allocator(), bytes) catch return;
        };
        defer bounded.allocator().free(image.data);
        if (image.width == 0 or image.height == 0) return;
        const scale = @max(@max(image.width, image.height), 64);
        self.width = @intCast(@max(1, @as(u64, image.width) * 64 / scale));
        self.height = @intCast(@max(1, @as(u64, image.height) * 64 / scale));
        for (0..self.height) |y| for (0..self.width) |x| {
            const src = ((self.height - y - 1) * image.height / self.height * image.width +
                x * image.width / self.width) * 4;
            const pixel = image.data[src..][0..4];
            const at = (y * self.width + x) * 4;
            inline for (0..3) |i| self.bgra[at + i] = @intCast(@as(u16, pixel[2 - i]) * pixel[3] / 255);
            self.bgra[at + 3] = pixel[3];
        };
    }
};

pub fn confirm(alloc: Allocator, owner: ?w32.HWND, state: apprt.ClipboardRequest, contents: anytype) Decision {
    const text = details(alloc, state, contents) catch return .{};
    defer alloc.free(text);
    const more = extraFormats(alloc, contents) catch return .{};
    defer if (more) |buf| alloc.free(buf);
    const selection = switch (state) {
        inline .kitty_read, .kitty_write => |req| req.location != .standard,
        inline else => |location| location != .standard,
    };
    const title: [*:0]const u16 = switch (state) {
        .paste => std.unicode.utf8ToUtf16LeStringLiteral("Paste text that could execute commands?"),
        .osc_52_read, .kitty_read => if (selection)
            std.unicode.utf8ToUtf16LeStringLiteral("Allow this application to read the Ghostty selection?")
        else
            std.unicode.utf8ToUtf16LeStringLiteral("Allow this application to read the clipboard?"),
        .osc_52_write, .kitty_write => if (selection)
            std.unicode.utf8ToUtf16LeStringLiteral("Allow this application to replace the Ghostty selection?")
        else
            std.unicode.utf8ToUtf16LeStringLiteral("Allow this application to replace the clipboard?"),
        .list => unreachable,
    };
    const remember_kind: i32 = switch (state) {
        .paste, .list => 0,
        .osc_52_read, .osc_52_write => 2,
        inline .kitty_read, .kitty_write => |req| @intFromBool(req.pw.len > 0),
    };
    var image: Thumbnail = .{};
    for (contents) |c| {
        if (Format.forMime(c.mime) == .png or std.ascii.eqlIgnoreCase(c.mime, "image/jpeg")) {
            image.fromImage(alloc, c.mime, c.data);
            break;
        }
    }
    var checked: i32 = 0;
    const button = ghostty_clipboard_confirm(owner, title, text, if (more) |buf| buf.ptr else null, remember_kind, if (image.width > 0) &image.bgra else null, @intCast(image.width), @intCast(image.height), &checked);
    return .{
        .button = switch (button) {
            w32.IDYES => .allow,
            w32.IDNO => .deny,
            else => .cancel,
        },
        .remember = remember_kind != 0 and checked != 0 and button != w32.IDCANCEL,
    };
}

test "Windows clipboard CF_HTML offsets and bounds" {
    const alloc = std.testing.allocator;
    const fragment = "<b>\u{4e2d}\u{1f388}</b>";
    const html = try encodeHtml(alloc, fragment);
    defer alloc.free(html);
    try std.testing.expectEqualStrings(fragment, htmlFragment(html).?);
    try std.testing.expect(htmlFragment("StartFragment:80\r\nEndFragment:2\r\n<body>x</body>") == null);
    try std.testing.expect(htmlFragment("StartFragment:80\r\nEndFragment:90\r\n<body>x</body>") == null);
}

test "Windows clipboard preview escapes controls and truncates by codepoint" {
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try preview(&text.writer, "A\n\x1b\u{202e}\u{4e2d}Z", 5);
    try std.testing.expectEqualStrings("A\\n\\u{1b}\\u{202e}\u{4e2d}...", text.written());
}

extern "user32" fn GetProcessWindowStation() callconv(.winapi) ?*anyopaque;
extern "user32" fn GetThreadDesktop(u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetUserObjectInformationW(*anyopaque, i32, *anyopaque, u32, *u32) callconv(.winapi) i32;

pub fn privateTestStation() bool {
    const station = GetProcessWindowStation() orelse return false;
    var flags: extern struct { inherit: i32, reserved: i32, flags: u32 } = undefined;
    var length: u32 = 0;
    if (GetUserObjectInformationW(station, 1, &flags, @sizeOf(@TypeOf(flags)), &length) == 0 or
        flags.flags & 1 != 0) return false; // WSF_VISIBLE: the interactive station
    const desktop = GetThreadDesktop(w32.GetCurrentThreadId()) orelse return false;
    var name: [256]u16 = undefined;
    if (GetUserObjectInformationW(desktop, 2, &name, @sizeOf(@TypeOf(name)), &length) == 0) return false;
    if (length < 2 or length > @sizeOf(@TypeOf(name))) return false;
    return std.mem.startsWith(u16, name[0 .. length / 2 - 1], std.unicode.utf8ToUtf16LeStringLiteral("GhosttyClipboardTest-"));
}

test "Windows clipboard private station native formats and permission decisions" {
    if (!privateTestStation()) return error.SkipZigTest;
    const testing = std.testing;
    const png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x0d\x49\x44\x41\x54\x78\x9c\x63\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99\x3d\x1d\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
    const parts: []const apprt.ClipboardContent = &.{
        .{ .mime = "text/plain", .data = "mixed \u{1f600}" },
        .{ .mime = "text/html", .data = "<b>mixed \u{1f600}</b>" },
        .{ .mime = "image/png", .data = png },
    };
    const noPaths = struct {
        fn read(_: Allocator, _: w32.HDROP) error{}!?[]u8 {
            return null;
        }
    };
    try write(testing.allocator, parts);
    try testing.expectError(error.UnsupportedClipboardFormat, write(testing.allocator, &.{
        .{ .mime = "text/plain", .data = "replace" }, .{ .mime = "text/html", .data = "invalid\x00html" },
    }));
    var pool: std.heap.ArenaAllocator = .init(testing.allocator);
    defer pool.deinit();
    const listed = try read(pool.allocator(), null, .{ .list = .standard }, noPaths.read);
    try testing.expectEqual(@as(usize, 0), listed.contents.items.len);
    try testing.expectEqual(@as(usize, 3), listed.available.items.len);
    var req: apprt.ClipboardRequest.KittyRead = undefined;
    req.mimes = &.{ "text/plain", "text/html", "image/png" };
    req.location = .standard;
    req.pw = "scoped test grant";
    req.name = "clipboard test";
    const result = try read(pool.allocator(), null, .{ .kitty_read = &req }, noPaths.read);
    try testing.expectEqual(parts.len, result.contents.items.len);
    for (parts, result.contents.items) |expected, actual| {
        try testing.expectEqualStrings(expected.mime, actual.mime);
        try testing.expectEqualSlices(u8, expected.data, actual.data);
    }
    std.debug.print("\nNative clipboard published text, CF_HTML and PNG, and rejected an invalid replacement.\n", .{});
    // Feed the native target listing to mode 5522 and serve the requested
    // HTML from this clipboard using the one-time password from the wire.
    const Stream = terminal.TerminalStream;
    const Handler = @FieldType(Stream, "handler");
    const Session = struct {
        var output: std.ArrayList(u8) = .empty;
        var approve_and_remember = false;
        fn writePty(_: *Handler, bytes: []const u8) void {
            output.appendSlice(std.testing.allocator, bytes) catch unreachable;
        }
        fn readHtml(_: *Handler, r: terminal.clipboard.Read) void {
            const remember = approve_and_remember and r.can_remember;
            if (!r.granted and !remember) return r.reply(.denied);
            approve_and_remember = false;
            if (r.mimes.len != 1 or !std.mem.eql(u8, r.mimes[0], "text/html")) return r.reply(.unsupported);
            var temp: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer temp.deinit();
            var html: apprt.ClipboardRequest.KittyRead = undefined;
            html.mimes = &.{"text/html"};
            const native = read(temp.allocator(), null, .{ .kitty_read = &html }, noPaths.read) catch return r.reply(.io_error);
            r.reply(.{ .success = .{ .contents = native.contents.items, .remember = remember } });
        }
    };
    defer Session.output.deinit(testing.allocator);
    var term: terminal.Terminal = try .init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer term.deinit(testing.allocator);
    var stream: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&term) });
    defer stream.deinit();
    stream.handler.effects.write_pty = &Session.writePty;
    stream.handler.effects.clipboard_read = &Session.readHtml;
    stream.nextSlice("\x1b[?5522h");
    var offered: [3]terminal.clipboard.Content = undefined;
    for (listed.available.items, &offered) |mime, *c| c.* = .{ .mime = mime, .data = "" };
    try testing.expect(try stream.handler.paste(.{ .contents = .{ .memory = &offered } }));
    const prefix = "\x1b]5522;type=read:status=OK:pw=";
    try testing.expect(std.mem.startsWith(u8, Session.output.items, prefix));
    const end = std.mem.indexOfPos(u8, Session.output.items, prefix.len, "\x1b\\").?;
    var scratch: [128]u8 = undefined;
    const followup = try std.mem.print(&scratch, "\x1b]5522;type=read:pw={s}:name=UGFzdGU=;dGV4dC9odG1s\x1b\\", .{Session.output.items[prefix.len..end]});
    Session.output.clearRetainingCapacity();
    stream.nextSlice(followup);
    var encoded: [128]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, Session.output.items, std.base64.standard.Encoder.encode(&encoded, parts[1].data)) != null);
    Session.output.clearRetainingCapacity();
    stream.nextSlice(followup);
    try testing.expect(std.mem.indexOf(u8, Session.output.items, "status=EPERM") != null);

    std.debug.print("Mode 5522 listed native targets and authorized one read.\n", .{});
    // Read the native DIB as an independent image consumer would.
    {
        try testing.expect(w32.OpenClipboard(null) != 0);
        defer _ = w32.CloseClipboard();
        const bitmap = w32.GetClipboardData(cf_dib) orelse return error.TestUnexpectedResult;
        var converted: ?*anyopaque = null;
        var n: usize = 0;
        try testing.expect(ghostty_clipboard_bitmap_png(cf_dib, bitmap, &converted, &n) >= 0);
        defer _ = w32.GlobalFree(converted.?);
        const bytes = w32.GlobalLock(converted.?) orelse return error.TestUnexpectedResult;
        defer _ = w32.GlobalUnlock(converted.?);
        try testing.expect(n <= w32.GlobalSize(converted.?));
        const decoded = try terminal.sys.decode_png.?(testing.allocator, bytes[0..n]);
        defer testing.allocator.free(decoded.data);
        try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, decoded.data);
    }
    std.debug.print("Native bitmap decoded correctly. Checking permission dialogs.\n", .{});
    // The isolated driver responds to these dialogs and checks their captions.
    const request: apprt.ClipboardRequest = .{ .kitty_read = &req };
    const grant = confirm(testing.allocator, null, request, parts);
    try testing.expect(grant.button == .allow and grant.remember);
    // Apply the actual checkbox decision to a password-bearing request.
    // Its second read succeeds after the one-shot UI approval is consumed.
    const persistent = "\x1b]5522;type=read:pw=c2NvcGVkIHRlc3QgZ3JhbnQ=:name=UGFzdGU=;dGV4dC9odG1s\x1b\\";
    Session.approve_and_remember = grant.remember;
    stream.nextSlice(persistent);
    try testing.expect(!Session.approve_and_remember);
    Session.output.clearRetainingCapacity();
    stream.nextSlice(persistent);
    try testing.expect(std.mem.indexOf(u8, Session.output.items, "status=DATA") != null);
    const deny = confirm(testing.allocator, null, request, parts);
    try testing.expect(deny.button == .deny and !deny.remember);
    const cancel = confirm(testing.allocator, null, request, parts);
    try testing.expect(cancel.button == .cancel and !cancel.remember);
}

extern fn ghostty_test_clipboard_stream(u32, [*]const u8, u32) i32;
extern fn ghostty_test_clipboard_stream_close() void;

test "Windows clipboard private station preserves arbitrary native MIME and exact byte lengths" {
    if (!privateTestStation()) return error.SkipZigTest;
    const t = std.testing;
    const noPaths = struct {
        fn read(_: Allocator, _: w32.HDROP) error{}!?[]u8 {
            return null;
        }
    };
    var pool: std.heap.ArenaAllocator = .init(t.allocator);
    defer pool.deinit();
    const a = pool.allocator();
    const base64 = "/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYwLjMxLjEwMgD/2wBDAAgEBAQEBAUFBQUFBQYGBgYGBgYGBgYGBgYHBwcICAgHBwcGBgcHCAgICAkJCQgICAgJCQoKCgwMCwsODg4RERT/xABMAAEBAAAAAAAAAAAAAAAAAAAABgEBAQAAAAAAAAAAAAAAAAAABgcQAQAAAAAAAAAAAAAAAAAAAAARAQAAAAAAAAAAAAAAAAAAAAD/wAARCAAQABADASIAAhEAAxEA/9oADAMBAAIRAxEAPwCLAFF/f//Z";
    const jpeg = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(base64));
    try std.base64.standard.Decoder.decode(jpeg, base64);
    const parts = [_]apprt.ClipboardContent{
        .{ .mime = "application/json", .data = "{\"id\":1}" },
        .{ .mime = "image/jpeg", .data = try a.dupeSentinel(u8, jpeg, 0) },
        .{ .mime = "application/x-ghostty-binary", .data = "\x00\xfe\x00\x00\x00" },
        .{ .mime = "application/x-ghostty-empty", .data = "" },
    };
    try write(a, &parts);
    var jpeg_preview: Thumbnail = .{};
    jpeg_preview.fromImage(a, "image/jpeg", jpeg);
    try t.expect(jpeg_preview.width == 16 and jpeg_preview.height == 16);

    var req: apprt.ClipboardRequest.KittyRead = undefined;
    req.mimes = &.{ parts[0].mime, parts[1].mime, parts[2].mime, parts[3].mime };
    const listed = try read(a, null, .{ .list = .standard }, noPaths.read);
    try t.expect(listed.contents.items.len == 0);
    const got = try read(a, null, .{ .kitty_read = &req }, noPaths.read);
    try t.expectEqual(parts.len, got.contents.items.len);
    for (parts) |p| {
        for (listed.available.items) |name| {
            if (std.mem.eql(u8, name, p.mime)) break;
        } else return error.MissingClipboardMime;
        for (got.contents.items) |c| {
            if (std.mem.eql(u8, c.mime, p.mime)) {
                try t.expectEqualSlices(u8, p.data, c.data);
                break;
            }
        } else return error.MissingClipboardMime;
    }
    {
        try t.expect(w32.OpenClipboard(null) != 0);
        defer _ = w32.CloseClipboard();
        const raw = w32.GetClipboardData(RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("image/jpeg"))) orelse return error.MissingClipboardMime;
        const data = w32.GlobalLock(raw) orelse return error.TestUnexpectedResult;
        defer _ = w32.GlobalUnlock(raw);
        try t.expect(w32.GlobalSize(raw) >= jpeg.len);
        try t.expectEqualSlices(u8, jpeg, data[0..jpeg.len]);
    }
    // Refuse an unrepresentable value and a batch beyond the registration
    // budget without replacing any previous format.
    try t.expectError(error.UnsupportedClipboardFormat, write(a, &.{
        parts[0], .{ .mime = "bad mime", .data = "bad" },
    }));
    var flood: [65]apprt.ClipboardContent = undefined;
    for (&flood, 0..) |*p, i| {
        p.* = .{ .mime = try std.fmt.allocPrintSentinel(a, "application/x-ghostty-budget-{d}", .{i}, 0), .data = "x" };
    }
    try t.expectError(error.ClipboardFormatLimit, write(a, &flood));
    const after = try read(a, null, .{ .kitty_read = &req }, noPaths.read);
    try t.expectEqual(parts.len, after.contents.items.len);

    // Another native producer can publish an IStream with an exact length.
    // It has no Ghostty manifest and the trailing zeroes are significant.
    const foreign_name = "application/x-ghostty-foreign";
    const foreign = "\xa1\x00\x00";
    const id = RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral(foreign_name));
    const published = ghostty_test_clipboard_stream(id, foreign.ptr, foreign.len);
    if (published < 0) {
        std.debug.print("Foreign clipboard producer HRESULT 0x{x}\n", .{@as(u32, @bitCast(published))});
        return error.ClipboardWriteFailed;
    }
    defer ghostty_test_clipboard_stream_close();
    req.mimes = &.{foreign_name};
    const exact = try read(a, null, .{ .kitty_read = &req }, noPaths.read);
    try t.expectEqual(@as(usize, 1), exact.contents.items.len);
    try t.expectEqualSlices(u8, foreign, exact.contents.items[0].data);
}
