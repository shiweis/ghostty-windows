//! Graphics API wrapper for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(OpenGL);
const Dmabuf = @import("Dmabuf.zig");
const is_wgl = apprt.runtime == apprt.win32;
const w32 = if (is_wgl) @import("../apprt/win32/win32.zig") else struct {};
pub const Device = if (is_wgl) @import("opengl/WGLDevice.zig") else @import("opengl/Device.zig");
const WindowsPresentation = @import("opengl/WindowsPresentation.zig");

pub const GraphicsAPI = OpenGL;
pub const Target = @import("opengl/Target.zig");
pub const Frame = @import("opengl/Frame.zig");
pub const RenderPass = @import("opengl/RenderPass.zig");
pub const Pipeline = @import("opengl/Pipeline.zig");
const bufferpkg = @import("opengl/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("opengl/Sampler.zig");
pub const Texture = @import("opengl/Texture.zig");
pub const shaders = @import("opengl/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .glsl;
pub const custom_shader_y_is_down = false;

/// Triple-buffering gives the GPU room to pipeline renders without
/// having to wait on the apprt consuming previous frames.
pub const swap_chain_count = 3;

const log = std.log.scoped(.opengl);
/// We require at least OpenGL 4.3
pub const MIN_VERSION_MAJOR = 4;
pub const MIN_VERSION_MINOR = 3;

alloc: Allocator,
blending: configpkg.Config.AlphaBlending,

/// The shared render device.
device: *const Device,

egl_context: if (is_wgl) void else *gl.egl.Context,
last_target: ?Target = null,
windows_presentation: ?WindowsPresentation = null,
windows_composition_supported: bool = false,
windows_composition_unavailable: bool = false,
windows_hwnd: if (is_wgl) ?std.os.windows.HWND else void = if (is_wgl) null else {},
windows_surface: if (is_wgl) ?*apprt.Surface else void = if (is_wgl) null else {},

context_loaded: bool = false,

pub fn init(
    alloc: Allocator,
    device: *const Device,
    opts: rendererpkg.Options,
) !OpenGL {
    // WGL contexts belong to native surfaces. GPU resources are now created
    // lazily on the render thread, so initialization must not bind the context
    // on the GUI thread or require an EGL installation on Windows.
    if (comptime is_wgl) {
        const surface = opts.rt_surface;
        return .{
            .alloc = alloc,
            .blending = opts.config.blending,
            .device = device,
            .egl_context = {},
            .windows_hwnd = surface.hwnd,
            .windows_surface = surface,
            .windows_composition_supported = surface.transparency_supported,
        };
    }

    const display = device.display;

    // Bind to OpenGL API explicitly before we create the context,
    // as otherwise it might fallback to OpenGL ES
    try egl.bindApi(egl.c.EGL_OPENGL_API);

    // Create our context. Contexts are surface-scoped because a
    // context can only be current on one thread at a time.
    const context = egl.Context.create(display, device.config, null, &.{
        egl.c.EGL_CONTEXT_MAJOR_VERSION,       MIN_VERSION_MAJOR,
        egl.c.EGL_CONTEXT_MINOR_VERSION,       MIN_VERSION_MINOR,
        egl.c.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
    }) catch |err| {
        log.warn("failed to create EGL context err={}", .{err});
        return err;
    };
    errdefer context.destroy(display) catch {};

    display.makeCurrent(null, null, context) catch |err| {
        log.warn("failed to make EGL context current err={}", .{err});
        return err;
    };

    // Release current so that the main thread
    // doesn't hold onto the GL context forever.
    defer display.releaseCurrent();

    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .device = device,
        .egl_context = context,
    };
}

pub fn deinit(self: *OpenGL) void {
    if (self.windows_presentation) |*presentation| presentation.deinit();
    if (comptime !is_wgl) {
        self.device.display.releaseCurrent();
        self.egl_context.destroy(self.device.display) catch {};
    }
    self.* = undefined;
}

/// 32-bit windows cross-compilation breaks with `.c` for some reason, so...
const gl_debug_proc_callconv =
    @typeInfo(
        @typeInfo(
            @typeInfo(
                gl.c.GLDEBUGPROC,
            ).optional.child,
        ).pointer.child,
    ).@"fn".attrs.@"callconv";

fn glDebugMessageCallback(
    src: gl.c.GLenum,
    typ: gl.c.GLenum,
    id: gl.c.GLuint,
    severity: gl.c.GLenum,
    len: gl.c.GLsizei,
    msg: [*c]const gl.c.GLchar,
    user_param: ?*const anyopaque,
) callconv(gl_debug_proc_callconv) void {
    _ = user_param;

    const src_str: []const u8 = switch (src) {
        gl.c.GL_DEBUG_SOURCE_API => "OpenGL API",
        gl.c.GL_DEBUG_SOURCE_WINDOW_SYSTEM => "Window System",
        gl.c.GL_DEBUG_SOURCE_SHADER_COMPILER => "Shader Compiler",
        gl.c.GL_DEBUG_SOURCE_THIRD_PARTY => "Third Party",
        gl.c.GL_DEBUG_SOURCE_APPLICATION => "User",
        gl.c.GL_DEBUG_SOURCE_OTHER => "Other",
        else => "Unknown",
    };

    const typ_str: []const u8 = switch (typ) {
        gl.c.GL_DEBUG_TYPE_ERROR => "Error",
        gl.c.GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR => "Deprecated Behavior",
        gl.c.GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR => "Undefined Behavior",
        gl.c.GL_DEBUG_TYPE_PORTABILITY => "Portability Issue",
        gl.c.GL_DEBUG_TYPE_PERFORMANCE => "Performance Issue",
        gl.c.GL_DEBUG_TYPE_MARKER => "Marker",
        gl.c.GL_DEBUG_TYPE_PUSH_GROUP => "Group Push",
        gl.c.GL_DEBUG_TYPE_POP_GROUP => "Group Pop",
        gl.c.GL_DEBUG_TYPE_OTHER => "Other",
        else => "Unknown",
    };

    const msg_str = msg[0..@intCast(len)];

    (switch (severity) {
        gl.c.GL_DEBUG_SEVERITY_HIGH => log.err(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_MEDIUM => log.warn(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_LOW => log.info(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_NOTIFICATION => log.debug(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        else => log.warn(
            "UNKNOWN SEVERITY [{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
    });
}

/// Prepares the provided GL context, loading it with glad.
fn prepareContext(getProcAddress: anytype) !void {
    const version = try gl.glad.load(getProcAddress);
    const major = gl.glad.versionMajor(@intCast(version));
    const minor = gl.glad.versionMinor(@intCast(version));
    errdefer gl.glad.unload();
    log.info("loaded OpenGL {}.{}", .{ major, minor });

    // Need to check version before trying to enable it
    if (major < MIN_VERSION_MAJOR or
        (major == MIN_VERSION_MAJOR and minor < MIN_VERSION_MINOR))
    {
        log.warn(
            "OpenGL version is too old. Ghostty requires OpenGL {d}.{d}",
            .{ MIN_VERSION_MAJOR, MIN_VERSION_MINOR },
        );
        return error.OpenGLOutdated;
    }

    // Enable debug output for the context.
    try gl.enable(gl.c.GL_DEBUG_OUTPUT);

    // Register our debug message callback with the OpenGL context.
    gl.glad.context.DebugMessageCallback.?(glDebugMessageCallback, null);

    // Enable SRGB framebuffer for linear blending support.
    try gl.enable(gl.c.GL_FRAMEBUFFER_SRGB);
}

/// Callback called by renderer.Thread when it begins. Called on the render
/// thread. The EGL context was created at `init` time on the main thread;
/// here we (re)bind it to this thread and load the thread-local glad
/// function pointers so all subsequent GL work on this thread is valid.
pub fn threadEnter(self: *OpenGL, surface: *apprt.Surface) !void {
    if (comptime is_wgl) {
        const hdc = surface.hdc orelse return error.InvalidSurface;
        const hglrc = surface.hglrc orelse return error.InvalidSurface;
        if (w32.wglMakeCurrent(hdc, hglrc) == 0) return error.WGLMakeCurrentFailed;
        errdefer _ = w32.wglMakeCurrent(null, null);
        try prepareContext(null);
        self.context_loaded = true;
        return;
    }
    try self.device.display.makeCurrent(null, null, self.egl_context);
    // Load our function pointers for this thread's threadlocal.
    try prepareContext(&gl.egl.getProcAddress);
    self.context_loaded = true;
}

/// Callback called by renderer.Thread when it exits. Called on the render
/// thread; unbinds the context from this thread so it can be destroyed on
/// the main thread.
pub fn threadExit(self: *OpenGL) void {
    if (comptime is_wgl) {
        _ = w32.wglMakeCurrent(null, null);
    } else {
        self.device.display.releaseCurrent();
    }
    if (self.context_loaded) {
        gl.glad.unload();
        self.context_loaded = false;
    }
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const OpenGL) !struct { width: u32, height: u32 } {
    _ = self;
    if (comptime is_wgl) {
        // GL_VIEWPORT can still describe the previous frame while WM_SIZE
        // is in flight. Query the window associated with this thread's DC.
        const hdc = w32.wglGetCurrentDC() orelse return error.NoCurrentContext;
        const hwnd = w32.WindowFromDC(hdc) orelse return error.NoWindow;
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &rect) == 0) return error.NoWindow;
        return .{
            .width = @intCast(@max(0, rect.right - rect.left)),
            .height = @intCast(@max(0, rect.bottom - rect.top)),
        };
    }
    var viewport: [4]gl.c.GLint = undefined;
    gl.glad.context.GetIntegerv.?(gl.c.GL_VIEWPORT, &viewport);
    return .{
        .width = @intCast(viewport[2]),
        .height = @intCast(viewport[3]),
    };
}

/// Set the GL viewport to cover the given size in device pixels.
///
/// This used to be automatically called by the GtkGLArea upon resizing,
/// but now we need to do this manually.
pub fn setViewport(self: *const OpenGL, width: u32, height: u32) void {
    _ = self;
    gl.viewport(0, 0, @intCast(width), @intCast(height)) catch |err| {
        log.warn("failed to set OpenGL viewport err={}", .{err});
    };
}

/// The presenter is valid only while its creating WGL context is current.
pub fn gpuResourcesReleased(self: *OpenGL) void {
    if (self.windows_presentation) |*presentation| presentation.deinit();
    self.windows_presentation = null;
    self.last_target = null;
    if (comptime is_wgl) {
        if (self.windows_surface) |surface| surface.invalidatePresentedFrame();
    }
}

pub fn displayRealized(_: *const OpenGL) void {
    if (comptime apprt.runtime == apprt.gtk) {
        prepareContext(null) catch |err| {
            log.warn("Error preparing GL context in displayRealized, err={}", .{err});
        };
    }
}

/// Actions taken before doing anything in `drawFrame`.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameStart(self: *OpenGL) void {
    _ = self;
}

/// Actions taken after `drawFrame` is done.
///
/// The opaque Win32 fallback swaps its double-buffered WGL surface.
pub fn drawFrameEnd(self: *OpenGL) void {
    if (comptime apprt.runtime == apprt.win32) {
        if (!self.windows_composition_supported) {
            const hdc = w32.wglGetCurrentDC();
            if (hdc != null and w32.SwapBuffers(hdc.?) != 0) {
                if (self.last_target) |target| self.windows_surface.?.signalFrameDrawn(
                    @intCast(target.width),
                    @intCast(target.height),
                );
            } else {
                self.windows_surface.?.invalidatePresentedFrame();
            }
        }
    }
}

pub fn initShaders(
    self: *const OpenGL,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(
        self.alloc,
        custom_shaders,
    );
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const OpenGL, width: usize, height: usize) !Target {
    _ = self;
    return Target.init(.{
        .width = width,
        .height = height,
    });
}

/// Export a rendered target. Caller takes ownership
/// of the frame and is responsible for freeing it.
///
/// This runs on the render thread.
pub fn present(
    self: *OpenGL,
    target: Target,
    presentation_health: rendererpkg.Health,
) !ExportedFrame {
    if (comptime is_wgl) {
        const surface = self.windows_surface.?;
        if (surface.transparency_supported and self.windows_composition_unavailable) {
            surface.requestOpaquePresentation();
            return error.CompositionUnavailable;
        }
        if (!surface.transparency_supported) {
            if (self.windows_presentation == null)
                self.windows_presentation = try WindowsPresentation.init(self.alloc, null);
            try self.windows_presentation.?.present(target, self.blending);
            self.windows_composition_supported = false;
            self.last_target = target;
            return;
        }
        if (self.windows_presentation == null) {
            const hwnd = self.windows_hwnd orelse return error.InvalidSurface;
            var presentation = try WindowsPresentation.init(self.alloc, hwnd);
            if (!presentation.compositionSupported()) {
                const hr = presentation.unavailable_hresult orelse @as(i32, @bitCast(@as(u32, 0x80004005)));
                log.warn(
                    "Windows transparency unavailable; switching to an opaque background (DirectComposition HRESULT=0x{x:0>8})",
                    .{@as(u32, @bitCast(hr))},
                );
                presentation.deinit();
                self.windows_composition_unavailable = true;
                surface.requestOpaquePresentation();
                return error.CompositionUnavailable;
            }
            self.windows_presentation = presentation;
            self.windows_composition_supported = true;
        }

        self.windows_presentation.?.present(target, self.blending) catch |err| {
            surface.invalidatePresentedFrame();
            return err;
        };
        surface.signalFrameDrawn(@intCast(target.width), @intCast(target.height));
        self.last_target = target;
        return;
    }
    // We only export DMABUFs when the apprt can present them.
    // Otherwise, use CPU buffers.
    if (presentation_health == .healthy) {
        if (target.exportDmabuf(self.device.display, self.egl_context)) |dmabuf| {
            return .{ .dmabuf = dmabuf };
        } else |_| {
            log.warn("failed to export DMABUF, falling back to CPU presentation", .{});
        }
    }

    return .{ .memory = .{
        .width = @intCast(target.width),
        .height = @intCast(target.height),
        .pixels = try target.readPixelsAlloc(self.alloc),
        .alloc = self.alloc,
    } };
}

/// A finished frame exported for presentation by the apprt.
pub const ExportedFrame = if (is_wgl) void else union(enum) {
    dmabuf: Dmabuf,
    memory: Memory,

    /// RGBA8 pixel data with premultiplied alpha, tightly packed
    /// (`width * 4` bytes per row), in CPU memory.
    pub const Memory = struct {
        width: u32,
        height: u32,
        pixels: []u8,
        alloc: Allocator,

        pub fn deinit(self: Memory) void {
            self.alloc.free(self.pixels);
        }
    };

    pub fn deinit(self: ExportedFrame) void {
        switch (self) {
            .dmabuf => |v| v.deinit(),
            .memory => |v| v.deinit(),
        }
    }
};

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: OpenGL) bufferpkg.Options {
    _ = self;
    return .{
        .target = .array,
        .usage = .dynamic_draw,
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: OpenGL) Texture.Options {
    _ = self;
    return .{
        .format = .rgba,
        .internal_format = .srgba,
        .target = .@"2d",
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: OpenGL) Sampler.Options {
    _ = self;
    return .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(self: ImageTextureFormat) gl.Texture.Format {
        return switch (self) {
            .gray => .red,
            .rgba => .rgba,
            .bgra => .bgra,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: OpenGL,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    return .{
        .format = format.toPixelFormat(),
        .internal_format = if (srgb) .srgba else .rgba,
        .target = .@"2d",
        // TODO: Generate mipmaps for image textures and use
        //       linear_mipmap_linear filtering so that they
        //       look good even when scaled way down.
        .min_filter = .linear,
        .mag_filter = .linear,
        // TODO: Separate out background image options, use
        //       repeating coordinate modes so we don't have
        //       to do the modulus in the shader.
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const OpenGL,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    _ = self;
    const format: gl.Texture.Format, const internal_format: gl.Texture.InternalFormat =
        switch (atlas.format) {
            .grayscale => .{ .red, .red },
            .bgra => .{ .bgra, .srgba },
            else => @panic("unsupported atlas format for OpenGL texture"),
        };

    return try Texture.init(
        .{
            .format = format,
            .internal_format = internal_format,
            .target = .rectangle,
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const OpenGL,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}
