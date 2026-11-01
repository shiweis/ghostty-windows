//! Native, searchable tab overview. All state and HWNDs belong to the app
//! thread. Results identify a live surface, never a possibly-stale tab index.
const TabOverview = @This();

const std = @import("std");
const Window = @import("Window.zig");
const w32 = @import("win32.zig");

pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyTabOverview");
pub const search_id = 1001;
pub const list_id = 1002;
const open_id = 1;
const cancel_id = 2;
const close_id = 3;
const max_tabs = 64;
const ws_tabstop = 0x00010000;
const ws_sysmenu = 0x00080000;
const lb_addstring = 0x0180;
const lb_resetcontent = 0x0184;
const lb_setcursel = 0x0186;
const lb_getcursel = 0x0188;
const lb_gettopindex = 0x018E;
const lb_settopindex = 0x0197;
const wm_setredraw = 0x000B;

owner: ?*Window = null,
hwnd: ?w32.HWND = null,
edit: ?w32.HWND = null,
list: ?w32.HWND = null,
open_button: ?w32.HWND = null,
close_button: ?w32.HWND = null,
cancel_button: ?w32.HWND = null,
label: ?w32.HWND = null,
status: ?w32.HWND = null,
font: ?*anyopaque = null,
brush: ?w32.HBRUSH = null,
background: u32 = 0,
foreground: u32 = 0,
scale: f32 = 1,
active: bool = false,
updating: bool = false,
results: [max_tabs]u64 = undefined,
count: usize = 0,

pub fn registerClass(instance: w32.HINSTANCE) !u16 {
    const atom = w32.RegisterClassExW(&.{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    });
    if (atom == 0) return error.Win32Error;
    return atom;
}

pub fn toggle(self: *TabOverview, owner: *Window) !void {
    if (self.active) {
        self.hide(true);
        return;
    }
    if (owner.closing or owner.is_quick_terminal or owner.tab_count == 0) return;
    try self.create(owner);
    // Other popups must not retain focus or float over the overview.
    owner.cancelTabRename();
    if (owner.getActiveSurface()) |surface| {
        if (surface.search_active) surface.setSearchActive(false, "");
        if (surface.palette_active) surface.setCommandPaletteActive(false);
    }
    self.active = true;
    self.count = 0; // Reopening starts on the current tab, not a canceled selection.
    _ = w32.SetWindowTextW(self.edit.?, std.unicode.utf8ToUtf16LeStringLiteral(""));
    self.refresh();
    self.position();
    _ = w32.ShowWindow(self.hwnd.?, w32.SW_SHOW);
    _ = w32.SetFocus(self.edit.?);
}

pub fn hide(self: *TabOverview, restore_focus: bool) void {
    self.active = false;
    if (self.hwnd) |hwnd| _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
    if (restore_focus) {
        const owner = self.owner orelse return;
        if (owner.closing) return;
        if (owner.getActiveSurface()) |surface| {
            if (surface.hwnd) |hwnd| _ = w32.SetFocus(hwnd);
        }
    }
}

pub fn deinit(self: *TabOverview) void {
    self.active = false;
    if (self.hwnd) |hwnd| {
        // DestroyWindow pumps messages; do not expose this object during teardown.
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
    }
    if (self.font) |font| _ = w32.DeleteObject(font);
    if (self.brush) |brush| _ = w32.DeleteObject(brush);
    self.* = .{};
}

fn control(self: *TabOverview, class: [*:0]const u16, text: [*:0]const u16, style: u32, id: usize) !w32.HWND {
    return w32.CreateWindowExW(
        0,
        class,
        text,
        w32.WS_CHILD | w32.WS_VISIBLE_STYLE | style,
        0,
        0,
        1,
        1,
        self.hwnd,
        @ptrFromInt(id),
        self.owner.?.app.hinstance,
        null,
    ) orelse error.Win32Error;
}

fn create(self: *TabOverview, owner: *Window) !void {
    if (self.hwnd != null) return;
    self.owner = owner;
    self.scale = owner.scale;
    self.hwnd = w32.CreateWindowExW(
        w32.WS_EX_TOOLWINDOW,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("Tab overview"),
        w32.WS_POPUP | w32.WS_CAPTION | ws_sysmenu | w32.WS_THICKFRAME,
        0,
        0,
        self.px(540),
        self.px(440),
        owner.hwnd,
        null,
        owner.app.hinstance,
        null,
    ) orelse return error.Win32Error;
    errdefer self.deinit();
    _ = w32.SetWindowLongPtrW(self.hwnd.?, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    const static = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const button = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
    const empty = std.unicode.utf8ToUtf16LeStringLiteral("");
    self.label = try self.control(static, std.unicode.utf8ToUtf16LeStringLiteral("Search &tabs"), 0, 1003);
    self.edit = try self.control(std.unicode.utf8ToUtf16LeStringLiteral("EDIT"), empty, w32.WS_BORDER | ws_tabstop | w32.ES_AUTOHSCROLL, search_id);
    // Do not sort: list order follows tab order, with native scrolling and accessibility.
    self.list = try self.control(std.unicode.utf8ToUtf16LeStringLiteral("LISTBOX"), empty, w32.WS_BORDER | w32.WS_VSCROLL | ws_tabstop | 0x0001 | 0x0100, list_id);
    self.status = try self.control(static, empty, 0, 1004);
    self.open_button = try self.control(button, std.unicode.utf8ToUtf16LeStringLiteral("&Switch"), ws_tabstop | 0x0001, open_id);
    self.close_button = try self.control(button, std.unicode.utf8ToUtf16LeStringLiteral("&Close tab"), ws_tabstop, close_id);
    self.cancel_button = try self.control(button, std.unicode.utf8ToUtf16LeStringLiteral("Cancel"), ws_tabstop, cancel_id);
    _ = w32.SendMessageW(self.edit.?, 0x00C5, 255, 0); // EM_SETLIMITTEXT
    self.updateAppearance();
    self.layout();
}

fn px(self: *const TabOverview, value: f32) i32 {
    return @intFromFloat(@round(value * self.scale));
}

pub fn updateAppearance(self: *TabOverview) void {
    const owner = self.owner orelse return;
    const hwnd = self.hwnd orelse return;
    const config = &owner.app.config;
    const bg = config.background;
    const fg = config.foreground;
    self.background = w32.RGB(bg.r, bg.g, bg.b);
    self.foreground = w32.RGB(fg.r, fg.g, fg.b);
    if (w32.CreateSolidBrush(self.background)) |brush| {
        if (self.brush) |old| _ = w32.DeleteObject(old);
        self.brush = brush;
    }
    const old_font = self.font;
    self.font = w32.CreateFontW(-self.px(16), 0, 0, 0, 400, 0, 0, 0, w32.DEFAULT_CHARSET, 0, 0, 0, 0, std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI")) orelse old_font;
    const dark: u32 = if (switch (config.@"window-theme") {
        .dark => true,
        .light => false,
        .system => !Window.systemUsesLightTheme(),
        else => @as(u32, bg.r) * 299 + @as(u32, bg.g) * 587 + @as(u32, bg.b) * 114 < 128_000,
    }) 1 else 0;
    _ = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_USE_IMMERSIVE_DARK_MODE, @ptrCast(&dark), @sizeOf(u32));
    const theme = if (dark != 0) std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer") else std.unicode.utf8ToUtf16LeStringLiteral("Explorer");
    for ([_]?w32.HWND{ self.label, self.edit, self.list, self.status, self.open_button, self.close_button, self.cancel_button }) |maybe| {
        const child = maybe orelse continue;
        _ = w32.SetWindowTheme(child, theme, null);
        if (self.font) |font| _ = w32.SendMessageW(child, w32.WM_SETFONT, @intFromPtr(font), 1);
    }
    if (old_font != self.font) {
        if (old_font) |font| _ = w32.DeleteObject(font);
    }
    _ = w32.InvalidateRect(hwnd, null, 1);
}

fn position(self: *TabOverview) void {
    const owner = self.owner orelse return;
    const hwnd = self.hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetWindowRect(owner.hwnd.?, &rect) == 0) return;
    var work = rect;
    var monitor: w32.MONITORINFO = undefined;
    monitor.cbSize = @sizeOf(w32.MONITORINFO);
    if (w32.GetMonitorInfoW(w32.MonitorFromWindow(owner.hwnd.?, w32.MONITOR_DEFAULTTONEAREST), &monitor) != 0) work = monitor.rcWork;
    const width = @min(self.px(540), work.right - work.left);
    const height = @min(self.px(440), work.bottom - work.top);
    const x = std.math.clamp(rect.left + @divTrunc(rect.right - rect.left - width, 2), work.left, work.right - width);
    const y = std.math.clamp(rect.top + @divTrunc(rect.bottom - rect.top - height, 2), work.top, work.bottom - height);
    _ = w32.SetWindowPos(hwnd, null, x, y, width, height, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
}

fn layout(self: *TabOverview) void {
    const hwnd = self.hwnd orelse return;
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) return;
    const pad = self.px(12);
    const width = @max(1, rect.right - 2 * pad);
    const bottom = @max(self.px(130), rect.bottom - pad);
    if (self.label) |h| _ = w32.MoveWindow(h, pad, pad, width, self.px(20), 1);
    if (self.edit) |h| _ = w32.MoveWindow(h, pad, self.px(34), width, self.px(28), 1);
    if (self.list) |h| _ = w32.MoveWindow(h, pad, self.px(72), width, @max(1, bottom - self.px(136)), 1);
    if (self.status) |h| _ = w32.MoveWindow(h, pad, bottom - self.px(57), width, self.px(22), 1);
    const button_width = @max(1, @divTrunc(width - 2 * pad, 3));
    for ([_]?w32.HWND{ self.open_button, self.close_button, self.cancel_button }, 0..) |maybe, i| {
        if (maybe) |h| _ = w32.MoveWindow(h, pad + @as(i32, @intCast(i)) * (button_width + pad), bottom - self.px(30), button_width, self.px(30), 1);
    }
}

fn selectedID(self: *const TabOverview) ?u64 {
    const list = self.list orelse return null;
    const index = w32.SendMessageW(list, lb_getcursel, 0, 0);
    if (index < 0 or index >= self.count) return null;
    return self.results[@intCast(index)];
}

/// Find a current tab from its snapshot identity without dereferencing a stale pointer.
pub fn findTab(owner: *Window, id: u64) ?usize {
    for (0..owner.tab_count) |i| {
        var it = owner.tab_trees[i].iterator();
        while (it.next()) |entry| {
            if (entry.view.core_surface.id == id) return i;
        }
    }
    return null;
}

fn matches(title: []const u16, query: []const u16) bool {
    if (query.len == 0) return true;
    if (query.len > title.len) return false;
    for (0..title.len - query.len + 1) |i| {
        if (w32.CompareStringOrdinal(title[i..].ptr, @intCast(query.len), query.ptr, @intCast(query.len), 1) == 2) return true;
    }
    return false;
}

pub fn refresh(self: *TabOverview) void {
    if (!self.active or self.updating) return;
    const owner = self.owner orelse return;
    if (owner.closing or owner.tab_count == 0) {
        self.hide(false);
        return;
    }
    const list = self.list orelse return;
    const previous = self.selectedID();
    const previous_index = w32.SendMessageW(list, lb_getcursel, 0, 0);
    const top = w32.SendMessageW(list, lb_gettopindex, 0, 0);
    var query: [256]u16 = undefined;
    const query_len: usize = @intCast(w32.GetWindowTextW(self.edit.?, &query, query.len));
    self.updating = true;
    defer self.updating = false;
    _ = w32.SendMessageW(list, wm_setredraw, 0, 0);
    defer {
        _ = w32.SendMessageW(list, wm_setredraw, 1, 0);
        _ = w32.InvalidateRect(list, null, 1);
    }
    _ = w32.SendMessageW(list, lb_resetcontent, 0, 0);
    self.count = 0;
    var selected: usize = 0;
    for (0..@min(owner.tab_count, max_tabs)) |i| {
        const title = owner.tab_titles[i][0..owner.tab_title_lens[i]];
        if (!matches(title, query[0..query_len])) continue;
        var text: [288:0]u16 = undefined;
        var prefix_buf: [24]u8 = undefined;
        const prefix = std.mem.print(&prefix_buf, "{s}{d}. ", .{ if (i == owner.active_tab) "* " else "  ", i + 1 }) catch continue;
        const prefix_len = std.unicode.utf8ToUtf16Le(&text, prefix) catch continue;
        @memcpy(text[prefix_len..][0..title.len], title);
        text[prefix_len + title.len] = 0;
        if (w32.SendMessageW(list, lb_addstring, 0, @bitCast(@intFromPtr(&text))) < 0) continue;
        const id = owner.tab_active_surface[i].core_surface.id;
        self.results[self.count] = id;
        if (previous) |old| {
            if (id == old) selected = self.count;
        } else if (i == owner.active_tab) selected = self.count;
        self.count += 1;
    }
    if (self.count > 0) {
        _ = w32.SendMessageW(list, lb_setcursel, selected, 0);
        // Preserve manual scrolling on title-only updates. After reordering
        // or filtering, let LB_SETCURSEL keep the new selection in view.
        if (previous_index >= 0 and selected == previous_index and top > 0 and top < self.count)
            _ = w32.SendMessageW(list, lb_settopindex, @intCast(top), 0);
    }
    var status: [96:0]u16 = undefined;
    var status_buf: [96]u8 = undefined;
    const message = std.mem.print(&status_buf, "{d} of {d} tabs. * marks the active tab.", .{ self.count, owner.tab_count }) catch return;
    const status_len = std.unicode.utf8ToUtf16Le(&status, message) catch return;
    status[status_len] = 0;
    _ = w32.SetWindowTextW(self.status.?, &status);
    _ = w32.EnableWindow(self.open_button.?, if (self.count > 0) 1 else 0);
    _ = w32.EnableWindow(self.close_button.?, if (self.count > 0) 1 else 0);
}

pub fn activateSelection(self: *TabOverview) void {
    const id = self.selectedID() orelse return;
    const owner = self.owner orelse return;
    const index = findTab(owner, id) orelse {
        self.refresh();
        return;
    };
    self.hide(false);
    owner.selectTabIndex(index);
}

fn closeSelection(self: *TabOverview) void {
    const id = self.selectedID() orelse return;
    const owner = self.owner orelse return;
    self.hide(true);
    // Confirmation pumps messages and may destroy owner/self. Do not access
    // either after handing off; Window re-resolves the surface after a dialog.
    owner.requestCloseTab(id);
}

pub fn ownsInput(self: *const TabOverview, hwnd: w32.HWND) bool {
    return hwnd == self.hwnd or hwnd == self.edit or hwnd == self.list or
        hwnd == self.open_button or hwnd == self.close_button or hwnd == self.cancel_button;
}

/// Called before the app's surface-edit routing: our controls have a Window
/// owner, not a Surface pointer in the parent's GWLP_USERDATA.
pub fn handleKey(self: *TabOverview, hwnd: w32.HWND, vk: u16) bool {
    switch (vk) {
        w32.VK_ESCAPE => self.hide(true),
        w32.VK_RETURN => {
            if (hwnd == self.close_button) self.closeSelection() else if (hwnd == self.cancel_button) self.hide(true) else self.activateSelection();
        },
        w32.VK_UP, w32.VK_DOWN => {
            if (hwnd != self.edit) return false;
            if (self.count == 0) return true;
            const current = w32.SendMessageW(self.list.?, lb_getcursel, 0, 0);
            const selected: usize = if (current < 0) 0 else @intCast(current);
            const next = if (vk == w32.VK_UP) selected -| 1 else @min(selected + 1, self.count - 1);
            _ = w32.SendMessageW(self.list.?, lb_setcursel, next, 0);
        },
        else => return false,
    }
    return true;
}

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *TabOverview = @ptrFromInt(@as(usize, @bitCast(userdata)));
    switch (msg) {
        w32.WM_CLOSE => {
            self.hide(true);
            return 0;
        },
        w32.WM_COMMAND => {
            const id: u16 = @truncate(wparam);
            const notification: u16 = @truncate(wparam >> 16);
            if (id == search_id and notification == w32.EN_CHANGE) self.refresh();
            if (id == list_id and notification == 2) self.activateSelection(); // LBN_DBLCLK
            if (notification == 0) switch (id) {
                open_id => self.activateSelection(),
                cancel_id => self.hide(true),
                close_id => self.closeSelection(),
                else => {},
            };
            return 0;
        },
        w32.WM_SIZE => {
            self.layout();
            return 0;
        },
        w32.WM_SETFOCUS => {
            if (self.edit) |edit| _ = w32.SetFocus(edit);
            return 0;
        },
        w32.WM_ACTIVATE => {
            if (@as(u16, @truncate(wparam)) == w32.WA_INACTIVE) self.hide(false);
            return 0;
        },
        w32.WM_DPICHANGED => {
            self.scale = @as(f32, @floatFromInt(@as(u16, @truncate(wparam)))) / 96;
            self.updateAppearance();
            if (lparam != 0) {
                const rect: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = w32.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
            }
            self.layout();
            return 0;
        },
        w32.WM_CTLCOLOREDIT, w32.WM_CTLCOLORLISTBOX, w32.WM_CTLCOLORSTATIC => {
            const dc: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(dc, self.foreground);
            _ = w32.SetBkColor(dc, self.background);
            if (self.brush) |brush| return @bitCast(@intFromPtr(brush));
        },
        w32.WM_ERASEBKGND => {
            var rect: w32.RECT = undefined;
            if (self.brush) |brush| {
                if (w32.GetClientRect(hwnd, &rect) != 0) _ = w32.FillRect(@ptrFromInt(wparam), &rect, brush);
                return 1;
            }
        },
        w32.WM_GETMINMAXINFO => {
            const limits: *w32.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            limits.ptMinTrackSize = .{ .x = self.px(320), .y = self.px(240) };
            return 0;
        },
        else => {},
    }
    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

test "tab overview Unicode title filtering" {
    const testing = std.testing;
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Build CAFÉ 日本語 🚀");
    try testing.expect(matches(title, std.unicode.utf8ToUtf16LeStringLiteral("café")));
    try testing.expect(matches(title, std.unicode.utf8ToUtf16LeStringLiteral("日本")));
    try testing.expect(matches(title, std.unicode.utf8ToUtf16LeStringLiteral("🚀")));
    try testing.expect(matches(title, &.{}));
    try testing.expect(!matches(title, std.unicode.utf8ToUtf16LeStringLiteral("missing")));
    try testing.expect(!matches(&.{}, title));
}

test "tab overview native controls filtering stable selection DPI and teardown" {
    // Hidden test-owned HWNDs only: no foreground activation or global input.
    const testing = std.testing;
    const App = @import("App.zig");
    const Surface = @import("Surface.zig");
    const Tree = @import("../../datastruct/split_tree.zig").SplitTree(Surface);
    const instance = w32.GetModuleHandleW(null) orelse return error.Win32Error;
    _ = try registerClass(instance);
    defer _ = w32.UnregisterClassW(class_name, instance);
    const owner_hwnd = w32.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral("overview test owner"),
        w32.WS_OVERLAPPEDWINDOW,
        0,
        0,
        800,
        600,
        null,
        null,
        instance,
        null,
    ) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(owner_hwnd);
    var app: App = .{ .core_app = undefined, .config = undefined, .hinstance = instance };
    app.config.background = .{ .r = 20, .g = 20, .b = 20 };
    app.config.foreground = .{ .r = 240, .g = 240, .b = 240 };
    app.config.@"window-theme" = .dark;
    var owner: Window = .{ .app = &app, .hwnd = owner_hwnd, .tab_count = 3 };
    var surfaces: [3]Surface = undefined;
    var nodes: [3][1]Tree.Node = undefined;
    const titles = [_][]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("Build CAFÉ"),
        std.unicode.utf8ToUtf16LeStringLiteral("日本語 🚀"),
        std.unicode.utf8ToUtf16LeStringLiteral("Logs"),
    };
    for (&surfaces, 0..) |*surface, i| {
        surface.* = .{ .app = &app, .parent_window = &owner };
        surface.core_surface.id = i + 11;
        nodes[i][0] = .{ .leaf = surface };
        owner.tab_trees[i] = .{ .arena = undefined, .nodes = &nodes[i], .zoomed = null };
        owner.tab_active_surface[i] = surface;
        @memcpy(owner.tab_titles[i][0..titles[i].len], titles[i]);
        owner.tab_title_lens[i] = @intCast(titles[i].len);
    }
    // These are borrowed stack trees, not ref-counted live sessions. Never
    // call Window.deinit/close on this fixture.
    const overview = &owner.tab_overview;
    try overview.create(&owner);
    defer overview.deinit();
    overview.active = true;
    overview.refresh();
    try testing.expectEqual(@as(usize, 3), overview.count);
    try testing.expectEqual(@as(?u64, 11), overview.selectedID());
    try testing.expectEqual(@as(isize, 3), w32.SendMessageW(overview.list.?, 0x018B, 0, 0)); // LB_GETCOUNT

    _ = w32.SetWindowTextW(overview.edit.?, std.unicode.utf8ToUtf16LeStringLiteral("café"));
    try testing.expectEqual(@as(usize, 1), overview.count);
    try testing.expectEqual(@as(?u64, 11), overview.selectedID());
    _ = w32.SetWindowTextW(overview.edit.?, std.unicode.utf8ToUtf16LeStringLiteral("日本"));
    try testing.expectEqual(@as(usize, 1), overview.count);
    try testing.expectEqual(@as(?u64, 12), overview.selectedID());

    // Reorder without refreshing the snapshot: activation must find the
    // same surface at its new index, not select the old numeric position.
    std.mem.swap(Tree, &owner.tab_trees[1], &owner.tab_trees[2]);
    std.mem.swap(*Surface, &owner.tab_active_surface[1], &owner.tab_active_surface[2]);
    std.mem.swap([256]u16, &owner.tab_titles[1], &owner.tab_titles[2]);
    std.mem.swap(u16, &owner.tab_title_lens[1], &owner.tab_title_lens[2]);
    overview.activateSelection();
    try testing.expectEqual(@as(usize, 2), owner.active_tab);
    try testing.expect(!overview.active);

    overview.active = true;
    _ = w32.SetWindowTextW(overview.edit.?, std.unicode.utf8ToUtf16LeStringLiteral(""));
    overview.refresh();
    try testing.expectEqual(@as(?u64, 12), overview.selectedID());
    _ = w32.SendMessageW(overview.list.?, lb_setcursel, 1, 0);
    const selected = overview.selectedID();
    // A title update must preserve selection by identity.
    owner.tab_titles[1][0] = 'l';
    overview.refresh();
    try testing.expectEqual(selected, overview.selectedID());
    try testing.expect(overview.handleKey(overview.edit.?, w32.VK_DOWN));
    try testing.expectEqual(@as(?u64, 12), overview.selectedID());
    try testing.expect(overview.handleKey(overview.edit.?, w32.VK_DOWN));
    try testing.expectEqual(@as(?u64, 12), overview.selectedID());

    // Remove the selected session before activation. It must not activate
    // whichever tab later occupies its stale list position.
    owner.tab_count = 2;
    owner.active_tab = 0;
    overview.activateSelection();
    try testing.expect(overview.active);
    try testing.expectEqual(@as(usize, 0), owner.active_tab);
    try testing.expectEqual(@as(usize, 2), overview.count);
    _ = w32.SetWindowTextW(overview.edit.?, std.unicode.utf8ToUtf16LeStringLiteral("no matches"));
    try testing.expectEqual(@as(usize, 0), overview.count);
    try testing.expectEqual(@as(?u64, null), overview.selectedID());
    try testing.expect(overview.handleKey(overview.edit.?, w32.VK_DOWN));
    overview.activateSelection();
    try testing.expectEqual(@as(usize, 0), owner.active_tab);

    const suggested: w32.RECT = .{ .left = 0, .top = 0, .right = 1080, .bottom = 880 };
    _ = w32.SendMessageW(overview.hwnd.?, w32.WM_DPICHANGED, 192 | (192 << 16), @bitCast(@intFromPtr(&suggested)));
    try testing.expectEqual(@as(f32, 2), overview.scale);
    var rect: w32.RECT = undefined;
    try testing.expect(w32.GetWindowRect(overview.edit.?, &rect) != 0);
    try testing.expectEqual(@as(i32, 56), rect.bottom - rect.top);
    owner.closing = true;
    overview.refresh();
    try testing.expect(!overview.active);
    overview.deinit();
    try testing.expectEqual(@as(?w32.HWND, null), overview.hwnd);
    try testing.expectEqual(@as(?*anyopaque, null), overview.font);
}
