//! Quick Terminal: a borderless popup window that slides in/out from a
//! screen edge. Owned by App, separate from the normal windows list.
const QuickTerminal = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");

const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32_quick_terminal);

/// Message-window timer ID, separate from quit and notification timers.
pub const ANIM_TIMER_ID: usize = 3;

/// Animation tick interval in milliseconds (~60fps).
const ANIM_TICK_MS: u32 = 16;

app: *App,
window: *Window,
visible: bool = false,
animating: bool = false,
animation_direction: enum { in, out } = .in,
animation_start_time: i64 = 0,
animation_duration: f64 = 0.2,
perf_freq: i64 = 1, // avoid division by zero

// Cached rects for animation interpolation.
target_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
hidden_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

pub fn init(app: *App) !*QuickTerminal {
    const alloc = app.core_app.alloc;
    const self = try alloc.create(QuickTerminal);
    errdefer alloc.destroy(self);

    self.* = .{
        .app = app,
        .window = undefined,
    };

    // Query performance counter frequency for animation timing.
    _ = w32.QueryPerformanceFrequency(&self.perf_freq);

    // Read animation duration from config.
    self.animation_duration = app.config.@"quick-terminal-animation-duration";

    // Create the window in quick terminal mode.
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(app, .{ .is_quick_terminal = true });
    self.window = window;

    // Add a single tab (surface) to the window.
    _ = try window.addTab();

    return self;
}

pub fn deinit(self: *QuickTerminal) void {
    const alloc = self.app.core_app.alloc;
    const app = self.app;

    // Kill animation timer if running.
    if (self.animating) {
        _ = w32.KillTimer(app.msg_hwnd, ANIM_TIMER_ID);
        self.animating = false;
    }

    // Prevent onDestroy from calling onWindowDestroyed (we're cleaning up ourselves).
    app.quick_terminal = null;

    // Clean up the window.
    self.window.close();
    alloc.destroy(self.window);
    alloc.destroy(self);
}

/// Toggle the quick terminal in or out. Called from App.performAction.
pub fn toggle(self: *QuickTerminal) void {
    if (self.animating) {
        // Mid-animation: reverse direction from current position.
        self.animation_direction = if (self.animation_direction == .in) .out else .in;
        // Adjust start time so progress continues smoothly from current position.
        const elapsed_ticks = self.now() - self.animation_start_time;
        const elapsed = @as(f64, @floatFromInt(elapsed_ticks)) / @as(f64, @floatFromInt(self.perf_freq));
        const progress = @min(elapsed / self.animation_duration, 1.0);
        const remaining = (1.0 - progress) * self.animation_duration;
        self.animation_start_time = self.now() - @as(i64, @intFromFloat(remaining * @as(f64, @floatFromInt(self.perf_freq))));
        return;
    }

    if (self.visible) {
        self.animateOut();
    } else {
        self.animateIn();
    }
}

fn animateIn(self: *QuickTerminal) void {
    // Recalculate position each time (handles monitor changes, config reload).
    self.calculateRects();

    const hwnd = self.window.hwnd orelse return;

    // Position at hidden rect before showing.
    _ = w32.SetWindowPos(
        hwnd,
        w32.HWND_TOPMOST,
        self.hidden_rect.left,
        self.hidden_rect.top,
        self.hidden_rect.right - self.hidden_rect.left,
        self.hidden_rect.bottom - self.hidden_rect.top,
        w32.SWP_NOACTIVATE,
    );

    _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);

    if (self.animation_duration <= 0) {
        // Instant: jump to target.
        _ = w32.SetWindowPos(
            hwnd,
            w32.HWND_TOPMOST,
            self.target_rect.left,
            self.target_rect.top,
            self.target_rect.right - self.target_rect.left,
            self.target_rect.bottom - self.target_rect.top,
            w32.SWP_NOACTIVATE,
        );
        self.visible = true;
        self.forceForeground();
        return;
    }

    self.animation_direction = .in;
    self.animation_start_time = self.now();
    self.animating = true;
    _ = w32.SetTimer(self.app.msg_hwnd, ANIM_TIMER_ID, ANIM_TICK_MS, null);
}

fn animateOut(self: *QuickTerminal) void {
    if (self.animation_duration <= 0) {
        // Instant hide.
        if (self.window.hwnd) |hwnd| {
            _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
        }
        self.visible = false;
        return;
    }

    self.animation_direction = .out;
    self.animation_start_time = self.now();
    self.animating = true;
    _ = w32.SetTimer(self.app.msg_hwnd, ANIM_TIMER_ID, ANIM_TICK_MS, null);
}

/// Called from App's WM_TIMER handler on each animation tick.
pub fn onAnimationTick(self: *QuickTerminal) void {
    if (!self.animating) return;

    const elapsed_ticks = self.now() - self.animation_start_time;
    const elapsed = @as(f64, @floatFromInt(elapsed_ticks)) / @as(f64, @floatFromInt(self.perf_freq));
    const progress = @min(elapsed / self.animation_duration, 1.0);

    // For animate-out, invert progress so interpolation goes from visible→hidden.
    const t = if (self.animation_direction == .in) easeInOutCubic(progress) else 1.0 - easeInOutCubic(progress);

    const hwnd = self.window.hwnd orelse return;

    // Interpolate position.
    const x = lerp(self.hidden_rect.left, self.target_rect.left, t);
    const y = lerp(self.hidden_rect.top, self.target_rect.top, t);
    const w = self.target_rect.right - self.target_rect.left;
    const h = self.target_rect.bottom - self.target_rect.top;

    _ = w32.SetWindowPos(hwnd, w32.HWND_TOPMOST, x, y, w, h, w32.SWP_NOACTIVATE);

    if (progress >= 1.0) {
        // Animation complete.
        _ = w32.KillTimer(self.app.msg_hwnd, ANIM_TIMER_ID);
        self.animating = false;

        if (self.animation_direction == .in) {
            self.visible = true;
            self.forceForeground();
        } else {
            self.visible = false;
            _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
        }
    }
}

/// Called when the quick terminal window loses focus.
pub fn onFocusLost(self: *QuickTerminal) void {
    if (!self.visible) return;
    if (self.animating and self.animation_direction == .out) return;
    if (!self.app.config.@"quick-terminal-autohide") return;

    self.animateOut();
}

/// Called when the quick terminal's window is destroyed (shell exited).
/// At this point Window.onDestroy has already cleaned up font/hwnd.
pub fn onWindowDestroyed(self: *QuickTerminal) void {
    const alloc = self.app.core_app.alloc;
    const app = self.app;

    // Kill the animation timer unconditionally — `self.animating` may
    // be false but a stray WM_TIMER could already be queued. Once `self`
    // is freed below, dispatching that timer would touch freed memory.
    _ = w32.KillTimer(app.msg_hwnd, ANIM_TIMER_ID);

    alloc.destroy(self.window);
    app.quick_terminal = null;
    alloc.destroy(self);

    // Check if we should start the quit timer (after self is freed).
    if (app.windows.items.len == 0) {
        app.startQuitTimer();
    }
}

/// Update cached config values after a config reload.
pub fn onConfigChange(self: *QuickTerminal, config: *const configpkg.Config) void {
    self.animation_duration = config.@"quick-terminal-animation-duration";
    self.window.onConfigChange();
}

// -----------------------------------------------------------------------
// Position calculation
// -----------------------------------------------------------------------

/// Compute the target (visible) and hidden (off-screen) rects based on
/// the current monitor and config.
fn calculateRects(self: *QuickTerminal) void {
    const monitor = self.getMonitor() orelse return;
    self.calculateMonitorRects(w32, monitor);
}

fn calculateMonitorRects(self: *QuickTerminal, comptime native: type, monitor: w32.HMONITOR) void {
    var mi = w32.MONITORINFO{
        .cbSize = @sizeOf(w32.MONITORINFO),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
    };
    if (native.GetMonitorInfoW(monitor, &mi) == 0) return;

    var dpi_x: u32 = 96;
    var dpi_y: u32 = 96;
    if (native.GetDpiForMonitor(monitor, w32.MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y) < 0) dpi_x = 96;
    const config = &self.app.config;
    const rects = placement(mi.rcWork, config.@"quick-terminal-position", config.@"quick-terminal-size", dpi_x);
    self.target_rect = rects.visible;
    self.hidden_rect = rects.hidden;
}

test "quick terminal switches work area and DPI with the selected monitor" {
    const monitors = struct {
        const primary: w32.HMONITOR = @ptrFromInt(1);
        const second: w32.HMONITOR = @ptrFromInt(2);
        fn GetMonitorInfoW(handle: w32.HMONITOR, info: *w32.MONITORINFO) i32 {
            info.rcWork = if (handle == primary)
                .{ .left = 0, .top = 0, .right = 1920, .bottom = 1040 }
            else
                .{ .left = -2560, .top = -200, .right = 0, .bottom = 1200 };
            return 1;
        }
        fn GetDpiForMonitor(handle: w32.HMONITOR, _: c_int, x: *u32, y: *u32) i32 {
            x.* = if (handle == primary) 96 else 144;
            y.* = x.*;
            return 0;
        }
    };
    var app: App = undefined;
    app.config.@"quick-terminal-position" = .top;
    app.config.@"quick-terminal-size" = .{ .secondary = .{ .percentage = 50 } };
    var quick: QuickTerminal = .{ .app = &app, .window = undefined };
    quick.calculateMonitorRects(monitors, monitors.primary);
    const primary: w32.RECT = .{ .left = 480, .top = 0, .right = 1440, .bottom = 400 };
    try std.testing.expectEqual(primary, quick.target_rect);
    quick.calculateMonitorRects(monitors, monitors.second);
    try std.testing.expectEqual(w32.RECT{ .left = -1920, .top = -200, .right = -640, .bottom = 400 }, quick.target_rect);
    try std.testing.expectEqual(w32.RECT{ .left = -1920, .top = -800, .right = -640, .bottom = -200 }, quick.hidden_rect);
    quick.calculateMonitorRects(monitors, monitors.primary);
    try std.testing.expectEqual(primary, quick.target_rect);
}

fn placement(
    work: w32.RECT,
    position: configpkg.Config.QuickTerminalPosition,
    configured: configpkg.Config.QuickTerminalSize,
    dpi: u32,
) struct { visible: w32.RECT, hidden: w32.RECT } {
    const width: u32 = @intCast(work.right - work.left);
    const height: u32 = @intCast(work.bottom - work.top);
    // User-specified pixels and monitor work areas are physical pixels.
    // Only the built-in 400/800 defaults scale with the monitor.
    var size = configured;
    const base = (400 * dpi + 48) / 96;
    if (size.primary == null) size.primary = .{ .pixels = if (position == .center) 2 * base else base };
    if (position == .center and size.secondary == null) size.secondary = .{ .pixels = base };
    for ([_]*?configpkg.Config.QuickTerminalSize.Size{ &size.primary, &size.secondary }) |field| {
        if (field.*) |*v| switch (v.*) {
            .percentage => |*pct| pct.* = @min(pct.*, 100),
            .pixels => {},
        };
    }
    const dims = size.calculate(position, .{ .width = width, .height = height });
    const w: i32 = @intCast(@min(width, dims.width));
    const h: i32 = @intCast(@min(height, dims.height));
    const x = switch (position) {
        .left => work.left,
        .right => work.right - w,
        else => work.left + @divTrunc(work.right - work.left - w, 2),
    };
    const y = switch (position) {
        .top => work.top,
        .bottom => work.bottom - h,
        else => work.top + @divTrunc(work.bottom - work.top - h, 2),
    };
    const hidden_x = switch (position) {
        .left => work.left - w,
        .right => work.right,
        else => x,
    };
    const hidden_y = switch (position) {
        .top, .center => work.top - h,
        .bottom => work.bottom,
        else => y,
    };
    return .{
        .visible = .{ .left = x, .top = y, .right = x + w, .bottom = y + h },
        .hidden = .{ .left = hidden_x, .top = hidden_y, .right = hidden_x + w, .bottom = hidden_y + h },
    };
}

test "quick terminal centers partial edges on the selected monitor" {
    const work: w32.RECT = .{ .left = -1600, .top = 40, .right = 0, .bottom = 1040 };
    const size: configpkg.Config.QuickTerminalSize = .{ .primary = .{ .pixels = 300 }, .secondary = .{ .percentage = 50 } };
    const cases = .{
        .{ .top, -1200, 40, -1200, -260, 800, 300 },
        .{ .bottom, -1200, 740, -1200, 1040, 800, 300 },
        .{ .left, -1600, 290, -1900, 290, 300, 500 },
        .{ .right, -300, 290, 0, 290, 300, 500 },
    };
    inline for (cases) |case| {
        for ([_]u32{ 96, 144, 192 }) |dpi| {
            const rect = placement(work, case[0], size, dpi);
            try std.testing.expectEqual(w32.RECT{ .left = case[1], .top = case[2], .right = case[1] + case[5], .bottom = case[2] + case[6] }, rect.visible);
            try std.testing.expectEqual(w32.RECT{ .left = case[3], .top = case[4], .right = case[3] + case[5], .bottom = case[4] + case[6] }, rect.hidden);
        }
    }
    // An explicit secondary dimension still leaves a DPI-scaled default on the primary axis.
    const partial = placement(work, .bottom, .{ .secondary = .{ .pixels = 600 } }, 144);
    try std.testing.expectEqual(w32.RECT{ .left = -1100, .top = 440, .right = -500, .bottom = 1040 }, partial.visible);
    const oversized = placement(work, .center, .{ .primary = .{ .percentage = 200 }, .secondary = .{ .pixels = 4000 } }, 96);
    try std.testing.expectEqual(work, oversized.visible);
}

fn getMonitor(self: *QuickTerminal) ?w32.HMONITOR {
    const screen = self.app.config.@"quick-terminal-screen";
    switch (screen) {
        .main, .@"macos-menu-bar" => {
            return w32.MonitorFromPoint(.{ .x = 0, .y = 0 }, w32.MONITOR_DEFAULTTOPRIMARY);
        },
        .mouse => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                return w32.MonitorFromPoint(pt, w32.MONITOR_DEFAULTTONEAREST);
            }
            return w32.MonitorFromPoint(.{ .x = 0, .y = 0 }, w32.MONITOR_DEFAULTTOPRIMARY);
        },
    }
}

// -----------------------------------------------------------------------
// Animation helpers
// -----------------------------------------------------------------------

/// Force the quick terminal to the foreground, even when Ghostty is a
/// background process. Uses AttachThreadInput to work around the Win32
/// SetForegroundWindow restriction.
fn forceForeground(self: *QuickTerminal) void {
    const hwnd = self.window.hwnd orelse return;
    const fg = w32.GetForegroundWindow();
    if (fg) |fg_hwnd| {
        const fg_tid = w32.GetWindowThreadProcessId(fg_hwnd, null);
        const our_tid = w32.GetCurrentThreadId();
        if (fg_tid != our_tid) {
            _ = w32.AttachThreadInput(our_tid, fg_tid, 1);
            _ = w32.SetForegroundWindow(hwnd);
            _ = w32.AttachThreadInput(our_tid, fg_tid, 0);
        } else {
            _ = w32.SetForegroundWindow(hwnd);
        }
    } else {
        _ = w32.SetForegroundWindow(hwnd);
    }
    // Focus the terminal surface inside the window.
    if (self.window.getActiveSurface()) |s| {
        if (s.hwnd) |sh| _ = w32.SetFocus(sh);
    }
}

fn now(_: *QuickTerminal) i64 {
    var count: i64 = 0;
    _ = w32.QueryPerformanceCounter(&count);
    return count;
}

/// Cubic ease-in-out: smooth acceleration and deceleration.
fn easeInOutCubic(t: f64) f64 {
    if (t < 0.5) {
        return 4.0 * t * t * t;
    } else {
        const f = -2.0 * t + 2.0;
        return 1.0 - (f * f * f) / 2.0;
    }
}

/// Interpolate between two values using eased progress.
fn lerp(a: i32, b: i32, t: f64) i32 {
    return a + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(b - a)) * t)));
}
