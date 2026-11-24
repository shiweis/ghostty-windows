const std = @import("std");
const t = std.testing;
const apprt = @import("../../apprt.zig");
const global = @import("../../global.zig");
const termio = @import("../../termio.zig");
const terminal = @import("../../terminal/main.zig");
const CoreApp = @import("../../App.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const Clipboard = @import("Clipboard.zig");

const Pane = struct {
    surface: Surface,
    mutex: std.Io.Mutex = .init,

    fn init(self: *Pane, app: *App, window: *Window, id: u64) !void {
        self.* = .{ .surface = .{ .app = app, .parent_window = window, .core_surface_ready = true } };
        const cs = &self.surface.core_surface;
        cs.id = id;
        cs.alloc = t.allocator;
        cs.app = app.core_app;
        cs.rt_app = app;
        cs.rt_surface = &self.surface;
        cs.inspector = null;
        cs.readonly = false;
        cs.mouse = .{};
        cs.config = try .init(t.allocator, &.{});
        errdefer cs.config.deinit();
        cs.io.terminal = try .init(global.io(), t.allocator, .{ .cols = 24, .rows = 2 });
        errdefer cs.io.terminal.deinit(t.allocator);
        cs.renderer_state = .{ .mutex = &self.mutex, .terminal = &cs.io.terminal };
        cs.io.renderer_state = &cs.renderer_state;
        cs.io.terminal_stream.handler.kitty_clipboard_grants = .{};
        cs.renderer_thread.wakeup = try global.xev.Async.init();
        errdefer cs.renderer_thread.wakeup.deinit();
        cs.io.mailbox = try termio.Mailbox.initSPSC(t.allocator);
        errdefer cs.io.mailbox.deinit(t.allocator);
        try app.core_app.surfaces.append(t.allocator, &self.surface);
    }

    fn deinit(self: *Pane) void {
        const cs = &self.surface.core_surface;
        while (cs.io.mailbox.spsc.queue.pop(global.io())) |msg| msg.deinit();
        cs.io.mailbox.deinit(t.allocator);
        cs.renderer_thread.wakeup.deinit();
        cs.io.terminal_stream.handler.kitty_clipboard_grants.deinit(t.allocator);
        cs.io.terminal.deinit(t.allocator);
        cs.config.deinit();
    }

    fn output(self: *Pane, arena: std.mem.Allocator) ![]const u8 {
        var bytes: std.Io.Writer.Allocating = .init(arena);
        while (self.surface.core_surface.io.mailbox.spsc.queue.pop(global.io())) |msg| {
            defer msg.deinit();
            try bytes.writer.writeAll(switch (msg) {
                .write_small => |v| v.data[0..v.len],
                .write_alloc => |v| v.data,
                .write_stable => |v| v,
                else => return error.UnexpectedInputMessage,
            });
        }
        return bytes.written();
    }
};

fn kittyRead(surface: *Surface) !void {
    var pool: std.heap.ArenaAllocator = .init(t.allocator);
    const req = try pool.allocator().create(apprt.ClipboardRequest.KittyRead);
    req.* = .{
        .arena = pool,
        .location = .primary,
        .mimes = &.{ "UTF8_STRING", "application/octet-stream" },
        .list = true,
        .id = "read",
        .pw = "private",
        .name = "test",
        .granted = true,
        .terminator = .st,
    };
    try surface.core_surface.handleMessage(.{ .kitty_clipboard_read = req });
}

fn kittyWrite(surface: *Surface) !void {
    var pool: std.heap.ArenaAllocator = .init(t.allocator);
    const req = try pool.allocator().create(apprt.ClipboardRequest.KittyWrite);
    req.* = .{
        .arena = pool,
        .location = .primary,
        .contents = &.{
            .{ .mime = "text/plain", .data = "rich" },
            .{ .mime = "application/octet-stream", .data = "\x09\x00\x00" },
        },
        .id = "write",
        .pw = "private",
        .name = "test",
        .granted = true,
        .terminator = .st,
    };
    try surface.core_surface.handleMessage(.{ .kitty_clipboard_write = req });
}

test "Windows clipboard selection snapshots survive replacement and failed writes" {
    var selection: Clipboard.Selection = .{};
    defer selection.deinit();
    try selection.write(t.allocator, &.{
        .{ .mime = "text/plain", .data = "first\r\nline" },
        .{ .mime = "UTF8_STRING", .data = "first\r\nline" },
        .{ .mime = "application/octet-stream", .data = "\x00\xff\x00" },
    });
    var pool: std.heap.ArenaAllocator = .init(t.allocator);
    defer pool.deinit();
    const arena = pool.allocator();
    const paste = try selection.read(arena, .{ .paste = .selection });
    const listing = try selection.read(arena, .{ .list = .selection });
    try t.expectEqual(@as(usize, 2), listing.available.items.len);
    try t.expect(listing.contents.items.len == 0);
    var req: apprt.ClipboardRequest.KittyRead = undefined;
    req.mimes = &.{"application/octet-stream"};
    const binary = try selection.read(arena, .{ .kitty_read = &req });
    var storage: [1]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&storage);
    const replacement: []const apprt.ClipboardContent = &.{.{ .mime = "text/plain", .data = "new" }};
    try t.expectError(error.OutOfMemory, selection.write(fixed.allocator(), replacement));
    try t.expectEqualStrings("first\r\nline", selection.contents[0].data);
    try t.expectError(error.UnsupportedClipboardFormat, selection.write(t.allocator, &.{.{ .mime = "bad name", .data = "new" }}));
    try t.expectError(error.UnsupportedClipboardFormat, selection.write(t.allocator, &.{
        .{ .mime = "text/plain", .data = "one" }, .{ .mime = "TEXT", .data = "two" },
    }));
    try selection.write(t.allocator, replacement);
    try t.expectEqualStrings("new", selection.contents[0].data);
    try t.expectEqualStrings("first\nline", paste.contents.items[0].data);
    try t.expectEqualStrings("application/octet-stream", listing.available.items[1]);
    try t.expectEqualSlices(u8, "\x00\xff\x00", binary.contents.items[0].data);
}

test "Windows clipboard private station selection copying, cross-window paste and explicit OSC locations" {
    if (!Clipboard.privateTestStation()) return error.SkipZigTest;
    var pool: std.heap.ArenaAllocator = .init(t.allocator);
    defer pool.deinit();
    const arena = pool.allocator();
    var core: CoreApp = undefined;
    core.alloc = t.allocator;
    core.surfaces = .empty;
    defer core.surfaces.deinit(t.allocator);
    var app: App = undefined;
    app.core_app = &core;
    app.selection_clipboard = .{};
    defer app.selection_clipboard.deinit();
    const windows = try arena.alloc(Window, 2);
    const panes = try arena.alloc(Pane, 2);
    try panes[0].init(&app, &windows[0], 1);
    defer panes[0].deinit();
    try panes[1].init(&app, &windows[1], 2);
    defer panes[1].deinit();
    const sender = &panes[0].surface.core_surface;
    const reader = &panes[1].surface.core_surface;
    try panes[0].surface.setClipboard(.standard, &.{.{ .mime = "text/plain", .data = "system" }}, false);
    try t.expect(!try reader.performBindingAction(.paste_from_selection));
    try sender.io.terminal.printString("first");
    try t.expectEqual(.none, sender.config.copy_on_select);
    try t.expect(try sender.performBindingAction(.select_all));
    try t.expect(!try reader.performBindingAction(.paste_from_selection));
    sender.config.copy_on_select = .primary;
    try t.expect(try sender.performBindingAction(.select_all));
    try t.expect(try reader.performBindingAction(.paste_from_selection));
    try t.expectEqualStrings("first", try panes[1].output(arena));
    try t.expectEqual(.@"primary-paste", reader.config.middle_click_action);
    _ = try reader.mouseButtonCallback(.press, .middle, .{});
    try t.expectEqualStrings("first", try panes[1].output(arena));
    reader.config.clipboard_read = .allow;
    try reader.handleMessage(.{ .clipboard_read = .selection });
    try t.expectEqualStrings("\x1b]52;s;Zmlyc3Q=\x1b\\", try panes[1].output(arena));
    try reader.handleMessage(.{ .clipboard_read = .primary });
    try t.expectEqualStrings("\x1b]52;p;Zmlyc3Q=\x1b\\", try panes[1].output(arena));
    reader.config.clipboard_read = .deny;
    try reader.handleMessage(.{ .clipboard_read = .primary });
    try t.expectEqualStrings("", try panes[1].output(arena));
    reader.io.terminal.modes.set(.kitty_paste_events, true);
    try t.expect(try reader.performBindingAction(.paste_from_selection));
    const event = try panes[1].output(arena);
    try t.expect(std.mem.indexOf(u8, event, ":loc=primary:pw=") != null);
    var encoded: [64]u8 = undefined;
    const targets = std.base64.standard.Encoder.encode(&encoded, "text/plain text/html\n");
    try t.expect(std.mem.indexOf(u8, event, targets) != null);
    reader.io.terminal.modes.set(.kitty_paste_events, false);
    try t.expect(try reader.performBindingAction(.paste_from_clipboard));
    try t.expectEqualStrings("system", try panes[1].output(arena));

    sender.config.copy_on_select = .both;
    try sender.io.terminal.printString(" and second");
    try t.expect(try sender.performBindingAction(.select_all));
    for ([_]@import("../../input.zig").Binding.Action{ .paste_from_selection, .paste_from_clipboard }) |action| {
        try t.expect(try reader.performBindingAction(action));
        try t.expectEqualStrings("first and second", try panes[1].output(arena));
    }
    sender.config.clipboard_write = .deny;
    const osc_write: @import("../../Surface.zig").Message = .{ .clipboard_write = .{
        .clipboard_type = .primary,
        .req = .{ .stable = "cHJpdmF0ZQ==" },
    } };
    try sender.handleMessage(osc_write);
    try t.expect(try reader.performBindingAction(.paste_from_selection));
    try t.expectEqualStrings("first and second", try panes[1].output(arena));
    sender.config.clipboard_write = .allow;
    try sender.handleMessage(osc_write);
    try t.expect(try reader.performBindingAction(.paste_from_selection));
    try t.expectEqualStrings("private", try panes[1].output(arena));
    sender.config.clipboard_write = .deny;
    try kittyWrite(&panes[0].surface);
    try t.expect(std.mem.indexOf(u8, try panes[0].output(arena), "status=EPERM") != null);
    try t.expect(try reader.performBindingAction(.paste_from_selection));
    try t.expectEqualStrings("private", try panes[1].output(arena));
    sender.config.clipboard_write = .ask;
    try kittyWrite(&panes[0].surface);
    try t.expect(std.mem.indexOf(u8, try panes[0].output(arena), "status=DONE") != null);
    try kittyRead(&panes[1].surface);
    try t.expect(std.mem.indexOf(u8, try panes[1].output(arena), "status=EPERM") != null);
    reader.config.clipboard_read = .ask;
    try kittyRead(&panes[1].surface);
    const response = try panes[1].output(arena);
    try t.expect(std.mem.indexOf(u8, response, "status=OK:loc=primary") != null);
    try t.expect(std.mem.indexOf(u8, response, ";CQAA\x1b\\") != null);
    try t.expect(std.mem.indexOf(u8, response, ";cmljaA==\x1b\\") != null);
    try t.expect(try reader.performBindingAction(.paste_from_clipboard));
    try t.expectEqualStrings("first and second", try panes[1].output(arena));
}
