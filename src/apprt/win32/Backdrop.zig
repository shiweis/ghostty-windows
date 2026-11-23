//! Live blur without Acrylic's additional tint; terminal colors provide the tint.
//! The accent API is undocumented, with checked Desktop Acrylic fallback.
const std = @import("std");
const w32 = @import("win32.zig");
const log = std.log.scoped(.win32);

pub fn apply(hwnd: w32.HWND, enabled: bool) void {
    const no_backdrop: u32 = w32.DWMSBT_NONE;
    _ = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_SYSTEMBACKDROP_TYPE, &no_backdrop, @sizeOf(u32));
    if (!enabled) {
        applyAccent(hwnd, w32.ACCENT_DISABLED) catch {
            log.warn("could not disable Windows background blur", .{});
        };
        return;
    }

    applyAccent(hwnd, w32.ACCENT_ENABLE_BLURBEHIND) catch {
        log.warn("untinted Windows blur unavailable; trying OS-tinted Desktop Acrylic", .{});
        applyAccent(hwnd, w32.ACCENT_DISABLED) catch {
            log.warn("could not clear accent policy before Acrylic fallback", .{});
        };
        const acrylic: u32 = w32.DWMSBT_TRANSIENTWINDOW;
        const result = w32.DwmSetWindowAttribute(
            hwnd,
            w32.DWMWA_SYSTEMBACKDROP_TYPE,
            &acrylic,
            @sizeOf(u32),
        );
        if (result < 0) {
            log.warn("Windows background blur unavailable (DwmSetWindowAttribute HRESULT=0x{x})", .{@as(u32, @bitCast(result))});
        }
    };
}

fn applyAccent(hwnd: w32.HWND, state: i32) error{SetAccentPolicy}!void {
    var policy: w32.ACCENT_POLICY = .{
        .AccentState = state,
        .AccentFlags = 0,
        .GradientColor = 0,
        .AnimationId = 0,
    };
    var data: w32.WINDOWCOMPOSITIONATTRIBDATA = .{
        .Attrib = w32.WCA_ACCENT_POLICY,
        .pvData = &policy,
        .cbData = @sizeOf(w32.ACCENT_POLICY),
    };
    if (w32.SetWindowCompositionAttribute(hwnd, &data) == 0) return error.SetAccentPolicy;
}
