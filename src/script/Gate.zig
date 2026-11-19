//! A script's lock. One thread at a time, and it can come back in from inside.

const std = @import("std");
const rt = @import("salamander_runtime");
const futex = @import("salamander_sys").futex;

const Gate = @This();

/// 0 free, 1 held, 2 held with someone waiting.
state: std.atomic.Value(u32) = .init(0),
/// Or 0. Only that thread reads it as itself.
holder: std.atomic.Value(std.Thread.Id) = .init(0),
depth: u32 = 0,

pub const How = enum {
    block,
    /// For threads that must never stall.
    try_,
};

/// By this thread.
pub fn held(g: *const Gate) bool {
    return g.holder.load(.monotonic) == std.Thread.getCurrentId();
}

/// Gives up once `unless` closes, so draining it never waits on a call that's only waiting to get in.
pub fn enter(g: *Gate, how: How, unless: ?*rt.Owner) bool {
    const me = std.Thread.getCurrentId();
    if (g.holder.load(.monotonic) == me) {
        g.depth += 1;
        return true;
    }
    if (g.state.cmpxchgStrong(0, 1, .acquire, .monotonic)) |seen| {
        if (how == .try_) return false;
        var c = seen;
        if (c != 2) c = g.state.swap(2, .acquire);
        while (c != 0) {
            if (unless) |o| if (!o.isOpen()) {
                // Others might still be waiting, so pass the wake on
                futex.wake(&g.state, false);
                return false;
            };
            // Timed, so a closing owner's noticed
            futex.wait(&g.state, 2, if (unless != null) 5 else null);
            c = g.state.swap(2, .acquire);
        }
    }
    g.holder.store(me, .monotonic);
    g.depth = 1;
    return true;
}

pub fn leave(g: *Gate) void {
    std.debug.assert(g.held());
    g.depth -= 1;
    if (g.depth > 0) return;
    g.holder.store(0, .monotonic);
    if (g.state.swap(0, .release) == 2) futex.wake(&g.state, false);
}

const testing = std.testing;

test "one thread at a time, and the holder comes back in" {
    var g: Gate = .{};
    try testing.expect(g.enter(.block, null));
    try testing.expect(g.enter(.try_, null));
    try testing.expectEqual(2, g.depth);

    const Other = struct {
        fn tryIt(gate: *Gate, got: *bool) void {
            got.* = gate.enter(.try_, null);
        }
        fn blockIt(gate: *Gate, done: *std.atomic.Value(bool)) void {
            _ = gate.enter(.block, null);
            done.store(true, .release);
            gate.leave();
        }
    };
    var got = true;
    (try std.Thread.spawn(.{}, Other.tryIt, .{ &g, &got })).join();
    try testing.expect(!got);

    var done: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, Other.blockIt, .{ &g, &done });
    g.leave();
    try testing.expect(!done.load(.acquire));
    g.leave();
    t.join();
    try testing.expect(done.load(.acquire));
    try testing.expect(!g.held());
}

test "a waiter gives up once its owner closes" {
    var g: Gate = .{};
    var o: rt.Owner = .init("waiter");
    try testing.expect(g.enter(.block, null));
    const Other = struct {
        fn wait(gate: *Gate, owner: *rt.Owner, got: *std.atomic.Value(u32)) void {
            got.store(if (gate.enter(.block, owner)) 1 else 2, .release);
        }
    };
    var got: std.atomic.Value(u32) = .init(0);
    const t = try std.Thread.spawn(.{}, Other.wait, .{ &g, &o, &got });
    // Closing lets it go while this thread's still in
    o.close();
    t.join();
    try testing.expectEqual(2, got.load(.acquire));
    g.leave();
}
