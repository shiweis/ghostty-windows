//! A pane's terminal inspector owns a separate WGL context on the UI
//! thread. The terminal's renderer continues using its own context.
const Inspector = @This();

const std = @import("std");
const imgui = @import("dcimgui");
const CoreInspector = @import("../../inspector/Inspector.zig");
const Surface = @import("Surface.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32_inspector);
pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyInspector");
const frame_timer: usize = 1;
const export_message = w32.WM_APP + 1;

surface: *Surface,
hwnd: w32.HWND,
dc: w32.HDC,
gl: w32.HGLRC,
ctx: *imgui.c.ImGuiContext,
pending_export: ?[]u8 = null,

extern "opengl32" fn wglGetCurrentContext() callconv(.winapi) ?w32.HGLRC;
extern "opengl32" fn glClearColor(r: f32, g: f32, b: f32, a: f32) callconv(.winapi) void;
extern "opengl32" fn glClear(mask: u32) callconv(.winapi) void;

const CurrentGL = struct {
    dc: ?w32.HDC,
    gl: ?w32.HGLRC,

    fn bind(dc: w32.HDC, gl: w32.HGLRC) !CurrentGL {
        const previous: CurrentGL = .{ .dc = w32.wglGetCurrentDC(), .gl = wglGetCurrentContext() };
        if (w32.wglMakeCurrent(dc, gl) == 0) return error.Win32Error;
        return previous;
    }

    fn restore(self: CurrentGL) void {
        if (w32.wglMakeCurrent(self.dc, self.gl) == 0) log.err("restoring WGL context failed", .{});
    }
};

pub fn registerClass(instance: w32.HINSTANCE) !u16 {
    const atom = w32.RegisterClassExW(&.{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_OWNDC | w32.CS_DBLCLKS,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = w32.LoadIconW(instance, w32.IDI_GHOSTTY),
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    });
    return if (atom != 0) atom else error.Win32Error;
}

pub fn create(surface: *Surface) !*Inspector {
    if (!surface.core_surface_ready or surface.parent_window.closing) return error.SurfaceClosed;
    if (surface.inspector) |existing| return existing;
    const owner = surface.parent_window.hwnd orelse return error.SurfaceClosed;
    const dpi = w32.GetDpiForWindow(owner);
    const scale: f32 = if (dpi == 0) 1 else @as(f32, @floatFromInt(dpi)) / 96;
    const hwnd = w32.CreateWindowExW(
        0,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty Terminal Inspector"),
        w32.WS_OVERLAPPEDWINDOW,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        @intFromFloat(900 * scale),
        @intFromFloat(640 * scale),
        owner,
        null,
        surface.app.hinstance,
        null,
    ) orelse return error.Win32Error;
    errdefer _ = w32.DestroyWindow(hwnd);
    const dc = w32.GetDC(hwnd) orelse return error.Win32Error;
    errdefer _ = w32.ReleaseDC(hwnd, dc);
    try Surface.setupPixelFormat(dc);
    const gl = w32.wglCreateContext(dc) orelse return error.Win32Error;
    errdefer _ = w32.wglDeleteContext(gl);
    const previous = try CurrentGL.bind(dc, gl);
    defer previous.restore();
    const previous_ctx = imgui.c.ImGui_GetCurrentContext();
    defer imgui.c.ImGui_SetCurrentContext(previous_ctx);
    const ctx = imgui.c.ImGui_CreateContext(null) orelse return error.OutOfMemory;
    errdefer imgui.c.ImGui_DestroyContext(ctx);
    imgui.c.ImGui_SetCurrentContext(ctx);
    if (!imgui.ImGui_ImplWin32_InitForOpenGL(hwnd)) return error.ImGuiPlatformInitialization;
    errdefer imgui.ImGui_ImplWin32_Shutdown();
    if (!imgui.ImGui_ImplOpenGL3_Init(null)) return error.ImGuiRendererInitialization;
    errdefer imgui.ImGui_ImplOpenGL3_ShutdownWithLoaderCleanup();
    CoreInspector.setup();
    applyDpi(w32.GetDpiForWindow(hwnd));
    const alloc = surface.app.core_app.alloc;
    const inspector = try alloc.create(Inspector);
    errdefer alloc.destroy(inspector);
    inspector.* = .{ .surface = surface, .hwnd = hwnd, .dc = dc, .gl = gl, .ctx = ctx };
    inspector.updateTheme(surface.app.windowThemeIsDark());
    if (w32.SetTimer(hwnd, frame_timer, 33, null) == 0) return error.Win32Error;
    try surface.core_surface.activateInspector();
    surface.inspector = inspector;
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(inspector)));
    return inspector;
}

pub fn present(self: *Inspector) void {
    _ = w32.ShowWindow(self.hwnd, if (w32.IsIconic(self.hwnd) != 0) w32.SW_RESTORE else w32.SW_SHOW);
    _ = w32.SetForegroundWindow(self.hwnd);
}

pub fn close(self: *Inspector) void {
    _ = w32.DestroyWindow(self.hwnd);
}

pub fn queueRender(self: *Inspector) void {
    if (w32.IsWindowVisible_(self.hwnd) != 0 and w32.IsIconic(self.hwnd) == 0)
        _ = w32.InvalidateRect(self.hwnd, null, 0);
}

// The export button runs inside Inspector.render with the terminal mutex
// held. Open the modal save dialog in a later message, after the frame.
pub fn queueExport(self: *Inspector, contents: []const u8) !bool {
    if (self.pending_export != null) return true;
    const alloc = self.surface.app.core_app.alloc;
    const copy = try alloc.dupe(u8, contents);
    errdefer alloc.free(copy);
    if (w32.PostMessageW(self.hwnd, export_message, 0, 0) == 0) return error.Win32Error;
    self.pending_export = copy;
    return true;
}

pub fn updateTheme(self: *Inspector, dark: bool) void {
    const dark_mode: u32 = @intFromBool(dark);
    _ = w32.DwmSetWindowAttribute(self.hwnd, w32.DWMWA_USE_IMMERSIVE_DARK_MODE, @ptrCast(&dark_mode), @sizeOf(u32));
    const previous = imgui.c.ImGui_GetCurrentContext();
    defer imgui.c.ImGui_SetCurrentContext(previous);
    imgui.c.ImGui_SetCurrentContext(self.ctx);
    if (dark) imgui.c.ImGui_StyleColorsDark(null) else imgui.c.ImGui_StyleColorsLight(null);
    self.queueRender();
}

fn applyDpi(dpi: u32) void {
    const scale: f32 = if (dpi == 0) 1 else @as(f32, @floatFromInt(dpi)) / 96;
    const style = imgui.c.ImGui_GetStyle();
    imgui.ext.ImGuiStyle_ImGuiStyle(style);
    imgui.c.ImGuiStyle_ScaleAllSizes(style, scale);
    style.*.FontSizeBase = 16;
    style.*.FontScaleDpi = scale;
}

fn render(self: *Inspector) !void {
    const surface = &self.surface.core_surface;
    if (!self.surface.core_surface_ready) return;
    const core = surface.inspector orelse return;
    const previous = try CurrentGL.bind(self.dc, self.gl);
    defer previous.restore();
    const previous_ctx = imgui.c.ImGui_GetCurrentContext();
    defer imgui.c.ImGui_SetCurrentContext(previous_ctx);
    imgui.c.ImGui_SetCurrentContext(self.ctx);
    imgui.ImGui_ImplOpenGL3_NewFrame();
    imgui.ImGui_ImplWin32_NewFrame();
    imgui.c.ImGui_NewFrame();
    core.render(surface);
    imgui.c.ImGui_Render();
    const bg = imgui.c.ImGui_GetStyle().*.Colors[imgui.c.ImGuiCol_WindowBg];
    glClearColor(bg.x, bg.y, bg.z, 1);
    glClear(0x4000); // GL_COLOR_BUFFER_BIT
    imgui.ImGui_ImplOpenGL3_RenderDrawData(imgui.c.ImGui_GetDrawData());
    if (w32.SwapBuffers(self.dc) == 0) return error.Win32Error;
}

fn destroyed(self: *Inspector) void {
    _ = w32.SetWindowLongPtrW(self.hwnd, w32.GWLP_USERDATA, 0);
    _ = w32.KillTimer(self.hwnd, frame_timer);
    self.surface.inspector = null;
    self.surface.core_surface.deactivateInspector();
    const previous_ctx = imgui.c.ImGui_GetCurrentContext();
    imgui.c.ImGui_SetCurrentContext(self.ctx);
    if (CurrentGL.bind(self.dc, self.gl)) |previous| {
        imgui.ImGui_ImplOpenGL3_ShutdownWithLoaderCleanup();
        if (previous.gl == self.gl) {
            _ = w32.wglMakeCurrent(null, null);
        } else previous.restore();
    } else |err| log.err("binding inspector context for shutdown failed err={}", .{err});
    imgui.ImGui_ImplWin32_Shutdown();
    imgui.c.ImGui_DestroyContext(self.ctx);
    imgui.c.ImGui_SetCurrentContext(if (previous_ctx == self.ctx) null else previous_ctx);
    _ = w32.wglDeleteContext(self.gl);
    _ = w32.ReleaseDC(self.hwnd, self.dc);
    const alloc = self.surface.app.core_app.alloc;
    if (self.pending_export) |contents| alloc.free(contents);
    alloc.destroy(self);
}

fn wndProc(hwnd: w32.HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
    const data = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (data == 0) return w32.DefWindowProcW(hwnd, msg, wp, lp);
    const self: *Inspector = @ptrFromInt(@as(usize, @bitCast(data)));
    switch (msg) {
        w32.WM_DESTROY => {
            self.destroyed();
            return 0;
        },
        w32.WM_ERASEBKGND => return 1,
        w32.WM_TIMER => if (wp == frame_timer) {
            self.queueRender();
            return 0;
        },
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            if (w32.BeginPaint(hwnd, &ps) == null) return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            self.render() catch |err| log.err("inspector frame failed err={}", .{err});
            return 0;
        },
        export_message => {
            const contents = self.pending_export orelse return 0;
            self.pending_export = null;
            const app = self.surface.app;
            const alloc = app.core_app.alloc;
            defer alloc.free(contents);
            _ = app.exportTerminalIo(hwnd, contents);
            return 0;
        },
        else => {},
    }

    const result = backend: {
        const previous_ctx = imgui.c.ImGui_GetCurrentContext();
        defer imgui.c.ImGui_SetCurrentContext(previous_ctx);
        imgui.c.ImGui_SetCurrentContext(self.ctx);
        if (msg == w32.WM_DPICHANGED) {
            applyDpi(@as(u16, @truncate(wp)));
            self.updateTheme(self.surface.app.windowThemeIsDark());
        }
        break :backend imgui.ImGui_ImplWin32_WndProcHandler(hwnd, msg, wp, lp);
    };
    if (msg == w32.WM_DPICHANGED and lp != 0) {
        const r: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
        _ = w32.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
        return 0;
    }
    return if (result != 0) result else w32.DefWindowProcW(hwnd, msg, wp, lp);
}

test "native inspector draws the shared terminal, routes local input, and detaches before surface shutdown" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const global = @import("../../global.zig");
    const terminal = @import("../../terminal/main.zig");
    const App = @import("App.zig");
    const Window = @import("Window.zig");
    const instance = w32.GetModuleHandleW(null) orelse return error.Win32Error;
    _ = try registerClass(instance);
    defer _ = w32.UnregisterClassW(class_name, instance);
    const parent = w32.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral(""), 0, 0, 0, 640, 480, null, null, instance, null) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(parent);
    var core_app: @import("../../App.zig") = undefined;
    core_app.alloc = alloc;
    var app: App = .{ .core_app = &core_app, .config = undefined, .hinstance = instance, .window_theme_override = .dark };
    var window: Window = .{ .app = &app, .hwnd = parent };
    const pane = try alloc.create(Surface);
    defer alloc.destroy(pane);
    pane.* = .{ .app = &app, .parent_window = &window, .core_surface_ready = true };
    const core = &pane.core_surface;
    core.alloc = alloc;
    core.id = 42;
    core.rt_surface = pane;
    core.rt_app = &app;
    core.inspector = null;
    core.readonly = false;
    core.mouse = .{};
    core.size = .{ .screen = .{ .width = 640, .height = 480 }, .cell = .{ .width = 8, .height = 16 }, .padding = .{} };
    core.font_size = .{ .points = 12 };
    core.io.terminal = try terminal.Terminal.init(global.io(), alloc, .{ .cols = 80, .rows = 30 });
    defer core.io.terminal.deinit(alloc);
    var mutex: std.Io.Mutex = .init;
    core.renderer_state = .{ .mutex = &mutex, .terminal = &core.io.terminal };
    core.renderer_thread.mailbox = try @import("../../renderer/Thread.zig").Mailbox.create(alloc);
    defer core.renderer_thread.mailbox.destroy(alloc);
    core.renderer_thread.wakeup = try global.xev.Async.init();
    defer core.renderer_thread.wakeup.deinit();
    core.io.mailbox = try @import("../../termio.zig").Mailbox.initSPSC(alloc);
    defer core.io.mailbox.deinit(alloc);
    defer if (pane.inspector) |current| current.close();

    // The window stays hidden throughout. All messages target this HWND;
    // the desktop focus, keyboard state and cursor remain the user's.
    const unrelated = w32.CreateWindowExW(
        0,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        0,
        0,
        0,
        1,
        1,
        null,
        null,
        instance,
        null,
    ) orelse return error.Win32Error;
    defer _ = w32.DestroyWindow(unrelated);
    const dc = w32.GetDC(unrelated) orelse return error.Win32Error;
    defer _ = w32.ReleaseDC(unrelated, dc);
    try Surface.setupPixelFormat(dc);
    const gl = w32.wglCreateContext(dc) orelse return error.Win32Error;
    defer _ = w32.wglDeleteContext(gl);
    const original_gl = try CurrentGL.bind(dc, gl);
    defer original_gl.restore();
    const before_gl = wglGetCurrentContext();
    const before_imgui = imgui.c.ImGui_GetCurrentContext();
    const inspector = try create(pane);
    try testing.expectEqual(inspector, try create(pane));
    try testing.expectEqual(before_gl, wglGetCurrentContext());
    try testing.expectEqual(core.inspector, core.renderer_state.inspector);
    try testing.expect(core.renderer_thread.mailbox.pop(global.io()).?.inspector);
    try testing.expect(core.io.mailbox.spsc.queue.pop(global.io()).?.inspector);
    try core.inspector.?.recordPtyRead(alloc, &core.io.terminal, "\x1b[31m");
    try core.inspector.?.recordKeyEvent(alloc, .{ .event = .{ .key = .key_a } });
    try testing.expect(!core.inspector.?.gui.vt_stream.events.empty());
    try testing.expectEqual(1, core.inspector.?.gui.key_stream.events.len());

    // Disable changes to the system cursor during the hidden test frames.
    imgui.c.ImGui_SetCurrentContext(inspector.ctx);
    imgui.c.ImGui_GetIO().*.ConfigFlags |= imgui.c.ImGuiConfigFlags_NoMouseCursorChange;
    imgui.c.ImGui_SetCurrentContext(before_imgui);
    _ = w32.SendMessageW(inspector.hwnd, w32.WM_SETFOCUS, 0, 0);
    _ = w32.SendMessageW(inspector.hwnd, w32.WM_KEYDOWN, 'A', 0);
    _ = w32.SendMessageW(inspector.hwnd, w32.WM_CHAR, 'a', 0);
    var rect: w32.RECT = .{ .left = 20, .top = 20, .right = 820, .bottom = 620 };
    _ = w32.SendMessageW(inspector.hwnd, w32.WM_DPICHANGED, 144 | (144 << 16), @bitCast(@intFromPtr(&rect)));
    try inspector.render();
    try inspector.render();
    try testing.expectEqual(before_gl, wglGetCurrentContext());
    try testing.expectEqual(before_imgui, imgui.c.ImGui_GetCurrentContext());
    imgui.c.ImGui_SetCurrentContext(inspector.ctx);
    const drew = imgui.c.ImGui_GetDrawData().*.TotalVtxCount > 0;
    const key_down = imgui.c.ImGui_IsKeyDown(imgui.c.ImGuiKey_A);
    const dpi = imgui.c.ImGui_GetStyle().*.FontScaleDpi;
    imgui.c.ImGui_SetCurrentContext(before_imgui);
    try testing.expect(drew and key_down);
    try testing.expectEqual(@as(f32, 1.5), dpi);
    try testing.expect(try app.performAction(.{ .surface = core }, .render_inspector, {}));

    _ = w32.SendMessageW(inspector.hwnd, w32.WM_CLOSE, 0, 0);
    try testing.expect(pane.inspector == null and core.inspector == null and core.renderer_state.inspector == null);
    try testing.expect(!core.renderer_thread.mailbox.pop(global.io()).?.inspector);
    try testing.expect(!core.io.mailbox.spsc.queue.pop(global.io()).?.inspector);

    const reopened = try create(pane);
    const hwnd = reopened.hwnd;
    try testing.expect(try reopened.queueExport("owned copy"));
    pane.deinit();
    try testing.expect(w32.GetWindowRect(hwnd, &rect) == 0);
    try testing.expect(pane.inspector == null and core.inspector == null);
    try testing.expectEqual(before_gl, wglGetCurrentContext());
}
