const std = @import("std");
const builtin = @import("builtin");

const global = @import("../global.zig");
const ShellEscapeWriter = @import("shell.zig").ShellEscapeWriter;

const log = std.log.scoped(.os_edit);

const Options = struct {
    default_editor: enum {
        /// Return an error if $EDITOR or $VISUAL is not defined.
        failure,
        /// Default to "vi" if $EDITOR or $VISUAL is not defined.
        vi,
        /// Default to "nano" if $EDITOR or $VISUAL is not defined.
        nano,
    } = .vi,

    pub const default: Options = .{};
};

pub const Error = error{NoEditorConfigured};

pub fn getConfigEditCommand(alloc: std.mem.Allocator, path: []const u8, options: Options) (Error || std.Io.Writer.Error || std.mem.Allocator.Error)![:0]const u8 {
    const editor: []const u8 = editor: {
        // VISUAL vs. EDITOR: https://unix.stackexchange.com/questions/4859/visual-vs-editor-what-s-the-difference
        for ([_][]const u8{ "VISUAL", "EDITOR" }) |name| {
            const value = global.environ().getAlloc(alloc, name) catch continue;
            const editor_name = if (comptime builtin.os.tag == .windows)
                std.mem.trim(u8, value, " \t")
            else
                value;
            if (editor_name.len != 0) break :editor value;
            alloc.free(value);
        }

        switch (options.default_editor) {
            .failure => {
                log.warn("$EDITOR or $VISUAL must be set to open config in a new window", .{});
                return error.NoEditorConfigured;
            },
            .vi => {
                log.warn("$EDITOR or $VISUAL not set, falling back to vi", .{});
                break :editor try alloc.dupe(u8, "vi");
            },
            .nano => {
                log.warn("$EDITOR or $VISUAL not set, falling back to nano", .{});
                break :editor try alloc.dupe(u8, "nano");
            },
        }
    };
    defer alloc.free(editor);

    if (comptime builtin.os.tag == .windows) {
        // A Windows config file path cannot contain a double quote and ends
        // with a filename. Keep the user's editor arguments in their native
        // quoting syntax and pass the config path as one final argument.
        return alloc.printSentinel("{s} \"{s}\"", .{ std.mem.trim(u8, editor, " \t"), path }, 0);
    }

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();
    const writer = &buffer.writer;

    try writer.writeAll(editor);
    try writer.writeByte(' ');
    {
        var sh: ShellEscapeWriter = .init(writer);
        try sh.writer.writeAll(path);
        try sh.writer.flush();
    }
    try writer.flush();

    return try buffer.toOwnedSliceSentinel(0);
}
