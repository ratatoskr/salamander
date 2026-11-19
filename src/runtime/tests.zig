const std = @import("std");
const testing = std.testing;

const rt = @import("root.zig");

const Vec = extern struct { x: f32, y: f32 };

/// Written the way the generator writes one.
const Shape = struct {
    pub const salamander = struct {
        pub const name = "Shape";
        pub const hash: u64 = 0x1234;
        pub const methods: []const rt.Method = &.{
            .{ .name = "area", .Fn = fn () f32 },
            .{ .name = "grow", .Fn = fn (by: f32) void, .conv = .thiscall },
            .{ .name = "label", .Fn = fn (prefix: []const u8) []const u8 },
            .{ .name = "find", .Fn = fn (limit: ?u32) ?u32 },
            .{ .name = "load", .Fn = fn (path: []const u8) (error{ NotFound, Gone, Unsupported })!Vec, .Errors = LoadError },
            .{ .name = "check", .Fn = fn () (error{ NotFound, Gone, Unsupported })!void, .Errors = LoadError },
            .{ .name = "parent", .Fn = fn () ?rt.Object(Shape) },
            .{ .name = "each", .Fn = fn (f: Visit) u32 },
            .{ .name = "count", .Fn = fn () u32, .static = true, .conv = .winapi },
        };
    };
};

/// What `error LoadError { NotFound, Corrupt = 7 }` crosses as.
const LoadError = enum(u32) { NotFound = 1, Corrupt = 7, _ };

const Visit = rt.Fn(.{ .name = "visit", .Fn = fn (n: u32) bool });

const Square = struct {
    side: f32,
    label_buf: [16]u8 = undefined,
    up: ?*Square = null,

    pub fn area(self: *Square) f32 {
        return self.side * self.side;
    }

    pub fn grow(self: *Square, by: f32) void {
        self.side += by;
    }

    pub fn label(self: *Square, prefix: []const u8) []const u8 {
        return std.fmt.bufPrint(&self.label_buf, "{s}{d}", .{ prefix, self.side }) catch "";
    }

    pub fn find(_: *Square, limit: ?u32) ?u32 {
        return if (limit) |l| l * 2 else null;
    }

    pub fn load(self: *Square, path: []const u8) !Vec {
        if (std.mem.eql(u8, path, "none")) return error.NotFound;
        if (std.mem.eql(u8, path, "odd")) return error.Weird;
        return .{ .x = self.side, .y = @floatFromInt(path.len) };
    }

    pub fn check(self: *Square) !void {
        if (self.side < 0) return error.NotFound;
    }

    pub fn parent(self: *Square) ?rt.Object(Shape) {
        const up = self.up orelse return null;
        return .init(up, table);
    }

    pub fn each(_: *Square, f: Visit) u32 {
        var n: u32 = 0;
        while (n < 10 and f.invoke(.{n})) n += 1;
        return n;
    }

    pub fn count() u32 {
        return 42;
    }

    const table = rt.implement(Shape, Square);
};

test "calls through a table" {
    var big: Square = .{ .side = 10 };
    var sq: Square = .{ .side = 2, .up = &big };
    const obj: rt.Object(Shape) = .init(&sq, Square.table);

    try testing.expectEqual(4, obj.call(.area, .{}));
    obj.call(.grow, .{1});
    try testing.expectEqual(3, sq.side);
    try testing.expectEqualStrings("side 3", obj.call(.label, .{"side "}));
    try testing.expectEqual(10, obj.call(.find, .{5}).?);
    try testing.expectEqual(null, obj.call(.find, .{null}));
    try testing.expectEqual(Vec{ .x = 3, .y = 4 }, try obj.call(.load, .{"abcd"}));
    try testing.expectError(error.NotFound, obj.call(.load, .{"none"}));
    // Errors it doesn't know cross as Unsupported
    try testing.expectError(error.Unsupported, obj.call(.load, .{"odd"}));
    try obj.call(.check, .{});
    try testing.expectEqual(100, obj.call(.parent, .{}).?.call(.area, .{}));
    try testing.expectEqual(null, rt.Object(Shape).init(&big, Square.table).call(.parent, .{}));
    try testing.expectEqual(42, obj.call(.count, .{}));
    try testing.expectEqual(0x1234, Square.table.salamander_info.hash);
}

test "function values" {
    var sq: Square = .{ .side = 1 };
    const obj: rt.Object(Shape) = .init(&sq, Square.table);
    var limit: u32 = 4;
    const visit: Visit = .init(&limit, struct {
        fn f(max: *u32, n: u32) bool {
            return n < max.*;
        }
    }.f);
    try testing.expectEqual(4, obj.call(.each, .{visit}));
}

test "no object gives zero or Gone" {
    const none: rt.Object(Shape) = .{};
    try testing.expectEqual(0, none.call(.area, .{}));
    try testing.expectEqual(null, none.call(.parent, .{}));
    try testing.expectError(error.Gone, none.call(.load, .{"x"}));
    try testing.expectError(error.Gone, none.call(.check, .{}));
    const no_fn: Visit = .{};
    try testing.expectEqual(false, no_fn.invoke(.{1}));
}

test "errors cross as their enum" {
    try testing.expectEqual(7, rt.lowerError(LoadError, error.Corrupt));
    try testing.expectEqual(rt.gone_code, rt.lowerError(LoadError, error.Gone));
    try testing.expectEqual(rt.unsupported_code, rt.lowerError(LoadError, error.Weird));
    const E = error{ NotFound, Corrupt, Gone, Unsupported };
    try testing.expectEqual(error.NotFound, rt.liftError(E, LoadError, 1));
    // A newer impl's error is one this side can't name
    try testing.expectEqual(error.Unsupported, rt.liftError(E, LoadError, 3));
    try testing.expectEqual(error.Gone, rt.liftError(E, null, rt.gone_code));
}

test "an owner's objects stop when it closes" {
    const owner = try rt.host().owner("plugin");
    var sq: Square = .{ .side = 2 };
    const obj: rt.Object(Shape) = .init(&sq, try rt.implementOwned(Shape, Square, owner));
    try testing.expectEqual(4, obj.call(.area, .{}));
    var limit: u32 = 2;
    const visit = try Visit.owned(owner, &limit, struct {
        fn f(max: *u32, n: u32) bool {
            return n < max.*;
        }
    }.f);
    try testing.expectEqual(2, obj.call(.each, .{visit}));

    owner.close();
    try testing.expectEqual(0, obj.call(.area, .{}));
    try testing.expectError(error.Gone, obj.call(.load, .{"x"}));
    try testing.expectEqual(false, visit.invoke(.{0}));
    // The same impl's static table has no owner, so it still works
    try testing.expectEqual(4, rt.Object(Shape).init(&sq, Square.table).call(.area, .{}));
}

test "closing from inside a call" {
    const Closer = struct {
        var owner: *rt.Owner = undefined;
        fn close(_: *u32, _: u32) bool {
            owner.close();
            return true;
        }
    };
    Closer.owner = try rt.host().owner("self");
    var n: u32 = 0;
    const visit = try Visit.owned(Closer.owner, &n, Closer.close);
    try testing.expect(visit.invoke(.{0}));
    try testing.expect(!visit.invoke(.{0}));
}

test "shapes cross without copying" {
    try testing.expectEqual(rt.String, rt.Abi([]const u8));
    try testing.expectEqual(?*Vec, rt.Abi(?*Vec));
    try testing.expectEqual(rt.Opt(u32), rt.Abi(?u32));
    try testing.expectEqual(rt.Object(Shape), rt.Abi(?rt.Object(Shape)));
    try testing.expectEqual(Vec, rt.Abi(Vec));
    try testing.expectEqual(2 * @sizeOf(usize), @sizeOf(rt.Object(Shape)));
    try testing.expectEqual(@sizeOf(usize), @offsetOf(rt.Table(Shape), "salamander_owner"));
    try testing.expectEqual(2 * @sizeOf(usize), @offsetOf(rt.Table(Shape), "area"));
}
