//! What salamander needs from the OS, behind a portable API. Only `win/`, `linux/` and `darwin/` call the OS.

const builtin = @import("builtin");

const native = switch (builtin.os.tag) {
    .windows => struct {
        pub const futex = @import("win/futex.zig");
    },
    .linux => struct {
        pub const futex = @import("linux/futex.zig");
    },
    .macos => struct {
        pub const futex = @import("darwin/futex.zig");
    },
    else => @compileError("salamander's sys is Windows, Linux and macOS"),
};

/// Waiting on an address. `wait(ptr, expect, timeout_ms)` while it holds `expect`, and `wake(ptr, all)`.
pub const futex = native.futex;

test {
    _ = native.futex;
}

test "futex waits till woken, or times out" {
    const std = @import("std");
    var word: std.atomic.Value(u32) = .init(0);
    // Not what it holds, so no wait
    futex.wait(&word, 1, null);
    futex.wait(&word, 0, 1);
    const Waker = struct {
        fn run(w: *std.atomic.Value(u32)) void {
            w.store(1, .release);
            futex.wake(w, true);
        }
    };
    const t = try std.Thread.spawn(.{}, Waker.run, .{&word});
    while (word.load(.acquire) == 0) futex.wait(&word, 0, 1000);
    t.join();
    try std.testing.expectEqual(1, word.load(.acquire));
}
