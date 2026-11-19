//! The JS binder against comptime Zig: scripts calling Zig's impl, and Zig calling a script's.

const std = @import("std");
const testing = std.testing;

const rt = @import("salamander_runtime");

const qjs = @import("qjs.zig");
const Binder = @import("Binder.zig");

const c = qjs.c;
const Value = qjs.Value;

const source = @embedFile("test.sal");
const B = @import("test_schema");
const Counter = B.Counter;
const Vec2 = B.Vec2;
const Mode = B.Mode;
const Visit = B.Visit;
const Later = rt.Promise(i32, null);

const Real = struct {
    held: Visit = .{},

    pub fn add(_: *Real, n: i32) i32 {
        return n + 1;
    }
    pub fn big(_: *Real, n: i64) i64 {
        return n * 2;
    }
    pub fn greet(_: *Real, who: []const u8) []const u8 {
        return if (std.mem.eql(u8, who, "zig")) "hello zig" else "hello you";
    }
    pub fn scale(_: *Real, v: Vec2, by: f32) Vec2 {
        return .{ .x = v.x * by, .y = v.y * by };
    }
    pub fn sum(_: *Real, xs: []const u32) u32 {
        var n: u32 = 0;
        for (xs) |x| n += x;
        return n;
    }
    pub fn half(_: *Real, x: ?u32) ?u32 {
        return if (x) |v| v / 2 else null;
    }
    pub fn next(_: *Real, m: Mode) Mode {
        return @fromBackingInt(@intCast(@backingInt(m) + 1));
    }
    pub fn check(_: *Real, x: i32) anyerror!Vec2 {
        if (x < 0) return error.Bad;
        return .{ .x = @floatFromInt(x), .y = 0 };
    }
    pub fn each(_: *Real, f: Visit, n: i32) i32 {
        return f.invoke(.{n}) + 1;
    }
    pub fn same(self: *Real) rt.Object(Counter) {
        return .init(self, rt.implement(Counter, Real));
    }
    pub fn later(_: *Real, x: i32) Later {
        return Later.settled(x * 2) catch .{};
    }
    pub fn hold(self: *Real, f: Visit) void {
        self.held = f;
    }
    pub fn stash(self: *Real, f: Visit) void {
        self.held = f;
    }
    pub fn callHeld(self: *Real, x: i32) i32 {
        return self.held.invoke(.{x});
    }
    pub fn drop(self: *Real) void {
        self.held.release();
    }
};

const Fixture = struct {
    jrt: *c.JSRuntime,
    ctx: *qjs.Context,
    queue: rt.Queue,
    binder: *Binder,
    module: *Binder.Module,

    fn init() !Fixture {
        const jrt = c.JS_NewRuntime() orelse return error.OutOfMemory;
        errdefer c.JS_FreeRuntime(jrt);
        const ctx = c.JS_NewContext(jrt) orelse return error.OutOfMemory;
        errdefer c.JS_FreeContext(ctx);
        const queue = try rt.host().queue();
        const binder = try Binder.init(testing.allocator, ctx, .{ .queue = queue, .report = report });
        errdefer binder.deinit();
        return .{ .jrt = jrt, .ctx = ctx, .queue = queue, .binder = binder, .module = try binder.load(source, null) };
    }

    fn deinit(f: *Fixture) void {
        f.binder.deinit();
        c.JS_FreeContext(f.ctx);
        c.JS_FreeRuntime(f.jrt);
    }

    fn report(_: *Binder, e: Value) void {
        _ = e;
        reported += 1;
    }

    /// Runs `code`, failing with what it threw.
    fn eval(f: *Fixture, code: []const u8) !Value {
        const v = c.JS_Eval(f.ctx, qjs.chars(code), code.len, qjs.cstr("<test>"), c.JS_EVAL_TYPE_GLOBAL);
        if (c.JS_IsException(v)) {
            const e = c.JS_GetException(f.ctx);
            defer c.JS_FreeValue(f.ctx, e);
            if (qjs.toString(f.ctx, e)) |s| {
                defer s.free();
                std.debug.print("threw: {s}\n", .{s.slice()});
            }
            return error.Threw;
        }
        return v;
    }

    /// Polls the queue and runs what that let go.
    fn settle(f: *Fixture) void {
        _ = f.queue.poll();
        var pctx: ?*qjs.Context = null;
        while (c.JS_ExecutePendingJob(f.jrt, &pctx) > 0) {}
    }

    fn global(f: *Fixture, name: []const u8) Value {
        const g = c.JS_GetGlobalObject(f.ctx);
        defer c.JS_FreeValue(f.ctx, g);
        return qjs.get(f.ctx, g, name);
    }
};

var reported: usize = 0;

test "scripts call Zig's impl" {
    var f: Fixture = try .init();
    defer f.deinit();
    var real: Real = .{};
    const obj: rt.Object(Counter) = .init(&real, rt.implement(Counter, Real));
    const t = try f.binder.trait(f.module, "Counter");
    const g = c.JS_GetGlobalObject(f.ctx);
    defer c.JS_FreeValue(f.ctx, g);
    qjs.set(f.ctx, g, "counter", try f.binder.wrap(t, .of(obj)));

    const v = try f.eval(
        \\function eq(a, b) {
        \\    const sa = JSON.stringify(a), sb = JSON.stringify(b);
        \\    if (sa !== sb) throw new Error(sa + " != " + sb);
        \\}
        \\const k = counter;
        \\eq(k.add(2), 3);
        \\eq(k.big(1n << 40n) === 1n << 41n, true);
        \\eq(k.greet("zig"), "hello zig");
        \\eq(k.scale({ x: 1, y: 2 }, 3), { x: 3, y: 6 });
        \\eq(k.sum([1, 2, 3, 4]), 10);
        \\eq(k.half(9), 4);
        \\eq(k.half(null), null);
        \\eq(k.next(1), 2);
        \\eq(k.next("one"), 2);
        \\eq(k.check(5), { x: 5, y: 0 });
        \\let err;
        \\try { k.check(-1); } catch (e) { err = e; }
        \\eq([err.name, err.code], ["Bad", 3]);
        \\eq(k.each(x => x * 3, 4), 13);
        \\eq(k.same().add(10), 11);
        \\globalThis.got = 0;
        \\k.later(21).then(v => { globalThis.got = v; });
        \\true
    );
    defer c.JS_FreeValue(f.ctx, v);
    try testing.expect(c.JS_ToBool(f.ctx, v) > 0);

    f.settle();
    const got = f.global("got");
    var n: i32 = 0;
    _ = c.JS_ToInt32(f.ctx, &n, got);
    try testing.expectEqual(42, n);
}

var factor: i32 = 3;

fn triple(by: *i32, x: i32) i32 {
    return x * by.*;
}

test "Zig calls a script's impl" {
    var f: Fixture = try .init();
    defer f.deinit();
    const before = reported;
    const impl = try f.eval(
        \\({
        \\    add(n) { return n + 10; },
        \\    big(n) { return n * 2n; },
        \\    greet(w) { return "hi " + w; },
        \\    scale(v, by) { return { x: v.x * by, y: v.y * by }; },
        \\    sum(xs) { return xs.reduce((a, b) => a + b, 0); },
        \\    half(x) { return x == null ? null : x >> 1; },
        \\    next(m) { return m + 1; },
        \\    check(x) {
        \\        if (x < 0) { const e = new Error("no"); e.name = "Bad"; throw e; }
        \\        if (x == 0) throw new Error("plain");
        \\        return { x, y: 0 };
        \\    },
        \\    each(f, n) { return f(n) + 1; },
        \\    same() { return this; },
        \\    async later(x) { await null; return x + 1; },
        \\    hold(f) { this.f = f; },
        \\    stash(f) { this.f = f; },
        \\    callHeld(x) { return this.f(x); },
        \\})
    );
    defer c.JS_FreeValue(f.ctx, impl);
    const t = try f.binder.trait(f.module, "Counter");
    const obj = (try f.binder.unwrap(t, impl)).as(rt.Object(Counter));

    try testing.expectEqual(15, obj.add(5));
    try testing.expectEqual(@as(i64, 1) << 41, obj.big(@as(i64, 1) << 40));
    try testing.expectEqualStrings("hi zig", obj.greet("zig"));
    try testing.expectEqual(Vec2{ .x = 2, .y = 4 }, obj.scale(.{ .x = 1, .y = 2 }, 2));
    try testing.expectEqual(10, obj.sum(&[_]u32{ 1, 2, 3, 4 }));
    try testing.expectEqual(4, obj.half(9).?);
    try testing.expectEqual(null, obj.half(null));
    try testing.expectEqual(2, @backingInt(obj.next(@as(Mode, @fromBackingInt(1)))));
    try testing.expectEqual(Vec2{ .x = 5, .y = 0 }, try obj.check(5));
    try testing.expectError(error.Bad, obj.check(-1));
    try testing.expectError(error.Unsupported, obj.check(0));
    try testing.expectEqual(13, obj.each(Visit.init(&factor, triple), 4));
    // The same JS object comes back as the same native one
    try testing.expectEqual(obj.table, obj.same().table);
    try testing.expectEqual(before, reported);

    const p = obj.later(5);
    try testing.expectEqual(null, p.take());
    f.settle();
    try testing.expectEqual(6, try p.take().?);
}

test "a script's objects stop once the binder's gone" {
    var f: Fixture = try .init();
    const impl = try f.eval("({ add(n) { return n + 1; } })");
    const t = try f.binder.trait(f.module, "Counter");
    const obj = (try f.binder.unwrap(t, impl)).as(rt.Object(Counter));
    c.JS_FreeValue(f.ctx, impl);
    try testing.expectEqual(2, obj.add(1));
    // A method it doesn't have
    try testing.expectEqualStrings("", obj.greet("x"));
    f.deinit();
    try testing.expectEqual(0, obj.add(1));
}

test "objects a script lends native code are let go after the call" {
    var f: Fixture = try .init();
    defer f.deinit();
    var real: Real = .{};
    const t = try f.binder.trait(f.module, "Counter");
    const g = c.JS_GetGlobalObject(f.ctx);
    defer c.JS_FreeValue(f.ctx, g);
    qjs.set(f.ctx, g, "counter", try f.binder.wrap(t, .of(rt.Object(Counter).init(&real, rt.implement(Counter, Real)))));

    // A new closure every time reuses one record, and keeps nothing
    const v = try f.eval("let n = 0; for (let i = 0; i < 1000; i++) n += counter.each(x => x + i, 1); n");
    c.JS_FreeValue(f.ctx, v);
    try testing.expectEqual(1, f.binder.core.spare.items.len);
    try testing.expectEqual(0, f.binder.core.root.impls.items.len);

    // Held past the call by mistake, it's gone
    c.JS_FreeValue(f.ctx, try f.eval("counter.stash(x => x * 2)"));
    try testing.expectEqual(0, real.callHeld(4));

    // Kept, it works until its scope closes
    const scope = try f.binder.openScope("handlers");
    f.binder.core.current = scope;
    c.JS_FreeValue(f.ctx, try f.eval("globalThis.h = x => x * 5; counter.hold(h); counter.hold(h)"));
    f.binder.core.current = f.binder.core.root;
    try testing.expectEqual(20, real.callHeld(4));
    // The same function twice is one object
    try testing.expectEqual(1, scope.impls.items.len);
    f.binder.closeScope(scope);
    try testing.expectEqual(0, real.callHeld(4));
    // And the function's free to be kept again
    c.JS_FreeValue(f.ctx, try f.eval("counter.hold(h)"));
    try testing.expectEqual(20, real.callHeld(4));
    try testing.expectEqual(1, f.binder.core.root.impls.items.len);
}

test "native objects lent to a script stop working after the call" {
    var f: Fixture = try .init();
    defer f.deinit();
    const impl = try f.eval(
        \\({
        \\    hold(f) { this.f = f; },
        \\    stash(f) { this.f = f; },
        \\    callHeld(x) { return this.f(x); },
        \\})
    );
    defer c.JS_FreeValue(f.ctx, impl);
    const t = try f.binder.trait(f.module, "Counter");
    const obj = (try f.binder.unwrap(t, impl)).as(rt.Object(Counter));

    obj.hold(Visit.init(&factor, triple));
    try testing.expectEqual(12, obj.callHeld(4));

    const before = reported;
    obj.stash(Visit.init(&factor, triple));
    try testing.expectEqual(0, obj.callHeld(4));
    // It threw Gone, with nowhere to go
    try testing.expectEqual(before + 1, reported);
}

test "a scope closed while a script's running is freed after" {
    var f: Fixture = try .init();
    defer f.deinit();
    const scope = try f.binder.openScope("inner");
    const Closer = struct {
        var binder: *Binder = undefined;
        var target: *Binder.Scope = undefined;
        fn close(_: *i32, x: i32) i32 {
            binder.closeScope(target);
            return x;
        }
    };
    Closer.binder = f.binder;
    Closer.target = scope;
    var unused: i32 = 0;
    const closer = Visit.init(&unused, Closer.close);

    f.binder.core.current = scope;
    const impl = try f.eval("({ each(f, n) { return f(n) + this.k(); }, k() { return 1; } })");
    defer c.JS_FreeValue(f.ctx, impl);
    const t = try f.binder.trait(f.module, "Counter");
    const obj = (try f.binder.unwrap(t, impl)).as(rt.Object(Counter));
    f.binder.core.current = f.binder.core.root;

    // Closing inside the call leaves the script running, and frees it once the queue's polled
    try testing.expectEqual(4, obj.each(closer, 3));
    try testing.expectEqual(1, f.binder.core.closing.items.len);
    try testing.expectEqual(0, obj.each(closer, 3));
    f.settle();
    try testing.expectEqual(0, f.binder.core.closing.items.len);
}

fn withCounter(f: *Fixture, real: *Real) !void {
    const t = try f.binder.trait(f.module, "Counter");
    const g = c.JS_GetGlobalObject(f.ctx);
    defer c.JS_FreeValue(f.ctx, g);
    qjs.set(f.ctx, g, "counter", try f.binder.wrap(t, .of(rt.Object(Counter).init(real, rt.implement(Counter, Real)))));
}

test "kept objects go once native code releases them all" {
    var f: Fixture = try .init();
    defer f.deinit();
    var real: Real = .{};
    try withCounter(&f, &real);

    // Two holds of one function is one object with two holders
    c.JS_FreeValue(f.ctx, try f.eval("globalThis.h = x => x * 5; counter.hold(h); counter.hold(h)"));
    try testing.expectEqual(1, f.binder.core.root.impls.items.len);
    real.drop();
    f.settle();
    try testing.expectEqual(20, real.callHeld(4));
    real.drop();
    // Nothing happens till the queue's polled
    try testing.expectEqual(20, real.callHeld(4));
    f.settle();
    try testing.expectEqual(0, f.binder.core.root.impls.items.len);
    try testing.expectEqual(0, real.callHeld(4));
    // An extra release is ignored
    real.drop();
    f.settle();

    // Holding and letting go of a new closure every time doesn't grow
    for (0..200) |_| {
        c.JS_FreeValue(f.ctx, try f.eval("counter.hold(x => x + 1)"));
        try testing.expectEqual(5, real.callHeld(4));
        real.drop();
        f.settle();
    }
    try testing.expectEqual(0, f.binder.core.root.impls.items.len);
    try testing.expect(f.binder.core.spare.items.len <= 2);
}

test "native code can release from another thread" {
    var f: Fixture = try .init();
    defer f.deinit();
    var real: Real = .{};
    try withCounter(&f, &real);
    c.JS_FreeValue(f.ctx, try f.eval("counter.hold(x => x)"));
    const thread = try std.Thread.spawn(.{}, Real.drop, .{&real});
    thread.join();
    try testing.expectEqual(1, f.binder.core.root.impls.items.len);
    f.settle();
    try testing.expectEqual(0, f.binder.core.root.impls.items.len);
}
