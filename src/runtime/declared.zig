//! How generated Zig finds existing code a schema declares, like a game's functions found by signature.
//! Each binary asks its own locator, set by whatever loads it. Addresses are found once, then kept.

const std = @import("std");

pub const Locator = struct {
    ctx: ?*anyopaque = null,
    /// Where `name` is, like `spawn`, `Player.heal`, `Player.local`, or `Player` for its vtable.
    address: *const fn (ctx: ?*anyopaque, name: []const u8) anyerror!usize,
};

var locator: ?Locator = null;

pub fn setLocator(l: ?Locator) void {
    locator = l;
}

/// Asks every time. `Found` keeps it.
pub fn address(name: []const u8) anyerror!usize {
    const l = locator orelse return error.NoLocator;
    return l.address(l.ctx, name);
}

/// `name`'s address, found once. A failure's kept too.
pub fn Found(comptime name: []const u8) type {
    return struct {
        var found: std.atomic.Value(usize) = .init(0);
        var failure: std.atomic.Value(@TypeOf(@intFromError(error.NotFound))) = .init(0);

        pub fn get() anyerror!usize {
            const have = found.load(.acquire);
            if (have != 0) return have;
            const failed = failure.load(.acquire);
            if (failed != 0) return @errorFromInt(failed);
            // Two threads might both look, but they find the same thing
            const at = address(name) catch |err| {
                failure.store(@intFromError(err), .release);
                return err;
            };
            found.store(at, .release);
            return at;
        }
    };
}

/// Calling a function that wasn't found can't do anything sensible.
pub fn missing(name: []const u8, err: anyerror) noreturn {
    std.debug.panic("salamander: called {s}, which wasn't found ({t})", .{ name, err });
}

/// Slot `slot` of the vtable at the start of `object`.
pub fn virtualAt(object: *const anyopaque, slot: usize) usize {
    const table: *const [*]const usize = @ptrCast(@alignCast(object));
    return table.*[slot];
}

test "found once, failures kept" {
    const Fake = struct {
        var asked: u32 = 0;
        fn find(_: ?*anyopaque, name: []const u8) anyerror!usize {
            asked += 1;
            if (std.mem.eql(u8, name, "here")) return 0x1234;
            return error.NotFound;
        }
    };
    setLocator(.{ .address = Fake.find });
    defer setLocator(null);
    try std.testing.expectEqual(0x1234, try Found("here").get());
    try std.testing.expectEqual(0x1234, try Found("here").get());
    try std.testing.expectError(error.NotFound, Found("gone").get());
    try std.testing.expectError(error.NotFound, Found("gone").get());
    try std.testing.expectEqual(2, Fake.asked);
    var object: [2]usize = .{ 0, 0 };
    const table = [_]usize{ 7, 9 };
    object[0] = @intFromPtr(&table);
    try std.testing.expectEqual(9, virtualAt(&object, 1));
}
