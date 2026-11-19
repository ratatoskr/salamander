//! Who something belongs to, like a plugin or a script. Its tables stop calling into it once it closes.
//! Callers enter a table's owner before calling through it, so its code can't go mid-call.
//! The host keeps owners for good since objects may still point at them. Extern so any language can do the same.

const std = @import("std");

const rt = @import("root.zig");

pub const Owner = extern struct {
    /// Calls in flight, bit 31 set once closed. Only touched atomically, 32 bits so x86 has it natively.
    calls: u32 = 0,
    /// The host's copy.
    name: rt.String = .{},

    pub const closed_bit: u32 = 1 << 31;

    pub fn init(name: []const u8) Owner {
        return .{ .name = .init(name) };
    }

    /// False once it's closed. `leave` after each true.
    pub fn enter(o: *Owner) bool {
        const was = @atomicRmw(u32, &o.calls, .Add, 1, .acquire);
        if (was & closed_bit != 0) {
            _ = @atomicRmw(u32, &o.calls, .Sub, 1, .release);
            return false;
        }
        return true;
    }

    pub fn leave(o: *Owner) void {
        _ = @atomicRmw(u32, &o.calls, .Sub, 1, .release);
    }

    pub fn isOpen(o: *Owner) bool {
        return @atomicLoad(u32, &o.calls, .acquire) & closed_bit == 0;
    }

    /// No new calls from now. Fine from anywhere, even inside one of its own calls.
    pub fn close(o: *Owner) void {
        _ = @atomicRmw(u32, &o.calls, .Or, closed_bit, .acq_rel);
    }

    /// Closes it, then waits for calls in flight so its code can go.
    /// Never from inside one of the owner's calls, or it waits on itself.
    pub fn drain(o: *Owner) void {
        o.close();
        while (@atomicLoad(u32, &o.calls, .acquire) & ~closed_bit != 0) std.Thread.yield() catch {};
    }
};

test "close refuses new calls, even from inside one" {
    const testing = std.testing;
    var o: Owner = .init("test");
    try testing.expect(o.enter());
    o.close();
    try testing.expect(!o.isOpen());
    try testing.expect(!o.enter());
    o.leave();
    o.drain();
    try testing.expectEqual(Owner.closed_bit, o.calls);
    try testing.expectEqual(0, @offsetOf(Owner, "calls"));
}

test "drain waits for another thread's call" {
    const testing = std.testing;
    var o: Owner = .init("threads");
    const Worker = struct {
        var inside: std.atomic.Value(bool) = .init(false);
        var done: std.atomic.Value(bool) = .init(false);

        fn run(owner: *Owner) void {
            _ = owner.enter();
            inside.store(true, .release);
            // Stays in a while, so drain has something to wait for
            var i: usize = 0;
            while (i < 200) : (i += 1) std.Thread.yield() catch {};
            done.store(true, .release);
            owner.leave();
        }
    };
    const t = try std.Thread.spawn(.{}, Worker.run, .{&o});
    while (!Worker.inside.load(.acquire)) std.Thread.yield() catch {};
    o.drain();
    try testing.expect(Worker.done.load(.acquire));
    t.join();
}
