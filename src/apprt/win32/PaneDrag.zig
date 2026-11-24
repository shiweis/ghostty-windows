//! The non-activating drag grip for a live terminal pane.
const PaneDrag = @This();
const std = @import("std");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const w32 = @import("win32.zig");

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyPaneDrag");
hwnd: ?w32.HWND = null,
origin: ?w32.POINT = null,

pub fn registerClass(instance: w32.HINSTANCE) !u16 {
    const atom = w32.RegisterClassExW(&.{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_SIZEALL),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    });
    if (atom == 0) return error.Win32Error;
    return atom;
}

pub fn deinit(self: *PaneDrag) void {
    if (self.hwnd) |hwnd| _ = w32.DestroyWindow(hwnd);
    self.* = .{};
}

pub fn hide(self: *PaneDrag) void {
    if (self.hwnd) |hwnd| _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
}

pub fn update(self: *PaneDrag, surface: *Surface, show: bool) void {
    if (!show) return self.hide();
    const pane = surface.hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetWindowRect(pane, &rect) == 0) return self.hide();
    const width: i32 = @intFromFloat(@round(34 * surface.scale));
    const height: i32 = @intFromFloat(@round(12 * surface.scale));
    if (rect.right - rect.left < width or rect.bottom - rect.top < height * 2) return self.hide();
    const hwnd = self.hwnd orelse create: {
        const h = w32.CreateWindowExW(
            w32.WS_EX_NOACTIVATE | w32.WS_EX_TOOLWINDOW,
            class_name,
            std.unicode.utf8ToUtf16LeStringLiteral("Move pane"),
            w32.WS_POPUP,
            0,
            0,
            width,
            height,
            surface.parent_window.hwnd,
            null,
            surface.app.hinstance,
            null,
        ) orelse return;
        _ = w32.SetWindowLongPtrW(h, w32.GWLP_USERDATA, @bitCast(@intFromPtr(surface)));
        self.hwnd = h;
        break :create h;
    };
    _ = w32.SetWindowPos(hwnd, null, @divTrunc(rect.left + rect.right - width, 2), rect.top, width, height, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER | w32.SWP_SHOWWINDOW);
}

const Direction = SplitTree(Surface).Split.Direction;
const Destination = struct { pane: *Surface, direction: Direction };

fn hitTest(source: *Surface, point: w32.POINT) ?Destination {
    const hit = w32.WindowFromPoint(point) orelse return null;
    for (source.app.windows.items) |win| {
        if (win.closing or win.tab_count == 0 or win.tab_overview.active) continue;
        if (hit == win.hwnd or hit == win.chrome_hwnd or hit == win.tab_bar_hwnd) {
            var local = point;
            if (w32.ScreenToClient(win.hwnd.?, &local) == 0 or local.y < 0 or local.y >= win.tabBarHeight()) continue;
            for (win.tab_rects[0..win.tab_count], 0..) |r, i| {
                if (local.x < r.left or local.x >= r.right) continue;
                const pane = win.tab_active_surface[i];
                if (win == source.parent_window and win.findTabIndex(source) == i) return null;
                return .{ .pane = pane, .direction = .right };
            }
        }
        var it = win.tab_trees[win.active_tab].iterator();
        while (it.next()) |entry| {
            const pane = entry.view;
            if (pane == source or !pane.core_surface_ready or (hit != pane.hwnd and hit != pane.drag_handle.hwnd)) continue;
            var r: w32.RECT = undefined;
            if (w32.GetWindowRect(pane.hwnd.?, &r) == 0) return null;
            const x: i64 = 2 * point.x - r.left - r.right;
            const y: i64 = 2 * point.y - r.top - r.bottom;
            const width: i64 = r.right - r.left;
            const height: i64 = r.bottom - r.top;
            return .{ .pane = pane, .direction = if (@abs(x * height) >= @abs(y * width))
                (if (x < 0) .left else .right)
            else
                (if (y < 0) .up else .down) };
        }
    }
    return null;
}

fn screenPoint(hwnd: w32.HWND, lparam: isize) ?w32.POINT {
    var point: w32.POINT = .{ .x = @as(i16, @truncate(lparam)), .y = @as(i16, @truncate(lparam >> 16)) };
    return if (w32.ClientToScreen(hwnd, &point) != 0) point else null;
}

fn cancel(surface: *Surface, hwnd: w32.HWND) void {
    surface.drag_handle.origin = null;
    if (surface.app.pane_drag_capture == hwnd) surface.app.pane_drag_capture = null;
    if (w32.GetCapture() == hwnd) _ = w32.ReleaseCapture();
}

fn wndProc(hwnd: w32.HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
    const data = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (data == 0) return w32.DefWindowProcW(hwnd, msg, wp, lp);
    const s: *Surface = @ptrFromInt(@as(usize, @bitCast(data)));
    switch (msg) {
        w32.WM_MOUSEACTIVATE => return w32.MA_NOACTIVATE,
        w32.WM_LBUTTONDOWN => {
            if (!s.core_surface_ready or s.parent_window.closing or w32.GetCapture() != null) return 0;
            const p = screenPoint(hwnd, lp) orelse return 0;
            _ = w32.SetCapture(hwnd);
            if (w32.GetCapture() == hwnd) {
                s.app.pane_drag_capture = hwnd;
                s.drag_handle.origin = p;
            }
            return 0;
        },
        w32.WM_MOUSEMOVE => {
            if (s.drag_handle.origin != null) {
                const point = screenPoint(hwnd, lp) orelse return 0;
                const cursor: usize = if (hitTest(s, point)) |dst| switch (dst.direction) {
                    .left, .right => w32.IDC_SIZEWE,
                    .up, .down => w32.IDC_SIZENS,
                } else w32.IDC_NO;
                _ = w32.SetCursor(w32.LoadCursorW(null, cursor));
            }
            return 0;
        },
        w32.WM_LBUTTONUP => {
            const origin = s.drag_handle.origin orelse return 0;
            const point = screenPoint(hwnd, lp);
            cancel(s, hwnd);
            const end = point orelse return 0;
            if (@abs(end.x - origin.x) < @as(u32, @intCast(w32.GetSystemMetrics(68))) and
                @abs(end.y - origin.y) < @as(u32, @intCast(w32.GetSystemMetrics(69)))) return 0;
            if (hitTest(s, end)) |dst| {
                _ = Window.movePane(s, dst.pane, dst.direction) catch |err| {
                    std.log.scoped(.win32).warn("could not move pane: {}", .{err});
                };
            }
            return 0;
        },
        w32.WM_CANCELMODE, w32.WM_CAPTURECHANGED, w32.WM_RBUTTONDOWN => {
            cancel(s, hwnd);
            return 0;
        },
        w32.WM_SHOWWINDOW => if (wp == 0) {
            cancel(s, hwnd);
        },
        w32.WM_DESTROY => {
            cancel(s, hwnd);
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            s.drag_handle.hwnd = null;
            return 0;
        },
        w32.WM_PAINT => {
            var paint: w32.PAINTSTRUCT = undefined;
            const dc = w32.BeginPaint(hwnd, &paint) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &paint);
            var rect: w32.RECT = undefined;
            if (w32.GetClientRect(hwnd, &rect) == 0) return 0;
            const colors = s.app.chromeColors();
            const brush = w32.GetStockObject(w32.DC_BRUSH) orelse return 0;
            _ = w32.SetDCBrushColor(dc, colors.mix(28));
            _ = w32.FillRect(dc, &rect, @ptrCast(brush));
            _ = w32.SetDCBrushColor(dc, colors.mix(180));
            const dot = @max(1, @divTrunc(rect.bottom, 6));
            for (0..2) |row| for (0..3) |col| {
                const x = @divTrunc(rect.right - 7 * dot, 2) + 3 * dot * @as(i32, @intCast(col));
                const y = @divTrunc(rect.bottom - 3 * dot, 2) + 2 * dot * @as(i32, @intCast(row));
                _ = w32.FillRect(dc, &.{ .left = x, .top = y, .right = x + dot, .bottom = y + dot }, @ptrCast(brush));
            };
            return 0;
        },
        else => {},
    }
    return w32.DefWindowProcW(hwnd, msg, wp, lp);
}
