//! Work for one thread, `core.Queue`. Any thread posts, the owning thread runs it with `poll`.
//! Script hosts poll theirs so promises settled elsewhere resume on the script's thread.
//! It's the host's, so every binary posts to the same one.

const std = @import("std");

const rt = @import("root.zig");

/// A `fn() void`. Owner-guarded like any function value, so one whose owner closed does nothing.
pub const Task = rt.core.Task;

pub const Queue = extern struct {
    const Self = @This();

    data: usize = 0,
    table: ?*const anyopaque = null,

    pub const salamander = rt.core.Queue.salamander;

    pub fn raw(self: Self) rt.core.Queue {
        return .{ .data = self.data, .table = self.table };
    }

    /// Runs `function(ctx)` on the queue's thread, next time it's polled.
    pub fn post(self: Self, ctx: anytype, comptime function: fn (@TypeOf(ctx)) void) error{OutOfMemory}!void {
        return self.postTask(Task.init(ctx, function));
    }

    pub fn postTask(self: Self, task: Task) error{OutOfMemory}!void {
        if (!self.raw().post(task)) return error.OutOfMemory;
    }

    /// Runs what was posted before it started, oldest first. Only from the queue's own thread.
    pub fn poll(self: Self) u32 {
        return self.raw().poll();
    }
};

/// Where a callback runs.
pub const Where = union(enum) {
    /// On whichever thread gets there.
    now,
    on: Queue,

    pub fn queue(self: Where) rt.core.Queue {
        return switch (self) {
            .now => .{},
            .on => |q| q.raw(),
        };
    }
};

/// The host's queue. Posting pushes onto a list, polling takes the whole list at once.
pub const Local = struct {
    head: std.atomic.Value(?*Node) = .init(null),

    const Node = struct {
        next: ?*Node,
        task: Task,
    };

    pub fn post(q: *Local, task: Task) bool {
        const node = std.heap.smp_allocator.create(Node) catch return false;
        node.task = task;
        var head = q.head.load(.monotonic);
        while (true) {
            node.next = head;
            head = q.head.cmpxchgWeak(head, node, .release, .monotonic) orelse return true;
        }
    }

    pub fn poll(q: *Local) u32 {
        // Newest first, so turn it round
        var list = q.head.swap(null, .acquire);
        var oldest: ?*Node = null;
        while (list) |n| {
            list = n.next;
            n.next = oldest;
            oldest = n;
        }
        var count: u32 = 0;
        while (oldest) |n| {
            oldest = n.next;
            const task = n.task;
            std.heap.smp_allocator.destroy(n);
            task.invoke(.{});
            count += 1;
        }
        return count;
    }
};

const testing = std.testing;

test "runs in order on poll, and only what was there" {
    const q = try rt.host().queue();
    const Log = struct {
        var buf: [8]u8 = undefined;
        var len: usize = 0;
        var queue: Queue = undefined;

        fn a(_: *const u8) void {
            buf[len] = 'a';
            len += 1;
            // Posted while polling, so it waits for the next poll
            queue.post(@as(*const u8, &buf[0]), c) catch {};
        }
        fn b(_: *const u8) void {
            buf[len] = 'b';
            len += 1;
        }
        fn c(_: *const u8) void {
            buf[len] = 'c';
            len += 1;
        }
    };
    Log.queue = q;
    const x: u8 = 0;
    try q.post(&x, Log.a);
    try q.post(&x, Log.b);
    try testing.expectEqual(0, Log.len);
    try testing.expectEqual(2, q.poll());
    try testing.expectEqualStrings("ab", Log.buf[0..Log.len]);
    try testing.expectEqual(1, q.poll());
    try testing.expectEqualStrings("abc", Log.buf[0..Log.len]);
    try testing.expectEqual(0, q.poll());
}

test "posted from other threads" {
    const q = try rt.host().queue();
    const Count = struct {
        var n: std.atomic.Value(u32) = .init(0);
        fn hit(_: *const u8) void {
            _ = n.fetchAdd(1, .monotonic);
        }
        fn run(queue: Queue) void {
            const x: u8 = 0;
            for (0..100) |_| queue.post(&x, hit) catch {};
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Count.run, .{q});
    for (threads) |t| t.join();
    try testing.expectEqual(400, q.poll());
    try testing.expectEqual(400, Count.n.load(.monotonic));
}

test "a closed owner's tasks do nothing" {
    const h = rt.host();
    const q = try h.queue();
    const o = try h.owner("script");
    var hits: u32 = 0;
    try q.postTask(try Task.owned(o, &hits, struct {
        fn f(n: *u32) void {
            n.* += 1;
        }
    }.f));
    o.close();
    try testing.expectEqual(1, q.poll());
    try testing.expectEqual(0, hits);
}
