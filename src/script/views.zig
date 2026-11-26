//! Live views of memory laid out like a schema's structs, for existing code like a game's.
//! Members read and write through the embedder's `Locator` when used, so they're never stale.

const std = @import("std");
const salamander_schema = @import("salamander_schema");

const memory = @import("memory.zig");

const Schema = salamander_schema.Schema;
const Ref = Schema.Ref;

/// A struct, union, bitfield or array.
pub const View = struct {
    schema: Schema,
    type: Ref,
    address: usize,
    /// For a `T[count]` array, where its count is. It has no items till `sized`.
    count: ?Place = null,

    /// Now its count's been read.
    pub fn sized(v: View, n: usize) View {
        return .{ .schema = v.schema, .type = .{ .array = v.type.array.sized(n) }, .address = v.address };
    }

    pub fn named(v: View) ?*const Schema.Type {
        return switch (v.type) {
            .named => |n| v.schema.findType(n),
            else => null,
        };
    }

    pub fn size(v: View) usize {
        return memory.shapeOf(v.schema, v.type).size;
    }
};

/// Read and written whole.
pub const Place = struct {
    type: Ref,
    address: usize,
};

pub const Bits = struct {
    address: usize,
    backing: Schema.Prim,
    bit: u16,
    bits: u16,
    member: Schema.Bits.Member,
};

pub const Member = union(enum) {
    /// Numbers, bools, enums, inline text and pointers to anything but structs.
    value: Place,
    /// To a struct or union. Reads as a view of it, or null.
    pointer: Place,
    /// Reads as a string.
    text: Place,
    bits: Bits,
    /// A struct, union, bitfield or array in place.
    view: View,
    /// `this` is the view unless it's static.
    method: Schema.Function,
    length: usize,
};

/// A `T[count]` array's count, read as more than this, is this.
pub const max_count = 1 << 20;

/// A field of `v` or its bases, a method, an index, or `length` for arrays.
pub fn member(v: View, name: []const u8) ?Member {
    const s = v.schema;
    switch (v.type) {
        .array => |a| {
            if (std.mem.eql(u8, name, "length")) return .{ .length = a.len };
            const i = std.fmt.parseInt(usize, name, 10) catch return null;
            if (i >= a.len) return null;
            return place(s, a.child.*, v.address + i * memory.shapeOf(s, a.child.*).size);
        },
        .named => |n| {
            const t = s.findType(n) orelse return null;
            switch (t.kind) {
                .@"struct", .@"union" => {
                    if (s.findField(t, name)) |f| {
                        if (f.type == .array) if (f.type.array.count) |len| if (s.findField(t, len)) |count|
                            return .{ .view = .{ .schema = s, .type = f.type, .address = v.address + f.offset, .count = .{ .type = count.type, .address = v.address + count.offset } } };
                        return place(s, f.type, v.address + f.offset);
                    }
                    var buf: [256]u8 = undefined;
                    const full = std.fmt.bufPrint(&buf, "{s}.{s}", .{ t.name, name }) catch return null;
                    if (s.findFunction(full)) |f| return .{ .method = f };
                    return null;
                },
                .bitfield => |bf| {
                    for (bf.members) |m| if (std.mem.eql(u8, m.name, name)) return .{ .bits = .{
                        .address = v.address,
                        .backing = bf.backing,
                        .bit = m.bit,
                        .bits = m.bits,
                        .member = m.type,
                    } };
                    return null;
                },
                else => return null,
            }
        },
        else => return null,
    }
}

pub fn place(s: Schema, r: Ref, address: usize) Member {
    switch (r) {
        .named => |n| if (s.findType(n)) |t| switch (t.kind) {
            .@"struct", .@"union", .bitfield => return .{ .view = .{ .schema = s, .type = r, .address = address } },
            else => {},
        },
        .array => |a| if (memory.isText(a) == null) return .{ .view = .{ .schema = s, .type = r, .address = address } },
        .pointer => |child| switch (child.*) {
            .prim => |p| if (p == .utf8 or p == .utf16) return .{ .text = .{ .type = r, .address = address } },
            .named => |n| if (s.findType(n)) |t| switch (t.kind) {
                .@"struct", .@"union" => return .{ .pointer = .{ .type = r, .address = address } },
                else => {},
            },
            .array => return .{ .pointer = .{ .type = r, .address = address } },
            else => {},
        },
        else => {},
    }
    return .{ .value = .{ .type = r, .address = address } };
}

/// Fields, or indices for arrays.
pub fn names(v: View, a: std.mem.Allocator, out: *std.ArrayList([]const u8)) error{OutOfMemory}!void {
    switch (v.type) {
        .array => |arr| for (0..arr.len) |i| try out.append(a, try std.fmt.allocPrint(a, "{d}", .{i})),
        .named => |n| {
            const t = v.schema.findType(n) orelse return;
            switch (t.kind) {
                .@"struct", .@"union" => {
                    var it = memory.fields(v.schema, t);
                    while (it.next()) |f| try out.append(a, f.name);
                },
                .bitfield => |bf| for (bf.members) |m| try out.append(a, m.name),
                else => {},
            }
        },
        else => {},
    }
}

pub fn readBits(b: Bits, word: u64) u64 {
    const mask: u64 = if (b.bits >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(b.bits)) - 1;
    return (word >> @intCast(b.bit)) & mask;
}

pub fn writeBits(b: Bits, word: u64, value: u64) u64 {
    const mask: u64 = if (b.bits >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(b.bits)) - 1;
    return (word & ~(mask << @intCast(b.bit))) | ((value & mask) << @intCast(b.bit));
}

pub fn pointee(s: Schema, r: Ref, address: usize) View {
    return .{ .schema = s, .type = r.pointer.*, .address = address };
}

/// How far a pointer to text is read.
pub const max_text = 4096;

/// Copied out in one read. Saving writes back only what changed since, so the game's own changes stay.
pub const Copy = struct {
    gpa: std.mem.Allocator,
    view: View,
    /// As of the copy or last save.
    original: []u8,

    pub fn destroy(self: *Copy) void {
        self.gpa.free(self.original);
        self.gpa.destroy(self);
    }

    /// To read the copy like the game's.
    pub fn local(self: *const Copy) View {
        return .{ .schema = self.view.schema, .type = self.view.type, .address = @intFromPtr(self.original.ptr) };
    }
};

/// `L.Item` is one of the language's values. `L` gives `child`, `element`, `release`, `put` and `bitsOf`.
/// `put` writes like setting a value on a live view.
pub fn save(comptime L: type, lang: L, gpa: std.mem.Allocator, copy: *Copy, root: L.Item, writer: anytype) !usize {
    const scratch = try gpa.dupe(u8, copy.original);
    defer gpa.free(scratch);
    var s: Saver(L, @TypeOf(writer)) = .{
        .lang = lang,
        .gpa = gpa,
        .scratch = @intFromPtr(scratch.ptr),
        .original = @intFromPtr(copy.original.ptr),
        .game = copy.view.address,
        .writer = writer,
    };
    try s.walk(.{ .schema = copy.view.schema, .type = copy.view.type, .address = s.scratch }, root, 0);
    // So saving again only writes what changed since
    @memcpy(copy.original, scratch);
    return s.written;
}

/// How deep `save` and plain copies go.
pub const max_depth = 16;

fn Saver(comptime L: type, comptime W: type) type {
    return struct {
        const Self = @This();

        lang: L,
        gpa: std.mem.Allocator,
        scratch: usize,
        original: usize,
        game: usize,
        /// Has `writeMemory` and `readMemory` on the game.
        writer: W,
        written: usize = 0,

        fn walk(self: *Self, v: View, item: L.Item, depth: usize) anyerror!void {
            if (depth > max_depth) return;
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();
            var list: std.ArrayList([]const u8) = .empty;
            try names(v, arena.allocator(), &list);
            for (list.items, 0..) |name, i| {
                const part = (if (v.type == .array) self.lang.element(item, i) else self.lang.child(item, name)) orelse continue;
                defer self.lang.release(part);
                switch (member(v, name) orelse continue) {
                    .view => |inner| try self.walk(inner, part, depth + 1),
                    .value, .pointer => |p| {
                        // Text is left alone
                        if (p.type == .array and memory.isText(p.type.array) != null) continue;
                        const size = memory.shapeOf(v.schema, p.type).size;
                        const at: [*]u8 = @ptrFromInt(p.address);
                        try self.lang.put(v.schema, p.type, part, at);
                        const offset = p.address - self.scratch;
                        const was: [*]const u8 = @ptrFromInt(self.original + offset);
                        if (std.mem.eql(u8, at[0..size], was[0..size])) continue;
                        try self.writer.writeMemory(self.game + offset, at[0..size]);
                        self.written += 1;
                    },
                    .bits => |b| {
                        const n = b.backing.size(v.schema.pointer_size);
                        const at: [*]u8 = @ptrFromInt(b.address);
                        const word = writeBits(b, memory.bits(at, n), try self.lang.bitsOf(part));
                        memory.put(at, n, word);
                        const offset = b.address - self.scratch;
                        const was = readBits(b, memory.bits(@ptrFromInt(self.original + offset), n));
                        if (readBits(b, word) == was) continue;
                        // Just these bits, around what the game has in the rest now
                        var game_word: u64 = 0;
                        try self.writer.readMemory(self.game + offset, std.mem.asBytes(&game_word)[0..n]);
                        game_word = writeBits(b, game_word, readBits(b, word));
                        try self.writer.writeMemory(self.game + offset, std.mem.asBytes(&game_word)[0..n]);
                        self.written += 1;
                    },
                    .text, .method, .length => {},
                }
            }
        }
    };
}

test "members of a view" {
    var parsed = try salamander_schema.parse(std.testing.allocator,
        \\struct Vec3 { f32 x; f32 y; f32 z; }
        \\bitfield Flags : u8 { bool alive; u8 level : 4; }
        \\struct Entity { [8] u32 id; }
        \\struct Player : Entity { Vec3 pos; Flags flags; Player* target; utf8[8] name; utf8* title; u32[4] ids; u16 used; u32[used] more; }
    , .{ .any_namespace = true }, null);
    defer parsed.deinit();
    const s = parsed.schema;
    const v: View = .{ .schema = s, .type = .{ .named = "Player" }, .address = 0x1000 };
    try std.testing.expectEqual(0x1008, member(v, "id").?.value.address);
    const pos = member(v, "pos").?.view;
    // After Entity's 12 bytes
    try std.testing.expectEqual(0x100C, pos.address);
    try std.testing.expectEqual(0x1010, member(pos, "y").?.value.address);
    try std.testing.expect(member(v, "target").? == .pointer);
    try std.testing.expect(member(v, "title").? == .text);
    try std.testing.expect(member(v, "name").? == .value);
    const ids = member(v, "ids").?.view;
    try std.testing.expectEqual(4, member(ids, "length").?.length);
    try std.testing.expectEqual(ids.address + 8, member(ids, "2").?.value.address);
    try std.testing.expect(member(ids, "4") == null);
    // Empty till its count's read, then as long as it says
    const more = member(v, "more").?.view;
    try std.testing.expectEqual(member(v, "used").?.value.address, more.count.?.address);
    try std.testing.expectEqual(0, member(more, "length").?.length);
    try std.testing.expectEqual(more.address + 4, member(more.sized(3), "1").?.value.address);
    try std.testing.expect(member(more.sized(3), "3") == null);
    const flags = member(v, "flags").?.view;
    const level = member(flags, "level").?.bits;
    // `level` starts at bit 1, after `alive`
    try std.testing.expectEqual(11, readBits(level, 0b1011_0));
    try std.testing.expectEqual(0b0110_1, writeBits(level, 0b1011_1, 6));
    try std.testing.expect(member(v, "nope") == null);
}
