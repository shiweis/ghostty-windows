//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const apprt = @import("../../apprt.zig");

const global = @import("../../global.zig");
const Renderer = @import("../generic.zig").Renderer(OpenGL);
const OpenGL = @import("../OpenGL.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.opengl);

/// Options for beginning a frame.
pub const Options = struct {};

renderer: *Renderer,
target: *Target,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Self {
    _ = opts;

    return .{
        .renderer = renderer,
        .target = target,
    };
}

/// Add a render pass to this frame with the provided attachments.
/// Returns a RenderPass which allows render steps to be added.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    _ = self;
    return RenderPass.begin(.{ .attachments = attachments });
}

/// Complete this frame and present the target.
///
/// If `sync` is true, this will block until the frame is presented.
///
/// NOTE: For OpenGL, `sync` is ignored and we never block, instead
/// pushing the newly presented and exported frame to the frame queue.
pub fn complete(self: *const Self, sync: bool) void {
    _ = sync;

    // If there are any GL errors, consider the frame unhealthy.
    var health: Health = if (gl.errors.getError()) .healthy else |_| .unhealthy;

    // Present healthy frames. EGL exports need GL completion before handoff;
    // WGL/D3D synchronization is provided by the shared-resource lock.
    const presented_frame: ?OpenGL.ExportedFrame = if (health == .healthy) frame: {
        const frame = self.renderer.api.present(
            self.target.*,
            self.renderer.presentationHealth(),
        ) catch |err| {
            log.warn("failed to present render target: err={}", .{err});
            health = .unhealthy;
            break :frame null;
        };
        break :frame frame;
    } else null;

    if (comptime apprt.runtime != apprt.win32) gl.finish();
    // At this point the ExportedFrame is finished and can be shared
    if (comptime OpenGL.ExportedFrame != void) if (presented_frame) |frame| {
        self.renderer.pushFrame(frame);

        // Notify the surface that it should redraw
        _ = self.renderer.surface_mailbox.push(.redraw, .instant);
    };

    // Report the health to the renderer.
    self.renderer.frameCompleted(health);
}
