const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const Target = @import("Target.zig");
const configpkg = @import("../../config.zig");

const log = std.log.scoped(.windows_presentation);
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

extern "user32" fn GetClientRect(hwnd: std.os.windows.HWND, rect: *RECT) callconv(.winapi) i32;

const vertex_source: [:0]const u8 =
    "#version 430 core\n" ++
    "void main() {\n" ++
    "    vec2 p = gl_VertexID == 0 ? vec2(-1.0, -1.0) :\n" ++
    "             gl_VertexID == 1 ? vec2( 3.0, -1.0) : vec2(-1.0, 3.0);\n" ++
    "    gl_Position = vec4(p, 0.0, 1.0);\n" ++
    "}\n";

const fragment_source: [:0]const u8 =
    "#version 430 core\n" ++
    "layout(location = 0) uniform sampler2D frameTexture;\n" ++
    "layout(location = 1) uniform int linearMode;\n" ++
    "layout(location = 2) uniform int flipY;\n" ++
    "out vec4 outputColor;\n" ++
    "vec3 srgbEncode(vec3 c) {\n" ++
    "    bvec3 low = lessThanEqual(c, vec3(0.0031308));\n" ++
    "    vec3 linearPart = c * 12.92;\n" ++
    "    vec3 srgbPart = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;\n" ++
    "    return mix(srgbPart, linearPart, low);\n" ++
    "}\n" ++
    "void main() {\n" ++
    "    ivec2 pixel = ivec2(gl_FragCoord.xy);\n" ++
    "    if (flipY != 0) pixel.y = textureSize(frameTexture, 0).y - 1 - pixel.y;\n" ++
    "    vec4 sampleColor = texelFetch(frameTexture, pixel, 0);\n" ++
    "    if (sampleColor.a == 0.0) { outputColor = vec4(0.0); return; }\n" ++
    "    if (linearMode != 0) {\n" ++
    "        vec3 straightLinear = clamp(sampleColor.rgb / sampleColor.a, 0.0, 1.0);\n" ++
    "        outputColor = vec4(srgbEncode(straightLinear) * sampleColor.a, sampleColor.a);\n" ++
    "    } else {\n" ++
    "        outputColor = sampleColor;\n" ++
    "    }\n" ++
    "}\n";

extern "c" fn ghostty_composition_create(
    hwnd: std.os.windows.HWND,
    width: u32,
    height: u32,
    renderbuffer: u32,
    out: *?*anyopaque,
) callconv(.c) i32;
extern "c" fn ghostty_composition_resize(
    self: *anyopaque,
    width: u32,
    height: u32,
    renderbuffer: u32,
) callconv(.c) i32;
extern "c" fn ghostty_composition_lock(self: *anyopaque) callconv(.c) i32;
extern "c" fn ghostty_composition_present(self: *anyopaque) callconv(.c) i32;
extern "c" fn ghostty_composition_cancel(self: *anyopaque) callconv(.c) i32;
extern "c" fn ghostty_composition_destroy(self: *anyopaque) callconv(.c) void;

program: gl.Program,
vao: gl.VertexArray,
framebuffer: ?gl.Framebuffer = null,
renderbuffer: ?gl.Renderbuffer = null,
composition: ?*anyopaque = null,
width: u32 = 0,
height: u32 = 0,
unavailable_hresult: ?i32 = null,

pub fn init(alloc: Allocator, hwnd: ?std.os.windows.HWND) !Self {
    _ = alloc;
    const program = try gl.Program.createVF(vertex_source, fragment_source);
    errdefer program.destroy();
    const vao = try gl.VertexArray.create();
    errdefer vao.destroy();
    var result: Self = .{ .program = program, .vao = vao };
    const window = hwnd orelse return result;

    var rect: RECT = undefined;
    if (GetClientRect(window, &rect) == 0) return error.GetClientRectFailed;
    const width: u32 = @intCast(@max(0, rect.right - rect.left));
    const height: u32 = @intCast(@max(0, rect.bottom - rect.top));

    const framebuffer = try gl.Framebuffer.create();
    errdefer framebuffer.destroy();
    const renderbuffer = try gl.Renderbuffer.create();
    errdefer renderbuffer.destroy();

    {
        const binding = try renderbuffer.bind();
        binding.unbind();
    }
    var composition: ?*anyopaque = null;
    const hr = ghostty_composition_create(
        window,
        @max(width, 1),
        @max(height, 1),
        renderbuffer.id,
        &composition,
    );
    if (hr < 0 or composition == null) {
        if (composition) |handle| ghostty_composition_destroy(handle);
        if (isUnavailable(hr)) {
            framebuffer.destroy();
            renderbuffer.destroy();
            result.unavailable_hresult = hr;
            return result;
        }
        log.err("DirectComposition create failed, HRESULT=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
        return error.CompositionCreateFailed;
    }

    errdefer ghostty_composition_destroy(composition.?);
    result.framebuffer = framebuffer;
    result.renderbuffer = renderbuffer;
    result.composition = composition.?;
    result.width = @max(width, 1);
    result.height = @max(height, 1);

    try result.lockAndAttach();
    return result;
}

fn isUnavailable(hr: i32) bool {
    return switch (@as(u32, @bitCast(hr))) {
        0x887A0004, // DXGI_ERROR_UNSUPPORTED
        0x887A0022, // DXGI_ERROR_NOT_CURRENTLY_AVAILABLE
        0x80004002, // E_NOINTERFACE
        0x80070032, // HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED)
        => true,
        else => false,
    };
}

pub fn compositionSupported(self: *const Self) bool {
    return self.composition != null;
}

fn deinitComposition(self: *Self) void {
    if (self.composition) |handle| ghostty_composition_destroy(handle);
    self.composition = null;
    if (self.framebuffer) |framebuffer| framebuffer.destroy();
    self.framebuffer = null;
    if (self.renderbuffer) |renderbuffer| renderbuffer.destroy();
    self.renderbuffer = null;
}

pub fn deinit(self: *Self) void {
    self.deinitComposition();
    self.vao.destroy();
    self.program.destroy();
}

fn attachAndValidate(self: *Self) !void {
    const context = &gl.glad.context;
    const c = gl.c;
    const framebuffer = self.framebuffer orelse return error.MissingPresentationFramebuffer;
    const renderbuffer = self.renderbuffer orelse return error.MissingPresentationRenderbuffer;
    var previous: c.GLint = undefined;
    context.GetIntegerv.?(c.GL_DRAW_FRAMEBUFFER_BINDING, &previous);
    defer context.BindFramebuffer.?(c.GL_DRAW_FRAMEBUFFER, @intCast(previous));

    context.BindFramebuffer.?(c.GL_DRAW_FRAMEBUFFER, framebuffer.id);
    context.FramebufferRenderbuffer.?(
        c.GL_DRAW_FRAMEBUFFER,
        c.GL_COLOR_ATTACHMENT0,
        c.GL_RENDERBUFFER,
        renderbuffer.id,
    );
    if (context.CheckFramebufferStatus.?(c.GL_DRAW_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE)
        return error.PresentationFramebufferIncomplete;
    try gl.errors.getError();
}

fn lock(self: *Self) !void {
    const handle = self.composition orelse return error.CompositionUnavailable;
    const hr = ghostty_composition_lock(handle);
    if (hr < 0) {
        log.err("DirectComposition lock failed, HRESULT=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
        return error.CompositionLockFailed;
    }
}

fn cancelLocked(self: *Self) !void {
    const handle = self.composition orelse return error.CompositionUnavailable;
    const hr = ghostty_composition_cancel(handle);
    if (hr < 0) {
        log.err("DirectComposition cancel failed, HRESULT=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
        return error.CompositionCancelFailed;
    }
}

fn lockAndAttach(self: *Self) !void {
    try self.lock();
    var locked = true;
    defer if (locked) {
        self.cancelLocked() catch {};
    };
    try self.attachAndValidate();
    try self.cancelLocked();
    locked = false;
}

fn resize(self: *Self, width: u32, height: u32) !void {
    const handle = self.composition orelse return error.CompositionUnavailable;
    const renderbuffer = self.renderbuffer orelse return error.MissingPresentationRenderbuffer;
    const hr = ghostty_composition_resize(handle, width, height, renderbuffer.id);
    if (hr < 0) {
        log.err("DirectComposition resize failed, HRESULT=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
        return error.CompositionResizeFailed;
    }
    try self.lockAndAttach();
    self.width = width;
    self.height = height;
}

pub fn present(
    self: *Self,
    target: Target,
    blending: configpkg.Config.AlphaBlending,
) !void {
    if (target.width == 0 or target.height == 0) return;
    const texture = target.texture;
    const width: u32 = @intCast(target.width);
    const height: u32 = @intCast(target.height);
    const is_composition = self.composition != null;
    if (is_composition and (width != self.width or height != self.height))
        try self.resize(width, height);

    var locked = false;
    if (self.composition != null) {
        try self.lock();
        locked = true;
    }
    defer if (locked) {
        self.cancelLocked() catch {};
    };

    {
        const c = gl.c;
        const context = &gl.glad.context;
        var previous_viewport: [4]c.GLint = undefined;
        var previous_program: c.GLint = undefined;
        var previous_vao: c.GLint = undefined;
        var previous_draw_framebuffer: c.GLint = undefined;
        var previous_read_framebuffer: c.GLint = undefined;
        var previous_active_texture: c.GLint = undefined;
        var previous_texture0: c.GLint = undefined;
        var previous_sampler0: c.GLint = undefined;
        context.GetIntegerv.?(c.GL_VIEWPORT, &previous_viewport);
        context.GetIntegerv.?(c.GL_CURRENT_PROGRAM, &previous_program);
        context.GetIntegerv.?(c.GL_VERTEX_ARRAY_BINDING, &previous_vao);
        context.GetIntegerv.?(c.GL_DRAW_FRAMEBUFFER_BINDING, &previous_draw_framebuffer);
        context.GetIntegerv.?(c.GL_READ_FRAMEBUFFER_BINDING, &previous_read_framebuffer);
        context.GetIntegerv.?(c.GL_ACTIVE_TEXTURE, &previous_active_texture);
        context.ActiveTexture.?(c.GL_TEXTURE0);
        context.GetIntegerv.?(c.GL_TEXTURE_BINDING_2D, &previous_texture0);
        context.GetIntegerv.?(c.GL_SAMPLER_BINDING, &previous_sampler0);
        const was_srgb = context.IsEnabled.?(c.GL_FRAMEBUFFER_SRGB) == c.GL_TRUE;
        const was_blending = context.IsEnabled.?(c.GL_BLEND) == c.GL_TRUE;
        const was_scissor = context.IsEnabled.?(c.GL_SCISSOR_TEST) == c.GL_TRUE;
        const was_depth = context.IsEnabled.?(c.GL_DEPTH_TEST) == c.GL_TRUE;
        const was_cull = context.IsEnabled.?(c.GL_CULL_FACE) == c.GL_TRUE;
        defer {
            context.BindFramebuffer.?(c.GL_DRAW_FRAMEBUFFER, @intCast(previous_draw_framebuffer));
            context.BindFramebuffer.?(c.GL_READ_FRAMEBUFFER, @intCast(previous_read_framebuffer));
            context.Viewport.?(
                previous_viewport[0],
                previous_viewport[1],
                previous_viewport[2],
                previous_viewport[3],
            );
            context.UseProgram.?(@intCast(previous_program));
            context.BindVertexArray.?(@intCast(previous_vao));
            context.BindTexture.?(c.GL_TEXTURE_2D, @intCast(previous_texture0));
            context.BindSampler.?(0, @intCast(previous_sampler0));
            context.ActiveTexture.?(@intCast(previous_active_texture));
            if (was_srgb) context.Enable.?(c.GL_FRAMEBUFFER_SRGB) else context.Disable.?(c.GL_FRAMEBUFFER_SRGB);
            if (was_blending) context.Enable.?(c.GL_BLEND) else context.Disable.?(c.GL_BLEND);
            if (was_scissor) context.Enable.?(c.GL_SCISSOR_TEST) else context.Disable.?(c.GL_SCISSOR_TEST);
            if (was_depth) context.Enable.?(c.GL_DEPTH_TEST) else context.Disable.?(c.GL_DEPTH_TEST);
            if (was_cull) context.Enable.?(c.GL_CULL_FACE) else context.Disable.?(c.GL_CULL_FACE);
        }

        context.BindFramebuffer.?(
            c.GL_DRAW_FRAMEBUFFER,
            if (self.framebuffer) |framebuffer| framebuffer.id else 0,
        );
        context.ActiveTexture.?(c.GL_TEXTURE0);
        context.BindSampler.?(0, 0);
        context.BindTexture.?(c.GL_TEXTURE_2D, texture.id);
        context.Viewport.?(0, 0, @intCast(width), @intCast(height));
        context.Disable.?(c.GL_FRAMEBUFFER_SRGB);
        context.Disable.?(c.GL_BLEND);
        context.Disable.?(c.GL_SCISSOR_TEST);
        context.Disable.?(c.GL_DEPTH_TEST);
        context.Disable.?(c.GL_CULL_FACE);
        const program_binding = try self.program.use();
        defer program_binding.unbind();
        const vao_binding = try self.vao.bind();
        defer vao_binding.unbind();
        context.Uniform1i.?(0, 0);
        context.Uniform1i.?(1, @intFromBool(blending.isLinear()));
        context.Uniform1i.?(2, @intFromBool(is_composition));
        context.DrawArrays.?(c.GL_TRIANGLES, 0, 3);
        try gl.errors.getError();
    }
    if (self.composition) |handle| {
        const hr = ghostty_composition_present(handle);
        if (hr < 0) {
            log.err("DirectComposition present failed, HRESULT=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
            return error.CompositionPresentFailed;
        }
        locked = false;
    }
}
