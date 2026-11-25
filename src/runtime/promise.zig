//! `async` results. A promise is a `Promise` trait object, and whoever does the work holds its `Resolver`.
//! Both point at one future the host keeps till both let go. Waiters run on the settling thread, or
//! where the resolver says they carry on.

const std = @import("std");

const rt = @import("root.zig");

const Task = rt.Task;
const Queue = rt.core.Queue;

/// Memory a value points at, kept with its future.
const Held = struct {
    next: ?*Held,
    bytes: []align(16) u8,

    fn freeAll(first: ?*Held) void {
        var at = first;
        while (at) |h| {
            at = h.next;
            std.heap.smp_allocator.free(h.bytes);
            std.heap.smp_allocator.destroy(h);
        }
    }
};

/// What the last value this thread took points at, kept till it takes another. Per thread in the
/// host's binary, since futures are the host's.
threadlocal var taken: ?*Held = null;

/// What a value's bytes sit after, so one table works for every type.
const Future = extern struct {
    /// The promise's and the resolver's.
    refs: std.atomic.Value(u32) = .init(2),
    bits: std.atomic.Value(u32) = .init(0),
    /// 0 for a value, or an error code.
    code: u32 = 0,
    size: u32,
    waiter: Task = .{},
    /// Where the waiter runs. No table is `carry_on`.
    where: Queue = .{},
    /// The resolver's say for waiters with no `where`. No table is on the settling thread.
    carry_on: Queue = .{},
    /// What the value points at. Only the resolver adds, before settling, and only `take` moves it.
    held: ?*Held = null,

    const settled_bit: u32 = 1;
    const waiter_bit: u32 = 2;
    const cancelled_bit: u32 = 4;
    /// Where the value goes, aligned for anything.
    const value_offset = std.mem.alignForward(usize, @sizeOf(Future), 16);

    fn create(size: usize) error{OutOfMemory}!*Future {
        const bytes = try std.heap.smp_allocator.alignedAlloc(u8, .@"16", value_offset + size);
        const f: *Future = @ptrCast(bytes.ptr);
        f.* = .{ .size = @intCast(size) };
        return f;
    }

    fn value(f: *Future) [*]u8 {
        const base: [*]u8 = @ptrCast(f);
        return base + value_offset;
    }

    fn unref(f: *Future) void {
        if (f.refs.fetchSub(1, .acq_rel) != 1) return;
        Held.freeAll(f.held);
        const base: [*]align(16) u8 = @ptrCast(@alignCast(f));
        std.heap.smp_allocator.free(base[0 .. value_offset + f.size]);
    }

    fn settle(f: *Future, code: u32, from: ?*const anyopaque) void {
        if (f.bits.load(.acquire) & settled_bit != 0) return;
        f.code = code;
        if (from) |v| @memcpy(f.value()[0..f.size], @as([*]const u8, @ptrCast(v))[0..f.size]);
        const was = f.bits.fetchOr(settled_bit, .acq_rel);
        if (was & waiter_bit != 0 and was & cancelled_bit == 0) run(f.waiter, f.target());
    }

    fn target(f: *const Future) Queue {
        return if (f.where.table != null) f.where else f.carry_on;
    }

    fn run(task: Task, where: Queue) void {
        if (where.table != null) {
            // Posting only fails out of memory, and running it here beats never
            if (!where.post(task)) task.invoke(.{});
        } else task.invoke(.{});
    }

    // The `Promise` trait, held by whoever waits

    pub fn isSettled(f: *Future) bool {
        return f.bits.load(.acquire) & settled_bit != 0;
    }

    /// The code, with the value copied to `out` if it's 0. Only once settled. What the value points
    /// at moves to this thread, good till it takes another.
    pub fn take(f: *Future, out: ?*anyopaque) u32 {
        if (f.code == 0) if (out) |o| {
            @memcpy(@as([*]u8, @ptrCast(o))[0..f.size], f.value()[0..f.size]);
            if (f.held != null) {
                Held.freeAll(taken);
                taken = f.held;
                f.held = null;
            }
        };
        return f.code;
    }

    /// Runs once it's settled, on `where`'s thread or the settling one. Only one waiter.
    pub fn then(f: *Future, task: Task, where: Queue) void {
        f.waiter = task;
        f.where = where;
        const was = f.bits.fetchOr(waiter_bit, .acq_rel);
        if (was & settled_bit != 0) run(task, f.target());
    }

    /// Lets go and tells the resolver. A waiter already running isn't waited for.
    pub fn cancel(f: *Future) void {
        _ = f.bits.fetchOr(cancelled_bit, .acq_rel);
        f.unref();
    }

    pub fn release(f: *Future) void {
        f.unref();
    }

    // The `Resolver` trait, held by whoever does the work

    pub fn hold(f: *Future, size: usize, alignment: usize) ?*anyopaque {
        if (alignment > 16 or f.isSettled()) return null;
        const h = std.heap.smp_allocator.create(Held) catch return null;
        const bytes = std.heap.smp_allocator.alignedAlloc(u8, .@"16", @max(size, 1)) catch {
            std.heap.smp_allocator.destroy(h);
            return null;
        };
        h.* = .{ .next = f.held, .bytes = bytes };
        f.held = h;
        return bytes.ptr;
    }

    pub fn resolve(f: *Future, v: ?*anyopaque) void {
        f.settle(0, v);
        f.unref();
    }

    pub fn reject(f: *Future, code: u32) void {
        f.settle(if (code == 0) rt.unsupported_code else code, null);
        f.unref();
    }

    pub fn cancelled(f: *Future) bool {
        return f.bits.load(.acquire) & cancelled_bit != 0;
    }

    /// Before settling. Seen by waiters once they see it's settled.
    pub fn carryOn(f: *Future, where: Queue) void {
        f.carry_on = where;
    }

    /// Dropped without settling, so whoever waits gets `Gone`.
    pub fn drop(f: *Future) void {
        f.settle(rt.gone_code, null);
        f.unref();
    }
};

pub const PromiseTrait = rt.core.Promise;
pub const ResolverTrait = rt.core.Resolver;

const promise_table = rt.implement(PromiseTrait, Future);
const resolver_table = rt.implement(ResolverTrait, Future);

/// Memory kept with `resolver`'s value, for what it points at. Frees nothing early.
pub fn holding(resolver: *const rt.core.Resolver) std.mem.Allocator {
    return .{ .ptr = @constCast(resolver), .vtable = &hold_vtable };
}

const hold_vtable: std.mem.Allocator.VTable = .{
    .alloc = holdAlloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = std.mem.Allocator.noFree,
};

fn holdAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const r: *const rt.core.Resolver = @ptrCast(@alignCast(ctx));
    return @ptrCast(r.hold(len, alignment.toByteUnits()));
}

/// The host's side: a future for a value `size` bytes big. No table out of memory.
pub fn makeFuture(size: usize, resolver: *rt.core.Resolver) rt.core.Promise {
    const f = Future.create(size) catch return .{};
    resolver.* = .{ .data = @intFromPtr(f), .table = resolver_table };
    return .{ .data = @intFromPtr(f), .table = promise_table };
}

/// A result's own errors and the built-in ones, or the value and the built-in ones.
pub fn Awaited(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |eu| (eu.error_set || rt.Failure)!eu.payload,
        else => rt.Failure!T,
    };
}

fn Payload(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |eu| eu.payload,
        else => T,
    };
}

/// An `async` method's result. `Errors` is the error set's enum when `T` is a result.
pub fn Promise(comptime T: type, comptime Errors: ?type) type {
    return extern struct {
        const Self = @This();
        const V = Payload(T);
        const Wire = if (V == void) u8 else rt.Abi(V);

        data: usize = 0,
        table: ?*const anyopaque = null,

        pub const salamander = PromiseTrait.salamander;
        pub const Value = T;

        /// A pending promise and what settles it.
        pub fn make() error{OutOfMemory}!struct { promise: Self, resolver: Resolver(T, Errors) } {
            const p, const r = try rt.host().promise(@sizeOf(Wire));
            return .{
                .promise = .{ .data = p.data, .table = p.table },
                .resolver = .{ .data = r.data, .table = r.table },
            };
        }

        /// Already settled, for work that's done straight away.
        pub fn settled(result: T) error{OutOfMemory}!Self {
            const pair = try make();
            pair.resolver.settle(result);
            return pair.promise;
        }

        fn obj(self: Self) rt.Object(PromiseTrait) {
            return .{ .data = self.data, .table = self.table };
        }

        pub fn isSettled(self: Self) bool {
            return self.obj().isSettled();
        }

        /// Null while pending. Otherwise the result, and the promise is let go.
        pub fn take(self: Self) ?Awaited(T) {
            if (self.table == null) return error.Gone;
            if (!self.isSettled()) return null;
            var out: Wire = undefined;
            const code = self.obj().take(&out);
            self.obj().release();
            if (code != 0) return rt.liftError(@typeInfo(Awaited(T)).error_union.error_set, Errors, code);
            return if (V == void) {} else rt.lift(V, out);
        }

        /// Blocks this thread until it's settled. Fine for workers, never for a script's thread.
        pub fn wait(self: Self) Awaited(T) {
            if (self.table == null) return error.Gone;
            while (!self.isSettled()) std.Thread.yield() catch {};
            return self.take().?;
        }

        /// Calls `function(ctx)` once it's settled, then `take` it in there.
        /// `.now` runs it on the settling thread, `.{ .on = queue }` when that queue's polled.
        pub fn then(self: Self, ctx: anytype, comptime function: fn (@TypeOf(ctx)) void, where: rt.Where) void {
            self.thenTask(Task.init(ctx, function), where);
        }

        /// Like `then`, with an owned task that does nothing once its owner's closed.
        pub fn thenTask(self: Self, task: Task, where: rt.Where) void {
            self.obj().then(task, where.queue());
        }

        /// Gives up on it. The resolver sees `cancelled`.
        pub fn cancel(self: Self) void {
            self.obj().cancel();
        }
    };
}

pub fn Resolver(comptime T: type, comptime Errors: ?type) type {
    return extern struct {
        const Self = @This();
        const V = Payload(T);
        const Wire = if (V == void) u8 else rt.Abi(V);

        data: usize = 0,
        table: ?*const anyopaque = null,

        pub const salamander = ResolverTrait.salamander;

        fn obj(self: Self) rt.Object(ResolverTrait) {
            return .{ .data = self.data, .table = self.table };
        }

        /// Settles it with a value, or an error when `T` is a result. Use it once.
        pub fn settle(self: Self, result: T) void {
            if (@typeInfo(T) == .error_union) {
                const v = result catch |err| return self.fail(err);
                return self.resolve(v);
            }
            self.resolve(result);
        }

        pub fn resolve(self: Self, v: V) void {
            var w: Wire = if (V == void) 0 else rt.lower(V, v);
            self.obj().resolve(&w);
        }

        pub fn fail(self: Self, err: anyerror) void {
            self.obj().reject(rt.lowerError(Errors, err));
        }

        /// For what the value points at, like its text, kept with it. The taker has it till its
        /// thread takes another. Before settling only.
        pub fn allocator(self: *const Self) std.mem.Allocator {
            return holding(@ptrCast(self));
        }

        /// `text` copied into memory kept with the value.
        pub fn hold(self: *const Self, text: []const u8) error{OutOfMemory}![]const u8 {
            return self.allocator().dupe(u8, text);
        }

        /// The waiter gave up, so the work can stop early.
        pub fn cancelled(self: Self) bool {
            return self.obj().cancelled();
        }

        /// Before settling. Waiters with no queue of their own carry on from `where`, even ones
        /// that come after it's settled.
        pub fn carryOn(self: Self, where: rt.Queue) void {
            self.obj().carryOn(where.raw());
        }

        /// Not going to settle it. The waiter gets `Gone`.
        pub fn drop(self: Self) void {
            self.obj().drop();
        }
    };
}

const testing = std.testing;

test "settles and takes" {
    const P = Promise(u32, null);
    const pair = try P.make();
    try testing.expectEqual(null, pair.promise.take());
    pair.resolver.resolve(7);
    try testing.expectEqual(7, try pair.promise.take().?);
}

test "errors cross as codes" {
    const E = enum(u32) { NotFound = 1, _ };
    const P = Promise(error{NotFound}!u32, E);
    const pair = try P.make();
    pair.resolver.settle(error.NotFound);
    try testing.expectError(error.NotFound, pair.promise.wait());

    const dropped = try P.make();
    dropped.resolver.drop();
    try testing.expectError(error.Gone, dropped.promise.wait());
}

test "then runs once, whichever comes first" {
    const Count = struct {
        n: u32 = 0,
        fn hit(self: *@This()) void {
            self.n += 1;
        }
    };
    var before: Count = .{};
    const a = try Promise(void, null).make();
    a.promise.then(&before, Count.hit, .now);
    try testing.expectEqual(0, before.n);
    a.resolver.resolve({});
    try testing.expectEqual(1, before.n);
    try a.promise.take().?;

    var after: Count = .{};
    const b = try Promise(void, null).settled({});
    b.then(&after, Count.hit, .now);
    try testing.expectEqual(1, after.n);
    try b.take().?;
}

test "then on a queue waits for the poll" {
    const Got = struct {
        value: u32 = 0,
        thread: std.Thread.Id = 0,
        p: Promise(u32, null) = .{},

        fn done(self: *@This()) void {
            self.thread = std.Thread.getCurrentId();
            self.value = self.p.take().? catch 0;
        }
    };
    const q = try rt.host().queue();
    const pair = try Promise(u32, null).make();
    var got: Got = .{ .p = pair.promise };
    pair.promise.then(&got, Got.done, .{ .on = q });

    // Settled on another thread, but the waiter only runs here
    const t = try std.Thread.spawn(.{}, struct {
        fn run(r: Resolver(u32, null)) void {
            r.resolve(42);
        }
    }.run, .{pair.resolver});
    t.join();
    try testing.expectEqual(0, got.value);
    try testing.expectEqual(1, q.poll());
    try testing.expectEqual(42, got.value);
    try testing.expectEqual(std.Thread.getCurrentId(), got.thread);
}

test "cancelling tells the resolver" {
    const pair = try Promise([]const u8, null).make();
    pair.promise.cancel();
    try testing.expect(pair.resolver.cancelled());
    pair.resolver.resolve("too late");
}

test "settled from another thread" {
    const pair = try Promise(u64, null).make();
    const t = try std.Thread.spawn(.{}, struct {
        fn run(r: Resolver(u64, null)) void {
            r.resolve(1 << 40);
        }
    }.run, .{pair.resolver});
    try testing.expectEqual(1 << 40, try pair.promise.wait());
    t.join();
}

test "waiters carry on where the resolver says, even ones that come after it's settled" {
    const P = Promise(u32, null);
    const Ran = struct {
        n: u32 = 0,
        fn hit(self: *@This()) void {
            self.n += 1;
        }
    };
    const q = try rt.host().queue();
    for ([_]bool{ false, true }) |late| {
        const pair = try P.make();
        pair.resolver.carryOn(q);
        var ran: Ran = .{};
        if (!late) pair.promise.then(&ran, Ran.hit, .now);
        pair.resolver.resolve(1);
        if (late) pair.promise.then(&ran, Ran.hit, .now);
        try testing.expectEqual(0, ran.n);
        _ = q.poll();
        try testing.expectEqual(1, ran.n);
        try testing.expectEqual(1, try pair.promise.take().?);
    }
}
