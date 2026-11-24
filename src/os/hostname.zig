const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const LocalHostnameValidationError = error{
    PermissionDenied,
    Unexpected,
};

/// Checks if a hostname is local to the current machine. This matches
/// both "localhost" and the current hostname of the machine (as returned
/// by `gethostname`).
pub fn isLocal(hostname: []const u8) LocalHostnameValidationError!bool {
    // A 'localhost' hostname is always considered local.
    if (std.mem.eql(u8, "localhost", hostname)) return true;

    // If hostname is not "localhost" it must match our hostname.
    switch (builtin.target.os.tag) {
        .windows => {
            const windows = @import("windows.zig");
            if (std.ascii.eqlIgnoreCase("localhost", hostname)) return true;
            // GetHostName (used by PowerShell) can return a DNS name longer
            // than the legacy NetBIOS name. Compare local aliases directly,
            // without doing DNS resolution on terminal-provided hostnames.
            inline for (.{ .dns_hostname, .dns_fully_qualified, .netbios }) |kind| {
                var wide: [256:0]u16 = undefined;
                var size: windows.DWORD = wide.len;
                if (windows.exp.kernel32.GetComputerNameExW(kind, &wide, &size) != windows.FALSE) {
                    var utf8: [3 * wide.len]u8 = undefined;
                    const len = std.unicode.utf16LeToUtf8(&utf8, wide[0..size]) catch return error.Unexpected;
                    if (std.ascii.eqlIgnoreCase(hostname, utf8[0..len])) return true;
                }
            }
            return false;
        },
        else => {
            var buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const ourHostname = try posix.gethostname(&buf);
            return std.mem.eql(u8, hostname, ourHostname);
        },
    }
}

test "isLocal returns true when provided hostname is localhost" {
    try std.testing.expect(try isLocal("localhost"));
}

test "isLocal returns true when hostname is local" {
    switch (builtin.target.os.tag) {
        .windows => {
            const windows = @import("windows.zig");
            var buf: [256:0]u8 = undefined;
            var nSize: windows.DWORD = buf.len;
            if (windows.exp.kernel32.GetComputerNameA(&buf, &nSize) == windows.FALSE)
                return error.GetComputerNameFailed;
            const localHostname = buf[0..nSize];
            try std.testing.expect(try isLocal(localHostname));
        },
        else => {
            var buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const localHostname = try posix.gethostname(&buf);
            try std.testing.expect(try isLocal(localHostname));
        },
    }
}

test "isLocal returns false when hostname is not local" {
    try std.testing.expectEqual(
        false,
        try isLocal("not-the-local-hostname"),
    );
}
