const std = @import("std");
const testing = std.testing;

const schema = @import("root.zig");
const Schema = schema.Schema;

const test_sal = @embedFile("test.sal");
const wraith: []const schema.Namespace = &.{.{ .name = "wraith", .annotations = &.{ "Sig", "VirtualTable" } }};

fn parseTest(source: []const u8, options: schema.Options) !schema.Parsed {
    var diag: Schema.Diagnostic = .{};
    return schema.parse(testing.allocator, source, options, &diag) catch |err| {
        std.debug.print("{s}\n", .{diag.message()});
        return err;
    };
}

fn offsetOf(s: Schema, type_name: []const u8, field: []const u8) usize {
    return s.findField(s.findType(type_name).?, field).?.offset;
}

fn expectLayout(s: Schema) !void {
    const player = s.findType("Player").?;
    try testing.expectEqual(0x100, player.size);
    try testing.expectEqual(8, player.alignment);
    try testing.expectEqual(0x20, offsetOf(s, "Player", "name"));
    try testing.expectEqual(0x30, offsetOf(s, "Player", "title"));
    try testing.expectEqual(0x3C, offsetOf(s, "Player", "job"));
    try testing.expectEqual(0x44, offsetOf(s, "Player", "stat"));
    try testing.expectEqual(0x76, offsetOf(s, "Player", "level"));
    try testing.expectEqual(0x80, offsetOf(s, "Player", "owner"));
    try testing.expectEqual(0x10, offsetOf(s, "Player", "pos"));
    try testing.expectEqual(0x14, s.fieldPath(player, "pos.y").?.offset);

    const pair = s.findType("Pair").?;
    try testing.expectEqual(8, pair.size);
    try testing.expectEqual(4, offsetOf(s, "Pair", "b"));
    try testing.expectEqual(4, s.findType("Stat").?.size);
}

test "parses everything" {
    var parsed = try parseTest(test_sal, .{ .pointer_size = 8, .namespaces = wraith });
    defer parsed.deinit();
    const s = parsed.schema;
    try expectLayout(s);

    const relation = s.findType("Player.relation").?;
    try testing.expect(relation.nested);
    try testing.expectEqual(6, relation.kind.bitfield.members[2].bit);

    try testing.expectEqual(7, s.findType("LoadError").?.kind.@"error".errors[1].code);
    try testing.expectEqual(-9.8, s.findConstant("gravity").?.value.float);

    const damageable = s.findTrait("Damageable").?;
    try testing.expectEqualStrings("Transform", s.findMethod(damageable, "position").?.trait.name);
    try testing.expectEqual(Schema.Conv.thiscall, s.findMethod(damageable, "damage").?.method.signature.conv);
    try testing.expect(s.findMethod(damageable, "local").?.method.static);

    const impl = s.findImpl("Damageable", "Player").?;
    try testing.expectEqual(Schema.Conv.thiscall, impl.conv.?);
    try testing.expectEqual(12, impl.items[0].source.virtual);
    try testing.expectEqual(.external, impl.items[1].source);
    // The `use` made [Sig] mean the namespaced one
    try testing.expectEqualStrings("wraith", impl.items[1].annotations[0].namespace);
    try testing.expectEqualStrings("health", impl.items[4].source.alias);
    try testing.expectEqualStrings("Rip", impl.items[7].annotations[0].args[1].ident);

    const vt = Schema.findAnnotation(s.findType("Player").?.annotations, "wraith", "VirtualTable").?;
    try testing.expectEqual(13, vt.args[1].call.args[0].int);
}

test "opaque, function and object types" {
    var parsed = try parseTest(test_sal, .{ .pointer_size = 8, .namespaces = wraith });
    defer parsed.deinit();
    const s = parsed.schema;
    try testing.expectEqual(.@"opaque", s.findType("Handle").?.kind);
    try testing.expectEqual(1, s.findType("Visitor").?.kind.func.params.len);
    try testing.expectEqual(0, offsetOf(s, "Hooks", "visit"));
    try testing.expectEqual(16, offsetOf(s, "Hooks", "maybe"));
    try testing.expectEqual(32, offsetOf(s, "Hooks", "handle"));
    try testing.expectEqual(40, offsetOf(s, "Hooks", "any"));
    try testing.expectEqual(56, s.findType("Hooks").?.size);
}

test "types print back as written" {
    var parsed = try parseTest(test_sal, .{ .pointer_size = 8, .namespaces = wraith });
    defer parsed.deinit();
    const freecam = parsed.schema.findTrait("Freecam").?;
    var buf: [128]u8 = undefined;
    const cases = [_][2][]const u8{
        .{ "onLand", "(fn(Vec3 at, ?Player* near) void listener) void" },
        .{ "load", "(string path, ?u32 limit) []u8" },
        .{ "find", "(u32 id) ?Damageable!LoadError" },
    };
    for (cases) |case| {
        const m = parsed.schema.findMethod(freecam, case[0]).?.method;
        try testing.expectEqualStrings(case[1], try std.fmt.bufPrint(&buf, "{f}", .{m.signature}));
    }
    try testing.expect(parsed.schema.findMethod(freecam, "flyTo").?.method.async);
}

test "default namespaces need no use" {
    var parsed = try parseTest(
        \\struct A { u32 x; }
        \\trait T { void f(); }
        \\impl T for A { [Sig("90")] f; }
    , .{ .namespaces = wraith, .uses = &.{"wraith"} });
    defer parsed.deinit();
    try testing.expectEqualStrings("wraith", parsed.schema.impls[0].items[0].annotations[0].namespace);
}

test "game code is declared where it lives" {
    const source =
        \\[VirtualTable("48 8D 05 ?? ?? ?? ??", Offset(3), Rip)]
        \\struct Entity {
        \\    [8] u32 id;
        \\    [Virtual(2)] void update(f32 dt);
        \\}
        \\struct Player : Entity {
        \\    [0x10] f32 health;
        \\    [Sig("48 89 5C"), Thiscall] f32 heal(f32 amount);
        \\    [Sig("40 53")] static i32 total(u32 n);
        \\    [Sig("48 8B 05", Offset(3), Rip)] static Player* instance;
        \\}
        \\[Sig("E8 ?? ?? ?? ??", Follow)] i32 spawn(Player* at, u32 kind);
        \\[Sig("B8")] static u32 answer;
    ;
    var parsed = try parseTest(source, .{ .namespaces = wraith, .uses = &.{"wraith"} });
    defer parsed.deinit();
    const s = parsed.schema;

    const update = s.findFunction("Player.update").?;
    try testing.expectEqual(2, update.method.virtual.?);
    try testing.expectEqualStrings("Entity", update.owner.?.name);
    try testing.expect(update.hasThis());
    const heal = s.findFunction("Player.heal").?;
    try testing.expectEqual(Schema.Conv.thiscall, heal.method.signature.conv);
    try testing.expectEqualStrings("Sig", heal.method.annotations[0].name);
    try testing.expect(!s.findFunction("Player.total").?.hasThis());
    try testing.expect(!s.findFunction("spawn").?.hasThis());
    try testing.expect(s.findFunction("Player.nope") == null);
    try testing.expectEqualStrings("Player", s.findStatic("Player.instance").?.owner.?.name);
    try testing.expectEqualStrings("answer", s.findStatic("answer").?.static.name);
    // Methods don't change the layout
    try testing.expectEqual(0x14, s.findType("Player").?.size);

    // Signatures by name, with `this` first for methods
    var buf: [128]u8 = undefined;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "Player.heal", "(Player* self, f32 amount) f32" },
        .{ "Player.update", "(Player* self, f32 dt) void" },
        .{ "Player.total", "(u32 n) i32" },
        .{ "spawn", "(Player* at, u32 kind) i32" },
    };
    for (cases) |case| {
        var named = try schema.parseSignature(testing.allocator, source, case[0], .{ .namespaces = wraith, .uses = &.{"wraith"} }, null);
        defer named.deinit();
        const sig = named.schema.findType(schema.signature_name).?.kind.func;
        try testing.expectEqualStrings(case[1], try std.fmt.bufPrint(&buf, "{f}", .{sig}));
    }
    var diag: Schema.Diagnostic = .{};
    try testing.expectError(error.InvalidSchema, schema.parseSignature(testing.allocator, source, "Player.nope", .{ .namespaces = wraith, .uses = &.{"wraith"} }, &diag));
    try testing.expectEqualStrings("there's no function or method named Player.nope", diag.message());
    try testing.expectError(error.NotASignature, schema.parseSignature(testing.allocator, source, "not a (sig", .{}, null));
}

test "winapi is a calling convention" {
    var parsed = try parseTest("trait T { [Winapi] u32 f(); }", .{});
    defer parsed.deinit();
    try testing.expectEqual(Schema.Conv.winapi, parsed.schema.traits[0].methods[0].signature.conv);
}

test "declarations for one kind of code" {
    const source =
        \\[X64] struct Cpu { u64 rax; }
        \\[X86] struct Cpu { u32 eax; }
        \\[X86] const u32 bits = 32;
        \\[X64] const u32 bits = 64;
        \\trait T { void f(Cpu c); }
    ;
    var wide = try parseTest(source, .{ .pointer_size = 8 });
    defer wide.deinit();
    try testing.expectEqualStrings("rax", wide.schema.findType("Cpu").?.kind.@"struct".fields[0].name);
    try testing.expectEqual(64, wide.schema.findConstant("bits").?.value.int);
    var narrow = try parseTest(source, .{ .pointer_size = 4 });
    defer narrow.deinit();
    try testing.expectEqualStrings("eax", narrow.schema.findType("Cpu").?.kind.@"struct".fields[0].name);
    try testing.expectEqual(32, narrow.schema.findConstant("bits").?.value.int);
}

test "inout crosses as a pointer, and counts in the hash" {
    var parsed = try parseTest(
        \\struct Pair { i32 a; i32 b; }
        \\trait T { void f(inout Pair p, inout f32 x, inout f32[3] v); void g(Pair* p, f32* x, f32[3]* v); }
    , .{});
    defer parsed.deinit();
    const ms = parsed.schema.traits[0].methods;
    const f = ms[0].signature;
    try testing.expect(f.params[0].inout and f.params[1].inout and f.params[2].inout and !ms[1].signature.params[0].inout);
    try testing.expectEqualStrings("Pair", f.params[0].inoutType().?.named);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("(inout Pair p, inout f32 x, inout f32[3] v) void", try std.fmt.bufPrint(&buf, "{f}", .{f}));
    // The same ABI as plain pointers, but not the same contract
    try testing.expect(f.params[0].type.eql(ms[1].signature.params[0].type));
    try testing.expect(!f.eql(ms[1].signature));
    try testing.expect(Schema.signatureHash(f) != Schema.signatureHash(ms[1].signature));
}

test "keep marks objects that outlive a call" {
    var parsed = try parseTest(
        \\fn void Cb();
        \\struct Hooks { Cb on; }
        \\trait T { void a(Cb f); void b(keep Cb f); void c(keep ?Hooks h); void d(keep []T all); }
    , .{});
    defer parsed.deinit();
    const ms = parsed.schema.traits[0].methods;
    try testing.expect(!ms[0].signature.params[0].keep);
    for (ms[1..]) |m| try testing.expect(m.signature.params[0].keep);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("(keep Cb f) void", try std.fmt.bufPrint(&buf, "{f}", .{ms[1].signature}));
    // A different contract, so callers built against the other don't match it
    try testing.expect(Schema.methodHash(&ms[0]) != Schema.methodHash(&ms[1]));
}

test "a bundle is one schema across files" {
    const files = [_]schema.File{
        .{ .name = "math.sal", .text = "struct Vec3 { f32 x; f32 y; f32 z; }" },
        .{ .name = "cam.sal", .text =
        \\use wraith;
        \\trait Camera { Vec3 at(); }
        \\struct Cam { Vec3 pos; }
        \\impl Camera for Cam { [Sig("90")] at; }
        },
    };
    const text = try schema.bundle(testing.allocator, &files);
    defer testing.allocator.free(text);
    var parsed = try parseTest(text, .{ .namespaces = wraith });
    defer parsed.deinit();
    // Types from one file in another's, and each file's own `use`
    try testing.expectEqual(12, parsed.schema.findType("Cam").?.size);
    try testing.expectEqualStrings("wraith", parsed.schema.impls[0].items[0].annotations[0].namespace);
}

test "problems in a bundle say which file" {
    const text = try schema.bundle(testing.allocator, &.{
        .{ .name = "ok.sal", .text = "struct A { u32 x; }" },
        .{ .name = "bad.sal", .text = "struct B { u32 y; }\nstruct C { D d; }" },
    });
    defer testing.allocator.free(text);
    var diag: Schema.Diagnostic = .{};
    try testing.expectError(error.InvalidSchema, schema.parse(testing.allocator, text, .{}, &diag));
    try testing.expect(std.mem.startsWith(u8, diag.message(), "bad.sal:2:"));
    try testing.expectError(error.InvalidFileName, schema.bundle(testing.allocator, &.{.{ .name = "a\"b", .text = "" }}));
}

test "pointers to arrays are fine as parameters" {
    var parsed = try parseTest("trait T { u8[4]* f(u8[4]* in, []u8 any); }", .{});
    defer parsed.deinit();
}

test "32-bit layout" {
    var parsed = try parseTest(
        \\struct S { u8 a; void* p; []u8 bytes; u64 big; }
    , .{ .pointer_size = 4 });
    defer parsed.deinit();
    const s = parsed.schema;
    try testing.expectEqual(4, offsetOf(s, "S", "p"));
    try testing.expectEqual(8, offsetOf(s, "S", "bytes"));
    try testing.expectEqual(16, offsetOf(s, "S", "big"));
    try testing.expectEqual(24, s.findType("S").?.size);
}

test "mistakes say where and why" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "struct A { u32 x; void f(); }", "1:19: A.f needs to say where it is" },
        .{ "struct A { u32 x; [Virtual(1)] void x(); }", "A already has a field x" },
        .{ "struct A { u32 x; [Virtual(1)] static void f(); }", "a static method can't have [Virtual]" },
        .{ "struct A { u32 x; static u32 count; }", "A.count needs to say where it is" },
        .{ "union U { u32 x; [Virtual(1)] void f(); }", "a union only holds data" },
        .{ "i32 spawn(u32 kind);", "spawn needs to say where it is" },
        .{ "[Virtual(2)] i32 spawn(u32 kind);", "a function can't have [Virtual]" },
        .{ "struct A { u32 x; } [wraith.Sig(\"90\")] static u32 A;", "already something named A" },
        .{ "strcut A { u32 x; }", "expected struct, union" },
        .{ "struct A { B b; }", "there's no type or trait named B" },
        .{ "struct A { A a; }", "A contains itself" },
        .{ "struct A : B { } struct B : A { }", "go in a circle" },
        .{ "[Size(2)] struct A { u32 x; }", "is [Size(0x2)], but its fields need 0x4" },
        .{ "struct A { [0] u32 x; [2] u16 y; }", "A.y at 0x2 overlaps x" },
        .{ "struct A { ?u32 x; }", "in memory, ? only goes on pointers" },
        .{ "struct A { u32!E x; } error E { X }", "A.x: a result like 'T!E' is only for returns" },
        .{ "struct A { void x; }", "A.x: void is only for returns" },
        .{ "struct A { u32 x; } struct A { u32 y; }", "already something named A" },
        .{ "[Sig(\"90\")] struct A { u32 x; }", "there's no [Sig]" },
        .{ "[foo.Bar] struct A { u32 x; }", "there's no namespace 'foo'" },
        .{ "struct A { u32 x; } use wraith;", "`use` goes at the top" },
        .{ "enum E : u8 { a = 300 }", "E.a = 300 doesn't fit in a u8" },
        .{ "enum E : u8 { a = 1, b = 1 }", "E.a and E.b are both 1" },
        .{ "bitfield F : u8 { u8 a : 6; u8 b : 4; }", "F.b goes past bit 8" },
        .{ "bitfield F : u8 { u8 a : 4; [Bit(2)] bool b; }", "F.b overlaps a" },
        .{ "error E { A = 0 }", "codes start at 1" },
        .{ "error E { A = 4294967293 }", "the top three codes are Cancelled, Unsupported and Gone" },
        .{ "error E { Gone }", "every result can already fail with Gone" },
        .{ "trait T { u32 x; }", "a trait only has methods" },
        .{ "trait T { void f(E e); } error E { X }", "E is an error set" },
        .{ "trait T { void f(u32!E e); } error E { X }", "only for returns" },
        .{ "trait T { void f(u32 a, u32 a); }", "already a parameter named a" },
        .{ "trait T { void f(keep u32 a); }", "keep is for objects outliving the call, and a has none" },
        .{ "struct S { [X64] u32 x; }", "can't have [X64]" },
        .{ "[X64] [X86] struct S { u32 x; }", "there's already an [X64] or [X86]" },
        .{ "trait T { void f(inout string s); }", "inout is for numbers, enums, bitfields, structs, unions and arrays of them, not string" },
        .{ "trait T { void f(inout T t); }", "inout is for numbers" },
        .{ "trait A { void f(); } trait B { void f(); } trait C : A, B { }", "C: A.f and B.f have the same name" },
        .{ "trait A : B { } trait B : A { }", "go in a circle" },
        .{ "trait T { u32 data(); }", "T.data: objects and tables use that name" },
        .{ "trait T { void f(); } struct S { u32 x; } impl T for S { g = field x; }", "T has no method g" },
        .{ "trait T { void f(); } struct S { u32 x; } impl T for S { f; }", "f needs to say where it is" },
        .{ "trait T { f32 f(); } struct S { u32 x; } impl T for S { f = field x; }", "f isn't a getter or setter of x, a u32" },
        .{ "trait T { u32 f(); } struct S { u32 x; } impl T for S { f = field y; }", "S has no field y" },
        .{ "trait T { u32 f(); u32 g(); } struct S { u32 x; } impl T for S { f = fn g; }", "g isn't in this impl" },
        .{ "trait T { u32 f(); f32 g(); } struct S { f32 y; } impl T for S { g = field y; f = fn g; }", "f and g have different signatures" },
        .{ "trait T { static u32 f(); } struct S { u32 x; } impl T for S { [Virtual(1)] f; }", "f is static" },
        .{ "trait T { } struct S { u32 x; } impl T for S; impl T for S;", "already an impl T for S" },
        .{ "const u8 x = 256;", "x = 256 doesn't fit in a u8" },
        .{ "const u8 x = \"a\";", "x is a u8, so it can't be string" },
        .{ "struct A { u32[4 x; }", "expected ']'" },
        .{ "struct A { u32 x; ", "found the end of the file" },
        .{ "trait T { void f(u32[] x); }", "a slice's [] goes in front" },
        .{ "trait T { void f(u8[4] x); }", "C can't pass an array by value" },
        .{ "opaque O; struct A { O o; }", "only goes behind a pointer" },
        .{ "opaque O; trait T { void f(O o); }", "O is opaque, so it only goes behind a pointer" },
        .{ "fn void F(u8[4] x);", "C can't pass an array by value" },
    };
    for (cases) |case| {
        var diag: Schema.Diagnostic = .{};
        if (schema.parse(testing.allocator, case[0], .{ .namespaces = wraith }, &diag)) |p| {
            var parsed = p;
            parsed.deinit();
            std.debug.print("no error for: {s}\n", .{case[0]});
            return error.TestExpectedError;
        } else |err| {
            try testing.expectEqual(error.InvalidSchema, err);
            if (std.mem.indexOf(u8, diag.message(), case[1]) == null) {
                std.debug.print("for: {s}\nwanted: {s}\ngot:    {s}\n", .{ case[0], case[1], diag.message() });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "types typed in, and lookups through bases" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const t = try schema.parseType(arena.allocator(), " Player*[4] ", null);
    try testing.expectEqual(4, t.array.len);
    try testing.expectEqualStrings("Player", t.array.child.pointer.named);
    var diag: schema.Diagnostic = .{};
    try testing.expectError(error.InvalidSchema, schema.parseType(arena.allocator(), "u8 x", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "the end of the type") != null);

    var p = try schema.parse(testing.allocator, test_sal, .{ .namespaces = wraith }, null);
    defer p.deinit();
    const s = p.schema;
    const player = s.findType("Player").?;
    const id = s.fieldOf(player, "id").?;
    try testing.expectEqualStrings("Entity", id.owner.name);
    try testing.expectEqual(0x8, id.field.offset);
    try testing.expectEqual(2, s.methodOf(player, "attack").?.method.virtual.?);
    try testing.expectEqualStrings("count", s.staticOf(player, "count").?.static.name);
    const job = s.findType("Job").?;
    try testing.expectEqualStrings("mage", Schema.enumName(job, 2).?);
    try testing.expectEqual(3, Schema.enumValue(job, "thief").?);
    try testing.expectEqual(4, Schema.findBits(s.findType("Flags").?, "level").?.bit);
    try testing.expectEqual(4 * @as(usize, s.pointer_size), s.sizeOf(t).?);
}
