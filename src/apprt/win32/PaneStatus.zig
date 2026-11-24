const PaneStatus = @This();

const std = @import("std");
const input = @import("../../input.zig");
const apprt = @import("../../apprt.zig");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");
const Allocator = std.mem.Allocator;

sequence: std.ArrayList(input.Trigger) = .empty,
tables: std.ArrayList([]const u8) = .empty,
readonly: bool = false,

pub fn deinit(self: *PaneStatus, alloc: Allocator) void {
    self.sequence.deinit(alloc);
    for (self.tables.items) |name| alloc.free(name);
    self.tables.deinit(alloc);
    self.* = .{};
}

pub fn keySequence(self: *PaneStatus, alloc: Allocator, value: apprt.action.KeySequence) !void {
    switch (value) {
        .trigger => |trigger| try self.sequence.append(alloc, trigger),
        .end => self.sequence.clearRetainingCapacity(),
    }
}

pub fn keyTable(self: *PaneStatus, alloc: Allocator, value: apprt.action.KeyTable) !void {
    switch (value) {
        .activate => |name| {
            const copy = try alloc.dupe(u8, name);
            errdefer alloc.free(copy);
            try self.tables.append(alloc, copy);
        },
        .deactivate => if (self.tables.pop()) |name| alloc.free(name),
        .deactivate_all => while (self.tables.pop()) |name| alloc.free(name),
    }
}

pub fn active(self: *const PaneStatus) bool {
    return self.readonly or self.sequence.items.len != 0 or self.tables.items.len != 0;
}

fn label(self: *const PaneStatus, writer: *std.Io.Writer) !void {
    if (self.readonly) try writer.writeAll("Read-only");
    if (self.tables.getLastOrNull()) |name| {
        if (self.readonly) try writer.writeAll("  ·  ");
        try writer.print("Key table {s}", .{name});
    }
    for (self.sequence.items, 0..) |trigger, i| {
        if (i == 0) {
            if (self.readonly or self.tables.items.len != 0) try writer.writeAll("  ·  ");
        } else try writer.writeAll(" → ");
        try writer.print("{f}", .{trigger});
    }
}

/// An owned, click-through control tracks the selected pane even if tab chrome is hidden.
pub fn refresh(window: *Window) !void {
    const owner = window.hwnd orelse return;
    const surface = visible: {
        const selected = window.getActiveSurface() orelse break :visible null;
        const pane = selected.hwnd orelse break :visible null;
        break :visible if (selected.pane_status.active() and w32.IsIconic(owner) == 0 and w32.IsWindowVisible_(pane) != 0) selected else null;
    } orelse {
        if (window.status_hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
        return;
    };
    const alloc = window.app.core_app.alloc;
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try surface.pane_status.label(&buf.writer);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, buf.written());
    defer alloc.free(wide);
    const hwnd = window.status_hwnd orelse blk: {
        const h = w32.CreateWindowExW(w32.WS_EX_LAYERED | w32.WS_EX_TRANSPARENT | w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), wide.ptr, w32.WS_POPUP | w32.WS_BORDER | w32.SS_CENTER | w32.SS_CENTERIMAGE | w32.SS_NOPREFIX, 0, 0, 1, 1, owner, null, window.app.hinstance, null) orelse return error.Win32Error;
        errdefer _ = w32.DestroyWindow(h);
        if (w32.SetLayeredWindowAttributes(h, 0, 255, w32.LWA_ALPHA) == 0) return error.Win32Error;
        window.status_hwnd = h;
        break :blk h;
    };
    if (window.tab_font) |font| _ = w32.SendMessageW(hwnd, w32.WM_SETFONT, @intFromPtr(font), 0);
    _ = w32.SetWindowTextW(hwnd, wide.ptr);
    var pane: w32.RECT = undefined;
    if (w32.GetWindowRect(surface.hwnd.?, &pane) == 0) return error.Win32Error;
    const dc = w32.GetDC(hwnd) orelse return error.Win32Error;
    defer _ = w32.ReleaseDC(hwnd, dc);
    const previous = if (window.tab_font) |font| w32.SelectObject(dc, font) else null;
    defer if (previous) |font| {
        _ = w32.SelectObject(dc, font);
    };
    var bounds: w32.RECT = std.mem.zeroes(w32.RECT);
    _ = w32.DrawTextW(dc, wide.ptr, @intCast(wide.len), &bounds, w32.DT_CALCRECT | w32.DT_SINGLELINE | w32.DT_NOPREFIX);
    const margin: i32 = @intFromFloat(@round(4 * window.scale));
    const width = @min(bounds.right + 4 * margin, pane.right - pane.left);
    const height = @min(bounds.bottom + 2 * margin, pane.bottom - pane.top);
    _ = w32.SetWindowPos(hwnd, null, @max(pane.left, pane.right - width - margin), @max(pane.top, pane.bottom - height - margin), width, height, w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW);
}

test "pane status tracks nested tables and completed key sequences independently" {
    const alloc = std.testing.allocator;
    var status: PaneStatus = .{ .readonly = true };
    defer status.deinit(alloc);
    try status.keyTable(alloc, .{ .activate = "normal" });
    try status.keyTable(alloc, .{ .activate = "移动" });
    try status.keySequence(alloc, .{ .trigger = .{ .key = .{ .unicode = 'a' } } });
    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();
    try status.label(&buf.writer);
    try std.testing.expectEqualStrings("Read-only  ·  Key table 移动  ·  a", buf.written());
    try status.keyTable(alloc, .deactivate);
    try status.keySequence(alloc, .end);
    try std.testing.expectEqualStrings("normal", status.tables.getLast());
    try status.keyTable(alloc, .deactivate_all);
    try std.testing.expect(status.active());
    status.readonly = false;
    try std.testing.expect(!status.active());
}
