//! Win32 Window. Each Window is a top-level container HWND that owns
//! one or more Surface child HWNDs as tabs. The Window manages the tab
//! bar, tab switching, and window-level state (fullscreen, DPI scale).
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const Config = @import("../../config.zig").Config;

const App = @import("App.zig");
const Surface = @import("Surface.zig");
const TabOverview = @import("TabOverview.zig");
const TabBarCanvas = @import("TabBarCanvas.zig");
const Backdrop = @import("Backdrop.zig");
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// Maximum number of tabs per window.
const MAX_TABS: usize = 64;
const WM_TOGGLE_TAB_OVERVIEW = w32.WM_APP + 5;
const WM_REFRESH_TAB_OVERVIEW = w32.WM_APP + 6;
const WM_PAINT_TAB_BAR = w32.WM_APP + 7;

/// The parent App.
app: *App,

/// The top-level window handle.
hwnd: ?w32.HWND = null,
chrome_hwnd: ?w32.HWND = null,
tab_bar_hwnd: ?w32.HWND = null,
tab_paint_pending: bool = false,
tab_canvas: TabBarCanvas = .{},

/// Tab split trees owned by this window (fixed-capacity inline array).
tab_count: usize = 0,
tab_overview: TabOverview = .{},
overview_refresh_pending: bool = false,
tab_trees: [64]SplitTree(Surface) = undefined,

/// The currently focused surface within each tab.
tab_active_surface: [64]*Surface = undefined,

/// Index of the currently active (visible) tab.
active_tab: usize = 0,

/// Whether the tab bar is visible (shown when >1 tab).
tab_bar_visible: bool = false,

/// DPI scale factor (DPI / 96.0).
scale: f32 = 1.0,

/// Hit-test rectangles for each tab in the tab bar. Zero-initialized
/// so input handlers that read it before the first paint (e.g., a
/// synthetic WM_LBUTTONDOWN during startup) get a no-match instead of
/// stack garbage.
tab_rects: [64]w32.RECT = std.mem.zeroes([64]w32.RECT),

/// Hit-test rectangle for the "+" (new tab) button.
new_tab_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Index of the tab currently being hovered (-1 = none).
hover_tab: isize = -1,

/// Whether the close button on the hovered tab is being hovered.
hover_close: bool = false,

/// Whether the "+" (new tab) button is being hovered.
hover_new_tab: bool = false,

/// Tab drag state: which tab is being dragged (-1 = none).
drag_tab: isize = -1,
/// Starting X position of the drag.
drag_start_x: i16 = 0,
/// Whether the drag has exceeded the threshold and is active.
drag_active: bool = false,

/// Non-owning HWND resolved against the current trees before each retry.
pending_tab_reveal: ?w32.HWND = null,
/// Presentation can lag logical selection; input follows active_tab.
displayed_tab: ?w32.HWND = null,

/// Inline tab rename: Edit control HWND, font, and target tab index.
rename_edit: ?w32.HWND = null,
rename_font: ?*anyopaque = null,
rename_tab: usize = 0,
rename_window: bool = false,

/// UTF-16 title buffers for each tab (for painting the tab bar).
tab_titles: [64][256]u16 = undefined,

/// Length of each tab title in UTF-16 code units.
tab_title_lens: [64]u16 = undefined,

/// Explicit top-level window title override. Null follows the active tab.
window_title_override_len: ?u16 = null,
window_title_override: [256]u16 = undefined,

/// Whether the window is currently in fullscreen mode.
is_fullscreen: bool = false,

/// Saved window style for restoring from fullscreen.
saved_style: u32 = 0,

/// Saved window rect for restoring from fullscreen.
saved_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Font used for painting the tab bar (Segoe UI).
tab_font: ?*anyopaque = null,

/// Whether WM_MOUSELEAVE tracking is active for the tab bar.
tracking_mouse: bool = false,

/// Whether this window is a quick terminal (borderless popup, no tabs).
is_quick_terminal: bool = false,

/// Split divider drag state.
dragging_split: bool = false,
drag_split_handle: SplitTree(Surface).Node.Handle = .root,
drag_split_layout: SplitTree(Surface).Split.Layout = .horizontal,
drag_start_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// True after the last tab has been closed and WM_CLOSE has been posted.
/// Input handlers must bail when this is set — between PostMessage(WM_CLOSE)
/// and the dispatch, queued mouse/keyboard messages can otherwise reach
/// handlers that allocate into a window about to be freed (e.g. the
/// new-tab "+" button calling addTab()).
closing: bool = false,

/// Optional resize limits in window-rect pixels (incl. non-client).
/// 0 means "no limit" — the OS default applies. Set by .size_limit
/// and consulted from WM_GETMINMAXINFO.
min_track_w: i32 = 0,
min_track_h: i32 = 0,
max_track_w: i32 = 0,
max_track_h: i32 = 0,

/// Transient "columns × rows" overlay shown while resizing
/// (resize-overlay config). Owned popup: destroyed with the window.
resize_overlay_hwnd: ?w32.HWND = null,

/// True once the initial WM_SIZE has been seen; resize-overlay =
/// after-first suppresses the overlay for that first layout pass.
resize_seen_first: bool = false,

opacity_mode: OpacityMode = .configured,
transparency_supported: bool = false,
/// Keep native interop failure latched across config and DWM refreshes.
native_composition_failed: bool = false,

pub const OpacityMode = enum { configured, forced_opaque };

pub const InitOptions = struct {
    is_quick_terminal: bool = false,
    opacity_mode: OpacityMode = .configured,
};

/// Read HKCU\...\Themes\Personalize\AppsUseLightTheme. Returns true when the
/// system apps theme is light. A missing/erroring value is treated as light,
/// which is how the Personalize key reads before it is ever written.
pub fn systemUsesLightTheme() bool {
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
    );
    const valname = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    var hkey: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(w32.HKEY_CURRENT_USER, subkey, 0, w32.KEY_READ, &hkey) !=
        w32.ERROR_SUCCESS) return true;
    defer _ = w32.RegCloseKey(hkey);
    var kind: u32 = 0;
    var val: u32 = 0;
    var cb: u32 = @sizeOf(u32);
    if (w32.RegQueryValueExW(hkey, valname, null, &kind, @ptrCast(&val), &cb) !=
        w32.ERROR_SUCCESS) return true;
    if (kind != w32.REG_DWORD) return true;
    return val != 0; // 0 = dark, nonzero = light
}

/// Explicit window themes use the OS caption color; auto follows terminal luminance.
fn applyChromeTheme(hwnd: w32.HWND, theme: anytype, bg: anytype) void {
    const luminance: f32 = (0.2126 * @as(f32, @floatFromInt(bg.r)) +
        0.7152 * @as(f32, @floatFromInt(bg.g)) +
        0.0722 * @as(f32, @floatFromInt(bg.b))) / 255.0;
    const by_luminance = luminance < 0.5;
    const dark = switch (theme) {
        .dark => true,
        .light => false,
        .system => !systemUsesLightTheme(),
        // `ghostty` is a Linux/GTK-only theme; treat it as auto on Windows.
        .auto, .ghostty => by_luminance,
    };

    const dark_mode: u32 = if (dark) 1 else 0;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    const tint_caption = switch (theme) {
        .auto, .ghostty => true,
        else => false,
    };
    const caption_color: u32 = if (tint_caption)
        (@as(u32, bg.r)) | (@as(u32, bg.g) << 8) | (@as(u32, bg.b) << 16)
    else
        w32.DWMWA_COLOR_DEFAULT;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_CAPTION_COLOR,
        @ptrCast(&caption_color),
        @sizeOf(u32),
    );
}

fn applyBackgroundBlur(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var presentation_ready = false;
    if (self.tab_count > 0) {
        const tree = self.tab_trees[self.active_tab];
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (tree.zoomed) |zoomed| if (entry.handle != zoomed) continue;
            if (entry.view.transparency_supported) {
                presentation_ready = true;
                break;
            }
        }
    }
    const enabled = self.transparency_supported and presentation_ready and
        self.opacity_mode == .configured and
        self.app.config.@"background-opacity" < 1 and
        self.app.config.@"background-blur".enabled();
    Backdrop.apply(hwnd, enabled);
}

fn applyComposition(self: *Window) !void {
    if (self.hwnd == null) return;
    var enabled: w32.BOOL = .FALSE;
    const status = w32.DwmIsCompositionEnabled(&enabled);
    self.transparency_supported = status >= 0 and enabled.toBool() and
        !self.native_composition_failed;
    if (self.native_composition_failed) {
        log.warn("DirectComposition unavailable; using an opaque background", .{});
    } else if (!self.transparency_supported) {
        if (status < 0) log.warn("Windows transparency unavailable; using an opaque background (DwmIsCompositionEnabled HRESULT=0x{x})", .{@as(u32, @bitCast(status))}) else log.warn("Windows transparency unavailable; using an opaque background (DWM composition disabled)", .{});
    }
    self.refreshOpacity();
}

pub fn onConfigChange(self: *Window) void {
    if (self.hwnd) |hwnd| applyChromeTheme(hwnd, self.app.config.@"window-theme", self.app.config.background);
    self.applyComposition() catch |err| log.warn("composition setup failed: {}", .{err});
    self.layoutSplits();
    self.invalidateTabBar();
}

pub fn refreshOpacity(self: *Window) void {
    self.applyBackgroundBlur();
    var tab: usize = 0;
    while (tab < self.tab_count) : (tab += 1) {
        var it = self.tab_trees[tab].iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            if (!surface.core_surface_ready) continue;
            surface.core_surface.setBackgroundOpacityOverride(surface.backgroundOpacityOverride()) catch |err| {
                log.warn("opacity override failed surface={*} err={}", .{ surface, err });
            };
        }
    }
    self.tab_overview.updateAppearance();
    self.invalidateTabBar();
}

pub fn surfaceHwndReplaced(self: *Window, old: w32.HWND, new: w32.HWND) void {
    if (self.displayed_tab == old) self.displayed_tab = new;
    if (self.pending_tab_reveal == old) self.pending_tab_reveal = new;
}

/// Initialize the Window by creating the top-level HWND and tab bar font.
pub fn init(self: *Window, app: *App, options: InitOptions) !void {
    self.* = .{
        .app = app,
        .is_quick_terminal = options.is_quick_terminal,
        .opacity_mode = options.opacity_mode,
    };

    const style: u32 = (if (options.is_quick_terminal)
        w32.WS_POPUP
    else if (app.config.@"window-decoration" == .none)
        w32.WS_POPUP | w32.WS_THICKFRAME
    else
        w32.WS_OVERLAPPEDWINDOW) | w32.WS_CLIPCHILDREN;
    const ex_style: u32 = w32.WS_EX_NOREDIRECTIONBITMAP |
        (if (options.is_quick_terminal) w32.WS_EX_TOOLWINDOW else 0);

    // Cascade non-quick-terminal windows: stack each new window 30px
    // down/right of the most recently created window. Stops once the
    // offset would push the window off the work area, then resets.
    // Quick terminals are positioned by QuickTerminal.calculateRects.
    const cascade_step: i32 = 30;
    var cx: i32 = w32.CW_USEDEFAULT;
    var cy: i32 = w32.CW_USEDEFAULT;
    // Honor an explicit configured window position; it takes precedence over
    // the cascade below. Only when BOTH coordinates are set — passing
    // CW_USEDEFAULT for one axis is not a valid literal coordinate (Win32
    // only special-cases it on x, and would use a huge negative y or treat
    // y as nCmdShow), so a partial config falls back to full default.
    if (!options.is_quick_terminal) {
        if (app.config.@"window-position-x") |px| {
            if (app.config.@"window-position-y") |py| {
                cx = px;
                cy = py;
            }
        }
    }
    if (!options.is_quick_terminal and
        cx == w32.CW_USEDEFAULT and cy == w32.CW_USEDEFAULT and
        app.windows.items.len > 0)
    {
        // Find the previously created window's position and bump.
        const prev = app.windows.items[app.windows.items.len - 1];
        if (prev.hwnd) |ph| {
            var prev_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            if (w32.GetWindowRect(ph, &prev_rect) != 0) {
                cx = prev_rect.left + cascade_step;
                cy = prev_rect.top + cascade_step;
                // Reset the cascade if it would push off-screen.
                if (cx + 800 > w32.GetSystemMetrics(0) or
                    cy + 600 > w32.GetSystemMetrics(1))
                {
                    cx = w32.CW_USEDEFAULT;
                    cy = w32.CW_USEDEFAULT;
                }
            }
        }
    }

    // Create the top-level container window using the GhosttyWindow class.
    const hwnd = w32.CreateWindowExW(
        ex_style,
        App.WINDOW_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        style,
        cx,
        cy,
        800,
        600,
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;

    self.hwnd = hwnd;
    errdefer {
        self.tab_canvas.deinit();
        if (self.tab_bar_hwnd) |bar| {
            _ = w32.SetWindowLongPtrW(bar, w32.GWLP_USERDATA, 0);
            _ = w32.DestroyWindow(bar);
            self.tab_bar_hwnd = null;
        }
        if (self.chrome_hwnd) |chrome| {
            _ = w32.SetWindowLongPtrW(chrome, w32.GWLP_USERDATA, 0);
            _ = w32.DestroyWindow(chrome);
            self.chrome_hwnd = null;
        }
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
    const chrome = w32.CreateWindowExW(
        w32.WS_EX_LAYERED,
        App.CHROME_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.WS_CLIPCHILDREN,
        0,
        0,
        0,
        0,
        hwnd,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;
    self.chrome_hwnd = chrome;
    // Give GDI chrome its own redirection surface under the nonredirected parent.
    if (w32.SetLayeredWindowAttributes(chrome, 0, 255, w32.LWA_ALPHA) == 0)
        return error.Win32Error;
    // Owned layers remain visible where this no-redirection parent drops layered-child pixels.
    const tab_bar = w32.CreateWindowExW(
        w32.WS_EX_LAYERED | w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
        App.CHROME_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_POPUP,
        0,
        0,
        0,
        0,
        hwnd,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;
    self.tab_bar_hwnd = tab_bar;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    _ = w32.SetWindowLongPtrW(chrome, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    _ = w32.SetWindowLongPtrW(tab_bar, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.updateChromeRegion();

    applyChromeTheme(hwnd, app.config.@"window-theme", app.config.background);
    self.applyComposition() catch |err| log.warn("composition setup failed: {}", .{err});

    // Apply dark theme to common controls (scrollbar, etc.).
    _ = w32.SetWindowTheme(
        hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // Query DPI scale.
    const dpi = w32.GetDpiForWindow(hwnd);
    if (dpi != 0) {
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    }

    // Use the Windows UI font while keeping the compact macOS-like tab density.
    const font_height: i32 = -@as(i32, @intFromFloat(14.0 * self.scale));
    self.tab_font = w32.CreateFontW(
        font_height, // cHeight (negative = character height)
        0, // cWidth
        0, // cEscapement
        0, // cOrientation
        w32.FW_NORMAL, // cWeight
        0, // bItalic
        0, // bUnderline
        0, // bStrikeOut
        w32.DEFAULT_CHARSET, // iCharSet
        0, // iOutPrecision
        0, // iClipPrecision
        4, // Grayscale antialiasing remains valid over a translucent background.
        0, // iPitchAndFamily
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );

    // Don't show the window yet — addTab() will show the child
    // surface which triggers ShowWindow on the parent as needed.
    // Showing the parent before the terminal is ready can cause
    // timing issues with ConPTY.
}

fn handleDpiChange(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const dpi = w32.GetDpiForWindow(hwnd);
    if (dpi == 0) return;
    self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    if (self.tab_font) |font| _ = w32.DeleteObject(font);
    self.tab_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(16.0 * self.scale)),
        0,
        0,
        0,
        w32.FW_NORMAL,
        0,
        0,
        0,
        w32.DEFAULT_CHARSET,
        0,
        0,
        4,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    self.handleResize();
}

/// Deinitialize the Window: close all tabs, delete font, destroy HWNDs.
pub fn deinit(self: *Window) void {
    self.tab_overview.deinit();
    self.cleanupAllSurfaces();
    self.tab_canvas.deinit();
    if (self.tab_bar_hwnd) |bar| {
        _ = w32.SetWindowLongPtrW(bar, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(bar);
        self.tab_bar_hwnd = null;
    }
    if (self.tab_font) |font| {
        _ = w32.DeleteObject(font);
        self.tab_font = null;
    }
    if (self.chrome_hwnd) |chrome| {
        _ = w32.SetWindowLongPtrW(chrome, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(chrome);
        self.chrome_hwnd = null;
    }
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}

/// Returns the tab bar height in pixels, accounting for DPI scale.
/// Returns 0 if the tab bar is not visible.
pub fn tabBarHeight(self: *const Window) i32 {
    if (!self.tab_bar_visible) return 0;
    return @intFromFloat(@round(32.0 * self.scale));
}

/// Returns the client rect available for the active surface, which is
/// the full client area minus the tab bar height from the top.
pub fn surfaceRect(self: *const Window) w32.RECT {
    const hwnd = self.hwnd orelse return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) {
        return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }
    rect.top += self.tabBarHeight();
    return rect;
}

/// Returns the currently active Surface, or null if there are no tabs.
pub fn getActiveSurface(self: *Window) ?*Surface {
    if (self.tab_count == 0) return null;
    return self.tab_active_surface[self.active_tab];
}

/// Find the tab index containing a given surface.
/// Checks tab_active_surface first, then scans all trees.
pub fn findTabIndex(self: *Window, surface: *Surface) ?usize {
    for (self.tab_active_surface[0..self.tab_count], 0..) |s, i| {
        if (s == surface) return i;
    }
    for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            if (entry.view == surface) return i;
        }
    }
    return null;
}

/// Find the Node.Handle for a surface in a given tab's tree.
fn findHandle(self: *Window, tab_idx: usize, surface: *Surface) ?SplitTree(Surface).Node.Handle {
    var it = self.tab_trees[tab_idx].iterator();
    while (it.next()) |entry| {
        if (entry.view == surface) return entry.handle;
    }
    return null;
}

/// Add a new tab surface to this window. The surface is created,
/// initialized, and inserted at the position dictated by config.
pub fn addTab(self: *Window) !*Surface {
    return self.addTabWithOptions(.{ .context = .tab });
}

pub const AddTabOptions = Surface.InitOptions;

/// Add a tab with per-surface configuration overrides.
pub fn addTabWithOptions(self: *Window, options: AddTabOptions) !*Surface {
    if (self.closing) return error.WindowClosing;
    if (self.tab_count >= MAX_TABS) return error.TooManyTabs;
    self.cancelTabRename();

    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    try surface.initWithOptions(self.app, self, options);
    // After surface.init succeeds, create the SplitTree which takes ownership
    // via ref(). If this fails, we manually clean up.
    var tree = SplitTree(Surface).init(alloc, surface) catch |err| {
        surface.deinit();
        if (!surface.leaked) alloc.destroy(surface);
        return err;
    };
    errdefer tree.deinit(); // tree.deinit() calls unref() which deinits+frees surface

    // Determine insert position based on config.
    const pos: usize = switch (self.app.config.@"window-new-tab-position") {
        .current => if (self.tab_count > 0) self.active_tab + 1 else 0,
        .end => self.tab_count,
    };

    // Shift elements right to make room at pos.
    var i: usize = self.tab_count;
    while (i > pos) : (i -= 1) {
        self.tab_trees[i] = self.tab_trees[i - 1];
        self.tab_active_surface[i] = self.tab_active_surface[i - 1];
        self.tab_titles[i] = self.tab_titles[i - 1];
        self.tab_title_lens[i] = self.tab_title_lens[i - 1];
    }
    self.tab_trees[pos] = tree;
    self.tab_active_surface[pos] = surface;
    self.tab_count += 1;

    // Set default title.
    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(self.tab_titles[pos][0..default_title.len], default_title);
    self.tab_title_lens[pos] = @intCast(default_title.len);
    // Prepare the incoming frame at its final geometry before revealing it.
    self.tab_bar_visible = self.shouldShowTabBar();

    if (self.tab_count == 1) {
        self.active_tab = pos;
        self.displayed_tab = surface.hwnd;
        self.layoutSplits();
        // First tab — show the parent window now that the terminal is ready.
        // Quick terminal windows are shown by QuickTerminal.animateIn() instead.
        if (!self.is_quick_terminal) {
            if (self.hwnd) |h| {
                _ = w32.ShowWindow(h, w32.SW_SHOW);
                _ = w32.UpdateWindow(h);
            }
        }
        self.updateWindowTitle();
        // Set keyboard focus to the child surface so it receives input.
        if (!self.is_quick_terminal) {
            if (surface.hwnd) |h| _ = w32.SetFocus(h);
        }
    } else {
        self.selectTabIndex(pos);
    }
    self.updateTabBarVisibility();
    self.invalidateTabBar();
    return surface;
}

/// The core may hold the renderer lock during an action. Opening an owned
/// window changes focus and re-enters core handlers, so defer to the loop.
pub fn requestToggleTabOverview(self: *Window) bool {
    if (self.closing or self.is_quick_terminal or self.tab_count == 0) return false;
    return w32.PostMessageW(self.hwnd orelse return false, WM_TOGGLE_TAB_OVERVIEW, 0, 0) != 0;
}

/// Close every split in the selected tab, confirming once if any needs it.
pub fn requestCloseOverviewTab(self: *Window, id: u64) void {
    const index = TabOverview.findTab(self, id) orelse return;
    var it = self.tab_trees[index].iterator();
    var needs_confirmation = false;
    while (it.next()) |entry| {
        if (entry.view.core_surface_ready and entry.view.core_surface.needsConfirmQuit()) {
            needs_confirmation = true;
            break;
        }
    }
    if (!needs_confirmation) {
        self.closeTabByIndex(index);
        return;
    }

    const core_app = self.app.core_app;
    const owner_hwnd = self.hwnd;
    const result = w32.MessageBoxW(
        owner_hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral("Processes are still running in this tab.\nClose the tab and all its splits?"),
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        w32.MB_OKCANCEL | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2,
    );
    if (result != w32.IDOK) return;
    // The modal loop may have processed child exits or destroyed this
    // window. Resolve identity again; never dereference the old self.
    const surface = core_app.findSurfaceByID(id) orelse return;
    const owner = surface.rt_surface.parent_window;
    if (owner.closing or owner.hwnd != owner_hwnd) return;
    owner.closeTabByIndex(TabOverview.findTab(owner, id) orelse return);
}

/// Close a tab by surface pointer. Removes from the tab list,
/// deinits the tree, and adjusts the active tab index.
pub fn closeTab(self: *Window, surface: *Surface) void {
    log.debug("closeTab called for surface={x} tab_count={}", .{ @intFromPtr(surface), self.tab_count });
    const idx = self.findTabIndex(surface) orelse return;
    self.closeTabByIndex(idx);
}

fn closeTabByIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;
    // Cancel any in-progress rename (the edit control may belong to this tab).
    self.cancelTabRename();
    var tree = self.tab_trees[idx];
    tree.deinit(); // This unrefs all surfaces → Surface.unref frees when ref_count=0
    var i: usize = idx;
    while (i + 1 < self.tab_count) : (i += 1) {
        self.tab_trees[i] = self.tab_trees[i + 1];
        self.tab_active_surface[i] = self.tab_active_surface[i + 1];
        self.tab_titles[i] = self.tab_titles[i + 1];
        self.tab_title_lens[i] = self.tab_title_lens[i + 1];
    }
    self.tab_count -= 1;
    if (self.tab_count == 0) {
        self.updateChromeRegion();
        self.closing = true;
        self.tab_overview.hide(false);
        if (self.hwnd) |hwnd| _ = w32.PostMessageW(hwnd, w32.WM_CLOSE, 0, 0);
        return;
    }
    if (self.active_tab >= self.tab_count) {
        self.active_tab = self.tab_count - 1;
    } else if (self.active_tab > idx) {
        self.active_tab -= 1;
    }
    self.selectTabIndex(self.active_tab);
    self.updateTabBarVisibility();
}

/// Close tabs based on mode: this (current), other (all but current), right (all after current).
pub fn closeTabMode(self: *Window, mode: apprt.action.CloseTabMode, surface: *Surface) void {
    switch (mode) {
        .this => self.closeSplitSurface(surface),
        .other => {
            var current = self.findTabIndex(surface) orelse return;
            var i: usize = self.tab_count;
            while (i > 0) {
                i -= 1;
                if (i != current) {
                    self.closeTabByIndex(i);
                    if (i < current) current -= 1;
                }
            }
        },
        .right => {
            const current = self.findTabIndex(surface) orelse return;
            var i: usize = self.tab_count;
            while (i > current + 1) {
                i -= 1;
                self.closeTabByIndex(i);
            }
        },
    }
}

/// Close a single surface within a split tree. If it's the last surface
/// in the tab, close the entire tab instead.
pub fn closeSplitSurface(self: *Window, surface: *Surface) void {
    const alloc = self.app.core_app.alloc;
    const tab = self.findTabIndex(surface) orelse {
        log.debug("closeSplitSurface: surface not found in any tab", .{});
        return;
    };
    const tree = &self.tab_trees[tab];

    if (!tree.isSplit()) {
        log.debug("closeSplitSurface: not split, closing whole tab", .{});
        self.closeTab(surface);
        return;
    }

    const handle = self.findHandle(tab, surface) orelse {
        log.debug("closeSplitSurface: handle not found", .{});
        return;
    };
    log.debug("closeSplitSurface: removing handle={} from tab={}", .{ handle.idx(), tab });

    // Find next focus target BEFORE removing.
    const next_handle = (tree.goto(alloc, handle, .next) catch null) orelse
        (tree.goto(alloc, handle, .previous) catch null);

    // Extract the surface pointer from the next handle before we modify the tree.
    const next_surface: ?*Surface = if (next_handle) |nh| blk: {
        break :blk switch (tree.nodes[nh.idx()]) {
            .leaf => |v| v,
            .split => null,
        };
    } else null;
    log.debug("closeSplitSurface: has_next={}", .{next_surface != null});

    const new_tree = tree.remove(alloc, handle) catch {
        log.err("failed to remove surface from split tree", .{});
        return;
    };
    log.debug("closeSplitSurface: remove returned, new_tree nodes={}", .{new_tree.nodes.len});

    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;

    if (next_surface) |ns| {
        log.debug("closeSplitSurface: focusing next surface", .{});
        self.tab_active_surface[tab] = ns;
        self.layoutSplits();
        if (!self.tab_overview.active) {
            if (ns.hwnd) |h| _ = w32.SetFocus(h);
        }
        self.invalidateTabBar();
    } else {
        log.debug("closeSplitSurface: no next surface, closing tab", .{});
        self.closeTabByIndex(tab);
    }
}

/// Whether the top-level window can display its active tab. A layout pass can
/// run while hidden (quick terminal, toggle_visibility) or minimized.
fn isVisible(self: *const Window) bool {
    const hwnd = self.hwnd orelse return false;
    return w32.IsWindowVisible_(hwnd) != 0 and w32.IsIconic(hwnd) == 0;
}

pub fn onSurfaceFocus(self: *Window, surface: *Surface) void {
    const idx = self.findTabIndex(surface) orelse return;
    self.tab_active_surface[idx] = surface;
    if (idx != self.active_tab) self.selectTabIndex(idx);
}

/// Publish parent visibility without exposing panes hidden by split zoom.
fn setActiveTabVisible(self: *Window, visible: bool) void {
    if (self.active_tab >= self.tab_count) return;
    const tree = self.tab_trees[self.active_tab];
    var it = tree.iterator();
    while (it.next()) |entry| {
        entry.view.setVisible(visible and (tree.zoomed == null or entry.handle == tree.zoomed.?));
    }
    if (self.displayedTabIndex()) |displayed| {
        if (displayed != self.active_tab) {
            const displayed_tree = self.tab_trees[displayed];
            it = displayed_tree.iterator();
            while (it.next()) |entry| {
                entry.view.setVisible(visible and (displayed_tree.zoomed == null or entry.handle == displayed_tree.zoomed.?));
            }
        }
    }
}

/// Switch to the tab at the given index.
pub fn selectTabIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;
    self.cancelPendingTabReveal(idx);
    self.cancelTabRename();
    // Clear any in-progress tab drag
    if (self.drag_tab >= 0) {
        self.drag_tab = -1;
        self.drag_active = false;
        _ = w32.ReleaseCapture();
    }
    const previous = self.displayedTabIndex() orelse self.active_tab;
    self.active_tab = idx;
    if (!self.prepareTabReveal(idx)) {
        self.pending_tab_reveal = self.tab_active_surface[idx].hwnd;
        if (self.hwnd) |h| {
            if (w32.SetTimer(h, TAB_REVEAL_TIMER_ID, 10, null) == 0) {
                self.cancelPendingTabReveal(null);
                log.warn("could not schedule incoming tab reveal", .{});
            }
        }
        if (self.tab_active_surface[idx].hwnd) |h| _ = w32.SetFocus(h);
        self.updateWindowTitle();
        return;
    }
    if (previous < self.tab_count and previous != idx) {
        var it = self.tab_trees[previous].iterator();
        while (it.next()) |entry| entry.view.setVisible(false);
    }
    self.swapTabVisibility(previous, idx) catch |err| {
        log.warn("tab visibility transaction failed err={}", .{err});
        if (previous < self.tab_count and previous != idx) {
            var it = self.tab_trees[previous].iterator();
            while (it.next()) |entry| {
                if (entry.view.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
            }
        }
    };
    const surface = self.tab_active_surface[idx];
    self.displayed_tab = surface.hwnd;
    self.layoutSplits();
    // An inactive child can exit while the user is searching. Keep focus
    // in the overview; explicit activation hides it before selecting.
    if (self.chrome_hwnd) |chrome| _ = w32.UpdateWindow(chrome);
    if (!self.tab_overview.active) {
        if (surface.hwnd) |h| _ = w32.SetFocus(h);
    }
    self.updateWindowTitle();
    self.invalidateTabBar();
}

const TAB_REVEAL_TIMER_ID: usize = 0x5452;

fn tabIndexForHwnd(self: *const Window, handle: ?w32.HWND) ?usize {
    const hwnd = handle orelse return null;
    for (0..self.tab_count) |idx| {
        var it = self.tab_trees[idx].iterator();
        while (it.next()) |entry| {
            if (entry.view.hwnd == hwnd) return idx;
        }
    }
    return null;
}

fn displayedTabIndex(self: *Window) ?usize {
    if (self.tabIndexForHwnd(self.displayed_tab)) |idx| return idx;
    // A split pane can exit while another pane still displays this tab.
    for (0..self.tab_count) |idx| {
        var it = self.tab_trees[idx].iterator();
        while (it.next()) |entry| {
            const hwnd = entry.view.hwnd orelse continue;
            if (w32.GetWindowLongW(hwnd, w32.GWL_STYLE) & w32.WS_VISIBLE_STYLE == 0) continue;
            self.displayed_tab = hwnd;
            return idx;
        }
    }
    return null;
}

fn pendingTabIndex(self: *const Window) ?usize {
    return self.tabIndexForHwnd(self.pending_tab_reveal);
}

fn cancelPendingTabReveal(self: *Window, next: ?usize) void {
    if (self.pending_tab_reveal == null) return;
    if (self.pendingTabIndex()) |idx| {
        if (self.displayedTabIndex() != idx and next != idx) {
            var it = self.tab_trees[idx].iterator();
            while (it.next()) |entry| entry.view.setVisible(false);
        }
    }
    self.pending_tab_reveal = null;
    if (self.hwnd) |h| _ = w32.KillTimer(h, TAB_REVEAL_TIMER_ID);
}

fn tabFramesReady(self: *const Window, idx: usize) bool {
    const tree = self.tab_trees[idx];
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (tree.zoomed) |zoomed| if (entry.handle != zoomed) continue;
        if (!entry.view.hasPresentedFrame()) return false;
    }
    return true;
}

fn prepareTabReveal(self: *Window, idx: usize) bool {
    const tree = self.tab_trees[idx];
    var it = tree.iterator();
    var hidden = false;
    while (it.next()) |entry| {
        if (tree.zoomed) |zoomed| if (entry.handle != zoomed) continue;
        if (entry.view.hwnd) |h| {
            if (w32.GetWindowLongW(h, w32.GWL_STYLE) & w32.WS_VISIBLE_STYLE == 0) hidden = true;
        }
    }
    if (!hidden) return true;

    // Size and present hidden children before removing the outgoing frame.
    self.layoutNode(tree, tree.zoomed orelse .root, self.surfaceRect(), false);
    if (self.tabFramesReady(idx)) return true;
    it = tree.iterator();
    while (it.next()) |entry| {
        if (tree.zoomed) |zoomed| if (entry.handle != zoomed) continue;
        const view = entry.view;
        if (!view.core_surface_ready) continue;
        if (view.frame_event) |event| _ = w32.ResetEvent(event);
        const already_visible = view.last_reported_visible == true;
        view.setVisible(true);
        if (already_visible) view.core_surface.renderer_thread.wakeup.notify() catch |err| {
            log.warn("tab reveal wakeup failed err={}", .{err});
        };
    }
    // Share one frame budget across panes, including a stalled renderer.
    const started = w32.GetTickCount64();
    it = tree.iterator();
    while (it.next()) |entry| {
        if (tree.zoomed) |zoomed| if (entry.handle != zoomed) continue;
        const elapsed = w32.GetTickCount64() - started;
        if (elapsed >= 16) break;
        if (entry.view.frame_event) |event| _ = w32.WaitForSingleObject(event, @intCast(16 - elapsed));
    }
    return self.tabFramesReady(idx);
}

fn swapTabVisibility(self: *Window, previous: usize, next: usize) !void {
    var count: i32 = 0;
    if (previous < self.tab_count and previous != next) {
        var it = self.tab_trees[previous].iterator();
        while (it.next()) |entry| {
            if (entry.view.hwnd != null) count += 1;
        }
    }
    const tree = self.tab_trees[next];
    var it = tree.iterator();
    while (it.next()) |entry| {
        if (entry.view.hwnd != null) count += 1;
    }
    var batch = w32.BeginDeferWindowPos(count) orelse return error.Win32Error;
    const flags = w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOZORDER | w32.SWP_NOACTIVATE;
    if (previous < self.tab_count and previous != next) {
        var old = self.tab_trees[previous].iterator();
        while (old.next()) |entry| {
            const h = entry.view.hwnd orelse continue;
            batch = w32.DeferWindowPos(batch, h, null, 0, 0, 0, 0, flags | w32.SWP_HIDEWINDOW) orelse return error.Win32Error;
        }
    }
    it = tree.iterator();
    while (it.next()) |entry| {
        const h = entry.view.hwnd orelse continue;
        const visible = if (tree.zoomed) |zoomed| entry.handle == zoomed else true;
        batch = w32.DeferWindowPos(batch, h, null, 0, 0, 0, 0, flags | (if (visible) w32.SWP_SHOWWINDOW else w32.SWP_HIDEWINDOW)) orelse return error.Win32Error;
    }
    if (w32.EndDeferWindowPos(batch) == 0) return error.Win32Error;
}

/// Layout split panes for the active tab.
pub fn layoutSplits(self: *Window) void {
    if (self.tab_count == 0) {
        self.updateChromeRegion();
        self.applyBackgroundBlur();
        return;
    }
    const tree = self.tab_trees[self.active_tab];
    const rect = self.surfaceRect();
    if (self.pending_tab_reveal != null) {
        self.layoutNode(tree, tree.zoomed orelse .root, rect, false);
        return;
    }
    if (tree.zoomed) |zoomed_handle| {
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (entry.handle == zoomed_handle) {
                entry.view.setVisible(self.isVisible());
                if (entry.view.hwnd) |h| {
                    const w = @max(rect.right - rect.left, 1);
                    const ht = @max(rect.bottom - rect.top, 1);
                    _ = w32.MoveWindow(h, rect.left, rect.top, @intCast(w), @intCast(ht), 1);
                    _ = w32.ShowWindow(h, w32.SW_SHOW);
                }
            } else {
                entry.view.setVisible(false);
                if (entry.view.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
            }
        }
        self.updateChromeRegion();
        self.applyBackgroundBlur();
        return;
    }
    self.layoutNode(tree, .root, rect, true);
    self.updateChromeRegion();
    self.applyBackgroundBlur();
}

fn positionTabBar(self: *Window, visible: bool) void {
    const parent = self.hwnd orelse return;
    const bar = self.tab_bar_hwnd orelse return;
    var client: w32.RECT = undefined;
    var origin = w32.POINT{ .x = 0, .y = 0 };
    if (w32.GetClientRect(parent, &client) == 0 or w32.ClientToScreen(parent, &origin) == 0) return;
    const height = self.tabBarHeight();
    const show = visible and height > 0 and !self.closing;
    const visibility: u32 = if (show) w32.SWP_SHOWWINDOW else w32.SWP_HIDEWINDOW;
    var after: ?w32.HWND = null;
    if (show) {
        var previous = w32.GetWindow(parent, w32.GW_HWNDPREV);
        if (previous == bar) previous = w32.GetWindow(bar, w32.GW_HWNDPREV);
        const topmost = w32.GetWindowLongW(parent, w32.GWL_EXSTYLE) & w32.WS_EX_TOPMOST != 0;
        const band = if (topmost) w32.HWND_TOPMOST else w32.HWND_NOTOPMOST;
        after = if (previous) |p|
            if ((w32.GetWindowLongW(p, w32.GWL_EXSTYLE) & w32.WS_EX_TOPMOST != 0) == topmost) p else band
        else
            band;
    }
    // Match the owner's z-order without raising it or covering unrelated apps.
    const flags = w32.SWP_NOACTIVATE | w32.SWP_NOOWNERZORDER | visibility |
        (if (show) @as(u32, 0) else w32.SWP_NOZORDER);
    if (w32.SetWindowPos(bar, after, origin.x, origin.y, client.right - client.left, height, flags) == 0) {
        log.warn("could not position translucent tab strip", .{});
    }
}

fn updateChromeRegion(self: *Window) void {
    const parent = self.hwnd orelse return;
    const chrome = self.chrome_hwnd orelse return;
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(parent, &client) == 0) return;
    const width = client.right - client.left;
    const height = client.bottom - client.top;
    const flags = w32.SWP_NOACTIVATE | (if (self.rename_edit == null) w32.SWP_NOZORDER else @as(u32, 0));
    if (w32.SetWindowPos(chrome, null, 0, 0, width, height, flags) == 0) {
        log.warn("could not size composition chrome", .{});
        return;
    }
    const bar_height = self.tabBarHeight();
    self.positionTabBar(self.isVisible());
    self.invalidateTabBar();

    const region = w32.CreateRectRgn(0, 0, width, height) orelse {
        log.warn("could not allocate composition chrome region", .{});
        return;
    };
    var owned = false;
    defer {
        if (!owned) _ = w32.DeleteObject(region);
    }
    const tab_region = w32.CreateRectRgn(0, 0, width, bar_height) orelse return;
    var tab_region_owned = false;
    defer {
        if (!tab_region_owned) _ = w32.DeleteObject(tab_region);
    }
    if (bar_height > 0) {
        const bar_region = w32.CreateRectRgn(0, 0, width, bar_height) orelse return;
        defer _ = w32.DeleteObject(bar_region);
        if (w32.CombineRgn(region, region, bar_region, w32.RGN_DIFF) == 0) {
            log.warn("could not exclude translucent tab strip from opaque chrome", .{});
            return;
        }
    }
    if (self.tab_count > 0) {
        const displayed = self.displayedTabIndex() orelse self.active_tab;
        const tree = self.tab_trees[displayed];
        var it = tree.iterator();
        while (it.next()) |entry| {
            if (tree.zoomed) |zoomed| if (entry.handle != zoomed) continue;
            const child = entry.view.hwnd orelse continue;
            if (w32.GetWindowLongW(child, w32.GWL_STYLE) & w32.WS_VISIBLE_STYLE == 0) continue;
            var rect: w32.RECT = undefined;
            if (w32.GetWindowRect(child, &rect) == 0) {
                log.warn("could not locate composition child", .{});
                return;
            }
            var points = [2]w32.POINT{
                .{ .x = rect.left, .y = rect.top },
                .{ .x = rect.right, .y = rect.bottom },
            };
            w32.SetLastError(0);
            if (w32.MapWindowPoints(null, chrome, &points[0], 2) == 0 and
                std.os.windows.GetLastError() != .SUCCESS)
            {
                log.warn("could not map composition child rectangle", .{});
                return;
            }
            const hole = w32.CreateRectRgn(points[0].x, points[0].y, points[1].x, points[1].y) orelse {
                log.warn("could not allocate composition child region", .{});
                return;
            };
            defer _ = w32.DeleteObject(hole);
            if (w32.CombineRgn(region, region, hole, w32.RGN_DIFF) == 0) {
                log.warn("could not exclude composition child region", .{});
                return;
            }
        }
    }
    if (self.rename_edit) |edit| {
        // Single-tab window-title editing can overlap a terminal.
        var rect: w32.RECT = undefined;
        if (w32.GetWindowRect(edit, &rect) == 0) {
            log.warn("could not locate composition title editor", .{});
            return;
        }
        var points = [2]w32.POINT{
            .{ .x = rect.left, .y = rect.top },
            .{ .x = rect.right, .y = rect.bottom },
        };
        w32.SetLastError(0);
        if (w32.MapWindowPoints(null, chrome, &points[0], 2) == 0 and
            std.os.windows.GetLastError() != .SUCCESS)
        {
            log.warn("could not map composition title editor", .{});
            return;
        }
        const overlay = w32.CreateRectRgn(points[0].x, points[0].y, points[1].x, points[1].y) orelse {
            log.warn("could not allocate composition title editor region", .{});
            return;
        };
        defer _ = w32.DeleteObject(overlay);
        if (w32.CombineRgn(region, region, overlay, w32.RGN_OR) == 0) {
            log.warn("could not include composition title editor region", .{});
            return;
        }
        if (w32.CombineRgn(tab_region, tab_region, overlay, w32.RGN_DIFF) == 0) {
            log.warn("could not expose native title editor through tab strip", .{});
            return;
        }
    }
    if (w32.SetWindowRgn(chrome, region, 1) != 0) {
        owned = true;
    } else {
        log.warn("could not apply composition chrome region", .{});
    }
    if (self.tab_bar_hwnd) |bar| {
        if (w32.SetWindowRgn(bar, tab_region, 1) != 0) {
            tab_region_owned = true;
        } else {
            log.warn("could not apply translucent tab strip region", .{});
        }
    }
    _ = w32.InvalidateRect(chrome, null, 1);
}

fn layoutNode(self: *Window, tree: SplitTree(Surface), handle: SplitTree(Surface).Node.Handle, rect: w32.RECT, show: bool) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => |view| {
            if (show) view.setVisible(self.isVisible());
            if (view.hwnd) |h| {
                const w = @max(rect.right - rect.left, 1);
                const ht = @max(rect.bottom - rect.top, 1);
                _ = w32.MoveWindow(h, rect.left, rect.top, @intCast(w), @intCast(ht), @intFromBool(show));
                if (show) _ = w32.ShowWindow(h, w32.SW_SHOW);
            }
        },
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.layoutNode(tree, s.left, left_rect, show);
                self.layoutNode(tree, s.right, right_rect, show);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.layoutNode(tree, s.left, top_rect, show);
                self.layoutNode(tree, s.right, bottom_rect, show);
            }
        },
    }
}

/// Paint divider lines between split panes in the active tab.
fn paintDividers(self: *Window, hdc: w32.HDC) void {
    if (self.tab_count == 0) return;
    const tree = self.tab_trees[self.active_tab];
    if (!tree.isSplit()) return;
    if (tree.zoomed != null) return;
    const rect = self.surfaceRect();
    self.paintDividerNode(hdc, tree, .root, rect);
}

fn dividerBitmapInfo() w32.BITMAPINFO {
    return .{ .bmiHeader = .{
        .biWidth = 1,
        .biHeight = -1,
        .biPlanes = 1,
        .biBitCount = 32,
        .biCompression = w32.BI_RGB,
        .biSizeImage = 4,
        .biXPelsPerMeter = 0,
        .biYPelsPerMeter = 0,
        .biClrUsed = 0,
        .biClrImportant = 0,
    } };
}
fn paintDividerNode(self: *Window, hdc: w32.HDC, tree: SplitTree(Surface), handle: SplitTree(Surface).Node.Handle, rect: w32.RECT) void {
    if (handle.idx() >= tree.nodes.len) return;
    switch (tree.nodes[handle.idx()]) {
        .leaf => {},
        .split => |s| {
            const gap: i32 = @intFromFloat(@round(5.0 * self.scale));
            const line_w: i32 = @max(@as(i32, @intFromFloat(@round(1.0 * self.scale))), 1);

            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                const pixel = [_]u8{ 0x80, 0x80, 0x80, 0xFF };
                const info = dividerBitmapInfo();
                _ = w32.StretchDIBits(hdc, split_x - @divTrunc(line_w, 2), rect.top, line_w, rect.bottom - rect.top, 0, 0, 1, 1, &pixel, &info, w32.DIB_RGB_COLORS, w32.SRCCOPY);
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                self.paintDividerNode(hdc, tree, s.left, left_rect);
                self.paintDividerNode(hdc, tree, s.right, right_rect);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                const pixel = [_]u8{ 0x80, 0x80, 0x80, 0xFF };
                const info = dividerBitmapInfo();
                _ = w32.StretchDIBits(hdc, rect.left, split_y - @divTrunc(line_w, 2), rect.right - rect.left, line_w, 0, 0, 1, 1, &pixel, &info, w32.DIB_RGB_COLORS, w32.SRCCOPY);
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                self.paintDividerNode(hdc, tree, s.left, top_rect);
                self.paintDividerNode(hdc, tree, s.right, bottom_rect);
            }
        },
    }
}

const DividerHit = struct {
    handle: SplitTree(Surface).Node.Handle,
    layout: SplitTree(Surface).Split.Layout,
};

fn hitTestDivider(self: *Window, x: i32, y: i32) ?DividerHit {
    if (self.tab_count == 0) return null;
    const tree = self.tab_trees[self.active_tab];
    if (!tree.isSplit()) return null;
    if (tree.zoomed != null) return null;
    const rect = self.surfaceRect();
    return self.hitTestDividerNode(tree, .root, rect, x, y);
}

fn hitTestDividerNode(
    self: *Window,
    tree: SplitTree(Surface),
    handle: SplitTree(Surface).Node.Handle,
    rect: w32.RECT,
    x: i32,
    y: i32,
) ?DividerHit {
    if (handle.idx() >= tree.nodes.len) return null;
    switch (tree.nodes[handle.idx()]) {
        .leaf => return null,
        .split => |s| {
            const gap: i32 = @as(i32, @intFromFloat(@round(5.0 * self.scale)));
            const hit_area: i32 = @max(@as(i32, @intFromFloat(@round(3.0 * self.scale))), 3);

            if (s.layout == .horizontal) {
                const total_w = rect.right - rect.left;
                const split_x = rect.left + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_w))));
                if (x >= split_x - hit_area and x <= split_x + hit_area and y >= rect.top and y <= rect.bottom) {
                    return .{ .handle = handle, .layout = .horizontal };
                }
                const left_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = split_x - @divTrunc(gap, 2), .bottom = rect.bottom };
                const right_rect = w32.RECT{ .left = split_x + @divTrunc(gap + 1, 2), .top = rect.top, .right = rect.right, .bottom = rect.bottom };
                return self.hitTestDividerNode(tree, s.left, left_rect, x, y) orelse
                    self.hitTestDividerNode(tree, s.right, right_rect, x, y);
            } else {
                const total_h = rect.bottom - rect.top;
                const split_y = rect.top + @as(i32, @intFromFloat(@as(f32, @floatCast(s.ratio)) * @as(f32, @floatFromInt(total_h))));
                if (y >= split_y - hit_area and y <= split_y + hit_area and x >= rect.left and x <= rect.right) {
                    return .{ .handle = handle, .layout = .vertical };
                }
                const top_rect = w32.RECT{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = split_y - @divTrunc(gap, 2) };
                const bottom_rect = w32.RECT{ .left = rect.left, .top = split_y + @divTrunc(gap + 1, 2), .right = rect.right, .bottom = rect.bottom };
                return self.hitTestDividerNode(tree, s.left, top_rect, x, y) orelse
                    self.hitTestDividerNode(tree, s.right, bottom_rect, x, y);
            }
        },
    }
}

fn startDividerDrag(self: *Window, handle: SplitTree(Surface).Node.Handle, layout: SplitTree(Surface).Split.Layout) void {
    self.dragging_split = true;
    self.drag_split_handle = handle;
    self.drag_split_layout = layout;
    self.drag_start_rect = self.surfaceRect();
    if (self.hwnd) |hwnd| _ = w32.SetCapture(hwnd);
}

fn updateDividerDrag(self: *Window, x: i32, y: i32) void {
    if (!self.dragging_split) return;
    const rect = self.drag_start_rect;
    const handle = self.drag_split_handle;

    const new_ratio: f16 = switch (self.drag_split_layout) {
        .horizontal => ratio: {
            const total: f32 = @floatFromInt(@max(rect.right - rect.left, 1));
            const pos: f32 = @floatFromInt(x - rect.left);
            break :ratio @floatCast(std.math.clamp(pos / total, 0.1, 0.9));
        },
        .vertical => ratio: {
            const total: f32 = @floatFromInt(@max(rect.bottom - rect.top, 1));
            const pos: f32 = @floatFromInt(y - rect.top);
            break :ratio @floatCast(std.math.clamp(pos / total, 0.1, 0.9));
        },
    };

    self.tab_trees[self.active_tab].resizeInPlace(handle, new_ratio);
    self.layoutSplits();
}

fn endDividerDrag(self: *Window) void {
    if (!self.dragging_split) return;
    self.dragging_split = false;
    _ = w32.ReleaseCapture();
}

/// Create a new split in the active tab.
pub fn newSplit(self: *Window, direction: SplitTree(Surface).Split.Direction) !void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    // Create new surface.
    const new_surface = try alloc.create(Surface);
    errdefer {
        new_surface.deinit();
        if (!new_surface.leaked) alloc.destroy(new_surface);
    }
    try new_surface.init(self.app, self, .split);

    // Create a single-node tree for the new surface.
    var insert_tree = try SplitTree(Surface).init(alloc, new_surface);
    defer insert_tree.deinit();

    // Split the current tree at the active surface.
    const new_tree = try self.tab_trees[tab].split(
        alloc,
        handle,
        direction,
        @as(f16, 0.5),
        &insert_tree,
    );

    // Replace old tree.
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;

    // Focus the new surface.
    self.tab_active_surface[tab] = new_surface;

    self.layoutSplits();
    if (new_surface.hwnd) |h| _ = w32.SetFocus(h);
}

/// Navigate to a split in the given direction.
pub fn gotoSplit(self: *Window, goto_target: apprt.action.GotoSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const tree = &self.tab_trees[tab];

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    const target: SplitTree(Surface).Goto = switch (goto_target) {
        .previous => .previous,
        .next => .next,
        .up => .{ .spatial = .up },
        .down => .{ .spatial = .down },
        .left => .{ .spatial = .left },
        .right => .{ .spatial = .right },
    };

    const dest_handle = (tree.goto(alloc, handle, target) catch return) orelse return;

    switch (tree.nodes[dest_handle.idx()]) {
        .leaf => |surface| {
            self.tab_active_surface[tab] = surface;
            if (surface.hwnd) |h| _ = w32.SetFocus(h);
        },
        .split => {},
    }
}

/// Resize the nearest split in the given direction by the given pixel amount.
pub fn resizeSplit(self: *Window, rs: apprt.action.ResizeSplit) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;
    const tree = &self.tab_trees[tab];

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    const layout: SplitTree(Surface).Split.Layout = switch (rs.direction) {
        .left, .right => .horizontal,
        .up, .down => .vertical,
    };

    const rect = self.surfaceRect();
    const dimension: f32 = switch (layout) {
        .horizontal => @floatFromInt(@max(rect.right - rect.left, 1)),
        .vertical => @floatFromInt(@max(rect.bottom - rect.top, 1)),
    };
    const sign: f32 = switch (rs.direction) {
        .left, .up => -1.0,
        .right, .down => 1.0,
    };
    const delta: f16 = @floatCast(sign * @as(f32, @floatFromInt(rs.amount)) / dimension);

    const new_tree = tree.resize(alloc, handle, layout, delta) catch return;
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.layoutSplits();
}

/// Equalize all splits in the active tab.
pub fn equalizeSplits(self: *Window) void {
    if (self.tab_count == 0) return;
    const alloc = self.app.core_app.alloc;
    const tab = self.active_tab;

    const new_tree = self.tab_trees[tab].equalize(alloc) catch return;
    var old_tree = self.tab_trees[tab];
    old_tree.deinit();
    self.tab_trees[tab] = new_tree;
    self.layoutSplits();
}

/// Toggle zoom on the active split surface.
pub fn toggleSplitZoom(self: *Window) void {
    if (self.tab_count == 0) return;
    const tab = self.active_tab;
    var tree = &self.tab_trees[tab];

    if (!tree.isSplit()) return;

    const active_surface = self.tab_active_surface[tab];
    const handle = self.findHandle(tab, active_surface) orelse return;

    if (tree.zoomed) |z| {
        if (z == handle) {
            tree.zoom(null);
        } else {
            tree.zoom(handle);
        }
    } else {
        tree.zoom(handle);
    }
    self.layoutSplits();
}

/// Navigate to a tab by GotoTab target (previous, next, last, or index).
pub fn selectTab(self: *Window, target: apprt.action.GotoTab) bool {
    if (self.tab_count <= 1) return false;
    const idx: usize = switch (target) {
        .previous => if (self.active_tab > 0) self.active_tab - 1 else self.tab_count - 1,
        .next => if (self.active_tab + 1 < self.tab_count) self.active_tab + 1 else 0,
        .last => self.tab_count - 1,
        _ => blk: {
            // GotoTab carries a c_int; clamp non-negative before casting
            // so a negative sentinel doesn't panic the @intCast.
            const raw = @backingInt(target);
            if (raw < 0) return false;
            const n: usize = @intCast(raw);
            break :blk if (n < self.tab_count) n else return false;
        },
    };
    self.selectTabIndex(idx);
    self.invalidateTabBar();
    return true;
}

/// Move the active tab by a relative offset, wrapping cyclically.
pub fn moveTab(self: *Window, amount: isize) void {
    if (self.tab_count <= 1) return;
    const n: isize = @intCast(self.active_tab);
    const count: isize = @intCast(self.tab_count);
    const new_index: usize = @intCast(@mod(n + amount, count));
    if (new_index == self.active_tab) return;

    // Swap all tab state between active_tab and new_index.
    std.mem.swap(SplitTree(Surface), &self.tab_trees[self.active_tab], &self.tab_trees[new_index]);
    std.mem.swap(*Surface, &self.tab_active_surface[self.active_tab], &self.tab_active_surface[new_index]);
    std.mem.swap([256]u16, &self.tab_titles[self.active_tab], &self.tab_titles[new_index]);
    std.mem.swap(u16, &self.tab_title_lens[self.active_tab], &self.tab_title_lens[new_index]);
    self.active_tab = new_index;
    self.invalidateTabBar();
}

/// Move the tab containing `surface`, including all of its splits, into a new
/// native window without restarting any child processes.
pub fn moveTabToNewWindow(self: *Window, surface: *Surface) !bool {
    if (self.is_quick_terminal or self.tab_count <= 1) return false;
    const tab_idx = self.findTabIndex(surface) orelse return false;

    const alloc = self.app.core_app.alloc;
    const destination = try alloc.create(Window);
    destination.init(self.app, .{ .opacity_mode = self.opacity_mode }) catch |err| {
        alloc.destroy(destination);
        return err;
    };
    errdefer {
        destination.deinit();
        alloc.destroy(destination);
    }

    try self.app.windows.append(alloc, destination);
    var tracked = true;
    errdefer if (tracked) {
        for (self.app.windows.items, 0..) |window, i| {
            if (window == destination) {
                _ = self.app.windows.orderedRemove(i);
                break;
            }
        }
    };

    const destination_hwnd = destination.hwnd orelse return error.Win32Error;
    var moved_tree = self.tab_trees[tab_idx];

    // Move child HWNDs and owned popups before mutating either tab array.
    try reparentTabWindows(&moved_tree, self.hwnd.?, destination_hwnd);

    const moved_active = self.tab_active_surface[tab_idx];
    const moved_title = self.tab_titles[tab_idx];
    const moved_title_len = self.tab_title_lens[tab_idx];

    var i = tab_idx;
    while (i + 1 < self.tab_count) : (i += 1) {
        self.tab_trees[i] = self.tab_trees[i + 1];
        self.tab_active_surface[i] = self.tab_active_surface[i + 1];
        self.tab_titles[i] = self.tab_titles[i + 1];
        self.tab_title_lens[i] = self.tab_title_lens[i + 1];
    }
    self.tab_count -= 1;
    if (self.active_tab > tab_idx) {
        self.active_tab -= 1;
    } else if (self.active_tab >= self.tab_count) {
        self.active_tab = self.tab_count - 1;
    }

    destination.tab_trees[0] = moved_tree;
    destination.tab_active_surface[0] = moved_active;
    destination.tab_titles[0] = moved_title;
    destination.tab_title_lens[0] = moved_title_len;
    destination.tab_count = 1;
    destination.active_tab = 0;

    var it = destination.tab_trees[0].iterator();
    while (it.next()) |entry| entry.view.parent_window = destination;
    destination.refreshOpacity();

    self.selectTabIndex(self.active_tab);
    self.updateTabBarVisibility();
    self.invalidateTabBar();

    destination.updateTabBarVisibility();
    destination.updateWindowTitle();
    _ = w32.ShowWindow(destination_hwnd, w32.SW_SHOW);
    _ = w32.UpdateWindow(destination_hwnd);
    destination.layoutSplits();
    if (moved_active.hwnd) |h| _ = w32.SetFocus(h);

    tracked = false;
    return true;
}

fn reparentTabWindows(tree: *const SplitTree(Surface), source: w32.HWND, destination: w32.HWND) !void {
    var moved: usize = 0;
    var it = tree.iterator();
    while (it.next()) |entry| {
        entry.view.reparentNativeWindows(destination) catch |err| {
            var rollback = tree.iterator();
            for (0..moved) |_| {
                rollback.next().?.view.reparentNativeWindows(source) catch |rollback_err| {
                    log.err("tab window transfer rollback failed: {}", .{rollback_err});
                };
            }
            return err;
        };
        moved += 1;
    }
}

test "detached tab rolls back child and popup transfers" {
    const testing = std.testing;
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const empty = std.unicode.utf8ToUtf16LeStringLiteral("");
    const source = w32.CreateWindowExW(0, class, empty, 0, 0, 0, 1, 1, null, null, null, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(source);
    const destination = w32.CreateWindowExW(0, class, empty, 0, 0, 0, 1, 1, null, null, null, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(destination);

    const first = try testing.allocator.create(Surface);
    defer testing.allocator.destroy(first);
    const second = try testing.allocator.create(Surface);
    defer testing.allocator.destroy(second);
    for ([_]*Surface{ first, second }) |surface| {
        surface.* = .{ .app = undefined };
        surface.hwnd = w32.CreateWindowExW(0, class, empty, w32.WS_CHILD, 0, 0, 1, 1, source, null, null, null) orelse return error.Win32Error;
        surface.search_hwnd = w32.CreateWindowExW(0, class, empty, w32.WS_POPUP, 0, 0, 1, 1, source, null, null, null) orelse return error.Win32Error;
    }
    // Fail after moving the first complete surface and the second surface's
    // child/search popup, exercising both levels of transaction rollback.
    second.palette_hwnd = @ptrFromInt(1);
    const nodes = [_]SplitTree(Surface).Node{
        .{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = @fromBackingInt(1), .right = @fromBackingInt(2) } },
        .{ .leaf = first },
        .{ .leaf = second },
    };
    const tree: SplitTree(Surface) = .{ .arena = undefined, .nodes = &nodes, .zoomed = null };
    try testing.expectError(error.Win32Error, reparentTabWindows(&tree, source, destination));
    for ([_]*Surface{ first, second }) |surface| {
        try testing.expectEqual(@as(?w32.HWND, source), w32.GetParent(surface.hwnd.?));
        try testing.expectEqual(@as(isize, @bitCast(@intFromPtr(source))), w32.GetWindowLongPtrW(surface.search_hwnd.?, w32.GWLP_HWNDPARENT));
    }

    second.palette_hwnd = null;
    try reparentTabWindows(&tree, source, destination);
    for ([_]*Surface{ first, second }) |surface| {
        try testing.expectEqual(@as(?w32.HWND, destination), w32.GetParent(surface.hwnd.?));
        try testing.expectEqual(@as(isize, @bitCast(@intFromPtr(destination))), w32.GetWindowLongPtrW(surface.search_hwnd.?, w32.GWLP_HWNDPARENT));
    }
}

/// Update the top-level window title to match the active tab's title.
fn updateWindowTitle(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.tab_count == 0) return;
    const len = self.window_title_override_len orelse
        self.tab_title_lens[self.active_tab];
    var buf: [257]u16 = undefined;
    if (self.window_title_override_len != null) {
        @memcpy(buf[0..len], self.window_title_override[0..len]);
    } else {
        @memcpy(buf[0..len], self.tab_titles[self.active_tab][0..len]);
    }
    buf[len] = 0;
    _ = w32.SetWindowTextW(hwnd, @ptrCast(&buf));
}

/// Set or clear the explicit top-level window title override.
pub fn setWindowTitle(self: *Window, title: [:0]const u8) void {
    if (title.len == 0) {
        self.window_title_override_len = null;
    } else {
        const len = std.unicode.utf8ToUtf16Le(&self.window_title_override, title) catch 0;
        self.window_title_override_len = @intCast(@min(len, self.window_title_override.len));
    }
    self.updateWindowTitle();
}

/// Called when a tab's title changes. Updates the stored title
/// and refreshes the window title bar / tab bar if needed.
pub fn onTabTitleChanged(self: *Window, surface: *Surface, title: [:0]const u8) void {
    const tab_idx = self.findTabIndex(surface) orelse return;
    var wbuf: [256]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, title) catch 0;
    const len: u16 = @intCast(@min(wlen, 255));
    @memcpy(self.tab_titles[tab_idx][0..len], wbuf[0..len]);
    self.tab_title_lens[tab_idx] = len;
    if (tab_idx == self.active_tab) self.updateWindowTitle();
    self.invalidateTabBar();
}

fn shouldShowTabBar(self: *const Window) bool {
    if (self.is_quick_terminal) return false;
    return switch (self.app.config.@"window-show-tab-bar") {
        .always => true,
        .auto => self.tab_count > 1,
        .never => false,
    };
}

/// Update tab bar visibility based on config and tab count.
fn updateTabBarVisibility(self: *Window) void {
    const should_show = self.shouldShowTabBar();
    if (should_show != self.tab_bar_visible) {
        self.tab_bar_visible = should_show;
        self.handleResize();
    }
}

/// Invalidate the tab bar region so it gets repainted.
pub fn invalidateTabBar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.tab_overview.active and !self.overview_refresh_pending) {
        self.overview_refresh_pending = w32.PostMessageW(hwnd, WM_REFRESH_TAB_OVERVIEW, 0, 0) != 0;
    }
    if (self.tab_bar_hwnd) |bar| {
        // A layered HWND needs its first pixels before Windows will paint it.
        if (!self.tab_paint_pending) {
            self.tab_paint_pending = w32.PostMessageW(bar, WM_PAINT_TAB_BAR, 0, 0) != 0;
        }
    }
    if (self.chrome_hwnd) |chrome| {
        _ = w32.InvalidateRect(chrome, null, 1);
        return;
    }
    var rect = w32.RECT{
        .left = 0,
        .top = 0,
        .right = 10000,
        .bottom = self.tabBarHeight(),
    };
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}

/// Fill the strip with adjacent tabs, retaining a minimum width on overflow.
fn layoutTabRects(
    rects: []w32.RECT,
    available_w: i32,
    bar_h: i32,
    min_tab_w: i32,
) i32 {
    const tab_count: i32 = @intCast(rects.len);
    if (tab_count == 0) return 0;
    const tab_w = @max(@divTrunc(available_w, tab_count), min_tab_w);
    const remainder: usize = @intCast(@max(available_w - tab_w * tab_count, 0));
    var x: i32 = 0;
    for (rects, 0..) |*rect, i| {
        const width = tab_w + @as(i32, @intFromBool(i < remainder));
        rect.* = .{ .left = x, .top = 0, .right = x + width, .bottom = bar_h };
        x += width;
    }
    return x;
}

/// Select the last tab midpoint crossed by a drag. Remainder pixels make the
/// fitted tabs differ by one pixel, so use their actual rectangles.
fn tabDragTarget(rects: []const w32.RECT, x: i32) usize {
    var target: usize = 0;
    for (rects, 0..) |rect, i| {
        if (x >= rect.left + @divTrunc(rect.right - rect.left, 2)) target = i;
    }
    return target;
}

test "tab bar fills fitted width and retains minimum widths on overflow" {
    const testing = std.testing;
    var rects: [3]w32.RECT = undefined;
    try testing.expectEqual(@as(i32, 965), layoutTabRects(&rects, 965, 32, 60));
    try testing.expectEqual(@as(i32, 322), rects[0].right - rects[0].left);
    try testing.expectEqual(@as(i32, 322), rects[1].right - rects[1].left);
    try testing.expectEqual(@as(i32, 321), rects[2].right - rects[2].left);
    try testing.expectEqual(rects[0].right, rects[1].left);
    try testing.expectEqual(rects[1].right, rects[2].left);
    try testing.expectEqual(@as(i32, 180), layoutTabRects(&rects, 100, 32, 60));
    for (rects) |rect| try testing.expectEqual(@as(i32, 60), rect.right - rect.left);
}

test "tab bar drag reorder follows actual nonuniform tab midpoints" {
    const testing = std.testing;
    // Only the first tab gets the remainder pixel. Multiplying its width
    // for every slot would put the final drag threshold a whole tab late.
    var rects: [64]w32.RECT = undefined;
    _ = layoutTabRects(&rects, 64 * 60 + 1, 32, 60);
    for (rects, 0..) |rect, i| {
        const midpoint = rect.left + @divTrunc(rect.right - rect.left, 2);
        try testing.expectEqual(i, tabDragTarget(&rects, midpoint));
        if (i > 0) try testing.expectEqual(i - 1, tabDragTarget(&rects, midpoint - 1));
    }
    try testing.expectEqual(@as(usize, 0), tabDragTarget(&rects, -100));
    try testing.expectEqual(@as(usize, 63), tabDragTarget(&rects, 10000));
}

fn tabColor(bg: Config.Color, fg: Config.Color, weight: u8) u32 {
    const foreground: u16 = weight;
    const background: u16 = 255 - foreground;
    return w32.RGB(
        @intCast((@as(u16, bg.r) * background + @as(u16, fg.r) * foreground + 127) / 255),
        @intCast((@as(u16, bg.g) * background + @as(u16, fg.g) * foreground + 127) / 255),
        @intCast((@as(u16, bg.b) * background + @as(u16, fg.b) * foreground + 127) / 255),
    );
}

fn tabCloseRect(self: *const Window, tab: w32.RECT) w32.RECT {
    const size: i32 = @intFromFloat(@round(24.0 * self.scale));
    const inset: i32 = @intFromFloat(@round(4.0 * self.scale));
    const top = @divTrunc(self.tabBarHeight() - size, 2);
    return .{ .left = tab.right - inset - size, .top = top, .right = tab.right - inset, .bottom = top + size };
}

fn paintTabBar(self: *Window, hwnd: w32.HWND) void {
    if (!self.tab_bar_visible) return;

    const bar_h = self.tabBarHeight();
    var client_rect: w32.RECT = undefined;
    if (bar_h <= 0 or w32.GetClientRect(hwnd, &client_rect) == 0) return;
    const client_w = client_rect.right - client_rect.left;
    if (client_w <= 0) return;
    const opacity = if (self.getActiveSurface()) |surface|
        surface.backgroundOpacityOverride() orelse self.app.config.@"background-opacity"
    else
        1;
    const canvas = &self.tab_canvas;
    canvas.begin(client_w, bar_h, self.tab_font, opacity) catch |err| {
        log.warn("could not prepare tab strip pixels err={}", .{err});
        return;
    };

    const bg = self.app.config.background;
    const fg = self.app.config.foreground;
    const bar_color = tabColor(bg, fg, 7);
    const hover_color = tabColor(bg, fg, 16);
    const active_bg_color = tabColor(bg, fg, 25);
    const divider_color = tabColor(bg, fg, 40);
    const active_text_color = w32.RGB(fg.r, fg.g, fg.b);
    const inactive_text_color = tabColor(bg, fg, 195);
    const bar_rect = w32.RECT{ .left = 0, .top = 0, .right = client_w, .bottom = bar_h };
    canvas.fillRect(&bar_rect, bar_color);

    const new_tab_btn_w: i32 = @intFromFloat(@round(36.0 * self.scale));
    const title_pad: i32 = @intFromFloat(@round(28.0 * self.scale));
    const divider_w: i32 = @max(1, @as(i32, @intFromFloat(@round(self.scale))));
    const divider_inset: i32 = @intFromFloat(@round(8.0 * self.scale));
    const available_w = client_w - new_tab_btn_w;
    const min_tab_w: i32 = @intFromFloat(@round(60.0 * self.scale));
    const tabs_right = layoutTabRects(
        self.tab_rects[0..self.tab_count],
        available_w,
        bar_h,
        min_tab_w,
    );

    for (0..self.tab_count) |i| {
        const is_active = i == self.active_tab;
        const is_hovered = @as(isize, @intCast(i)) == self.hover_tab;
        const x = self.tab_rects[i].left;
        const this_tab_w = self.tab_rects[i].right - x;
        if (is_active) {
            canvas.fillRect(&self.tab_rects[i], active_bg_color);
        } else if (is_hovered) {
            canvas.fillRect(&self.tab_rects[i], hover_color);
        }
        if (i > 0) {
            const divider = w32.RECT{
                .left = x,
                .top = divider_inset,
                .right = x + divider_w,
                .bottom = bar_h - divider_inset,
            };
            canvas.fillRect(&divider, divider_color);
        }
        const title_len = self.tab_title_lens[i];
        if (title_len > 0) {
            var text_rect = w32.RECT{
                .left = x + title_pad,
                .top = 0,
                .right = x + this_tab_w - title_pad,
                .bottom = bar_h,
            };
            canvas.drawText(
                @ptrCast(&self.tab_titles[i]),
                @intCast(title_len),
                &text_rect,
                w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
                if (is_active) active_text_color else inactive_text_color,
            );
        }
        if (is_hovered) {
            var close_rect = self.tabCloseRect(self.tab_rects[i]);
            if (self.hover_close) canvas.fillRect(&close_rect, divider_color);
            canvas.drawText(
                std.unicode.utf8ToUtf16LeStringLiteral("\u{00D7}"),
                1,
                &close_rect,
                w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
                if (self.hover_close) active_text_color else inactive_text_color,
            );
        }
    }

    self.new_tab_rect = .{
        .left = tabs_right,
        .top = 0,
        .right = tabs_right + new_tab_btn_w,
        .bottom = bar_h,
    };
    if (self.hover_new_tab) canvas.fillRect(&self.new_tab_rect, hover_color);
    var plus_rect = self.new_tab_rect;
    canvas.drawText(
        std.unicode.utf8ToUtf16LeStringLiteral("+"),
        1,
        &plus_rect,
        w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        inactive_text_color,
    );
    canvas.present(hwnd) catch |err| log.warn("could not present translucent tab strip err={}", .{err});
}

/// Honor a program's CSI 8 t resize only when it owns the whole window.
/// Changing the outer dimensions by the surface-size delta accounts for
/// non-client borders without assuming a particular decoration or DPI.
pub fn resizeSurface(self: *Window, surface: *Surface, size: apprt.action.ResizeWindow) bool {
    const hwnd = self.hwnd orelse return false;
    if (self.closing or self.is_quick_terminal or self.is_fullscreen or
        w32.IsZoomed(hwnd) != 0 or w32.IsIconic(hwnd) != 0) return false;
    if (self.tab_count != 1 or self.tab_trees[0].isSplit() or
        self.tab_active_surface[0] != surface) return false;
    const surface_hwnd = surface.hwnd orelse return false;
    var outer: w32.RECT = undefined;
    var client: w32.RECT = undefined;
    if (w32.GetWindowRect(hwnd, &outer) == 0 or
        w32.GetClientRect(surface_hwnd, &client) == 0) return false;

    // The surface's drawable width excludes a reserved (non-overlay)
    // scrollbar strip; the child HWND's client rectangle does not.
    const current = surface.getSize() catch return false;
    var width = resizedDimension(size.width, surface.scale, @intCast(current.width), outer.right - outer.left);
    var height = resizedDimension(size.height, surface.scale, @intCast(current.height), outer.bottom - outer.top);
    var monitor: w32.MONITORINFO = undefined;
    monitor.cbSize = @sizeOf(w32.MONITORINFO);
    if (w32.GetMonitorInfoW(w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST), &monitor) != 0) {
        if (size.width > 0) width = @min(width, monitor.rcWork.right - monitor.rcWork.left);
        if (size.height > 0) height = @min(height, monitor.rcWork.bottom - monitor.rcWork.top);
    }
    return w32.SetWindowPos(hwnd, null, 0, 0, width, height, w32.SWP_NOZORDER | w32.SWP_NOMOVE | w32.SWP_NOACTIVATE) != 0;
}

fn resizedDimension(requested: u32, scale: f32, current: i32, outer: i32) i32 {
    if (requested == 0) return outer;
    // Bound untrusted terminal requests before converting back to Win32's
    // signed dimensions. Larger sizes are not useful desktop window sizes.
    const px = @min(@as(f64, @floatFromInt(requested)) * scale, 32_767);
    return @max(1, outer - current + @as(i32, @intFromFloat(@ceil(px))));
}

test "program resize preserves zero dimensions and scales points" {
    const testing = std.testing;
    try testing.expectEqual(@as(i32, 816), resizedDimension(0, 1.5, 800, 816));
    try testing.expectEqual(@as(i32, 916), resizedDimension(600, 1.5, 800, 816));
    try testing.expectEqual(@as(i32, 516), resizedDimension(500, 1, 800, 816));
    try testing.expectEqual(@as(i32, 32_783), resizedDimension(std.math.maxInt(u32), 2, 800, 816));
}

test "program resize native window guards and zero dimensions" {
    const testing = std.testing;
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const title = std.unicode.utf8ToUtf16LeStringLiteral("");
    // Hidden system-class windows need neither a renderer nor an application.
    const hwnd = w32.CreateWindowExW(0, class, title, w32.WS_OVERLAPPEDWINDOW, 0, 0, 400, 300, null, null, null, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(hwnd);
    const child = w32.CreateWindowExW(0, class, title, w32.WS_CHILD, 0, 0, 200, 100, hwnd, null, null, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(child);
    var surface: Surface = undefined;
    surface.hwnd = child;
    surface.scale = 1;
    // Simulate a 20-pixel scrollbar reservation within the 200-pixel child.
    surface.width = 180;
    surface.height = 100;
    var window: Window = .{ .app = undefined, .hwnd = hwnd, .tab_count = 1 };
    window.tab_active_surface[0] = &surface;
    window.tab_trees[0] = .{ .arena = undefined, .nodes = &.{.{ .leaf = &surface }}, .zoomed = null };

    var before: w32.RECT = undefined;
    var after: w32.RECT = undefined;
    try testing.expect(w32.GetWindowRect(hwnd, &before) != 0);
    try testing.expect(window.resizeSurface(&surface, .{ .width = 220, .height = 0 }));
    try testing.expect(w32.GetWindowRect(hwnd, &after) != 0);
    try testing.expectEqual(before.right - before.left + 40, after.right - after.left);
    try testing.expectEqual(before.bottom - before.top, after.bottom - after.top);
    before = after;
    try testing.expect(window.resizeSurface(&surface, .{ .width = 0, .height = 120 }));
    try testing.expect(w32.GetWindowRect(hwnd, &after) != 0);
    try testing.expectEqual(before.right - before.left, after.right - after.left);
    try testing.expectEqual(before.bottom - before.top + 20, after.bottom - after.top);

    window.is_fullscreen = true;
    try testing.expect(!window.resizeSurface(&surface, .{ .width = 100, .height = 100 }));
    window.is_fullscreen = false;
    window.is_quick_terminal = true;
    try testing.expect(!window.resizeSurface(&surface, .{ .width = 100, .height = 100 }));
    window.is_quick_terminal = false;
    window.tab_count = 2;
    try testing.expect(!window.resizeSurface(&surface, .{ .width = 100, .height = 100 }));
    window.tab_count = 1;
    window.tab_trees[0].nodes = &.{.{ .split = undefined }};
    try testing.expect(!window.resizeSurface(&surface, .{ .width = 100, .height = 100 }));
}

/// Toggle fullscreen mode on the top-level window.
/// Saves/restores window style and placement.
pub fn toggleFullscreen(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (!self.is_fullscreen) {
        self.saved_style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
        _ = w32.GetWindowRect(hwnd, &self.saved_rect);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, w32.WS_POPUP | w32.WS_VISIBLE_STYLE | w32.WS_CLIPCHILDREN);
        const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST);
        var mi: w32.MONITORINFO = undefined;
        mi.cbSize = @sizeOf(w32.MONITORINFO);
        if (w32.GetMonitorInfoW(monitor, &mi) != 0) {
            _ = w32.SetWindowPos(hwnd, null, mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
        }
    } else {
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, self.saved_style | w32.WS_CLIPCHILDREN);
        _ = w32.SetWindowPos(hwnd, null, self.saved_rect.left, self.saved_rect.top, self.saved_rect.right - self.saved_rect.left, self.saved_rect.bottom - self.saved_rect.top, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
    }
    self.is_fullscreen = !self.is_fullscreen;
}

/// Toggle window decorations (title bar + borders) on/off.
pub fn toggleWindowDecorations(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
    const has_decorations = (style & w32.WS_CAPTION) != 0;

    if (has_decorations) {
        // Remove decorations: strip caption and thick frame.
        const new_style = style & ~@as(u32, w32.WS_CAPTION | w32.WS_THICKFRAME);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    } else {
        // Restore decorations.
        const new_style = style | w32.WS_CAPTION | w32.WS_THICKFRAME;
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    }
    // Force frame recalculation.
    _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0, w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
}

/// Handle WM_SIZE: re-layout the active tab's split panes and repaint tab bar.
/// Timer id used to auto-hide the resize overlay.
const RESIZE_OVERLAY_TIMER_ID: usize = 0x5247; // 'RG'

fn handleResize(self: *Window) void {
    self.layoutSplits();
    self.invalidateTabBar();
    self.showResizeOverlay();
}

/// Show the transient "columns × rows" overlay during a resize, honoring
/// the resize-overlay / -position / -duration config. Auto-hides via a
/// timer that each subsequent resize re-arms.
fn showResizeOverlay(self: *Window) void {
    switch (self.app.config.@"resize-overlay") {
        .never => return,
        .@"after-first" => if (!self.resize_seen_first) {
            // Suppress for the initial layout pass at window creation.
            self.resize_seen_first = true;
            return;
        },
        .always => {},
    }
    self.resize_seen_first = true;
    const hwnd = self.hwnd orelse return;

    // Grid dimensions from the active surface.
    const surface = self.getActiveSurface() orelse return;
    if (!surface.core_surface_ready) return;
    const grid = surface.core_surface.size.grid();

    var buf8: [32]u8 = undefined;
    const text8 = std.mem.print(&buf8, "{d} \u{00D7} {d}", .{
        grid.columns,
        grid.rows,
    }) catch return;
    var buf16: [32]u16 = undefined;
    const len16 = std.unicode.utf8ToUtf16Le(&buf16, text8) catch return;
    buf16[len16] = 0;

    if (self.resize_overlay_hwnd == null) {
        self.resize_overlay_hwnd = w32.CreateWindowExW(
            w32.WS_EX_TOOLWINDOW | w32.WS_EX_NOACTIVATE,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_POPUP | w32.WS_BORDER | w32.SS_CENTER | w32.SS_CENTERIMAGE,
            0,
            0,
            10,
            10,
            hwnd,
            null,
            self.app.hinstance,
            null,
        );
        if (self.resize_overlay_hwnd) |h| {
            if (self.tab_font) |f| {
                _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
            }
        }
    }
    const overlay = self.resize_overlay_hwnd orelse return;
    _ = w32.SetWindowTextW(overlay, @ptrCast(&buf16));

    // Position within the client area per resize-overlay-position.
    const s = self.scale;
    const ow: i32 = @intFromFloat(@round(110.0 * s));
    const oh: i32 = @intFromFloat(@round(34.0 * s));
    const margin: i32 = @intFromFloat(@round(16.0 * s));
    var client: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    _ = w32.GetClientRect(hwnd, &client);
    const cw = client.right - client.left;
    const ch = client.bottom - client.top;
    const cx = @divTrunc(cw - ow, 2);
    const cy = @divTrunc(ch - oh, 2);
    var pt: w32.POINT = switch (self.app.config.@"resize-overlay-position") {
        .center => .{ .x = cx, .y = cy },
        .@"top-left" => .{ .x = margin, .y = margin },
        .@"top-center" => .{ .x = cx, .y = margin },
        .@"top-right" => .{ .x = cw - ow - margin, .y = margin },
        .@"bottom-left" => .{ .x = margin, .y = ch - oh - margin },
        .@"bottom-center" => .{ .x = cx, .y = ch - oh - margin },
        .@"bottom-right" => .{ .x = cw - ow - margin, .y = ch - oh - margin },
    };
    _ = w32.ClientToScreen(hwnd, &pt);
    _ = w32.SetWindowPos(overlay, null, pt.x, pt.y, ow, oh, w32.SWP_NOACTIVATE | w32.SWP_NOZORDER);
    _ = w32.ShowWindow(overlay, w32.SW_SHOWNOACTIVATE);

    // (Re-)arm the auto-hide timer. asMilliseconds saturates, so huge
    // configured durations don't overflow the u32 SetTimer argument.
    const dur_ms: u32 = @max(1, self.app.config.@"resize-overlay-duration".asMilliseconds());
    _ = w32.SetTimer(hwnd, RESIZE_OVERLAY_TIMER_ID, dur_ms, null);
}

/// Handle a left-button click in the tab bar region.
/// Dispatches to addTab, closeTab, or selectTabIndex depending on hit position.
fn handleTabBarClick(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;

    // Check new-tab button.
    if (x >= self.new_tab_rect.left and x < self.new_tab_rect.right) {
        _ = self.addTab() catch |err| {
            log.err("failed to create new tab: {}", .{err});
            return;
        };
        return;
    }

    // Check each tab.
    for (0..self.tab_count) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) {
            const close_rect = self.tabCloseRect(rect);
            if (x >= close_rect.left and x < close_rect.right and y >= close_rect.top and y < close_rect.bottom) {
                self.closeTabByIndex(i);
            } else {
                self.selectTabIndex(i);
                // Start tracking potential tab drag
                self.drag_tab = @intCast(i);
                self.drag_start_x = x;
                self.drag_active = false;
                if (self.hwnd) |h| _ = w32.SetCapture(h);
                self.invalidateTabBar();
            }
            return;
        }
    }
}

/// Move a tab from one index to another, shifting intermediate tabs.
fn moveTabTo(self: *Window, from: usize, to: usize) void {
    if (from == to) return;
    if (from >= self.tab_count or to >= self.tab_count) return;

    // Cancel any in-progress rename: the edit control's tab index
    // would otherwise point at the wrong tab after the move.
    self.cancelTabRename();

    // Save the source tab state
    const saved_tree = self.tab_trees[from];
    const saved_surface = self.tab_active_surface[from];
    const saved_title = self.tab_titles[from];
    const saved_title_len = self.tab_title_lens[from];

    if (from < to) {
        // Shift left: move [from+1..to+1] to [from..to]
        var i: usize = from;
        while (i < to) : (i += 1) {
            self.tab_trees[i] = self.tab_trees[i + 1];
            self.tab_active_surface[i] = self.tab_active_surface[i + 1];
            self.tab_titles[i] = self.tab_titles[i + 1];
            self.tab_title_lens[i] = self.tab_title_lens[i + 1];
        }
    } else {
        // Shift right: move [to..from] to [to+1..from+1]
        var i: usize = from;
        while (i > to) : (i -= 1) {
            self.tab_trees[i] = self.tab_trees[i - 1];
            self.tab_active_surface[i] = self.tab_active_surface[i - 1];
            self.tab_titles[i] = self.tab_titles[i - 1];
            self.tab_title_lens[i] = self.tab_title_lens[i - 1];
        }
    }

    // Place the saved tab at the destination
    self.tab_trees[to] = saved_tree;
    self.tab_active_surface[to] = saved_surface;
    self.tab_titles[to] = saved_title;
    self.tab_title_lens[to] = saved_title_len;

    self.active_tab = to;
    self.invalidateTabBar();
}

/// Handle mouse movement over the tab bar for hover effects.
/// Registers TrackMouseEvent on first move so we get WM_MOUSELEAVE.
fn handleTabBarMouseMove(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;

    // Register for WM_MOUSELEAVE if not already tracking.
    if (!self.tracking_mouse) {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd.?,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking_mouse = true;
    }

    var new_hover: isize = -1;
    var new_close = false;
    var new_new_tab = false;

    if (y < self.tabBarHeight()) {
        // Check new-tab button.
        if (x >= self.new_tab_rect.left and x < self.new_tab_rect.right) {
            new_new_tab = true;
        } else {
            // Check tabs.
            for (0..self.tab_count) |i| {
                const rect = self.tab_rects[i];
                if (x >= rect.left and x < rect.right) {
                    new_hover = @intCast(i);
                    const close_rect = self.tabCloseRect(rect);
                    new_close = x >= close_rect.left and x < close_rect.right and y >= close_rect.top and y < close_rect.bottom;
                    break;
                }
            }
        }
    }

    if (new_hover != self.hover_tab or new_close != self.hover_close or new_new_tab != self.hover_new_tab) {
        self.hover_tab = new_hover;
        self.hover_close = new_close;
        self.hover_new_tab = new_new_tab;
        self.invalidateTabBar();
    }
}

// Context menu command IDs.
const TAB_CTX_CLOSE: usize = 9001;
const TAB_CTX_CLOSE_OTHERS: usize = 9002;
const TAB_CTX_CLOSE_RIGHT: usize = 9003;
const TAB_CTX_NEW_TAB: usize = 9004;

/// Handle a right-button click in the tab bar region.
/// Shows a context menu for the clicked tab.
fn handleTabBarRightClick(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return;

    // Hit-test to find which tab was right-clicked.
    var clicked_tab: ?usize = null;
    for (0..self.tab_count) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) {
            clicked_tab = i;
            break;
        }
    }

    // If clicked on empty area (not a tab), only show "New Tab".
    const menu = w32.CreatePopupMenu() orelse return;
    defer _ = w32.DestroyMenu(menu);

    if (clicked_tab) |tab| {
        _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_CLOSE, std.unicode.utf8ToUtf16LeStringLiteral("Close Tab"));
        _ = w32.AppendMenuW(menu, if (self.tab_count > 1) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_OTHERS, std.unicode.utf8ToUtf16LeStringLiteral("Close Other Tabs"));
        _ = w32.AppendMenuW(menu, if (tab + 1 < self.tab_count) w32.MF_STRING else w32.MF_GRAYED, TAB_CTX_CLOSE_RIGHT, std.unicode.utf8ToUtf16LeStringLiteral("Close Tabs to the Right"));
        _ = w32.AppendMenuW(menu, w32.MF_SEPARATOR, 0, null);
    }
    _ = w32.AppendMenuW(menu, w32.MF_STRING, TAB_CTX_NEW_TAB, std.unicode.utf8ToUtf16LeStringLiteral("New Tab"));

    // Convert client coords to screen coords for the popup.
    var pt = w32.POINT{ .x = @intCast(x), .y = @intCast(y) };
    if (self.hwnd) |h| _ = w32.ClientToScreen(h, &pt);

    const cmd = w32.TrackPopupMenuEx(
        menu,
        w32.TPM_LEFTALIGN | w32.TPM_TOPALIGN | w32.TPM_RETURNCMD,
        pt.x,
        pt.y,
        self.hwnd.?,
        null,
    );

    switch (@as(usize, @intCast(cmd))) {
        TAB_CTX_CLOSE => {
            if (clicked_tab) |tab| self.closeTabByIndex(tab);
        },
        TAB_CTX_CLOSE_OTHERS => {
            if (clicked_tab) |tab| {
                var current = tab;
                var i: usize = self.tab_count;
                while (i > 0) {
                    i -= 1;
                    if (i != current) {
                        self.closeTabByIndex(i);
                        if (i < current) current -= 1;
                    }
                }
            }
        },
        TAB_CTX_CLOSE_RIGHT => {
            if (clicked_tab) |tab| {
                var i: usize = self.tab_count;
                while (i > tab + 1) {
                    i -= 1;
                    self.closeTabByIndex(i);
                }
            }
        },
        TAB_CTX_NEW_TAB => {
            _ = self.addTab() catch |err| {
                log.err("failed to create new tab: {}", .{err});
            };
        },
        else => {},
    }
}

/// Handle WM_MOUSELEAVE: reset all hover state and repaint.
fn handleTabBarMouseLeave(self: *Window) void {
    self.tracking_mouse = false;
    if (self.hover_tab != -1 or self.hover_new_tab) {
        self.hover_tab = -1;
        self.hover_close = false;
        self.hover_new_tab = false;
        self.invalidateTabBar();
    }
}

/// Rename edit control child ID.
const RENAME_EDIT_ID: u16 = 300;

/// Start inline editing of a tab title. Creates a small Edit control
/// overlay on the tab and pre-fills it with the current title.
pub fn startTabRename(self: *Window, tab_idx: usize) void {
    // Cancel any existing rename
    self.cancelTabRename();
    self.rename_window = false;

    const hwnd = self.hwnd orelse return;
    // EDIT uses CS_PARENTDC and must draw into the redirected chrome.
    const chrome = self.chrome_hwnd orelse return;
    const rect = rect: {
        if (self.tab_bar_visible) break :rect self.tab_rects[tab_idx];

        // A single-tab window has no tab bar. Use a compact editor at the
        // top of the client area so prompt_*_title remains usable.
        var client: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &client) == 0) return;
        break :rect w32.RECT{
            .left = 8,
            .top = 8,
            .right = @max(168, client.right - 8),
            .bottom = 38,
        };
    };

    // tab_titles stores only `tab_title_lens` valid u16s; the rest is
    // uninitialized. CreateWindowExW reads a NUL-terminated wide string,
    // so a NUL-terminated copy avoids the Edit displaying garbage past
    // the real title.
    var title_buf: [257]u16 = undefined;
    const tlen = self.tab_title_lens[tab_idx];
    @memcpy(title_buf[0..tlen], self.tab_titles[tab_idx][0..tlen]);
    title_buf[tlen] = 0;

    // Create an Edit control overlaid on the tab
    const edit = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        @ptrCast(&title_buf),
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | w32.ES_AUTOHSCROLL | w32.WS_BORDER,
        rect.left + 2,
        rect.top + 2,
        rect.right - rect.left - 4,
        rect.bottom - rect.top - 4,
        chrome,
        @ptrFromInt(@as(usize, RENAME_EDIT_ID)),
        self.app.hinstance,
        null,
    ) orelse return;

    // Apply dark theme
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        edit,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        edit,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // Set font — stored for cleanup
    self.rename_font = w32.CreateFontW(
        -@as(i32, @intFromFloat(@round(12.0 * self.scale))),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    if (self.rename_font) |f| {
        _ = w32.SendMessageW(edit, w32.WM_SETFONT, @intFromPtr(f), 1);
    }

    // Select all text
    _ = w32.SendMessageW(edit, 0x00B1, 0, -1); // EM_SETSEL(0, -1)

    self.rename_edit = edit;
    self.rename_tab = tab_idx;
    self.updateChromeRegion();
    _ = w32.SetFocus(edit);
}

/// Prompt for an explicit top-level window title using the same lightweight
/// inline editor as tab renaming.
pub fn startWindowRename(self: *Window) void {
    self.startTabRename(self.active_tab);
    const edit = self.rename_edit orelse return;
    self.rename_window = true;

    var title: [257]u16 = undefined;
    const len: usize = if (self.window_title_override_len) |override_len| len: {
        @memcpy(title[0..override_len], self.window_title_override[0..override_len]);
        break :len override_len;
    } else @intCast(w32.GetWindowTextW(self.hwnd.?, &title, 256));
    title[len] = 0;
    _ = w32.SetWindowTextW(edit, @ptrCast(&title));
    _ = w32.SendMessageW(edit, 0x00B1, 0, -1); // EM_SETSEL(0, -1)
}

/// Apply the edit text as the new tab title and destroy the edit control.
pub fn finishTabRename(self: *Window) void {
    const edit = self.rename_edit orelse return;
    const tab_idx = self.rename_tab;

    // Read the edit control text
    var wbuf: [256]u16 = undefined;
    const wlen: usize = @intCast(w32.GetWindowTextW(edit, &wbuf, 256));
    if (self.rename_window) {
        if (wlen == 0) {
            self.window_title_override_len = null;
        } else {
            const len: u16 = @intCast(@min(wlen, 255));
            @memcpy(self.window_title_override[0..len], wbuf[0..len]);
            self.window_title_override_len = len;
        }
        self.updateWindowTitle();
    } else if (wlen > 0) {
        const len: u16 = @intCast(@min(wlen, 255));
        @memcpy(self.tab_titles[tab_idx][0..len], wbuf[0..len]);
        self.tab_title_lens[tab_idx] = len;
        if (tab_idx == self.active_tab) self.updateWindowTitle();
    }

    // Clear our state BEFORE DestroyWindow: the Edit synchronously emits
    // EN_KILLFOCUS as it's torn down, which re-enters this function via
    // the WM_COMMAND handler. The early `orelse return` then makes that
    // re-entrant call a no-op.
    self.rename_edit = null;
    self.rename_window = false;
    _ = w32.DestroyWindow(edit);
    if (self.rename_font) |f| {
        _ = w32.DeleteObject(f);
        self.rename_font = null;
    }
    self.updateChromeRegion();
    self.invalidateTabBar();

    // Return focus to the active surface
    if (self.getActiveSurface()) |s| {
        if (s.hwnd) |h| _ = w32.SetFocus(h);
    }
}

/// Cancel inline rename without applying changes.
pub fn cancelTabRename(self: *Window) void {
    if (self.rename_edit) |edit| {
        // Same re-entry concern as finishTabRename: null before destroy.
        self.rename_edit = null;
        self.rename_window = false;
        _ = w32.DestroyWindow(edit);
        if (self.rename_font) |f| {
            _ = w32.DeleteObject(f);
            self.rename_font = null;
        }
        self.updateChromeRegion();
        if (self.getActiveSurface()) |s| {
            if (s.hwnd) |h| _ = w32.SetFocus(h);
        }
    }
}

/// Return true if it is safe to close this whole window. If any tab still
/// has a running process, show a single aggregate confirmation dialog
/// (mirroring macOS/GTK, which confirm once per window) and return whether
/// the user approved. Whole-window close paths (title-bar X, Alt+F4,
/// close_window) previously skipped this check entirely; the per-surface
/// close path (Ctrl+Shift+W) still confirms separately in Surface.close.
/// When the last tab has already been closed (tab_count == 0) there is
/// nothing to confirm, so this returns true silently.
pub fn confirmCloseIfNeeded(self: *Window) bool {
    var needs = false;
    outer: for (0..self.tab_count) |i| {
        var it = self.tab_trees[i].iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            if (surface.core_surface_ready and
                surface.core_surface.needsConfirmQuit())
            {
                needs = true;
                break :outer;
            }
        }
    }
    if (!needs) return true;

    const result = w32.MessageBoxW(
        self.hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral(
            "Processes are still running in this window.\nClose anyway?",
        ),
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        w32.MB_OKCANCEL | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2,
    );
    return result == w32.IDOK;
}

/// Handle WM_CLOSE: clean up all tabs, then destroy the window.
/// OpenGL contexts and DCs must be released BEFORE DestroyWindow,
/// because Win32 destroys child HWNDs during DestroyWindow and the
/// OpenGL driver crashes if contexts are still active on destroyed windows.
pub fn close(self: *Window) void {
    self.tab_overview.deinit();
    // First, cleanly shut down all surfaces (renderer/IO threads, WGL, DC).
    self.cleanupAllSurfaces();

    // Now safe to destroy the parent HWND (children already cleaned up).
    if (self.hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
    }
}

/// Deinit and free all tab trees (which unrefs and frees surfaces).
fn cleanupAllSurfaces(self: *Window) void {
    // Deinit in place and reset to .empty. SplitTree.deinit sets self.*
    // to undefined; deinit'ing a local copy would only mark the copy,
    // leaving stale arena/node pointers in tab_trees that any post-WM_CLOSE
    // message walking the slot could dereference.
    for (self.tab_trees[0..self.tab_count]) |*tree| {
        tree.deinit();
        tree.* = .empty;
    }
    self.tab_count = 0;
}

/// Handle WM_DESTROY: remove this window from the App's list,
/// free resources, and start the quit timer if no windows remain.
/// Surfaces are already cleaned up by close() before DestroyWindow.
fn onDestroy(self: *Window) void {
    const app = self.app;
    self.tab_overview.deinit();
    self.tab_canvas.deinit();
    if (self.tab_bar_hwnd) |bar| {
        _ = w32.SetWindowLongPtrW(bar, w32.GWLP_USERDATA, 0);
        self.tab_bar_hwnd = null;
    }
    if (self.chrome_hwnd) |chrome| {
        _ = w32.SetWindowLongPtrW(chrome, w32.GWLP_USERDATA, 0);
        self.chrome_hwnd = null;
    }

    // Quick terminal windows are managed by QuickTerminal, not the windows list.
    if (self.is_quick_terminal) {
        if (self.tab_font) |font| {
            _ = w32.DeleteObject(font);
            self.tab_font = null;
        }
        self.hwnd = null;
        // QuickTerminal handles the rest of cleanup (freeing self, quit timer).
        if (app.quick_terminal) |qt| {
            qt.onWindowDestroyed();
        }
        return;
    }

    // Remove from App's window list.
    for (app.windows.items, 0..) |w, i| {
        if (w == self) {
            _ = app.windows.orderedRemove(i);
            break;
        }
    }

    // Clean up Window-level resources.
    if (self.tab_font) |font| {
        _ = w32.DeleteObject(font);
        self.tab_font = null;
    }
    self.hwnd = null;

    // Free the Window allocation.
    app.core_app.alloc.destroy(self);

    // If no windows remain (and no quick terminal), start the quit timer.
    if (app.windows.items.len == 0 and app.quick_terminal == null) {
        app.startQuitTimer();
    }
}

/// Window procedure for the redirected chrome child.
/// GWLP_USERDATA stores a *Window pointer.
pub fn chromeWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const window: *Window = @ptrFromInt(@as(usize, @bitCast(userdata)));
    switch (msg) {
        w32.WM_NCHITTEST => return @intCast(w32.HTTRANSPARENT),
        w32.WM_COMMAND => {
            const parent = window.hwnd orelse return 0;
            return w32.SendMessageW(parent, msg, wparam, lparam);
        },
        WM_PAINT_TAB_BAR => {
            window.tab_paint_pending = false;
            window.paintTabBar(hwnd);
            return 0;
        },
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            if (w32.BeginPaint(hwnd, &ps)) |dc| {
                if (window.tab_bar_hwnd != hwnd) window.paintDividers(dc);
                _ = w32.EndPaint(hwnd, &ps);
            }
            return 0;
        },
        w32.WM_ERASEBKGND => return 1,
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

pub fn windowWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const window: *Window = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    // Once the last tab is closed and WM_CLOSE has been posted, drop any
    // input messages still queued for this window. They could otherwise
    // mutate state (allocate, capture mouse, start drags) on a window
    // about to be destroyed. WM_CLOSE/WM_DESTROY/paint/size still flow
    // through so close itself can complete cleanly.
    if (window.closing) switch (msg) {
        w32.WM_LBUTTONDOWN,
        w32.WM_LBUTTONUP,
        w32.WM_LBUTTONDBLCLK,
        w32.WM_RBUTTONUP,
        w32.WM_MBUTTONDOWN,
        w32.WM_MOUSEMOVE,
        w32.WM_MOUSELEAVE,
        w32.WM_MOUSEWHEEL,
        w32.WM_MOUSEHWHEEL,
        w32.WM_KEYDOWN,
        w32.WM_KEYUP,
        w32.WM_SYSKEYDOWN,
        w32.WM_SYSKEYUP,
        w32.WM_CHAR,
        w32.WM_SETFOCUS,
        w32.WM_SETCURSOR,
        => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
        else => {},
    };

    switch (msg) {
        WM_TOGGLE_TAB_OVERVIEW => {
            window.tab_overview.toggle(window) catch |err| {
                log.warn("unable to open tab overview err={}", .{err});
            };
            return 0;
        },
        WM_REFRESH_TAB_OVERVIEW => {
            window.overview_refresh_pending = false;
            window.tab_overview.refresh();
            return 0;
        },
        w32.WM_DWMCOMPOSITIONCHANGED => {
            window.applyComposition() catch |err| log.warn("composition setup failed: {}", .{err});
            window.invalidateTabBar();
            window.layoutSplits();
            return 0;
        },
        w32.WM_WINDOWPOSCHANGED => {
            const position: *const w32.WINDOWPOS = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const z_order_changed = position.flags & w32.SWP_NOZORDER == 0;
            const result = w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            if (z_order_changed) window.positionTabBar(window.isVisible());
            return result;
        },
        w32.WM_DPICHANGED => {
            window.handleDpiChange();
            return 0;
        },
        w32.WM_GETOBJECT => {
            // Opt out of MSAA accessibility for OBJID_CLIENT on the
            // top-level window too. See the matching handler in
            // App.surfaceWndProc for the rationale: returning 0 here
            // prevents oleacc from creating an AccWrap proxy whose
            // later destruction can re-enter our WindowProc via
            // SetFocus and deadlock on a COM marshaling reply.
            if (lparam == w32.OBJID_CLIENT) return 0;
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_TIMER => {
            if (wparam == TAB_REVEAL_TIMER_ID) {
                const idx = window.pendingTabIndex() orelse {
                    window.cancelPendingTabReveal(null);
                    return 0;
                };
                if (window.tabFramesReady(idx)) window.selectTabIndex(idx);
                return 0;
            }
            if (wparam == RESIZE_OVERLAY_TIMER_ID) {
                if (window.resize_overlay_hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
                _ = w32.KillTimer(hwnd, RESIZE_OVERLAY_TIMER_ID);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_CTLCOLORSTATIC => {
            // Dark theming for the STATIC popups owned by this window
            // (hovered-URL link preview, resize overlay). Static controls
            // send this to their owner, i.e. here — not to surfaceWndProc.
            const hdc_static: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_static, w32.RGB(220, 220, 220));
            _ = w32.SetBkColor(hdc_static, w32.RGB(45, 45, 45));
            if (window.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SHOWWINDOW => {
            // ShowWindow sends this before updating WS_VISIBLE, so use its
            // new state rather than querying the old native style. This also
            // covers quick-terminal animation completion and app hide/show.
            window.setActiveTabVisible(wparam != 0 and w32.IsIconic(hwnd) == 0);
            window.positionTabBar(wparam != 0 and w32.IsIconic(hwnd) == 0);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SIZE => {
            // Minimizing does not hide child surface HWNDs, so tell the core
            // to stop rendering the active tab while minimized. Return early:
            // the client rect is 0x0 while minimized, so re-laying-out would
            // both re-mark the surfaces visible (undoing the occlusion) and
            // collapse the grid, and the resize overlay would flash offscreen.
            if (wparam == w32.SIZE_MINIMIZED) {
                window.setActiveTabVisible(false);
                window.positionTabBar(false);
                return 0;
            }
            if (wparam == w32.SIZE_RESTORED or wparam == w32.SIZE_MAXIMIZED) {
                window.setActiveTabVisible(window.isVisible());
            }
            window.handleResize();
            return 0;
        },
        w32.WM_POWERBROADCAST => {
            // After system sleep/resume nothing else kicks a re-present:
            // the renderer has no vsync/power awareness, so without this
            // the last pre-sleep frame can stay on screen stale (the same
            // bug as microsoft/terminal#14483). Invalidate every surface
            // in the active tab; the surface WM_PAINT handler validates
            // and wakes the renderer thread, driving a full re-present
            // through the existing pipeline. Both resume events may
            // arrive for a single resume; the redundant invalidation is
            // harmless. Return TRUE per the message contract.
            if (wparam == w32.PBT_APMRESUMEAUTOMATIC or
                wparam == w32.PBT_APMRESUMESUSPEND)
            {
                if (window.active_tab < window.tab_count) {
                    var it = window.tab_trees[window.active_tab].iterator();
                    while (it.next()) |entry| {
                        if (entry.view.hwnd) |h| _ = w32.InvalidateRect(h, null, 0);
                    }
                }
                return 1;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOVE => {
            window.positionTabBar(window.isVisible());
            // Top-level move: child surface HWNDs do NOT receive WM_MOVE
            // (their position relative to the parent is unchanged), but the
            // scrollbar is a screen-positioned popup that must follow its
            // owner. Reposition every surface's scrollbar across all tabs
            // so hidden tabs don't surface a stale position when activated.
            for (0..window.tab_count) |i| {
                var it = window.tab_trees[i].iterator();
                while (it.next()) |entry| {
                    if (entry.view.scrollbar) |sb| _ = sb.repositionAndResize();
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_GETMINMAXINFO => {
            // Apply user-configured size limits if any. lparam points
            // to a MINMAXINFO the OS will consult for resize clamping.
            if (window.min_track_w > 0 or window.min_track_h > 0 or
                window.max_track_w > 0 or window.max_track_h > 0)
            {
                const mmi: *w32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
                if (window.min_track_w > 0) mmi.ptMinTrackSize.x = window.min_track_w;
                if (window.min_track_h > 0) mmi.ptMinTrackSize.y = window.min_track_h;
                if (window.max_track_w > 0) mmi.ptMaxTrackSize.x = window.max_track_w;
                if (window.max_track_h > 0) mmi.ptMaxTrackSize.y = window.max_track_h;
                return 0;
            }
            // No limits → fall through to DefWindowProc.
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_ENTERSIZEMOVE => {
            if (window.tab_count > 0) {
                var it = window.tab_trees[window.active_tab].iterator();
                while (it.next()) |entry| entry.view.in_live_resize = true;
            }
            return 0;
        },
        w32.WM_EXITSIZEMOVE => {
            if (window.tab_count > 0) {
                var it = window.tab_trees[window.active_tab].iterator();
                while (it.next()) |entry| entry.view.in_live_resize = false;
            }
            return 0;
        },
        w32.WM_CLOSE => {
            // Title-bar X / Alt+F4 / close_all_windows land here. Confirm
            // once for the whole window if any tab has a running process.
            if (!window.confirmCloseIfNeeded()) return 0;
            window.close();
            return 0;
        },
        w32.WM_DESTROY => {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            window.onDestroy();
            return 0;
        },
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            if (w32.BeginPaint(hwnd, &ps)) |_| _ = w32.EndPaint(hwnd, &ps);
            window.invalidateTabBar();
            return 0;
        },
        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            // Tab rename Edit lost focus — commit (standard Win32
            // convention, matches Explorer file rename and Edge tabs).
            // Esc still cancels via the message-loop intercept that
            // catches VK_ESCAPE before it reaches the Edit.
            if (control_id == RENAME_EDIT_ID and notification == w32.EN_KILLFOCUS) {
                window.finishTabRename();
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_SETFOCUS => {
            // Forward keyboard focus to the active child surface.
            // Without this, keyboard input stays on the parent and
            // is never delivered to the terminal.
            if (window.getActiveSurface()) |s| {
                if (s.hwnd) |h| _ = w32.SetFocus(h);
            }
            return 0;
        },
        w32.WM_ERASEBKGND => return 1,
        w32.WM_LBUTTONDOWN => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (window.hitTestDivider(x, y)) |hit| {
                window.startDividerDrag(hit.handle, hit.layout);
                return 0;
            }
            if (y < window.tabBarHeight()) {
                window.handleTabBarClick(@truncate(x), @truncate(y));
            }
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (window.dragging_split) {
                window.endDividerDrag();
                return 0;
            }
            if (window.drag_tab >= 0) {
                window.drag_tab = -1;
                window.drag_active = false;
                _ = w32.ReleaseCapture();
                return 0;
            }
            return 0;
        },
        w32.WM_LBUTTONDBLCLK => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            // Double-click on tab bar starts inline rename
            if (y < window.tabBarHeight()) {
                for (0..window.tab_count) |i| {
                    const rect = window.tab_rects[i];
                    if (x >= rect.left and x < rect.right) {
                        window.startTabRename(i);
                        return 0;
                    }
                }
                return 0;
            }
            if (window.hitTestDivider(x, y)) |hit| {
                window.tab_trees[window.active_tab].resizeInPlace(hit.handle, @as(f16, 0.5));
                window.layoutSplits();
                return 0;
            }
            return 0;
        },
        w32.WM_RBUTTONUP => {
            const x: i16 = @truncate(lparam & 0xFFFF);
            const y: i16 = @truncate((lparam >> 16) & 0xFFFF);
            if (y < window.tabBarHeight()) {
                window.handleTabBarRightClick(x, y);
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSEMOVE => {
            const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
            const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
            if (window.dragging_split) {
                window.updateDividerDrag(x, y);
                return 0;
            }
            // Handle tab drag reorder
            if (window.drag_tab >= 0) {
                const xi16: i16 = @truncate(x);
                const dx = if (xi16 > window.drag_start_x) xi16 - window.drag_start_x else window.drag_start_x - xi16;
                if (!window.drag_active and dx > 5) {
                    window.drag_active = true;
                }
                if (window.drag_active and window.tab_count > 1) {
                    const from: usize = @intCast(window.drag_tab);
                    const target = tabDragTarget(window.tab_rects[0..window.tab_count], x);
                    if (target != from) {
                        window.moveTabTo(from, target);
                        window.drag_tab = @intCast(target);
                        if (window.hwnd) |h| _ = w32.UpdateWindow(h);
                    }
                }
                return 0;
            }
            if (y < window.tabBarHeight()) {
                window.handleTabBarMouseMove(@truncate(x), @truncate(y));
            }
            return 0;
        },
        w32.WM_SETCURSOR => {
            var pt: w32.POINT = undefined;
            if (w32.GetCursorPos_(&pt) != 0) {
                if (window.hwnd) |h| _ = w32.ScreenToClient(h, &pt);
                if (window.hitTestDivider(pt.x, pt.y)) |hit| {
                    const cursor_id: usize = if (hit.layout == .horizontal) w32.IDC_SIZEWE else w32.IDC_SIZENS;
                    if (w32.LoadCursorW(null, cursor_id)) |cursor| {
                        _ = w32.SetCursor(cursor);
                    }
                    return 1;
                }
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        w32.WM_MOUSELEAVE => {
            window.handleTabBarMouseLeave();
            return 0;
        },
        w32.WM_ACTIVATE => {
            const activated = @as(u16, @truncate(wparam & 0xFFFF));
            if (activated == w32.WA_INACTIVE and window.is_quick_terminal) {
                if (window.app.quick_terminal) |qt| {
                    qt.onFocusLost();
                }
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
