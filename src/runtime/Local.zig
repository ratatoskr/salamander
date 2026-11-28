//! The host, what `Host` calls into. A host program has one and hands `host()` to each plugin.
//! Everything's kept for good and plugin tables are copied in, so a binary can go once its owner's drained.

const Local = @This();

const std = @import("std");

const rt = @import("root.zig");
const Owner = rt.Owner;
const promise_file = @import("promise.zig");
const core = rt.core;
const Resolver = core.Resolver;

/// Thread-safe, so `keep` doesn't take the lock.
arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
lock: SpinLock = .{},
entries: std.ArrayList(Entry) = .empty,
waiters: std.ArrayList(Waiter) = .empty,
adapted: std.ArrayList(Adapted) = .empty,
hooks: std.ArrayList(Hook) = .empty,

const Entry = struct {
    name: []const u8,
    major: u32,
    data: usize,
    /// The host's copy.
    table: *const anyopaque,
    withdrawn: bool = false,

    fn live(e: *const Entry) bool {
        if (e.withdrawn) return false;
        const o = rt.headerOf(e.table).owner orelse return true;
        return o.isOpen();
    }
};

const Waiter = struct {
    name: []const u8,
    major: u32,
    want: *const rt.Info,
    resolver: Resolver,
};

const Adapted = struct {
    from: *const anyopaque,
    want: *const rt.Info,
    table: *const anyopaque,
};

const Hook = struct {
    owner: *Owner,
    hook: core.Release,
};

/// Held briefly, and never while calling out.
const SpinLock = struct {
    held: std.atomic.Value(u32) = .init(0),

    fn lock(l: *SpinLock) void {
        while (l.held.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.Thread.yield() catch {};
    }

    fn unlock(l: *SpinLock) void {
        l.held.store(0, .release);
    }
};

/// What a binary uses when nobody gave it a host, so a host program needs nothing else.
pub fn default() *Local {
    return &struct {
        var instance: Local = .{};
    }.instance;
}

pub fn host(l: *Local) rt.Host {
    return .{ .data = @intFromPtr(l), .table = rt.implement(core.Host, Local) };
}

fn allocator(l: *Local) std.mem.Allocator {
    return l.arena.allocator();
}

fn words(table: *const anyopaque) [*]const usize {
    return @ptrCast(@alignCast(table));
}

fn infoOf(want: *core.Info) *const rt.Info {
    return @ptrCast(@alignCast(want));
}

/// The host's copy, names and all, so nothing points into the binary that made it.
fn copyInfo(l: *Local, info: *const rt.Info) ?*const rt.Info {
    const a = l.allocator();
    const n = info.methods.len;
    const methods = a.alloc(rt.MethodInfo, n) catch return null;
    for (methods, info.methods.get()) |*to, from| to.* = .{ .name = rt.String.init(a.dupe(u8, from.name.get()) catch return null), .sig = from.sig };
    const copy = a.create(rt.Info) catch return null;
    copy.* = .{ .hash = info.hash, .abi = info.abi, .name = rt.String.init(a.dupe(u8, info.name.get()) catch return null), .methods = .{ .ptr = methods.ptr, .len = n } };
    return copy;
}

/// Copies a table and its info so only its code points into its binary. An existing owner is kept.
fn adoptTable(l: *Local, table: *const anyopaque, o: ?*Owner) ?*const anyopaque {
    const header = rt.headerOf(table);
    const info = header.info;
    const n = info.methods.len;
    const out = l.allocator().alloc(usize, n + 2) catch return null;
    @memcpy(out, words(table)[0 .. n + 2]);
    out[0] = @intFromPtr(l.copyInfo(info) orelse return null);
    out[1] = @intFromPtr(header.owner orelse o);
    return out.ptr;
}

/// Same version gives the table back, else methods match by name and signature, the rest null. Made once per pair, null across ABIs.
fn adaptTable(l: *Local, table: *const anyopaque, want: *const rt.Info) ?*const anyopaque {
    const have = rt.headerOf(table).info;
    if (have.abi != want.abi) return null;
    if (have.hash == want.hash) return table;
    l.lock.lock();
    defer l.lock.unlock();
    for (l.adapted.items) |x| if (x.from == table and x.want == want) return x.table;

    const n = want.methods.len;
    const out = l.allocator().alloc(usize, n + 2) catch return null;
    @memset(out, 0);
    out[0] = @intFromPtr(l.copyInfo(want) orelse return null);
    out[1] = @intFromPtr(rt.headerOf(table).owner);
    for (want.methods.get(), 0..) |w, i| for (have.methods.get(), 0..) |h, j| {
        if (w.sig == h.sig and std.mem.eql(u8, w.name.get(), h.name.get())) {
            out[i + 2] = words(table)[j + 2];
            break;
        }
    };
    l.adapted.append(l.allocator(), .{ .from = table, .want = want, .table = out.ptr }) catch return null;
    return out.ptr;
}

fn find(l: *Local, name: []const u8, major: u32) ?*Entry {
    for (l.entries.items) |*e| if (e.major == major and std.mem.eql(u8, e.name, name) and e.live()) return e;
    return null;
}

fn settle(l: *Local, resolver: Resolver, data: usize, table: *const anyopaque, want: *const rt.Info) void {
    const t = l.adaptTable(table, want) orelse return resolver.drop();
    var found: rt.AnyObject = .{ .data = data, .table = t };
    resolver.resolve(&found);
}

// The `Host` trait

pub fn keep(l: *Local, size: usize, alignment: usize) ?*anyopaque {
    return l.allocator().rawAlloc(@max(size, 1), .fromByteUnits(alignment), @returnAddress());
}

pub fn owner(l: *Local, name: []const u8) ?*core.Owner {
    const a = l.allocator();
    const o = a.create(Owner) catch return null;
    o.* = .init(a.dupe(u8, name) catch return null);
    return @ptrCast(o);
}

pub fn adopt(l: *Local, obj: rt.AnyObject, o: ?*core.Owner) rt.AnyObject {
    const table = obj.table orelse return .{};
    return .{ .data = obj.data, .table = l.adoptTable(table, @ptrCast(@alignCast(o))) };
}

pub fn adapt(l: *Local, obj: rt.AnyObject, want: *core.Info) rt.AnyObject {
    const table = obj.table orelse return .{};
    return .{ .data = obj.data, .table = l.adaptTable(table, infoOf(want)) };
}

pub fn promise(_: *Local, size: usize, resolver: *core.Resolver) core.Promise {
    return promise_file.makeFuture(size, resolver);
}

pub fn provide(l: *Local, name: []const u8, major: u32, obj: rt.AnyObject) u32 {
    const table = obj.table orelse return 0;
    // Without an owner the host would point at the plugin's code after it's gone
    const o = rt.headerOf(table).owner orelse return 3;
    const copy = l.adoptTable(table, o) orelse return 2;
    var ready: std.ArrayList(Waiter) = .empty;
    defer ready.deinit(std.heap.smp_allocator);
    {
        l.lock.lock();
        defer l.lock.unlock();
        if (l.find(name, major) != null) return 1;
        const a = l.allocator();
        l.entries.append(a, .{ .name = a.dupe(u8, name) catch return 2, .major = major, .data = obj.data, .table = copy }) catch return 2;
        var i: usize = 0;
        while (i < l.waiters.items.len) {
            const w = l.waiters.items[i];
            if (w.major == major and std.mem.eql(u8, w.name, name)) {
                ready.append(std.heap.smp_allocator, w) catch return 2;
                _ = l.waiters.swapRemove(i);
            } else i += 1;
        }
    }
    // Outside the lock, since waiters' callbacks can come back here
    for (ready.items) |w| l.settle(w.resolver, obj.data, copy, w.want);
    return 0;
}

pub fn withdraw(l: *Local, name: []const u8, major: u32) void {
    l.lock.lock();
    defer l.lock.unlock();
    if (l.find(name, major)) |e| e.withdrawn = true;
}

pub fn get(l: *Local, name: []const u8, major: u32, want: *core.Info) rt.AnyObject {
    const e = blk: {
        l.lock.lock();
        defer l.lock.unlock();
        break :blk (l.find(name, major) orelse return .{}).*;
    };
    return .{ .data = e.data, .table = l.adaptTable(e.table, infoOf(want)) };
}

pub fn wait(l: *Local, name: []const u8, major: u32, want: *core.Info, resolver: Resolver) bool {
    l.lock.lock();
    if (l.find(name, major)) |e| {
        const found = e.*;
        l.lock.unlock();
        l.settle(resolver, found.data, found.table, infoOf(want));
        return true;
    }
    defer l.lock.unlock();
    const a = l.allocator();
    l.waiters.append(a, .{ .name = a.dupe(u8, name) catch return false, .major = major, .want = infoOf(want), .resolver = resolver }) catch return false;
    return true;
}

pub fn release(l: *Local, obj: rt.AnyObject) void {
    // Copies keep their owner, so this finds the maker through any of them
    const o = rt.headerOf(obj.table orelse return).owner orelse return;
    const hook = blk: {
        l.lock.lock();
        defer l.lock.unlock();
        for (l.hooks.items) |h| if (h.owner == o) break :blk h.hook;
        return;
    };
    // Guarded like a call, so the maker's never released into once it's drained
    if (!o.enter()) return;
    defer o.leave();
    hook.invoke(.{obj.data});
}

pub fn releasable(l: *Local, o: *core.Owner, hook: core.Release) bool {
    const guard: *Owner = @ptrCast(@alignCast(o));
    l.lock.lock();
    defer l.lock.unlock();
    // Ones for closed owners go, so owners made now and then don't pile up
    var i: usize = 0;
    while (i < l.hooks.items.len) {
        if (!l.hooks.items[i].owner.isOpen()) _ = l.hooks.swapRemove(i) else i += 1;
    }
    l.hooks.append(l.allocator(), .{ .owner = guard, .hook = hook }) catch return false;
    return true;
}

pub fn blob(_: *Local, size: usize) core.Blob {
    return rt.blobs.hostMake(size);
}

pub fn toJson(l: *Local, value: rt.Any) (core.JsonError || rt.Failure)!core.Blob {
    const info = value.type orelse return error.Unsupported;
    const text = rt.json.stringifyInfo(std.heap.smp_allocator, info, value.value orelse return error.Unsupported, .{}) catch |err| return switch (err) {
        error.OutOfMemory => l.failJson(error.Unsupported, "out of memory"),
        error.Unsupported => l.failJson(error.Unsupported, "it holds something with no JSON, like a pointer or object"),
    };
    defer std.heap.smp_allocator.free(text);
    return rt.blobs.copy(text) catch l.failJson(error.Unsupported, "out of memory");
}

pub fn fromJson(l: *Local, text: []const u8, info: *core.raw.TypeInfo) (core.JsonError || rt.Failure)!core.Blob {
    return rt.json.parseInfoBlob(std.heap.smp_allocator, info, text) catch |err| switch (err) {
        error.Invalid => error.Invalid,
        error.Mismatch => error.Mismatch,
        error.Unsupported => l.failJson(error.Unsupported, "it holds something with no JSON, like a pointer or object"),
        error.OutOfMemory => l.failJson(error.Unsupported, "out of memory"),
    };
}

fn failJson(l: *Local, err: anytype, message: []const u8) @TypeOf(err) {
    l.explain(@errorName(err), message);
    return err;
}

/// Per thread, in the host's binary. Set as a call fails, read as its error's shown.
threadlocal var explained_name: [64]u8 = undefined;
threadlocal var explained_name_len: usize = 0;
threadlocal var explained: [1024]u8 = undefined;
threadlocal var explained_len: usize = 0;
threadlocal var given: [1024]u8 = undefined;

pub fn explain(_: *Local, name: []const u8, message: []const u8) void {
    explained_name_len = @min(name.len, explained_name.len);
    @memcpy(explained_name[0..explained_name_len], name[0..explained_name_len]);
    explained_len = @min(message.len, explained.len);
    @memcpy(explained[0..explained_len], message[0..explained_len]);
}

pub fn explanation(_: *Local, name: []const u8) []const u8 {
    defer explained_len = 0;
    if (explained_len == 0 or !std.mem.eql(u8, name, explained_name[0..explained_name_len])) return "";
    @memcpy(given[0..explained_len], explained[0..explained_len]);
    return given[0..explained_len];
}

pub fn queue(l: *Local) core.Queue {
    const Q = @import("Queue.zig");
    const q = l.allocator().create(Q.Local) catch return .{};
    q.* = .{};
    return .{ .data = @intFromPtr(q), .table = rt.implement(core.Queue, Q.Local) };
}
const testing = std.testing;

fn Counter(comptime version: u64, comptime extra: bool) type {
    return struct {
        pub const salamander = struct {
            pub const name = "Counter";
            pub const hash: u64 = version;
            pub const methods: []const rt.Method = &[_]rt.Method{.{ .name = "next", .Fn = fn () u32 }} ++
                if (extra) &[_]rt.Method{.{ .name = "reset", .Fn = fn (u32) u32 }} else &[_]rt.Method{};
        };
    };
}

const V1 = Counter(1, false);
const V2 = Counter(2, true);

/// V2 with `reset` put first, like a method added in the middle.
const Reordered = struct {
    pub const salamander = struct {
        pub const name = "Counter";
        pub const hash: u64 = 3;
        pub const methods: []const rt.Method = &.{ .{ .name = "reset", .Fn = fn (u32) u32 }, .{ .name = "next", .Fn = fn () u32 } };
    };
};

test "an object from another version of its trait is called by method name" {
    var c: Count = .{};
    // Made by a newer binary, called by one built against V1
    const newer: rt.Object(V1) = .{ .data = @intFromPtr(&c), .table = rt.implement(Reordered, Count) };
    try testing.expectEqual(1, newer.call(.next, .{}));
    try testing.expectEqual(2, newer.call(.next, .{}));
    // One it doesn't have does nothing
    const older: rt.Object(V2) = .{ .data = @intFromPtr(&c), .table = rt.implement(V1, Count) };
    try testing.expectEqual(0, older.call(.reset, .{7}));
    try testing.expectEqual(3, older.call(.next, .{}));
}

const Count = struct {
    n: u32 = 0,

    pub fn next(self: *Count) u32 {
        self.n += 1;
        return self.n;
    }

    pub fn reset(self: *Count, to: u32) u32 {
        self.n = to;
        return to;
    }
};

fn owned(h: rt.Host, comptime V: type, c: *Count) !rt.Object(V) {
    return .init(c, try h.adopt(V, rt.implement(V, Count), try h.owner("test")));
}

test "explanations go with their error, once" {
    const h = rt.host();
    try testing.expectEqual(error.Broken, h.explain(error.Broken, "it's {s}", .{"bent"}));
    try testing.expectEqualStrings("", h.explanation("Other"));
    // Asking for another error cleared it
    try testing.expectEqualStrings("", h.explanation("Broken"));
    try testing.expectEqual(error.Broken, h.explain(error.Broken, "again", .{}));
    try testing.expectEqualStrings("again", h.explanation("Broken"));
    try testing.expectEqualStrings("", h.explanation("Broken"));
}

test "provided objects need an owner" {
    var l: Local = .{};
    const h = l.host();
    var c: Count = .{};
    try testing.expectError(error.NoOwner, h.provide("static", 1, rt.Object(V1).init(&c, rt.implement(V1, Count))));
}

test "tables from another ABI don't mix" {
    var l: Local = .{};
    const h = l.host();
    var c: Count = .{};
    const t = try h.adopt(V2, rt.implement(V2, Count), null);
    @constCast(t.salamander_info).abi += 1;
    try testing.expectEqual(null, h.adapt(V1, rt.Object(V2).init(&c, t)).table);
}

test "provide and get" {
    var l: Local = .{};
    const h = l.host();
    var c: Count = .{};
    try h.provide("counter", 1, try owned(h, V1, &c));
    try testing.expectEqual(1, h.get(V1, "counter", 1).?.call(.next, .{}));
    try testing.expectEqual(null, h.get(V1, "counter", 2));
    try testing.expectError(error.Taken, h.provide("counter", 1, try owned(h, V1, &c)));
    h.withdraw("counter", 1);
    try testing.expectEqual(null, h.get(V1, "counter", 1));
}

test "callers built against another version get what's there" {
    var l: Local = .{};
    const h = l.host();
    var c: Count = .{};
    try h.provide("new", 1, try owned(h, V2, &c));
    // An older caller sees its one method
    try testing.expectEqual(1, h.get(V1, "new", 1).?.call(.next, .{}));

    try h.provide("old", 1, try owned(h, V1, &c));
    const newer = h.get(V2, "old", 1).?;
    try testing.expectEqual(2, newer.call(.next, .{}));
    // A method the provider doesn't have gives zero
    try testing.expectEqual(0, newer.call(.reset, .{9}));
    try testing.expectEqual(2, c.n);
    // Made once
    try testing.expectEqual(newer.table, h.get(V2, "old", 1).?.table);
}

test "waiting for one that comes later" {
    var l: Local = .{};
    const h = l.host();
    const later = try h.wait(V1, "later", 1);
    const newer = try h.wait(V2, "later", 1);
    try testing.expectEqual(null, later.take());
    var c: Count = .{ .n = 10 };
    try h.provide("later", 1, try owned(h, V1, &c));
    try testing.expectEqual(11, (try later.wait()).call(.next, .{}));
    try testing.expectEqual(12, (try newer.wait()).call(.next, .{}));
    // Already there settles straight away
    try testing.expectEqual(13, (try (try h.wait(V1, "later", 1)).wait()).call(.next, .{}));
}

test "a closed owner's object is gone, and the name is free again" {
    var l: Local = .{};
    const h = l.host();
    const o = try h.owner("plugin");
    var c: Count = .{};
    try h.provide("svc", 1, rt.Object(V1).init(&c, try h.adopt(V1, rt.implement(V1, Count), o)));
    const held = h.get(V1, "svc", 1).?;
    o.drain();
    try testing.expectEqual(0, held.call(.next, .{}));
    try testing.expectEqual(null, h.get(V1, "svc", 1));
    try h.provide("svc", 1, try owned(h, V1, &c));
    try testing.expectEqual(1, h.get(V1, "svc", 1).?.call(.next, .{}));
}

test "adopting keeps the owner a table already has" {
    var l: Local = .{};
    const h = l.host();
    const first = try h.owner("maker");
    const later = try h.owner("holder");
    var c: Count = .{};
    const obj = rt.Object(V1).init(&c, try h.adopt(V1, rt.implement(V1, Count), first));
    const held = try h.own(obj, later);
    try testing.expectEqual(1, held.call(.next, .{}));
    first.drain();
    try testing.expectEqual(0, held.call(.next, .{}));
    try testing.expectEqual(1, c.n);
}

test "release finds the owner's hook, through copies" {
    var l: Local = .{};
    const h = l.host();
    const maker = try h.owner("maker");
    const Seen = struct {
        var last: usize = 0;
        var count: usize = 0;
        fn hook(_: *u8, data: usize) void {
            last = data;
            count += 1;
        }
    };
    var ctx: u8 = 0;
    try h.releasable(maker, .init(&ctx, Seen.hook));
    var c: Count = .{};
    const obj = rt.Object(V1).init(&c, try h.adopt(V1, rt.implement(V1, Count), maker));
    h.release(obj);
    try testing.expectEqual(@intFromPtr(&c), Seen.last);
    // Through a copy someone adopted, and one adapted to another version
    h.release(try h.own(obj, try h.owner("holder")));
    h.release(h.adapt(V2, obj));
    try testing.expectEqual(3, Seen.count);
    // Objects of other owners, or none
    h.release(try owned(h, V1, &c));
    h.release(rt.Object(V1).init(&c, rt.implement(V1, Count)));
    try testing.expectEqual(3, Seen.count);
    // Once the owner's closed its hook never runs, and it's dropped the next time one's added
    maker.drain();
    h.release(obj);
    try testing.expectEqual(3, Seen.count);
    try h.releasable(try h.owner("other"), .init(&ctx, Seen.hook));
    try testing.expectEqual(1, l.hooks.items.len);
}

test "adopted tables live in the host" {
    var l: Local = .{};
    const h = l.host();
    const o = try h.owner("plugin");
    const t = try h.adopt(V1, rt.implement(V1, Count), o);
    try testing.expect(t != rt.implement(V1, Count));
    try testing.expect(t.salamander_info != rt.infoOf(V1));
    try testing.expectEqualStrings("next", t.salamander_info.methods.get()[0].name.get());
    try testing.expectEqual(o, t.salamander_owner.?);
}
