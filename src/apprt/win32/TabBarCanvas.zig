const std = @import("std");
const w32 = @import("win32.zig");

pub const Self = @This();

width: i32 = 0,
height: i32 = 0,
color_dc: ?w32.HDC = null,
mask_dc: ?w32.HDC = null,
color_bitmap: ?w32.HANDLE = null,
mask_bitmap: ?w32.HANDLE = null,
color_bits: ?[*]u32 = null,
mask_bits: ?[*]u32 = null,
color_old_bitmap: ?*anyopaque = null,
mask_old_bitmap: ?*anyopaque = null,
color_old_font: ?*anyopaque = null,
mask_old_font: ?*anyopaque = null,
brush: ?*anyopaque = null,
background_alpha: u8 = 255,
font_selected: bool = false,

pub fn begin(self: *Self, width: i32, height: i32, font: ?w32.HANDLE, opacity: f64) !void {
    self.restoreFonts();
    if (width <= 0 or height <= 0) return error.Win32Error;

    if (self.width != width or self.height != height or self.color_dc == null or self.mask_dc == null) {
        try self.resize(width, height);
    }

    if (self.brush == null) {
        self.brush = w32.GetStockObject(w32.DC_BRUSH) orelse return error.Win32Error;
    }

    const alpha = if (std.math.isFinite(opacity))
        @as(u8, @intFromFloat(@round(@max(0.0, @min(1.0, opacity)) * 255.0)))
    else
        255;
    self.background_alpha = alpha;

    _ = w32.SetDCBrushColor(self.mask_dc.?, 0);

    if (font) |selected_font| {
        self.color_old_font = select(self.color_dc.?, selected_font) orelse return error.Win32Error;
        self.font_selected = true;
        errdefer self.restoreFonts();
        self.mask_old_font = select(self.mask_dc.?, selected_font) orelse return error.Win32Error;
    }

    if (w32.SetBkMode(self.color_dc.?, w32.TRANSPARENT) == 0 or
        w32.SetBkMode(self.mask_dc.?, w32.TRANSPARENT) == 0)
    {
        self.restoreFonts();
        return error.Win32Error;
    }
}

pub fn fillRect(self: *Self, rect: *const w32.RECT, color: u32) void {
    if (self.color_dc == null or self.mask_dc == null or self.brush == null) return;
    var clipped = rect.*;
    clipped.left = @max(clipped.left, 0);
    clipped.top = @max(clipped.top, 0);
    clipped.right = @min(clipped.right, self.width);
    clipped.bottom = @min(clipped.bottom, self.height);
    if (clipped.left >= clipped.right or clipped.top >= clipped.bottom) return;

    const alpha = self.background_alpha;
    const red: u32 = color & 0xff;
    const green: u32 = (color >> 8) & 0xff;
    const blue: u32 = (color >> 16) & 0xff;
    const premultiplied = w32.RGB(
        @intCast(premultiply(red, alpha)),
        @intCast(premultiply(green, alpha)),
        @intCast(premultiply(blue, alpha)),
    );
    _ = w32.SetDCBrushColor(self.color_dc.?, premultiplied);
    _ = w32.FillRect(self.color_dc.?, &clipped, @ptrCast(self.brush.?));
    _ = w32.FillRect(self.mask_dc.?, &clipped, @ptrCast(self.brush.?));
}

pub fn drawText(
    self: *Self,
    text: [*]const u16,
    len: i32,
    rect: *w32.RECT,
    flags: u32,
    color: u32,
) void {
    if (self.color_dc == null or self.mask_dc == null or len <= 0) return;
    _ = w32.SetBkMode(self.color_dc.?, w32.TRANSPARENT);
    _ = w32.SetBkMode(self.mask_dc.?, w32.TRANSPARENT);
    _ = w32.SetTextColor(self.color_dc.?, color);
    _ = w32.SetTextColor(self.mask_dc.?, w32.RGB(255, 255, 255));
    _ = w32.DrawTextW(self.color_dc.?, text, len, rect, flags);
    _ = w32.DrawTextW(self.mask_dc.?, text, len, rect, flags);
}

pub fn present(self: *Self, hwnd: w32.HWND) !void {
    const color_dc = self.color_dc orelse return error.Win32Error;
    _ = self.mask_dc orelse return error.Win32Error;
    const color_bits = self.color_bits orelse return error.Win32Error;
    const mask_bits = self.mask_bits orelse return error.Win32Error;

    if (w32.GdiFlush() == 0) {
        self.restoreFonts();
        return error.Win32Error;
    }
    self.restoreFonts();
    const pixel_count = @as(usize, @intCast(self.width)) * @as(usize, @intCast(self.height));
    for (0..pixel_count) |i| {
        const coverage_pixel = mask_bits[i];
        const coverage: u32 = @max(coverage_pixel & 0xff, @max((coverage_pixel >> 8) & 0xff, (coverage_pixel >> 16) & 0xff));
        const alpha: u32 = @as(u32, self.background_alpha) + (coverage * (255 - self.background_alpha) + 127) / 255;
        color_bits[i] = (color_bits[i] & 0x00ffffff) | (alpha << 24);
    }

    const source = w32.POINT{ .x = 0, .y = 0 };
    const size = w32.SIZE{ .cx = self.width, .cy = self.height };
    const blend = w32.BLENDFUNCTION{ .SourceConstantAlpha = 255 };
    if (w32.UpdateLayeredWindow(
        hwnd,
        null,
        null,
        &size,
        color_dc,
        &source,
        0,
        &blend,
        w32.ULW_ALPHA,
    ) == 0) return error.Win32Error;
}

pub fn deinit(self: *Self) void {
    self.restoreFonts();
    self.releaseBitmaps();
    self.width = 0;
    self.height = 0;
    self.color_bits = null;
    self.mask_bits = null;
    self.brush = null;
}

fn resize(self: *Self, width: i32, height: i32) !void {
    self.releaseBitmaps();
    self.width = 0;
    self.height = 0;
    self.color_bits = null;
    self.mask_bits = null;

    const color_dc = w32.CreateCompatibleDC(null) orelse return error.OutOfMemory;
    errdefer _ = w32.DeleteDC(color_dc);
    const mask_dc = w32.CreateCompatibleDC(null) orelse return error.OutOfMemory;
    errdefer _ = w32.DeleteDC(mask_dc);

    const info = w32.BITMAPINFO{
        .bmiHeader = .{
            .biWidth = width,
            .biHeight = -height,
        },
    };
    var color_bits: ?*anyopaque = null;
    const color_bitmap = w32.CreateDIBSection(color_dc, &info, w32.DIB_RGB_COLORS, &color_bits, null, 0) orelse return error.OutOfMemory;
    errdefer _ = w32.DeleteObject(color_bitmap);
    var mask_bits: ?*anyopaque = null;
    const mask_bitmap = w32.CreateDIBSection(mask_dc, &info, w32.DIB_RGB_COLORS, &mask_bits, null, 0) orelse return error.OutOfMemory;
    errdefer _ = w32.DeleteObject(mask_bitmap);

    const color_old_bitmap = select(color_dc, color_bitmap) orelse return error.Win32Error;
    errdefer _ = w32.SelectObject(color_dc, color_old_bitmap);
    const mask_old_bitmap = select(mask_dc, mask_bitmap) orelse return error.Win32Error;
    errdefer _ = w32.SelectObject(mask_dc, mask_old_bitmap);
    const color_pixels: [*]u32 = @ptrCast(@alignCast(color_bits orelse return error.Win32Error));
    const mask_pixels: [*]u32 = @ptrCast(@alignCast(mask_bits orelse return error.Win32Error));

    self.color_dc = color_dc;
    self.mask_dc = mask_dc;
    self.color_bitmap = color_bitmap;
    self.mask_bitmap = mask_bitmap;
    self.color_old_bitmap = color_old_bitmap;
    self.mask_old_bitmap = mask_old_bitmap;
    self.color_bits = color_pixels;
    self.mask_bits = mask_pixels;
    self.width = width;
    self.height = height;
}

fn restoreFonts(self: *Self) void {
    if (!self.font_selected) return;
    if (self.color_old_font) |old| _ = w32.SelectObject(self.color_dc.?, old);
    if (self.mask_old_font) |old| _ = w32.SelectObject(self.mask_dc.?, old);
    self.color_old_font = null;
    self.mask_old_font = null;
    self.font_selected = false;
}

fn releaseBitmaps(self: *Self) void {
    if (self.color_dc) |dc| {
        if (self.color_old_font) |font| _ = w32.SelectObject(dc, font);
        if (self.color_old_bitmap) |bitmap| _ = w32.SelectObject(dc, bitmap);
        _ = w32.DeleteDC(dc);
    }
    if (self.mask_dc) |dc| {
        if (self.mask_old_font) |font| _ = w32.SelectObject(dc, font);
        if (self.mask_old_bitmap) |bitmap| _ = w32.SelectObject(dc, bitmap);
        _ = w32.DeleteDC(dc);
    }
    if (self.color_bitmap) |bitmap| _ = w32.DeleteObject(bitmap);
    if (self.mask_bitmap) |bitmap| _ = w32.DeleteObject(bitmap);
    self.color_dc = null;
    self.mask_dc = null;
    self.color_bitmap = null;
    self.mask_bitmap = null;
    self.color_old_bitmap = null;
    self.mask_old_bitmap = null;
    self.color_old_font = null;
    self.mask_old_font = null;
    self.font_selected = false;
}

fn select(dc: w32.HDC, object: anytype) ?*anyopaque {
    const selected: ?*anyopaque = w32.SelectObject(dc, @ptrCast(object));
    const old = selected orelse return null;
    if (@intFromPtr(old) == std.math.maxInt(usize)) return null;
    return old;
}

fn premultiply(channel: u32, alpha: u8) u32 {
    return (channel * alpha + 127) / 255;
}
