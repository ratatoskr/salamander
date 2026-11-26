//! The host's side of the runtime, `core.Host`, so plugins in any binary or language share it.
//! A plugin gets the host's object when it loads and calls `setHost`. Without one a binary uses its own `Local`.

const std = @import("std");

const rt = @import("root.zig");
const Owner = rt.Owner;
const core = rt.core;

var current: ?Host = null;

/// The one this binary uses.
pub fn host() Host {
    return current orelse rt.Local.default().host();
}

/// What a plugin does first, with what the host gave it.
pub fn setHost(h: Host) void {
    current = h;
}

pub const ProvideError = error{ OutOfMemory, Taken, NoOwner };

fn ownerOf(o: ?*Owner) ?*core.Owner {
    return @ptrCast(o);
}

fn infoPtr(comptime Desc: type) *core.Info {
    return @ptrCast(@constCast(rt.infoOf(Desc)));
}

/// `core.Host` with Zig's types.
pub const Host = extern struct {
    const Self = @This();

    data: usize = 0,
    table: ?*const anyopaque = null,

    pub const salamander = core.Host.salamander;

    pub fn raw(self: Self) core.Host {
        return .{ .data = self.data, .table = self.table };
    }

    pub fn keep(self: Self, comptime T: type, n: usize) error{OutOfMemory}![]T {
        const p = self.raw().keep(@sizeOf(T) * n, @alignOf(T)) orelse return error.OutOfMemory;
        const many: [*]T = @ptrCast(@alignCast(p));
        return many[0..n];
    }

    /// The name's copied.
    pub fn owner(self: Self, name: []const u8) error{OutOfMemory}!*Owner {
        return @ptrCast(@alignCast(self.raw().owner(name) orelse return error.OutOfMemory));
    }

    /// `obj` with the host's copy of its table, which stops calling into it once `o` closes. An existing owner is kept.
    pub fn own(self: Self, obj: anytype, o: ?*Owner) error{OutOfMemory}!@TypeOf(obj) {
        const out = self.raw().adopt(.of(obj), ownerOf(o));
        if (out.table == null) return error.OutOfMemory;
        return out.as(@TypeOf(obj));
    }

    /// Just the table, for `Desc`'s.
    pub fn adopt(self: Self, comptime Desc: type, table: *const rt.Table(Desc), o: ?*Owner) error{OutOfMemory}!*const rt.Table(Desc) {
        const out = self.raw().adopt(.{ .table = table }, ownerOf(o));
        return @ptrCast(@alignCast(out.table orelse return error.OutOfMemory));
    }

    /// `obj`, maybe another version of `Desc`, laid out for this binary's. No table across ABIs.
    pub fn adapt(self: Self, comptime Desc: type, obj: anytype) rt.Object(Desc) {
        if (obj.table == null) return .{};
        return self.raw().adapt(.of(obj), infoPtr(Desc)).as(rt.Object(Desc));
    }

    /// A pending promise for a value `size` bytes big, and what settles it.
    pub fn promise(self: Self, size: usize) error{OutOfMemory}!struct { core.Promise, core.Resolver } {
        var resolver: core.Resolver = .{};
        const p = self.raw().promise(size, &resolver);
        if (p.table == null) return error.OutOfMemory;
        return .{ p, resolver };
    }

    /// Findable as `name` till withdrawn or its owner closes. Its table needs an owner, so the host never points at a gone plugin.
    pub fn provide(self: Self, name: []const u8, major: u32, obj: anytype) ProvideError!void {
        if (obj.table == null) return;
        return switch (self.raw().provide(name, major, .of(obj))) {
            0 => {},
            1 => error.Taken,
            3 => error.NoOwner,
            else => error.OutOfMemory,
        };
    }

    pub fn withdraw(self: Self, name: []const u8, major: u32) void {
        self.raw().withdraw(name, major);
    }

    /// Null if there's nothing live by that name and major. Methods it doesn't have give zero or `Unsupported`.
    pub fn get(self: Self, comptime Desc: type, name: []const u8, major: u32) ?rt.Object(Desc) {
        const out = self.raw().get(name, major, infoPtr(Desc));
        if (out.table == null) return null;
        return out.as(rt.Object(Desc));
    }

    /// Done holding `obj`, from a `keep` parameter or a return. Does nothing unless its table's maker asked with `releasable`.
    pub fn release(self: Self, obj: anytype) void {
        if (obj.table == null) return;
        self.raw().release(.of(obj));
    }

    /// Has `release` call `hook` with the data of objects whose tables `o` guards, while it's open.
    pub fn releasable(self: Self, o: *Owner, hook: core.Release) error{OutOfMemory}!void {
        if (!self.raw().releasable(@ptrCast(o), hook)) return error.OutOfMemory;
    }

    /// Says why this thread's call fails with `err`, for its caller to show. Gives `err` back.
    pub fn explain(self: Self, err: anytype, comptime fmt: []const u8, args: anytype) @TypeOf(err) {
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
            @memcpy(buf[buf.len - 3 ..], "...");
            break :blk &buf;
        };
        self.raw().explain(@errorName(err), text);
        return err;
    }

    /// Why this thread's last call failed with the error called `name`, if it said. Asking clears it.
    pub fn explanation(self: Self, name: []const u8) []const u8 {
        return self.raw().explanation(name);
    }

    pub fn queue(self: Self) error{OutOfMemory}!rt.Queue {
        const q = self.raw().queue();
        if (q.table == null) return error.OutOfMemory;
        return .{ .data = q.data, .table = q.table };
    }

    /// Settles once it's provided.
    pub fn wait(self: Self, comptime Desc: type, name: []const u8, major: u32) error{OutOfMemory}!rt.Promise(rt.Object(Desc), null) {
        const pair = try rt.Promise(rt.Object(Desc), null).make();
        if (!self.raw().wait(name, major, infoPtr(Desc), .{ .data = pair.resolver.data, .table = pair.resolver.table })) {
            pair.resolver.drop();
            pair.promise.cancel();
            return error.OutOfMemory;
        }
        return pair.promise;
    }
};
