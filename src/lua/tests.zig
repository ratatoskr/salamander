//! The Lua binder against comptime Zig, same cases as the JS one's.

const std = @import("std");
const testing = std.testing;

const rt = @import("salamander_runtime");

const lua = @import("lua.zig");
const Binder = @import("Binder.zig");

const c = lua.c;
const State = lua.State;

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

var reported: usize = 0;

const Fixture = struct {
    l: *State,
    queue: rt.Queue,
    binder: *Binder,
    module: *Binder.Module,

    fn init() !Fixture {
        const l = c.luaL_newstate() orelse return error.OutOfMemory;
        errdefer c.lua_close(l);
        c.luaL_requiref(l, lua.cstr("_G"), c.luaopen_base, 1);
        c.luaL_requiref(l, lua.cstr("coroutine"), c.luaopen_coroutine, 1);
        lua.pop(l, 2);
        const queue = try rt.host().queue();
        const binder = try Binder.init(testing.allocator, l, .{ .queue = queue, .report = report });
        errdefer binder.deinit();
        binder.pushTask(l);
        c.lua_setglobal(l, lua.cstr("task"));
        return .{ .l = l, .queue = queue, .binder = binder, .module = try binder.load(source, null) };
    }

    fn deinit(f: *Fixture) void {
        f.binder.deinit();
        c.lua_close(f.l);
    }

    fn report(_: *Binder, message: []const u8) void {
        _ = message;
        reported += 1;
    }

    /// Runs `code`, failing with what it raised.
    fn eval(f: *Fixture, code: []const u8) !void {
        const l = f.l;
        if (lua.load(l, code, "=test") != lua.ok or lua.pcall(l, 0, 0, 0) != lua.ok) {
            var len: usize = 0;
            const p = c.luaL_tolstring(l, -1, &len);
            std.debug.print("raised: {s}\n", .{@as([*]const u8, @ptrCast(p))[0..len]});
            lua.pop(l, 2);
            return error.Raised;
        }
    }

    /// Polls the queue and runs what that let go.
    fn settle(f: *Fixture) void {
        _ = f.queue.poll();
        f.binder.runJobs();
    }

    fn int(f: *Fixture, name: [:0]const u8) i64 {
        _ = c.lua_getglobal(f.l, lua.cstr(name));
        defer lua.pop(f.l, 1);
        return c.lua_tointegerx(f.l, -1, null);
    }

    /// A global table as a native Counter.
    fn counter(f: *Fixture, name: [:0]const u8) !rt.Object(Counter) {
        const t = try f.binder.trait(f.module, "Counter");
        _ = c.lua_getglobal(f.l, lua.cstr(name));
        defer lua.pop(f.l, 1);
        return (try f.binder.unwrap(f.l, t, lua.top(f.l))).as(rt.Object(Counter));
    }

    fn withCounter(f: *Fixture, real: *Real) !void {
        const t = try f.binder.trait(f.module, "Counter");
        try f.binder.wrap(f.l, t, .of(rt.Object(Counter).init(real, rt.implement(Counter, Real))));
        c.lua_setglobal(f.l, lua.cstr("counter"));
    }
};

const script_impl =
    \\M = {}
    \\function M:add(n) return n + 10 end
    \\function M:big(n) return n * 2 end
    \\function M:greet(w) return "hi " .. w end
    \\function M:scale(v, by) return { x = v.x * by, y = v.y * by } end
    \\function M:sum(xs) local n = 0 for i = 1, #xs do n = n + xs[i] end return n end
    \\function M:half(x) if x == nil then return nil end return x // 2 end
    \\function M:next(m) return m + 1 end
    \\function M:check(x)
    \\    if x < 0 then error({ name = "Bad" }) end
    \\    if x == 0 then error("plain") end
    \\    return { x = x, y = 0 }
    \\end
    \\function M:each(f, n) return f(n) + 1 end
    \\function M:same() return self end
    \\function M:later(x) task.yield() return x + 1 end
    \\function M:hold(f) self.f = f end
    \\function M:stash(f) self.f = f end
    \\function M:callHeld(x) return self.f(x) end
;

test "scripts call Zig's impl" {
    var f: Fixture = try .init();
    defer f.deinit();
    var real: Real = .{};
    try f.withCounter(&real);
    try f.eval(
        \\local function eq(a, b) if a ~= b then error(tostring(a) .. " ~= " .. tostring(b), 2) end end
        \\local k = counter
        \\eq(k:add(2), 3)
        \\eq(k:big(1 << 40), 1 << 41)
        \\eq(k:greet("zig"), "hello zig")
        \\local v = k:scale({ x = 1, y = 2 }, 3)
        \\eq(v.x, 3) eq(v.y, 6)
        \\eq(k:sum({ 1, 2, 3, 4 }), 10)
        \\eq(k:half(9), 4)
        \\eq(k:half(nil), nil)
        \\eq(k:next(1), 2)
        \\eq(k:next("one"), 2)
        \\local r = k:check(5)
        \\eq(r.x, 5) eq(r.y, 0)
        \\local ok, e = pcall(k.check, k, -1)
        \\eq(ok, false) eq(e.name, "Bad") eq(e.code, 3)
        \\eq(k:each(function(x) return x * 3 end, 4), 13)
        \\eq(k:same():add(10), 11)
        \\got = 0
        \\k:later(21):next(function(v) got = v end)
    );
    f.settle();
    try testing.expectEqual(42, f.int("got"));
}

/// Only weighs Vec2s.
const Weigher = struct {
    pub fn weigh(_: *Weigher, value: rt.Any) f32 {
        const v = value.as(Vec2) orelse return -1;
        return v.x;
    }
    pub fn grow(_: *Weigher, s: B.Shape) B.Shape {
        return switch (s) {
            .circle => |r| .{ .circle = r * 2 },
            .label => |l| .{ .label = if (std.mem.eql(u8, l, "a")) "aa" else l },
            .none => .none,
        };
    }
};

test "anys cross as { type, value }" {
    var f: Fixture = try .init();
    defer f.deinit();
    var w: Weigher = .{};
    const t = try f.binder.trait(f.module, "Scale");
    try f.binder.wrap(f.l, t, .of(rt.Object(B.Scale).init(&w, rt.implement(B.Scale, Weigher))));
    c.lua_setglobal(f.l, lua.cstr("scale"));
    f.binder.pushBuiltin(f.l);
    c.lua_setglobal(f.l, lua.cstr("salamander"));
    try f.eval(
        \\assert(scale:weigh(salamander.any("Vec2", { x = 3, y = 4 })) == 3, "as a Vec2")
        \\assert(scale:weigh({ type = "Mode", value = "two" }) == -1, "as a Mode")
        \\assert(not pcall(scale.weigh, scale, salamander.any("Nope", 1)), "an unknown type")
        \\assert(scale:grow({ circle = 2 }).circle == 4, "a circle")
        \\assert(scale:grow({ label = "a" }).label == "aa", "a label")
        \\assert(scale:grow("none") == "none", "none")
        \\assert(not pcall(scale.grow, scale, "circle"), "a member that holds something, by name")
        \\W = {}
        \\function W:weigh(a) return a.type == "Vec2" and a.value.y or -1 end
    );

    // And a script's, given one from Zig
    _ = c.lua_getglobal(f.l, lua.cstr("W"));
    defer lua.pop(f.l, 1);
    const back = (try f.binder.unwrap(f.l, t, lua.top(f.l))).as(rt.Object(B.Scale));
    var vec: Vec2 = .{ .x = 1, .y = 7 };
    try testing.expectEqual(7, back.weigh(.of(&vec)));
    var mode: Mode = .two;
    try testing.expectEqual(-1, back.weigh(.of(&mode)));
}

var factor: i32 = 3;

fn triple(by: *i32, x: i32) i32 {
    return x * by.*;
}

test "Zig calls a script's impl" {
    var f: Fixture = try .init();
    defer f.deinit();
    const before = reported;
    try f.eval(script_impl);
    const obj = try f.counter("M");

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
    // The same table comes back as the same native object
    try testing.expectEqual(obj.table, obj.same().table);
    try testing.expectEqual(before, reported);

    const p = obj.later(5);
    try testing.expectEqual(null, p.take());
    f.settle();
    try testing.expectEqual(6, try p.take().?);
}

test "a script's objects stop once the binder's gone" {
    var f: Fixture = try .init();
    try f.eval("M = {} function M:add(n) return n + 1 end");
    const obj = try f.counter("M");
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
    try f.withCounter(&real);

    // A new closure every time reuses one record, and keeps nothing
    try f.eval("n = 0 for i = 1, 1000 do n = n + counter:each(function(x) return x + i end, 1) end");
    try testing.expectEqual(1, f.binder.core.spare.items.len);
    try testing.expectEqual(0, f.binder.core.root.impls.items.len);

    // Held past the call by mistake, it's gone
    try f.eval("counter:stash(function(x) return x * 2 end)");
    try testing.expectEqual(0, real.callHeld(4));

    // Kept, it works until its scope closes
    const scope = try f.binder.openScope("handlers");
    f.binder.core.current = scope;
    try f.eval("h = function(x) return x * 5 end counter:hold(h) counter:hold(h)");
    f.binder.core.current = f.binder.core.root;
    try testing.expectEqual(20, real.callHeld(4));
    try testing.expectEqual(1, scope.impls.items.len);
    f.binder.closeScope(scope);
    try testing.expectEqual(0, real.callHeld(4));
    // And the function's free to be kept again
    try f.eval("counter:hold(h)");
    try testing.expectEqual(20, real.callHeld(4));
    try testing.expectEqual(1, f.binder.core.root.impls.items.len);
}

test "native objects lent to a script stop working after the call" {
    var f: Fixture = try .init();
    defer f.deinit();
    try f.eval(script_impl);
    const obj = try f.counter("M");

    obj.hold(Visit.init(&factor, triple));
    try testing.expectEqual(12, obj.callHeld(4));

    const before = reported;
    obj.stash(Visit.init(&factor, triple));
    try testing.expectEqual(0, obj.callHeld(4));
    // It raised Gone, with nowhere to go
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
    try f.eval("M = {} function M:each(f, n) return f(n) + self:k() end function M:k() return 1 end");
    const obj = try f.counter("M");
    f.binder.core.current = f.binder.core.root;

    try testing.expectEqual(4, obj.each(closer, 3));
    try testing.expectEqual(1, f.binder.core.closing.items.len);
    try testing.expectEqual(0, obj.each(closer, 3));
    f.settle();
    try testing.expectEqual(0, f.binder.core.closing.items.len);
}

test "kept objects go once native code releases them all" {
    var f: Fixture = try .init();
    defer f.deinit();
    var real: Real = .{};
    try f.withCounter(&real);

    try f.eval("h = function(x) return x * 5 end counter:hold(h) counter:hold(h)");
    try testing.expectEqual(1, f.binder.core.root.impls.items.len);
    real.drop();
    f.settle();
    try testing.expectEqual(20, real.callHeld(4));
    real.drop();
    f.settle();
    try testing.expectEqual(0, f.binder.core.root.impls.items.len);
    try testing.expectEqual(0, real.callHeld(4));

    for (0..200) |_| {
        try f.eval("counter:hold(function(x) return x + 1 end)");
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
    try f.withCounter(&real);
    try f.eval("counter:hold(function(x) return x end)");
    const thread = try std.Thread.spawn(.{}, Real.drop, .{&real});
    thread.join();
    try testing.expectEqual(1, f.binder.core.root.impls.items.len);
    f.settle();
    try testing.expectEqual(0, f.binder.core.root.impls.items.len);
}
