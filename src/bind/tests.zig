//! bind against comptime Zig, where LLVM decides the ABI: Zig's tables called through bind,
//! and bind's tables called from Zig, with every way an argument can cross.

const std = @import("std");
const testing = std.testing;

const salamander_schema = @import("salamander_schema");
const rt = @import("salamander_runtime");

const bind = @import("root.zig");

const source = @embedFile("test.sal");
const B = @import("test_schema");
const Kitchen = B.Kitchen;
const Vec3 = B.Vec3;
const Pair = B.Pair;
const Big = B.Big;
const Huge = B.Huge;
const Mode = B.Mode;

/// Zig's own impl, the reference.
const Real = struct {
    pub fn add(_: *Real, a: i32, b: i64, c: u8) i32 {
        return a + @as(i32, @intCast(b)) + c;
    }
    pub fn mix(_: *Real, a: f32, b: f64, c: i32, d: f32) f64 {
        return a + b + @as(f64, @floatFromInt(c)) + d;
    }
    pub fn flip(_: *Real, b: bool) bool {
        return !b;
    }
    pub fn next(_: *Real, m: Mode) Mode {
        return @fromBackingInt(@intCast(@backingInt(m) + 1));
    }
    pub fn len(_: *Real, s: []const u8) usize {
        return s.len;
    }
    pub fn echo(_: *Real, s: []const u8) []const u8 {
        return s;
    }
    pub fn scale(_: *Real, v: Vec3, by: f32) Vec3 {
        return .{ .x = v.x * by, .y = v.y * by, .z = v.z * by };
    }
    pub fn swap(_: *Real, p: Pair) Pair {
        return .{ .a = p.b, .b = p.a };
    }
    pub fn bigger(_: *Real, b: Big, by: u64) Big {
        return .{ .a = b.a + by, .b = b.b + by, .c = b.c + by };
    }
    pub fn sum(_: *Real, xs: []const u32) u32 {
        var n: u32 = 0;
        for (xs) |x| n += x;
        return n;
    }
    pub fn half(_: *Real, x: ?u32) ?u32 {
        return if (x) |v| v / 2 else null;
    }
    pub fn check(_: *Real, x: i32) anyerror!Vec3 {
        if (x < 0) return error.Bad;
        return .{ .x = @floatFromInt(x), .y = 0, .z = 0 };
    }
    pub fn ok(_: *Real, good: bool) anyerror!void {
        if (!good) return error.Bad;
    }
    pub fn thisVec(_: *Real, v: Vec3, n: i32) Vec3 {
        return .{ .x = v.x + @as(f32, @floatFromInt(n)), .y = v.y, .z = v.z };
    }
    pub fn std(_: *Real, a: i32, b: i64, p: Pair) i64 {
        return a + b + p.a + p.b;
    }
    pub fn same(self: *Real) rt.Object(Kitchen) {
        return .init(self, rt.implement(Kitchen, Real));
    }
    pub fn total(_: *Real, h: Huge, extra: u32) u64 {
        var n: u64 = extra;
        for (h.parts) |p| n += p;
        return n;
    }
};

fn huge() Huge {
    var h: Huge = undefined;
    for (&h.parts, 0..) |*p, i| p.* = i + 1;
    return h;
}

fn runtimeTrait() !*const bind.Trait {
    var diag: salamander_schema.Diagnostic = .{};
    var parsed = try salamander_schema.parse(testing.allocator, source, .{}, &diag);
    defer parsed.deinit();
    // The trait's copied into the host, so the parse can go
    return bind.Trait.init(rt.host(), parsed.schema, parsed.schema.findTrait("Kitchen").?);
}

fn ptr(v: anytype) [*]const u8 {
    return @ptrCast(v);
}

/// Calls by name through bind, with Zig values for the arguments.
fn callBind(t: *const bind.Trait, obj: rt.AnyObject, name: []const u8, args: anytype, comptime R: type) !struct { R, u32 } {
    var ptrs: [args.len][*]const u8 = undefined;
    // Real memory for each, since literals in `args` are comptime
    comptime var types: [args.len]type = undefined;
    inline for (0..args.len) |i| types[i] = @TypeOf(args[i]);
    var copies: @Tuple(&types) = undefined;
    inline for (0..args.len) |i| {
        copies[i] = args[i];
        ptrs[i] = ptr(&copies[i]);
    }
    var out: R = undefined;
    const code = bind.call(t, obj, t.find(name) orelse return error.NoMethod, &ptrs, @ptrCast(&out));
    return .{ out, code };
}

test "bind calls Zig's tables like Zig does" {
    const t = try runtimeTrait();
    var real: Real = .{};
    const obj: rt.AnyObject = .{ .data = @intFromPtr(&real), .table = rt.implement(Kitchen, Real) };

    try testing.expectEqual(1 + 2 + 3, (try callBind(t, obj, "add", .{ @as(i32, 1), @as(i64, 2), @as(u8, 3) }, i32))[0]);
    try testing.expectEqual(1.5 + 2.25 + 3 + 0.5, (try callBind(t, obj, "mix", .{ @as(f32, 1.5), @as(f64, 2.25), @as(i32, 3), @as(f32, 0.5) }, f64))[0]);
    try testing.expectEqual(false, (try callBind(t, obj, "flip", .{true}, bool))[0]);
    try testing.expectEqual(Mode.two, (try callBind(t, obj, "next", .{Mode.one}, Mode))[0]);
    try testing.expectEqual(5, (try callBind(t, obj, "len", .{rt.String.init("hello")}, usize))[0]);
    try testing.expectEqualStrings("hi", (try callBind(t, obj, "echo", .{rt.String.init("hi")}, rt.String))[0].get());
    try testing.expectEqual(Vec3{ .x = 2, .y = 4, .z = 6 }, (try callBind(t, obj, "scale", .{ Vec3{ .x = 1, .y = 2, .z = 3 }, @as(f32, 2) }, Vec3))[0]);
    try testing.expectEqual(Pair{ .a = 2, .b = 1 }, (try callBind(t, obj, "swap", .{Pair{ .a = 1, .b = 2 }}, Pair))[0]);
    try testing.expectEqual(Big{ .a = 11, .b = 12, .c = 13 }, (try callBind(t, obj, "bigger", .{ Big{ .a = 1, .b = 2, .c = 3 }, @as(u64, 10) }, Big))[0]);
    const xs = [_]u32{ 1, 2, 3 };
    try testing.expectEqual(6, (try callBind(t, obj, "sum", .{rt.Slice(u32).init(&xs)}, u32))[0]);
    try testing.expectEqual(rt.Opt(u32).init(5), (try callBind(t, obj, "half", .{rt.Opt(u32).init(10)}, rt.Opt(u32)))[0]);
    try testing.expectEqual(false, (try callBind(t, obj, "half", .{rt.Opt(u32).init(null)}, rt.Opt(u32)))[0].some);

    const good = try callBind(t, obj, "check", .{@as(i32, 4)}, Vec3);
    try testing.expectEqual(0, good[1]);
    try testing.expectEqual(4, good[0].x);
    try testing.expectEqual(3, (try callBind(t, obj, "check", .{@as(i32, -1)}, Vec3))[1]);
    try testing.expectEqual(0, (try callBind(t, obj, "ok", .{true}, u8))[1]);
    try testing.expectEqual(3, (try callBind(t, obj, "ok", .{false}, u8))[1]);

    try testing.expectEqual(Vec3{ .x = 6, .y = 2, .z = 3 }, (try callBind(t, obj, "thisVec", .{ Vec3{ .x = 1, .y = 2, .z = 3 }, @as(i32, 5) }, Vec3))[0]);
    try testing.expectEqual(1 + 2 + 3 + 4, (try callBind(t, obj, "std", .{ @as(i32, 1), @as(i64, 2), Pair{ .a = 3, .b = 4 } }, i64))[0]);
    const same = (try callBind(t, obj, "same", .{}, rt.AnyObject))[0];
    try testing.expectEqual(obj.data, same.data);
    try testing.expectEqual(25 * 26 / 2 + 1000, (try callBind(t, obj, "total", .{ huge(), @as(u32, 1000) }, u64))[0]);

    // No object, and no table entry
    try testing.expectEqual(rt.gone_code, (try callBind(t, .{}, "check", .{@as(i32, 1)}, Vec3))[1]);
    try testing.expectEqual(0, (try callBind(t, .{}, "add", .{ @as(i32, 1), @as(i64, 2), @as(u8, 3) }, i32))[0]);
}

/// A dispatch written the way a script host's would be: it only reads and writes memory.
const Fake = struct {
    calls: u32 = 0,

    fn read(comptime T: type, p: [*]u8) T {
        return std.mem.bytesToValue(T, p[0..@sizeOf(T)]);
    }

    fn write(value: anytype, out: [*]u8) void {
        @memcpy(out[0..@sizeOf(@TypeOf(value))], std.mem.asBytes(&value));
    }

    fn dispatch(ctx: usize, method: u32, args: []const [*]u8, out: [*]u8) u32 {
        const self: *Fake = @ptrFromInt(ctx);
        self.calls += 1;
        const names = [_][]const u8{ "add", "mix", "flip", "next", "len", "echo", "scale", "swap", "bigger", "sum", "half", "check", "ok", "thisVec", "std", "same", "total" };
        const name = names[method];
        if (std.mem.eql(u8, name, "add")) write(read(i32, args[0]) + @as(i32, @intCast(read(i64, args[1]))) + read(u8, args[2]), out);
        if (std.mem.eql(u8, name, "mix")) write(read(f32, args[0]) + read(f64, args[1]) + @as(f64, @floatFromInt(read(i32, args[2]))) + read(f32, args[3]), out);
        if (std.mem.eql(u8, name, "flip")) write(!read(bool, args[0]), out);
        if (std.mem.eql(u8, name, "next")) write(read(u8, args[0]) + 1, out);
        if (std.mem.eql(u8, name, "len")) write(read(rt.String, args[0]).len, out);
        if (std.mem.eql(u8, name, "echo")) write(read(rt.String, args[0]), out);
        if (std.mem.eql(u8, name, "scale")) {
            const v = read(Vec3, args[0]);
            const by = read(f32, args[1]);
            write(Vec3{ .x = v.x * by, .y = v.y * by, .z = v.z * by }, out);
        }
        if (std.mem.eql(u8, name, "swap")) {
            const p = read(Pair, args[0]);
            write(Pair{ .a = p.b, .b = p.a }, out);
        }
        if (std.mem.eql(u8, name, "bigger")) {
            const b = read(Big, args[0]);
            const by = read(u64, args[1]);
            write(Big{ .a = b.a + by, .b = b.b + by, .c = b.c + by }, out);
        }
        if (std.mem.eql(u8, name, "sum")) {
            var n: u32 = 0;
            for (read(rt.Slice(u32), args[0]).get()) |x| n += x;
            write(n, out);
        }
        if (std.mem.eql(u8, name, "half")) write(rt.Opt(u32).init(if (read(rt.Opt(u32), args[0]).get()) |v| v / 2 else null), out);
        if (std.mem.eql(u8, name, "check")) {
            const x = read(i32, args[0]);
            if (x < 0) return 3;
            write(Vec3{ .x = @floatFromInt(x), .y = 0, .z = 0 }, out);
        }
        if (std.mem.eql(u8, name, "ok")) return if (read(bool, args[0])) 0 else 3;
        if (std.mem.eql(u8, name, "thisVec")) {
            const v = read(Vec3, args[0]);
            write(Vec3{ .x = v.x + @as(f32, @floatFromInt(read(i32, args[1]))), .y = v.y, .z = v.z }, out);
        }
        if (std.mem.eql(u8, name, "std")) {
            const p = read(Pair, args[2]);
            write(@as(i64, read(i32, args[0])) + read(i64, args[1]) + p.a + p.b, out);
        }
        if (std.mem.eql(u8, name, "same")) write(rt.AnyObject{ .data = 7, .table = null }, out);
        if (std.mem.eql(u8, name, "total")) {
            var n: u64 = read(u32, args[1]);
            for (read(Huge, args[0]).parts) |p| n += p;
            write(n, out);
        }
        return 0;
    }
};

test "Zig calls bind's tables like its own" {
    const t = try runtimeTrait();
    var fake: Fake = .{};
    const any = try bind.implement(rt.host(), t, @intFromPtr(&fake), Fake.dispatch, null);
    const obj = any.as(rt.Object(Kitchen));

    try testing.expectEqual(6, obj.add(1, 2, 3));
    try testing.expectEqual(1.5 + 2.25 + 3 + 0.5, obj.mix(1.5, 2.25, 3, 0.5));
    try testing.expectEqual(false, obj.flip(true));
    try testing.expectEqual(Mode.two, obj.next(.one));
    try testing.expectEqual(5, obj.len("hello"));
    try testing.expectEqualStrings("hi", obj.echo("hi"));
    try testing.expectEqual(Vec3{ .x = 2, .y = 4, .z = 6 }, obj.scale(.{ .x = 1, .y = 2, .z = 3 }, 2));
    try testing.expectEqual(Pair{ .a = 2, .b = 1 }, obj.swap(.{ .a = 1, .b = 2 }));
    try testing.expectEqual(Big{ .a = 11, .b = 12, .c = 13 }, obj.bigger(.{ .a = 1, .b = 2, .c = 3 }, 10));
    const xs = [_]u32{ 1, 2, 3 };
    try testing.expectEqual(6, obj.sum(&xs));
    try testing.expectEqual(5, obj.half(10).?);
    try testing.expectEqual(null, obj.half(null));
    try testing.expectEqual(4, (try obj.check(4)).x);
    try testing.expectError(error.Bad, obj.check(-1));
    try obj.ok(true);
    try testing.expectError(error.Bad, obj.ok(false));
    try testing.expectEqual(Vec3{ .x = 6, .y = 2, .z = 3 }, obj.thisVec(.{ .x = 1, .y = 2, .z = 3 }, 5));
    try testing.expectEqual(10, obj.std(1, 2, .{ .a = 3, .b = 4 }));
    try testing.expectEqual(7, obj.same().data);
    try testing.expectEqual(25 * 26 / 2 + 1000, obj.total(huge(), 1000));
    // half, check and ok twice each
    try testing.expectEqual(20, fake.calls);
}

test "bind's tables have owners like any other" {
    const t = try runtimeTrait();
    var fake: Fake = .{};
    const o = try rt.host().owner("script");
    const obj = (try bind.implement(rt.host(), t, @intFromPtr(&fake), Fake.dispatch, o)).as(rt.Object(Kitchen));
    try testing.expectEqual(6, obj.add(1, 2, 3));
    o.close();
    try testing.expectEqual(0, obj.add(1, 2, 3));
    try testing.expectError(error.Gone, obj.check(1));
    try testing.expectEqual(1, fake.calls);
}

const Plain = struct {
    fn scale(v: Vec3, by: f32) callconv(.c) Vec3 {
        return .{ .x = v.x * by, .y = v.y * by, .z = v.z * by };
    }

    fn add(a: i32, b: i64, c: u8) callconv(.c) i32 {
        return a + @as(i32, @intCast(b)) + c;
    }

    var record: bind.FnRecord = undefined;

    fn find() *const bind.FnRecord {
        return &record;
    }

    /// Adds 100 to whatever `add` would.
    fn dispatch(_: usize, method: u32, args: []const [*]u8, value: [*]u8) u32 {
        std.debug.assert(method == 0);
        const a = std.mem.bytesToValue(i32, args[0][0..4]);
        const b = std.mem.bytesToValue(i64, args[1][0..8]);
        const c = args[2][0];
        const out = add(a, b, c) + 100;
        @memcpy(value[0..4], std.mem.asBytes(&out));
        return 0;
    }
};

test "plain functions from a signature parsed while running: called, and detoured" {
    var diag: salamander_schema.Diagnostic = .{};
    var parsed = try salamander_schema.parseSignature(testing.allocator, source, "fn Vec3 (Vec3 v, f32 by)", .{}, &diag);
    defer parsed.deinit();
    const s = parsed.schema;
    const scale = try bind.Function.init(rt.host(), s, s.findType(salamander_schema.signature_name).?.kind.func);
    var v: Vec3 = .{ .x = 1, .y = 2, .z = 3 };
    var by: f32 = 2;
    var out: Vec3 = undefined;
    _ = bind.callAt(scale, @intFromPtr(&Plain.scale), &.{ std.mem.asBytes(&v), std.mem.asBytes(&by) }, std.mem.asBytes(&out));
    try testing.expectEqual(Vec3{ .x = 2, .y = 4, .z = 6 }, out);

    var p2 = try salamander_schema.parseSignature(testing.allocator, source, "fn i32 (i32 a, i64 b, u8 c);", .{}, null);
    defer p2.deinit();
    const add = try bind.Function.init(rt.host(), p2.schema, p2.schema.findType(salamander_schema.signature_name).?.kind.func);
    Plain.record = .{ .function = add, .ctx = 0, .dispatch = Plain.dispatch };
    const detoured: *const fn (i32, i64, u8) callconv(.c) i32 = @ptrFromInt(bind.Detour(Plain.find).address());
    try testing.expectEqual(Plain.add(1, 2, 3) + 100, detoured(1, 2, 3));

    // Functions of their own, each with its own ctx, like a host giving code for declared ones
    const Own = struct {
        fn dispatch(ctx: usize, _: u32, args: []const [*]u8, value: [*]u8) u32 {
            const sum = std.mem.bytesToValue(i32, args[0][0..4]) + @as(i32, @intCast(ctx));
            @memcpy(value[0..4], std.mem.asBytes(&sum));
            return 0;
        }
    };
    const plus_one: *const fn (i32, i64, u8) callconv(.c) i32 = @ptrFromInt(try bind.function(add, 1, Own.dispatch));
    const plus_two: *const fn (i32, i64, u8) callconv(.c) i32 = @ptrFromInt(try bind.function(add, 2, Own.dispatch));
    try testing.expectEqual(11, plus_one(10, 0, 0));
    try testing.expectEqual(12, plus_two(10, 0, 0));

    // What's wrong points into the signature
    try testing.expectError(error.InvalidSchema, salamander_schema.parseSignature(testing.allocator, source, "fn Nope (u32 a)", .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "Nope") != null);
    try testing.expectError(error.NotASignature, salamander_schema.parseSignature(testing.allocator, source, "u32 a", .{}, null));
}

test "a thiscall signature on x86" {
    if (@import("builtin").cpu.arch != .x86) return error.SkipZigTest;
    const T = struct {
        fn method(self: usize, x: i32) callconv(.{ .x86_thiscall = .{} }) i32 {
            return @as(i32, @intCast(self)) * 10 + x;
        }
    };
    var parsed = try salamander_schema.parseSignature(testing.allocator, source, "[Thiscall] fn i32 (usize self, i32 x)", .{}, null);
    defer parsed.deinit();
    const f = try bind.Function.init(rt.host(), parsed.schema, parsed.schema.findType(salamander_schema.signature_name).?.kind.func);
    var self: usize = 4;
    var x: i32 = 2;
    var out: i32 = 0;
    _ = bind.callAt(f, @intFromPtr(&T.method), &.{ std.mem.asBytes(&self), std.mem.asBytes(&x) }, std.mem.asBytes(&out));
    try testing.expectEqual(42, out);
}
