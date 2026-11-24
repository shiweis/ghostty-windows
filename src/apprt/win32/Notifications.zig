//! Native desktop balloons use one tray ID per live delivery. Explorer may
//! queue callbacks after removal, so IDs are never recycled in this process.
const Notifications = @This();
const std = @import("std");
const w32 = @import("win32.zig");
const Allocator = std.mem.Allocator;
pub const callback = w32.WM_APP + 3;
pub const first_id: u32 = 32; // Lower IDs belong to window timers and the updater.
const per_surface_limit = 64;

const Entry = struct { id: u32, surface: u64, hash: u64 };
entries: std.ArrayList(Entry) = .empty,
next_id: u64 = first_id,
notify: @TypeOf(&w32.Shell_NotifyIconW) = w32.Shell_NotifyIconW,

pub fn send(self: *Notifications, alloc: Allocator, sink: Shell, surface: u64, focused: bool, title: []const u8, body: []const u8) !void {
    if (self.next_id > std.math.maxInt(u32)) return error.NotificationIdsExhausted;
    try self.entries.ensureUnusedCapacity(alloc, 1);
    // Hash the two fields separately so ("ab", "c") and ("a", "bc") differ.
    const hash = std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, title), body);
    var count: usize = 0;
    var oldest: ?u32 = null;
    var duplicate: ?u32 = null;
    for (self.entries.items) |entry| {
        if (entry.surface != surface) continue;
        count += 1;
        if (oldest == null) oldest = entry.id;
        if (entry.hash == hash) duplicate = entry.id;
    }
    const id: u32 = @intCast(self.next_id);
    self.next_id += 1;
    self.entries.appendAssumeCapacity(.{ .id = id, .surface = surface, .hash = hash });
    if (!sink.show(id, focused, title, body)) {
        _ = self.dismiss(sink, id);
        return error.NotificationUnavailable;
    }
    // Preserve the previous delivery if Explorer rejected its replacement.
    if (duplicate orelse (if (count >= per_surface_limit) oldest else null)) |previous|
        _ = self.dismiss(sink, previous);
}

fn removeAt(self: *Notifications, sink: Shell, idx: usize) void {
    const entry = self.entries.orderedRemove(idx);
    sink.remove(entry.id);
}

/// Both dismissals and clicks consume a delivery once. The caller resolves
/// the returned surface ID against the live core before taking focus.
pub fn dismiss(self: *Notifications, sink: Shell, id: usize) ?u64 {
    for (self.entries.items, 0..) |entry, i| {
        if (entry.id != id) continue;
        const owner = entry.surface;
        self.removeAt(sink, i);
        return owner;
    }
    return null;
}

pub fn clear(self: *Notifications, sink: Shell, surface: u64) void {
    while (true) {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.surface == surface) {
                self.removeAt(sink, i);
                break;
            }
        } else return;
    }
}

pub fn deinit(self: *Notifications, alloc: Allocator, sink: Shell) void {
    while (self.entries.items.len != 0) self.removeAt(sink, self.entries.items.len - 1);
    self.entries.deinit(alloc);
    self.entries = .empty;
}

/// Leave room for the terminator and never split a UTF-16 surrogate pair.
fn copyText(dest: []u16, text: []const u8) void {
    dest[0] = 0;
    const view = std.unicode.Utf8View.init(text) catch return;
    var iter = view.iterator();
    var len: usize = 0;
    while (iter.nextCodepointSlice()) |cp| {
        const units: usize = if (cp.len == 4) 2 else 1;
        if (len + units >= dest.len) break;
        len += std.unicode.utf8ToUtf16Le(dest[len..], cp) catch unreachable;
    }
    dest[len] = 0;
}

pub const Shell = struct {
    hwnd: ?w32.HWND,
    instance: w32.HINSTANCE,
    notify: @TypeOf(&w32.Shell_NotifyIconW),

    fn data(self: @This(), id: u32) w32.NOTIFYICONDATAW {
        var info = std.mem.zeroes(w32.NOTIFYICONDATAW);
        info.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
        info.hWnd = self.hwnd;
        info.uID = id;
        return info;
    }

    fn show(self: @This(), id: u32, focused: bool, title: []const u8, body: []const u8) bool {
        if (self.hwnd == null) return false;
        var info = self.data(id);
        info.uFlags = w32.NIF_ICON | w32.NIF_TIP | w32.NIF_MESSAGE;
        info.uCallbackMessage = callback;
        info.hIcon = w32.LoadIconW(self.instance, w32.IDI_GHOSTTY) orelse w32.LoadIconW(null, w32.IDI_APPLICATION);
        copyText(&info.szTip, "Ghostty");
        if (self.notify(w32.NIM_ADD, &info) == 0) return false;
        info.uFlags = w32.NIF_INFO;
        info.dwInfoFlags = w32.NIIF_INFO;
        copyText(&info.szInfoTitle, if (title.len == 0) "Ghostty" else title);
        copyText(&info.szInfo, body);
        if (self.notify(w32.NIM_MODIFY, &info) == 0) return false;
        // Match the upstream focused-pane timeout. Explorer sends its
        // own dismissal events for notifications shown in the background.
        if (focused and w32.SetTimer(self.hwnd, id, 3000, null) == 0) return false;
        return true;
    }

    fn remove(self: @This(), id: u32) void {
        if (self.hwnd == null) return;
        _ = w32.KillTimer(self.hwnd, id);
        var info = self.data(id);
        _ = self.notify(w32.NIM_DELETE, &info);
    }
};

test "native desktop notification text truncates at Unicode boundaries" {
    var buf: [4]u16 = undefined;
    copyText(&buf, "ab🚀x");
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("ab"), std.mem.sliceTo(&buf, 0));
    copyText(&buf, "a🚀x");
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("a🚀"), std.mem.sliceTo(&buf, 0));
}
