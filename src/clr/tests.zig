//! Starts a real runtime, so needs the .NET 10 SDK and skips without it. Every test shares the one runtime.

const std = @import("std");
const clr = @import("root.zig");
const probe = @import("clr_test");

const testing = std.testing;

const Add = *const fn (i32, i32) callconv(clr.cc) i32;
const Get = *const fn () callconv(clr.cc) i32;
const exports = "Probe.Exports, Probe";

var shared: ?clr.Host = null;

fn host() !*const clr.Host {
    if (probe.dll.len == 0) return error.SkipZigTest;
    if (shared) |*h| return h;
    var messages: std.Io.Writer.Allocating = .init(testing.allocator);
    defer messages.deinit();
    const was_running = clr.running();
    shared = clr.Host.open(testing.allocator, testing.io, .{ .runtime_config = probe.runtime_config, .messages = &messages.writer }) catch |e| {
        // No .NET for this process, like x86 or musl tests on a machine with only x64 glibc's
        if (e == error.NoDotnet or e == error.LoadFailed) return error.SkipZigTest;
        std.debug.print("hostfxr {x}: {s}\n", .{ @as(u32, @bitCast(clr.lastStatus())), messages.written() });
        return e;
    };
    try testing.expectEqual(was_running, shared.?.joined);
    try testing.expect(clr.running());
    return &shared.?;
}

test "calls C# in a context of its own" {
    const h = try host();
    const add = try h.isolatedFunction(Add, testing.allocator, probe.dll, exports, "Add");
    try testing.expectEqual(5, add(2, 3));
    const major = try h.isolatedFunction(Get, testing.allocator, probe.dll, exports, "RuntimeMajor");
    try testing.expect(major() >= 10);
    const in_default = try h.isolatedFunction(Get, testing.allocator, probe.dll, exports, "InDefaultContext");
    try testing.expectEqual(0, in_default());
}

test "calls C# loaded where the app's own is" {
    const h = try host();
    try h.load(testing.allocator, probe.dll);
    const in_default = try h.function(Get, testing.allocator, exports, "InDefaultContext");
    try testing.expectEqual(1, in_default());
}

test "a method that isn't there" {
    const h = try host();
    try testing.expectError(error.NotFound, h.isolatedFunction(Get, testing.allocator, probe.dll, exports, "Nope"));
    try testing.expectError(error.NotFound, h.function(Get, testing.allocator, "Probe.Nope, Probe", "Add"));
}

test "joins the runtime that's running" {
    _ = try host();
    const again: clr.Host = try .open(testing.allocator, testing.io, .{ .runtime_config = probe.runtime_config, .join_only = true });
    try testing.expect(again.joined);
    try again.load(testing.allocator, probe.dll);
    const add = try again.function(Add, testing.allocator, exports, "Add");
    try testing.expectEqual(7, add(3, 4));
}

// test.sal's types and traits, as generated Zig here and generated C# in the probe

const schema = @import("test_schema");
const rt = @import("salamander_runtime");
const traits = "Probe.Traits, Probe";

fn traitsHost() !*const clr.Host {
    const h = try host();
    try h.load(testing.allocator, probe.dll);
    return h;
}

test "C# lays out the schema like Zig" {
    const h = try traitsHost();
    const layout = try h.function(*const fn ([*]usize, i32) callconv(clr.cc) i32, testing.allocator, traits, "Layout");
    const M = schema.Mixed;
    const want = [_]usize{
        @sizeOf(schema.Vec3),              @sizeOf(schema.Num),        @sizeOf(schema.Flags), @sizeOf(M),
        @offsetOf(M, "big"),               @offsetOf(M, "yes"),        @offsetOf(M, "at"),    @offsetOf(M, "shorts"),
        @offsetOf(M, "flags"),             @offsetOf(M, "points"),     @offsetOf(M, "num"),   @sizeOf(rt.Opt(u32)),
        @sizeOf(rt.Table(schema.Counter)), @sizeOf(schema.raw.Tagged),
    };
    var got: [want.len]usize = undefined;
    try testing.expectEqual(@as(i32, want.len), layout(&got, want.len));
    try testing.expectEqualSlices(usize, &want, &got);
}

const ZigCounter = struct {
    total: u32 = 10,
    greeting: [64]u8 = undefined,
    numbers: [16]u32 = undefined,
    pending: ?rt.Resolver(u32, null) = null,
    pending_value: u32 = 0,

    pub fn add(self: *ZigCounter, n: u32) u32 {
        self.total += n;
        return self.total;
    }

    pub fn scale(_: *ZigCounter, v: schema.Vec3, by: f32) schema.Vec3 {
        return .{ .x = v.x * by, .y = v.y * by, .z = v.z * by };
    }

    pub fn flip(_: *ZigCounter, b: bool) bool {
        return !b;
    }

    pub fn name(_: *ZigCounter) []const u8 {
        return "zig";
    }

    pub fn check(_: *ZigCounter, n: u32) !u32 {
        if (n == 0) return error.Bad;
        return n * 2;
    }

    pub fn echo(_: *ZigCounter, m: schema.Mixed) schema.Mixed {
        var out = m;
        out.small += 1;
        return out;
    }

    pub fn find(_: *ZigCounter, n: u32) ?u32 {
        return if (n == 0) null else n * 2;
    }

    pub fn greet(self: *ZigCounter, who: []const u8) []const u8 {
        return std.fmt.bufPrint(&self.greeting, "hi {s}", .{who}) catch "";
    }

    pub fn sum(_: *ZigCounter, ids: []const u32) u32 {
        var total: u32 = 0;
        for (ids) |i| total += i;
        return total;
    }

    pub fn range(self: *ZigCounter, n: u32) []const u32 {
        for (0..n) |i| self.numbers[i] = @intCast(i);
        return self.numbers[0..n];
    }

    pub fn retag(_: *ZigCounter, t: schema.raw.Tagged) schema.raw.Tagged {
        var out = t;
        out.at.x += 1;
        return out;
    }

    pub fn each(_: *ZigCounter, n: u32, visit: schema.Visit) u32 {
        var count: u32 = 0;
        for (0..n) |i| {
            if (visit.invoke(.{@as(u32, @intCast(i))})) count += 1;
        }
        return count;
    }

    pub fn later(_: *ZigCounter, n: u32) rt.Promise(u32, null) {
        return rt.Promise(u32, null).settled(n * 2) catch .{};
    }

    const LaterCheck = rt.Promise((schema.Fail || rt.Failure)!u32, schema.FailCode);

    pub fn laterCheck(_: *ZigCounter, n: u32) LaterCheck {
        return LaterCheck.settled(if (n == 0) error.Bad else n * 3) catch .{};
    }

    pub fn bump(_: *ZigCounter, v: *schema.Vec3) void {
        v.x += 1;
    }

    pub fn soon(self: *ZigCounter, n: u32) rt.Promise(u32, null) {
        const made = rt.Promise(u32, null).make() catch return .{};
        self.pending = made.resolver;
        self.pending_value = n + 1;
        return made.promise;
    }

    const table = rt.implement(schema.Counter, ZigCounter);
};

test "C#'s await carries on on the thread that settled what it awaited" {
    const h = try traitsHost();
    const start = try h.function(*const fn (schema.Counter) callconv(clr.cc) void, testing.allocator, traits, "StartSoon");
    const got = try h.function(Get, testing.allocator, traits, "SoonGot");
    const ran_here = try h.function(Get, testing.allocator, traits, "SoonRanHere");
    var counter: ZigCounter = .{};
    start(.init(&counter, ZigCounter.table));
    try testing.expectEqual(0, got());

    const Settler = struct {
        fn go(c: *ZigCounter, here: Get, out: *i32) void {
            c.pending.?.resolve(c.pending_value);
            out.* = here();
        }
    };
    var on_settler: i32 = 0;
    const t = try std.Thread.spawn(.{}, Settler.go, .{ &counter, ran_here, &on_settler });
    t.join();
    try testing.expectEqual(2, got());
    try testing.expectEqual(1, on_settler);
}

test "C# calls a trait Zig implements, raw" {
    const h = try traitsHost();
    const use = try h.function(*const fn (schema.Counter) callconv(clr.cc) u32, testing.allocator, traits, "UseRaw");
    var counter: ZigCounter = .{};
    // Which of its checks failed, if one did
    try testing.expectEqual(0, use(.init(&counter, ZigCounter.table)));
}

test "C# calls a trait Zig implements, as plain C#" {
    const h = try traitsHost();
    const use = try h.function(*const fn (schema.Counter) callconv(clr.cc) u32, testing.allocator, traits, "UsePlain");
    var counter: ZigCounter = .{};
    try testing.expectEqual(0, use(.init(&counter, ZigCounter.table)));
}

test "Zig calls a trait C# implements in plain C#" {
    const h = try traitsHost();
    // C#'s async methods settle promises from the host
    const init = try h.function(*const fn (rt.core.Host) callconv(clr.cc) void, testing.allocator, traits, "Init");
    init(rt.host().raw());
    const make = try h.function(*const fn () callconv(clr.cc) schema.Counter, testing.allocator, traits, "MakePlain");
    const free = try h.function(*const fn (schema.Counter) callconv(clr.cc) void, testing.allocator, traits, "FreeCounter");
    const thrown = try h.function(Get, testing.allocator, traits, "Thrown");
    const c = make();
    defer free(c);

    try testing.expectEqual(105, c.add(5));
    try testing.expectEqual(schema.Vec3{ .x = 3, .y = 6, .z = 9 }, c.scale(.{ .x = 1, .y = 2, .z = 3 }, 3));
    try testing.expect(c.flip(false));
    try testing.expectEqualStrings("cs", c.name());
    try testing.expectEqual(6, try c.check(2));
    try testing.expectError(error.Bad, c.check(0));
    // What it throws stays in C#, and the call's Gone
    const before = thrown();
    try testing.expectError(error.Gone, c.check(13));
    try testing.expectEqual(before + 1, thrown());

    var m: schema.Mixed = .{ .small = 3, .big = 4, .yes = true };
    m.shorts[1] = 5;
    m.flags.level = 7;
    m.flags.mode = .on;
    m.num = .{ .float = 2.5 };
    const back = c.echo(m);
    try testing.expectEqual(3, back.small);
    try testing.expectEqual(40, back.big);
    try testing.expect(back.yes);
    try testing.expectEqual([3]u16{ 42, 5, 0 }, back.shorts);
    try testing.expect(back.flags.alive);
    try testing.expectEqual(7, back.flags.level);
    try testing.expectEqual(.on, back.flags.mode);
    try testing.expectEqual(2.5, back.num.float);
    try testing.expectEqual(5, c.find(4).?);
    try testing.expectEqual(null, c.find(0));

    try testing.expectEqualStrings("hello zig", c.greet("zig"));
    try testing.expectEqual(6, c.sum(&.{ 1, 2, 3 }));
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, c.range(3));
    const ids = [_]u32{ 1, 2 };
    const t = c.retag(.{ .tag = "t", .ids = &ids, .at = .{ .x = 1, .y = 2, .z = 3 } });
    try testing.expectEqualStrings("t!", t.tag);
    try testing.expectEqualSlices(u32, &.{ 2, 1 }, t.ids);
    try testing.expectEqual(11, t.at.x);

    var evens: u32 = 0;
    const visit: schema.Visit = .init(&evens, struct {
        fn f(count: *u32, i: u32) bool {
            count.* += 1;
            return i % 2 == 0;
        }
    }.f);
    try testing.expectEqual(2, c.each(4, visit));
    try testing.expectEqual(4, evens);

    try testing.expectEqual(40, try c.later(4).wait());
    try testing.expectEqual(20, try c.laterCheck(2).wait());
    try testing.expectError(error.Bad, c.laterCheck(0).wait());

    var v: schema.Vec3 = .{ .x = 1, .y = 2, .z = 3 };
    c.bump(&v);
    try testing.expectEqual(3, v.y);
}
