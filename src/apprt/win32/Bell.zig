//! Bell playback and visual state for a single native terminal pane.
const Bell = @This();
const std = @import("std");
const Config = @import("../../config.zig").Config;
const w32 = @import("win32.zig");
const log = std.log.scoped(.win32_bell);

extern "c" fn ghostty_bell_open(path: [*:0]const u16, owner: *const Bell, device: *u32) u32;
extern "c" fn ghostty_bell_play(device: u32, volume: u32) u32;
extern "c" fn ghostty_bell_close(device: u32) void;

device: ?u32 = null,
ringing: bool = false,
title_visible: bool = false,
/// Read by the WGL thread, in physical pixels.
border_width: std.atomic.Value(u32) = .init(0),

pub const Settings = struct {
    features: Config.BellFeatures,
    path: ?[:0]const u16,
    path_optional: bool,
    volume: u32,
    finish_mode: Config.NotifyOnCommandFinish,
    finish_action: Config.NotifyOnCommandFinishAction,
    finish_after: Config.Duration,

    pub fn init(alloc: std.mem.Allocator, cfg: *const Config) !Settings {
        const features = cfg.@"bell-features";
        const path = if (features.audio) cfg.@"bell-audio-path" else null;
        const volume = cfg.@"bell-audio-volume";
        return .{
            .features = features,
            .path = if (path) |p| switch (p) {
                inline else => |value| std.unicode.wtf8ToWtf16LeAllocZ(alloc, value) catch |err| switch (err) {
                    error.InvalidWtf8 => invalid: {
                        if (p == .required) log.warn("invalid bell audio path encoding", .{});
                        break :invalid null;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                },
            } else null,
            .path_optional = if (path) |p| p == .optional else false,
            .volume = if (std.math.isFinite(volume)) @intFromFloat(@round(1000 * std.math.clamp(volume, 0, 1))) else 0,
            .finish_mode = cfg.@"notify-on-command-finish",
            .finish_action = cfg.@"notify-on-command-finish-action",
            .finish_after = cfg.@"notify-on-command-finish-after",
        };
    }
};

pub fn closeAudio(self: *Bell) void {
    const device = self.device orelse return;
    self.device = null;
    ghostty_bell_close(device);
}

pub fn playAudio(self: *Bell, settings: Settings) void {
    const path = settings.path orelse return;
    if (self.device == null) {
        var device: u32 = undefined;
        const err = ghostty_bell_open(path.ptr, self, &device);
        if (err != 0) {
            if (!settings.path_optional) log.warn("could not open bell audio, MCI error={d}", .{err});
            return;
        }
        self.device = device;
    }
    const err = ghostty_bell_play(self.device.?, settings.volume);
    if (err != 0) {
        log.warn("could not play bell audio, MCI error={d}", .{err});
        self.closeAudio();
    }
}

pub fn ring(self: *Bell, settings: Settings) void {
    if (settings.features.system) _ = w32.MessageBeep(0); // MB_OK, the configured Windows default sound.
    if (settings.features.audio) self.playAudio(settings);
}

test "native bell custom audio plays a silent Unicode WAV at configured volume" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // PCM mono, 8000 Hz, 16 bit, 32 zero samples. No audible output even
    // when the test exercises a nonzero playback volume.
    const name = "通知 bell.wav";
    const samples: [64]u8 = @splat(0);
    const wav = "RIFF" ++ "\x64\x00\x00\x00" ++ "WAVEfmt " ++
        "\x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x80\x3e\x00\x00\x02\x00\x10\x00" ++
        "data" ++ "\x40\x00\x00\x00" ++ samples;
    try tmp.dir.writeFile(t.io, .{ .sub_path = name, .data = wav });
    const path = try tmp.dir.realPathFileAlloc(t.io, name, alloc);
    var cfg = try Config.default(t.allocator);
    defer cfg.deinit();
    cfg.@"bell-audio-path" = .{ .required = try alloc.dupeSentinel(u8, path, 0) };
    cfg.@"bell-audio-volume" = 0.625;
    cfg.@"bell-features" = .{ .audio = true, .title = false, .attention = false };
    var settings = try Settings.init(alloc, &cfg);
    try t.expectEqual(@as(u32, 625), settings.volume);
    var bell: Bell = .{};
    defer bell.closeAudio();
    const Com = struct {
        extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) i32;
        extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    };
    const hr = Com.CoInitializeEx(null, 2);
    defer if (hr >= 0) Com.CoUninitialize();
    bell.ring(settings);
    const device = bell.device orelse return error.AudioDidNotOpen;
    settings.volume = 0;
    var peer: Bell = .{};
    defer peer.closeAudio();
    peer.ring(settings);
    try t.expect(peer.device != null and peer.device.? != device);
    bell.ring(settings);
    try t.expectEqual(@as(?u32, device), bell.device);
    bell.closeAudio();
    settings.features.audio = false;
    bell.ring(settings);
    try t.expect(bell.device == null);
    cfg.@"bell-audio-volume" = 2;
    try t.expectEqual(@as(u32, 1000), (try Settings.init(alloc, &cfg)).volume);
}
