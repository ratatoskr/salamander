//! Checks the generated `.zig` of `schema/test.sal` lays everything out as the schema says, and C agrees.

const std = @import("std");
const testing = std.testing;

const salamander_schema = @import("salamander_schema");
const rt = @import("salamander_runtime");
const gen = @import("generated");

const source = @embedFile("schema/test.sal");

fn parsed() !salamander_schema.Parsed {
    return salamander_schema.parse(testing.allocator, source, .{ .any_namespace = true }, null);
}

/// Like `Schema.writeFlatName`, which Zig has its names as.
fn genName(comptime name: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    comptime var i = 0;
    inline while (i < name.len) : (i += 1) out = out ++ switch (name[i]) {
        '.', '<', ',' => "_",
        '*' => "Ptr",
        '>', ' ' => "",
        else => &[_]u8{name[i]},
    };
    return out;
}

/// `test.sal`'s types, since Zig can't list a file's declarations.
const type_names = .{
    "Vec3",        "Entity",                  "Player",                      "Pair",             "Bag",                           "Job",
    "Flags",       "Stat",                    "Handle",                      "Hooks",            "Visitor",                       "Scene.Node",
    "Scene.Graph", "Scene.List<Scene.Node*>", "Scene.Map<u32, Scene.Node*>", "Scene.List<Vec3>", "Scene.Entry<u32, Scene.Node*>", "Scene.List<Scene.Entry<u32, Scene.Node*>>",
};
const trait_names = .{ "Walker", "Transform", "Named", "Damageable", "OnMove", "Freecam", "Scene.Picker" };

fn check(s: salamander_schema.Schema) !void {
    @setEvalBranchQuota(100_000);
    try testing.expectEqual(type_names.len + 1, s.types.len - nested(s));
    inline for (type_names) |name| {
        const G = @field(gen, genName(name));
        const found = s.findType(name).?;
        switch (@typeInfo(G)) {
            .@"struct" => |info| if (info.layout == .@"bitpack") {
                try testing.expectEqual(found.kind.bitfield.backing.size(s.pointer_size) * 8, @bitSizeOf(G));
            } else if (found.kind != .@"struct") {} else {
                try testing.expectEqual(found.size, @sizeOf(G));
                try testing.expectEqual(@as(usize, found.alignment), @alignOf(G));
                for (found.kind.@"struct".fields) |f| {
                    inline for (info.field_names) |gf| {
                        if (std.mem.eql(u8, gf, f.name)) try testing.expectEqual(f.offset, @offsetOf(G, gf));
                    }
                }
            },
            .@"union" => {
                try testing.expectEqual(found.size, @sizeOf(G));
                try testing.expectEqual(@as(usize, found.alignment), @alignOf(G));
            },
            .@"enum" => |info| for (found.kind.@"enum".values) |v| {
                inline for (info.field_names, info.field_values) |n, gv| {
                    if (std.mem.eql(u8, n, v.name)) try testing.expectEqual(v.value, gv);
                }
            },
            else => {},
        }
    }
}

/// Fields' own bitfields, which aren't top-level types.
fn nested(s: salamander_schema.Schema) usize {
    var n: usize = 0;
    for (s.types) |t| n += @intFromBool(t.nested);
    return n;
}

test "types are laid out as the schema says" {
    var p = try parsed();
    defer p.deinit();
    try check(p.schema);
}

test "unions are unions" {
    try testing.expect(@typeInfo(gen.Stat) == .@"union");
}

test "traits have the schema's hashes" {
    var p = try parsed();
    defer p.deinit();
    try testing.expectEqual(trait_names.len, p.schema.traits.len);
    inline for (trait_names) |name| {
        const G = @field(gen, genName(name));
        try testing.expectEqual(p.schema.traitHash(p.schema.findTrait(name).?), G.salamander.hash);
        inline for (G.salamander.methods) |m| try testing.expect(m.sig != 0);
    }
}

test "constants" {
    try testing.expectEqual(4, gen.max_players);
    try testing.expectEqual(-9.8, gen.gravity);
    try testing.expectEqualStrings("hi", gen.greeting);
    try testing.expect(!gen.debug);
}

fn damage(this: usize, amount: f32) callconv(rt.callingConvention(.thiscall)) bool {
    const p: *align(1) f32 = @ptrFromInt(this + 0x38);
    p.* -= amount;
    return p.* <= 0;
}

/// Slot 12 is `damage`, the rest are never called.
const vtable: [13]*const anyopaque = @splat(@ptrCast(&damage));

test "impls call through vtables and fields" {
    var player: gen.Player = std.mem.zeroes(gen.Player);
    const vt: *const anyopaque = &vtable;
    @memcpy(std.mem.asBytes(&player)[0..@sizeOf(usize)], std.mem.asBytes(&vt));
    player.pos = .{ .x = 1, .y = 2, .z = 3 };

    const obj: gen.Damageable = .init(&player, gen.impl.@"Damageable for Player"());
    obj.setHealth(10);
    try testing.expectEqual(10, obj.health());
    try testing.expectEqual(10, obj.hp());
    try testing.expect(!obj.damage(4));
    try testing.expectEqual(6, player.health);
    try testing.expectEqual(2, obj.position().y);
    obj.setPosition(.{ .x = 7, .y = 8, .z = 9 });
    try testing.expectEqual(9, player.pos.z);
    // [Sig] is for a tool to find, so it's missing until then
    try testing.expectEqualStrings("", obj.name());
    try testing.expect(obj.damage(6));
    // One table per impl
    try testing.expectEqual(gen.impl.@"Damageable for Player"(), gen.impl.@"Damageable for Player"());
}

const Cam = struct {
    speed: f32 = 0,

    pub fn setSpeed(self: *Cam, speed: f32) void {
        self.speed = speed;
    }
    pub fn onMove(_: *Cam, _: gen.OnMove) void {}
    pub fn onLand(_: *Cam, _: @typeInfo(@TypeOf(gen.Freecam.onLand)).@"fn".param_types[1].?) void {}
    pub fn flyTo(_: *Cam, to: gen.Vec3) rt.Promise(gen.Vec3, null) {
        return rt.Promise(gen.Vec3, null).settled(to) catch .{};
    }
    pub fn load(_: *Cam, path: []const u8, limit: ?u32) []const u8 {
        return path[0..@min(path.len, limit orelse path.len)];
    }
    pub fn restore(_: *Cam, n: []const u8) (gen.LoadError || rt.Failure)!gen.Vec3 {
        if (n.len == 0) return error.NotFound;
        return .{ .x = 1, .y = 0, .z = 0 };
    }
    pub fn find(_: *Cam, _: u32) rt.Promise((gen.LoadError || rt.Failure)!?gen.Damageable, gen.LoadErrorCode) {
        return rt.Promise((gen.LoadError || rt.Failure)!?gen.Damageable, gen.LoadErrorCode).settled(error.Corrupt) catch .{};
    }
};

test "plugins implement generated traits" {
    var cam: Cam = .{};
    const obj: gen.Freecam = .init(&cam, rt.implement(gen.Freecam, Cam));
    obj.setSpeed(3);
    try testing.expectEqual(3, cam.speed);
    try testing.expectEqualStrings("ab", obj.load("abc", 2));
    try testing.expectError(error.NotFound, obj.restore(""));
    try testing.expectEqual(1, (try obj.restore("x")).x);
    try testing.expectEqual(5, (try obj.flyTo(.{ .x = 5, .y = 0, .z = 0 }).wait()).x);
    try testing.expectError(error.Corrupt, obj.find(1).wait());
}

// C's side, in c/test.c, built against the generated header
const from_c = struct {
    extern fn c_damage(d: gen.Damageable, amount: f32) bool;
    extern fn c_health(d: gen.Damageable) f32;
    extern fn c_position(d: gen.Damageable) gen.Vec3;
    extern fn c_restore(f: gen.Freecam, name: rt.String, out: *gen.Vec3) u32;
    extern fn c_load(f: gen.Freecam, path: rt.String, limit: rt.Opt(u32)) rt.String;
    extern fn c_flags_level(f: u32) u32;
    extern fn c_flags_with_job(f: u32, j: u8) u32;
    extern fn c_cam() gen.Freecam;
    extern fn c_cam_speed() f32;
    extern fn c_provide(h: rt.Host) u32;
    extern fn c_get_and_set(h: rt.Host, speed: f32) f32;
};

test "C calls through Zig's tables" {
    var player: gen.Player = std.mem.zeroes(gen.Player);
    const vt: *const anyopaque = &vtable;
    @memcpy(std.mem.asBytes(&player)[0..@sizeOf(usize)], std.mem.asBytes(&vt));
    player.health = 10;
    player.pos = .{ .x = 1, .y = 2, .z = 3 };
    const obj: gen.Damageable = .init(&player, gen.impl.@"Damageable for Player"());
    // damage is thiscall, so on x86 this checks C and Zig agree on it
    try testing.expect(!from_c.c_damage(obj, 4));
    try testing.expectEqual(6, from_c.c_health(obj));
    try testing.expectEqual(gen.Vec3{ .x = 1, .y = 2, .z = 3 }, from_c.c_position(obj));

    var cam: Cam = .{ .speed = 2 };
    const fc: gen.Freecam = .init(&cam, rt.implement(gen.Freecam, Cam));
    var v: gen.Vec3 = undefined;
    try testing.expectEqual(0, from_c.c_restore(fc, .init("x"), &v));
    try testing.expectEqual(1, v.x);
    try testing.expectEqual(@backingInt(gen.LoadErrorCode.NotFound), from_c.c_restore(fc, .init(""), &v));
    try testing.expectEqualStrings("ab", from_c.c_load(fc, .init("abc"), .init(2)).get());
    try testing.expectEqualStrings("abc", from_c.c_load(fc, .init("abc"), .init(null)).get());

    // No object gives zero, or SAL_GONE for a result
    try testing.expectEqual(0, from_c.c_health(.{}));
    try testing.expectEqual(rt.gone_code, from_c.c_restore(.{}, .init("x"), &v));
}

test "Zig calls a trait implemented in C" {
    const obj = from_c.c_cam();
    obj.setSpeed(4);
    try testing.expectEqual(4, from_c.c_cam_speed());
    try testing.expectEqualStrings("ab", obj.load("abc", 2));
    try testing.expectError(error.NotFound, obj.restore(""));
    try testing.expectEqual(2, (try obj.restore("xy")).y);
    // Ones C left out give zero
    try testing.expectEqual(null, obj.flyTo(.{ .x = 0, .y = 0, .z = 0 }).table);
}

test "C reads bitfields like Zig" {
    var flags: gen.Flags = .{ .alive = true, .level = 0x5a, .job = .mage };
    const bits: u32 = @bitCast(flags);
    try testing.expectEqual(0x5a, from_c.c_flags_level(bits));
    flags.job = .thief;
    try testing.expectEqual(@as(u32, @bitCast(flags)), from_c.c_flags_with_job(bits, @backingInt(gen.Job.thief)));
}

test "C provides through the host, and Zig gets it" {
    try testing.expectEqual(0, from_c.c_provide(rt.host()));
    const cam = rt.host().get(gen.Freecam, "c.cam", 1).?;
    cam.setSpeed(7);
    try testing.expectEqual(7, from_c.c_cam_speed());
    try testing.expectEqual(9, from_c.c_get_and_set(rt.host(), 9));
}

/// What `test.sal`'s game code finds, standing in for a game.
const FakeGame = struct {
    var player: gen.Player = .{};
    var main_player: ?*gen.Player = null;
    var count: u32 = 3;
    var answer: u32 = 42;
    var table: [3]usize = .{ 0, 0, 0 };

    fn heal(self: *gen.Player, amount: f32) callconv(rt.callingConvention(.c)) f32 {
        self.health += amount;
        return self.health;
    }
    fn attack(self: *gen.Player, times: u32) callconv(rt.callingConvention(.c)) u32 {
        return @as(u32, @intFromFloat(self.health)) * times;
    }
    fn total(n: u32) callconv(rt.callingConvention(.c)) i32 {
        return @intCast(n * 2);
    }
    fn entry(a: u32, b: u32) callconv(rt.callingConvention(.c)) i32 {
        return @intCast(a + b);
    }

    fn find(_: ?*anyopaque, name: []const u8) anyerror!usize {
        const all = .{
            .{ "Player.heal", @intFromPtr(&heal) },
            .{ "Player.total", @intFromPtr(&total) },
            .{ "Player.main", @intFromPtr(&main_player) },
            .{ "Player.count", @intFromPtr(&count) },
            .{ "Player", @intFromPtr(&table) },
            .{ "answer", @intFromPtr(&answer) },
            .{ "entry", @intFromPtr(&entry) },
            .{ "Scene.Graph.sum", @intFromPtr(&entry) },
        };
        inline for (all) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
        return error.NotFound;
    }
};

test "generated Zig calls game code and reads its statics" {
    rt.declared.setLocator(.{ .address = FakeGame.find });
    defer rt.declared.setLocator(null);
    FakeGame.table[2] = @intFromPtr(&FakeGame.attack);
    // Its vtable is the one the locator finds, like a game's that every instance shares
    const at_vtable: *usize = @ptrCast(&FakeGame.player);
    at_vtable.* = @intFromPtr(&FakeGame.table);
    FakeGame.main_player = &FakeGame.player;

    const p = (try gen.Player.main()).?;
    try testing.expectEqual(10, p.heal(10));
    try testing.expectEqual(30, p.attack(3));
    try testing.expectEqual(8, gen.Player.total(4));
    (try gen.Player.count()).* += 1;
    try testing.expectEqual(4, FakeGame.count);
    try testing.expectEqual(42, (try gen.answer()).*);
    try testing.expectEqual(7, gen.entry(3, 4));
    try testing.expectEqual(7, gen.Scene.Graph.sum(3, 4));
    try testing.expectEqual(@intFromPtr(&FakeGame.table) + 2 * @sizeOf(usize), try gen.Player.addresses.attack());
    try gen.resolve();
}

const plain = @import("plain");

/// Implements `Profiles` with wire types, like a host does.
const Shelf = struct {
    pub fn echo(_: *Shelf, p: plain.raw.Profile) plain.raw.Profile {
        return p;
    }
    pub fn count(_: *Shelf, tags: []const plain.raw.Tag) u32 {
        var n: u32 = 0;
        for (tags) |t| n += t.weight;
        return n;
    }
    pub fn first(_: *Shelf, names: []const rt.String) []const u8 {
        return if (names.len > 0) names[0].get() else "";
    }
    pub fn find(_: *Shelf, name: []const u8) (plain.ProfileError || rt.Failure)!plain.raw.Profile {
        if (name.len == 0) return error.Missing;
        return .{ .name = .init(name) };
    }
};

test "plain types convert both ways" {
    var shelf: Shelf = .{};
    const obj: plain.Profiles = .init(&shelf, rt.implement(plain.Profiles, Shelf));
    const tags = [_]plain.Tag{ .{ .label = "a", .weight = 2 }, .{ .label = "b", .weight = 3 } };
    const back = obj.echo(.{ .name = "kai", .tags = &tags, .scores = &.{ 7, 8 }, .best = .{ .label = "top" } });
    try testing.expectEqualStrings("kai", back.name);
    try testing.expectEqual(2, back.tags.len);
    try testing.expectEqualStrings("b", back.tags[1].label);
    try testing.expectEqual(8, back.scores[1]);
    try testing.expectEqualStrings("top", back.best.label);
    try testing.expectEqual(5, obj.count(&tags));
    try testing.expectEqualStrings("x", obj.first(&.{ "x", "y" }));
    try testing.expectEqualStrings("found", (try obj.find("found")).name);
    try testing.expectError(error.Missing, obj.find(""));
    // The wire layout's there for hosts
    try testing.expect(@sizeOf(plain.raw.Profile) != @sizeOf(plain.Profile) or @hasField(plain.raw.Profile, "name"));
}

/// The same with plain types, converted for it.
const PlainShelf = struct {
    pub fn echo(_: *PlainShelf, p: plain.Profile) plain.Profile {
        return p;
    }
    pub fn count(_: *PlainShelf, tags: []const plain.Tag) u32 {
        return @intCast(tags.len);
    }
    pub fn first(_: *PlainShelf, names: []const []const u8) []const u8 {
        return if (names.len > 0) names[names.len - 1] else "";
    }
    pub fn find(_: *PlainShelf, name: []const u8) (plain.ProfileError || rt.Failure)!plain.Profile {
        return .{ .name = name, .tags = &.{.{ .label = "found" }} };
    }
};

test "implementations can take plain types" {
    var shelf: PlainShelf = .{};
    const obj: plain.Profiles = .init(&shelf, rt.implement(plain.Profiles, PlainShelf));
    const tags = [_]plain.Tag{.{ .label = "a" }};
    try testing.expectEqualStrings("kai", obj.echo(.{ .name = "kai", .tags = &tags }).name);
    try testing.expectEqual(1, obj.count(&tags));
    try testing.expectEqualStrings("y", obj.first(&.{ "x", "y" }));
    try testing.expectEqualStrings("found", (try obj.find("z")).tags[0].label);
}

test "an array as long as a field" {
    // Its pairs are after it, past its own size
    var held: extern struct { bag: gen.Bag, pairs: [3]gen.Pair } = .{ .bag = .{ .count = 2 }, .pairs = .{ .{ .a = 1, .b = 10 }, .{ .a = 2, .b = 20 }, .{ .a = 3, .b = 30 } } };
    try testing.expectEqual(@offsetOf(@TypeOf(held), "pairs"), @offsetOf(gen.Bag, "pairs"));
    const pairs = held.bag.pairsSlice();
    try testing.expectEqual(2, pairs.len);
    try testing.expectEqual(20, pairs[1].b);
}

test "namespaces and generics" {
    try testing.expectEqual(gen.Scene_Node, gen.Scene.Node);
    try testing.expectEqual(gen.Scene_Picker, gen.Scene.Picker);
    try testing.expectEqual(gen.Scene_List_Scene_NodePtr, gen.Scene.List_Scene_NodePtr);
    // Each instance has its own types in it
    try testing.expectEqual(?*?*gen.Scene_Node, @FieldType(gen.Scene_List_Scene_NodePtr, "first"));
    try testing.expectEqual(?*gen.Vec3, @FieldType(gen.Scene_List_Vec3, "first"));
    try testing.expectEqual(gen.Scene_List_Scene_Entry_u32_Scene_NodePtr, @FieldType(gen.Scene_Map_u32_Scene_NodePtr, "entries"));
    try testing.expectEqual(3 * @sizeOf(usize), @sizeOf(gen.Scene.List_Vec3));
}
