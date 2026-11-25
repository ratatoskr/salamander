//! What salamander needs from the OS, behind a portable API. Only `win/`, `linux/`, `darwin/` and
//! `posix/` call the OS. `posix/` needs libc, so only what uses `library` or `env` links it.

const builtin = @import("builtin");

const native = switch (builtin.os.tag) {
    .windows => struct {
        pub const futex = @import("win/futex.zig");
        pub const library = @import("win/library.zig");
        pub const env = @import("win/env.zig");
        pub const registry = @import("win/registry.zig");
    },
    .linux => struct {
        pub const futex = @import("linux/futex.zig");
        pub const library = @import("posix/library.zig");
        pub const env = @import("posix/env.zig");
    },
    .macos => struct {
        pub const futex = @import("darwin/futex.zig");
        pub const library = @import("posix/library.zig");
        pub const env = @import("posix/env.zig");
    },
    else => @compileError("salamander's sys is Windows, Linux and macOS"),
};

/// Waiting on an address. `wait(ptr, expect, timeout_ms)` while it holds `expect`, and `wake(ptr, all)`.
pub const futex = native.futex;

/// Shared libraries. `find(name)` one already loaded, `load(path)`, and `symbol(lib, name)`.
pub const library = native.library;

/// `get(allocator, name)` an environment variable, as UTF-8.
pub const env = native.env;

/// Windows only. `string(allocator, root, key, value, view)` reads a string value.
pub const registry = if (builtin.os.tag == .windows) native.registry else struct {};

test {
    _ = native.futex;
    if (builtin.os.tag == .windows) _ = native.registry;
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
