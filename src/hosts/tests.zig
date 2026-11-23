//! The same scripts in every language, through the engine interface.

const std = @import("std");
const testing = std.testing;

const rt = @import("salamander_runtime");

const hosts = @import("root.zig");
const engine = hosts.engine;

const source = @embedFile("test.sal");
const B = @import("test_schema");
const Greeter = B.Greeter;
const Plugin = B.Plugin;

/// A blob that counts, so tests can see every count let go.
const Counted = struct {
    refs: u32 = 0,
    buf: [16]u8 = undefined,
    len: usize = 0,

    pub fn bytes(self: *Counted) []const u8 {
        return self.buf[0..self.len];
    }
    pub fn retain(self: *Counted) void {
        self.refs += 1;
    }
    pub fn release(self: *Counted) void {
        self.refs -= 1;
    }
};

const Hello = struct {
    counted: Counted = .{},
    greeted: u32 = 0,
    buf: [64]u8 = undefined,
    len: usize = 0,

    pub fn greet(self: *Hello, who: []const u8) []const u8 {
        self.greeted += 1;
        const out = std.fmt.bufPrint(&self.buf, "hello {s}", .{who}) catch "hello";
        self.len = out.len;
        return out;
    }
    pub fn count(self: *Hello) u32 {
        return self.greeted;
    }
    pub fn pack(self: *Hello, text: []const u8) rt.Blob {
        self.counted = .{ .refs = 1, .len = text.len };
        @memcpy(self.counted.buf[0..text.len], text);
        return .{ .data = @intFromPtr(&self.counted), .table = rt.implement(rt.Blob, Counted) };
    }
    pub fn size(_: *Hello, b: rt.Blob) u32 {
        return @intCast(b.bytes().len);
    }
    pub fn apply(_: *Hello, f: rt.AnyObject, a: i32, b: i32) i32 {
        // A fn value's one method is its table's first entry, with the object first
        const entries: [*]const usize = @ptrCast(@alignCast(f.table orelse return -1));
        const call: *const fn (usize, i32, i32) callconv(.c) i32 = @ptrFromInt(entries[2]);
        return call(f.data, a, b);
    }
    pub fn sum(_: *Hello, bytes: []const u8) u32 {
        var n: u32 = 0;
        for (bytes) |x| n += x;
        return n;
    }
    pub fn bump(_: *Hello, n: *i32, p: *B.Pair) void {
        n.* += 1;
        p.a += 10;
    }
    pub fn echo(text: ?[*:0]const u8, seen: ?*i32) ?[*:0]const u8 {
        if (seen) |n| n.* += 1;
        return text;
    }
    pub fn wave(_: *Hello) error{Shy}!void {
        return rt.host().explain(error.Shy, "not before {d}", .{9});
    }
};

/// What each language runs, and the module it imports.
const Case = struct {
    language: hosts.Language,
    main: []const u8,
    util: []const u8,
    util_name: []const u8,
    forever: []const u8,
    broken: []const u8,
    stray: []const u8,
};

const cases = [_]Case{
    .{
        .language = .js,
        .main =
        \\import { greeter } from "app";
        \\import { double } from "./util.js";
        \\export const plugin = {
        \\    name() { return "js"; },
        \\    run(g, n) { return double(n) + g.count(); },
        \\    check() { const e = new Error("too shy"); e.name = "Shy"; throw e; },
        \\    swap(p, x) { const t = p.a; p.a = p.b; p.b = t; x.value = x.value * 2; },
        \\    async later(who) { return "later " + who; },
        \\    halve(n) { n.f = n.f / 2; },
        \\};
        \\const nb = { value: 1 }, pr = { a: 1, b: 2 };
        \\greeter.bump(nb, pr);
        \\globalThis.bumped = `${nb.value},${pr.a},${pr.b}`;
        \\globalThis.greeting = greeter.greet("js");
        \\try { greeter.wave(); } catch (e) { globalThis.waved = e.message; }
        \\const seen = { value: 1 };
        \\globalThis.echoed = `${greeter.echo("hey", seen)} ${seen.value} ${greeter.echo(null)}`;
        ,
        .util = "export function double(x) { return x * 2; }",
        .util_name = "util.js",
        .forever = "while (true) {}",
        .broken = "this is not js",
        .stray = "Promise.reject(new Error('boom'));",
    },
    .{
        .language = .lua,
        .main =
        \\local app = require("app")
        \\local util = require("util")
        \\local plugin = {
        \\    name = function(self) return "lua" end,
        \\    run = function(self, g, n) return util.double(n) + g:count() end,
        \\    check = function(self) error({ name = "Shy", message = "too shy" }) end,
        \\    swap = function(self, p, x) p.a, p.b = p.b, p.a; x.value = x.value * 2 end,
        \\    later = function(self, who) return "later " .. who end,
        \\    halve = function(self, n) n.f = n.f / 2 end,
        \\}
        \\local nb, pr = { value = 1 }, { a = 1, b = 2 }
        \\app.greeter:bump(nb, pr)
        \\bumped = nb.value .. "," .. pr.a .. "," .. pr.b
        \\greeting = app.greeter:greet("lua")
        \\local _, err = pcall(function() app.greeter:wave() end)
        \\waved = err.message
        \\local seen = { value = 1 }
        \\echoed = app.greeter:echo("hey", seen) .. " " .. seen.value .. " " .. tostring(app.greeter:echo(nil))
        \\return { plugin = plugin }
        ,
        .util = "return { double = function(x) return x * 2 end }",
        .util_name = "util.lua",
        .forever = "while true do end",
        .broken = "this is not lua",
        .stray = "task.spawn(function() error('boom') end)",
    },
};

/// Modules from memory, Lua's without their extension.
const Files = struct {
    case: *const Case,

    fn resolve(ctx: ?*anyopaque, buf: []u8, from: []const u8, name: []const u8) ?[]const u8 {
        const self: *Files = @ptrCast(@alignCast(ctx.?));
        const path = engine.relative(buf, from, name) orelse return null;
        if (self.case.language == .lua and std.mem.indexOfScalar(u8, path, '.') == null) {
            if (path.len + 4 > buf.len) return null;
            @memcpy(buf[path.len..][0..4], ".lua");
            return buf[0 .. path.len + 4];
        }
        return path;
    }

    fn read(ctx: ?*anyopaque, gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
        const self: *Files = @ptrCast(@alignCast(ctx.?));
        if (!std.mem.eql(u8, name, self.case.util_name)) return null;
        return gpa.dupe(u8, self.case.util) catch null;
    }
};

var reported: usize = 0;

fn onReport(_: ?*anyopaque, message: []const u8) void {
    _ = message;
    reported += 1;
}

fn make(case: *const Case, files: *Files) !hosts.Script {
    files.* = .{ .case = case };
    return hosts.create(case.language, .{
        .gpa = testing.allocator,
        .resolver = .{ .ctx = files, .resolve = Files.resolve, .read = Files.read },
        .report = .{ .f = onReport },
    });
}

test "scripts in every language use native objects and give their own" {
    for (&cases) |*case| {
        var files: Files = undefined;
        const s = try make(case, &files);
        defer s.deinit();
        const types = try s.schema(source);
        var hello: Hello = .{};
        const greeter: rt.Object(Greeter) = .init(&hello, rt.implement(Greeter, Hello));
        try s.module("app", &.{.{ .name = "greeter", .schema = types, .trait = "Greeter", .obj = .of(greeter) }});

        s.run(case.main, "main") catch |e| {
            std.debug.print("{t}: {s}\n", .{ case.language, s.lastError() });
            return e;
        };
        var buf: [256]u8 = undefined;
        const shown = s.eval("greeting", &buf);
        try testing.expect(shown == .value);
        try testing.expect(std.mem.indexOf(u8, shown.value, "hello") != null);
        // A native error comes with why
        try testing.expect(std.mem.indexOf(u8, s.eval("waved", &buf).value, "Shy: not before 9") != null);
        // C text both ways, and an inout that can be null
        try testing.expectEqualStrings(if (case.language == .js) "hey 2 null" else "hey 2 nil", s.eval("echoed", &buf).value);

        const plugin = (try s.take("plugin", types, "Plugin")).as(rt.Object(Plugin));
        defer plugin.release();
        try testing.expectEqualStrings(@tagName(case.language), plugin.name());
        // 5 doubled, and the one greeting so far
        try testing.expectEqual(11, plugin.run(greeter, 5));
        // A script's error comes with its message
        try testing.expectError(error.Shy, plugin.check());
        try testing.expectEqualStrings("too shy", rt.host().explanation("Shy"));

        // inout both ways, scripts' own objects written back and native memory changed
        try testing.expectEqualStrings("2,11,2", s.eval("bumped", &buf).value);
        var pair: B.Pair = .{ .a = 3, .b = 4 };
        var x: f32 = 1.5;
        plugin.swap(&pair, &x);
        try testing.expectEqual(4, pair.a);
        try testing.expectEqual(3, pair.b);
        try testing.expectEqual(3, x);

        // Text a promise settled with lasts till it's taken, whatever else calls in first
        const later = plugin.later("zig");
        s.pump();
        _ = plugin.name();
        _ = plugin.run(greeter, 1);
        try testing.expectEqualStrings("later zig", try later.wait());

        // A union only gets the member that changed back
        var num: B.Num = .{ .f = 3 };
        plugin.halve(&num);
        try testing.expectEqual(1.5, num.f);
    }
}

test "require gives native modules the way import does" {
    const checks = [_][]const u8{
        "require('app').greeter.pack('hi').length + ' ' + (require('app') === require('app'))",
        "return #require('app').greeter:pack('hi') .. ' ' .. tostring(require('app') == require('app'))",
    };
    for (&cases, checks) |*case, check| {
        var files: Files = undefined;
        const s = try make(case, &files);
        defer s.deinit();
        const types = try s.schema(source);
        var hello: Hello = .{};
        const greeter: rt.Object(Greeter) = .init(&hello, rt.implement(Greeter, Hello));
        try s.module("app", &.{.{ .name = "greeter", .schema = types, .trait = "Greeter", .obj = .of(greeter) }});
        var buf: [256]u8 = undefined;
        const shown = s.eval(check, &buf);
        if (shown == .thrown) std.debug.print("{t}: {s}\n", .{ case.language, shown.thrown });
        try testing.expectEqualStrings("2 true", shown.value);
    }
}

test "blobs go both ways without copying, and every count's let go" {
    const scripts = [_][]const u8{
        \\import { greeter } from "app";
        \\const b = greeter.pack("hi");
        \\globalThis.packed = String.fromCharCode(...b) + " " + greeter.size(b) + " " + greeter.sum(new Uint8Array([1, 2, 3])) + " " + greeter.sum([4, 5]) + " " + greeter.sum(b);
        \\export const plugin = { shout(x) { return x.map((c) => c - 32); } };
        ,
        \\local app = require("app")
        \\local b = app.greeter:pack("hi")
        \\packed = b:string() .. " " .. app.greeter:size(b) .. " " .. #b .. " " .. b:byte(2) .. " " .. b:sub(-1) .. " " .. app.greeter:sum("\1\2\3") .. " " .. app.greeter:sum(b)
        \\return { plugin = { shout = function(self, x) return x:string():upper() end } }
        ,
    };
    for (&cases, scripts) |*case, text| {
        var hello: Hello = .{};
        {
            var files: Files = undefined;
            const s = try make(case, &files);
            defer s.deinit();
            const types = try s.schema(source);
            const greeter: rt.Object(Greeter) = .init(&hello, rt.implement(Greeter, Hello));
            try s.module("app", &.{.{ .name = "greeter", .schema = types, .trait = "Greeter", .obj = .of(greeter) }});
            s.run(text, "blobs") catch |e| {
                std.debug.print("{t}: {s}\n", .{ case.language, s.lastError() });
                return e;
            };
            var buf: [256]u8 = undefined;
            const want = if (case.language == .js) "hi 2 6 9 209" else "hi 2 2 105 i 6 209";
            try testing.expectEqualStrings(want, s.eval("packed", &buf).value);

            const plugin = (try s.take("plugin", types, "Plugin")).as(rt.Object(Plugin));
            defer plugin.release();
            const input = try rt.blobs.copy("hi");
            defer input.release();
            const out = plugin.shout(input);
            defer out.release();
            try testing.expectEqualStrings("HI", out.bytes());
        }
        // The script's own count went with it, and the one it was handed was let go
        try testing.expectEqual(0, hello.counted.refs);
    }
}

fn addNative(a: i32, b: i32) callconv(.c) i32 {
    return a + b;
}

test "scripts type functions and call native ones from signatures they write" {
    const address = @intFromPtr(&addNative);
    const js = try std.fmt.allocPrint(testing.allocator,
        \\import {{ greeter }} from "app";
        \\import {{ fn, native }} from "salamander";
        \\const add = native("fn i32 (i32 a, i32 b)", {d});
        \\const typed = fn("fn i32 (i32 a, i32 b)", (a, b) => a * b);
        \\let bad = "";
        \\try {{ native("fn Nope (u32 a)", 1); }} catch (e) {{ bad = e.message; }}
        \\globalThis.out = add(1, 2) + " " + greeter.apply(typed, 6, 7) + " " + bad.includes("Nope");
    , .{address});
    defer testing.allocator.free(js);
    const lua_source = try std.fmt.allocPrint(testing.allocator,
        \\local app = require("app")
        \\local sal = require("salamander")
        \\local add = sal.native("fn i32 (i32 a, i32 b)", {d})
        \\local typed = sal.fn("fn i32 (i32 a, i32 b)", function(a, b) return a * b end)
        \\local ok, err = pcall(sal.native, "fn Nope (u32 a)", 1)
        \\out = add(1, 2) .. " " .. app.greeter:apply(typed, 6, 7) .. " " .. tostring(typed(2, 3)) .. " " .. tostring(string.find(tostring(err), "Nope") ~= nil)
    , .{address});
    defer testing.allocator.free(lua_source);
    const sources = [_][]const u8{ js, lua_source };
    const want = [_][]const u8{ "3 42 true", "3 42 6 true" };
    for (&cases, sources, want) |*case, text, expected| {
        var files: Files = undefined;
        const s = try make(case, &files);
        defer s.deinit();
        const types = try s.schema(source);
        var hello: Hello = .{};
        const greeter: rt.Object(Greeter) = .init(&hello, rt.implement(Greeter, Hello));
        try s.module("app", &.{.{ .name = "greeter", .schema = types, .trait = "Greeter", .obj = .of(greeter) }});
        s.run(text, "signatures") catch |e| {
            std.debug.print("{t}: {s}\n", .{ case.language, s.lastError() });
            return e;
        };
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings(expected, s.eval("out", &buf).value);
    }
}

fn addSelf(self: usize, b: i32) callconv(.c) i32 {
    return @as(i32, @intCast(self)) + b;
}

test "scripts type and call game functions by their declared names" {
    const game =
        \\struct Adder { usize vt; [Virtual(0)] i32 add(i32 b); }
    ;
    const address = @intFromPtr(&addSelf);
    const js = try std.fmt.allocPrint(testing.allocator,
        \\import {{ greeter }} from "app";
        \\import {{ fn, native }} from "salamander";
        \\const add = native("Adder.add", {d});
        \\const typed = fn("Adder.add", (self, b) => self * b);
        \\let bad = "";
        \\try {{ native("Adder.nope", 1); }} catch (e) {{ bad = e.message; }}
        \\globalThis.out = add(5, 2) + " " + greeter.apply(typed, 6, 7) + " " + bad.includes("Adder.nope");
    , .{address});
    defer testing.allocator.free(js);
    const lua_source = try std.fmt.allocPrint(testing.allocator,
        \\local app = require("app")
        \\local sal = require("salamander")
        \\local add = sal.native("Adder.add", {d})
        \\local typed = sal.fn("Adder.add", function(self, b) return self * b end)
        \\local ok, err = pcall(sal.native, "Adder.nope", 1)
        \\out = add(5, 2) .. " " .. app.greeter:apply(typed, 6, 7) .. " " .. tostring(string.find(tostring(err), "Adder.nope", 1, true) ~= nil)
    , .{address});
    defer testing.allocator.free(lua_source);
    const sources = [_][]const u8{ js, lua_source };
    for (&cases, sources) |*case, text| {
        var files: Files = undefined;
        const s = try make(case, &files);
        defer s.deinit();
        const types = try s.schema(source);
        _ = try s.schema(game);
        var hello: Hello = .{};
        const greeter: rt.Object(Greeter) = .init(&hello, rt.implement(Greeter, Hello));
        try s.module("app", &.{.{ .name = "greeter", .schema = types, .trait = "Greeter", .obj = .of(greeter) }});
        s.run(text, "named") catch |e| {
            std.debug.print("{t}: {s}\n", .{ case.language, s.lastError() });
            return e;
        };
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings("7 42 true", s.eval("out", &buf).value);
    }
}

/// A game's memory, laid out like `schema` says, found by `locator`.
const Game = struct {
    const schema =
        \\enum Mode : u8 { off, on = 4 }
        \\struct Entity { usize vt; [Virtual(1)] void bump(); }
        \\struct GameManager : Entity {
        \\    f32 health;
        \\    u32 level;
        \\    GameManager* other;
        \\    utf8[8] name;
        \\    u8 flags { bool paused; u8 speed : 3; }
        \\    [test.Sig("90")] i32 hello(i32 n);
        \\    [test.Sig("90")] static GameManager* instance;
        \\}
        \\[test.Sig("90")] static u32 frames;
    ;
    const Manager = extern struct {
        vt: *const [2]usize,
        health: f32 = 0,
        level: u32 = 0,
        other: ?*Manager = null,
        name: [8]u8 = @splat(0),
        flags: u8 = 0,
    };
    fn hello(self: *Manager, n: i32) callconv(.c) i32 {
        return @as(i32, @intFromFloat(self.health)) + n;
    }
    fn bump(self: *Manager) callconv(.c) void {
        self.level += 1;
    }
    var vtable: [2]usize = .{ 0, 0 };
    var main: Manager = .{ .vt = &vtable };
    var instance: ?*Manager = null;
    var frames: u32 = 7;

    fn reset() void {
        vtable = .{ 0, @intFromPtr(&bump) };
        main = .{ .vt = &vtable };
        instance = &main;
        frames = 7;
    }
    fn address(_: ?*anyopaque, name: []const u8) anyerror!usize {
        if (std.mem.eql(u8, name, "GameManager.instance")) return @intFromPtr(&instance);
        if (std.mem.eql(u8, name, "GameManager.hello")) return @intFromPtr(&hello);
        if (std.mem.eql(u8, name, "frames")) return @intFromPtr(&frames);
        return rt.host().explain(error.NotFound, "no {s} here", .{name});
    }
    fn read(_: ?*anyopaque, at: usize, out: []u8) bool {
        @memcpy(out, @as([*]const u8, @ptrFromInt(at))[0..out.len]);
        return true;
    }
    fn write(_: ?*anyopaque, at: usize, bytes: []const u8) bool {
        @memcpy(@as([*]u8, @ptrFromInt(at))[0..bytes.len], bytes);
        return true;
    }
};

test "scripts use the game's structs live, with their methods and statics" {
    const js =
        \\import { GameManager, default as all } from "schema";
        \\import { addressOf, typeOf, at, sizeOf, snapshot, save, edit, load } from "salamander";
        \\const m = GameManager.instance;
        \\m.health = 40;
        \\m.bump();
        \\m.bump();
        \\m.name = "hi";
        \\m.flags.speed = 5;
        \\all.frames = all.frames + 1;
        \\const again = GameManager.at(addressOf(m));
        \\const plain = JSON.parse(JSON.stringify(m));
        \\globalThis.out = [m.hello(2), GameManager.hello(m, 3), m.level, m.name, typeOf(m), m.other,
        \\    again.health, m.flags.speed, m.flags.paused, plain.name, all.frames, sizeOf("GameManager") > 0,
        \\    at("GameManager", 0)].join(" ");
        \\const copy = snapshot(m);
        \\copy.level = 9;
        \\copy.flags.speed = 2;
        \\copy.name = "nope";
        \\globalThis.saved = save(copy) + " " + save(copy) + " " + (copy.other === null);
        \\edit(m, (c) => { c.health = 41; });
        \\globalThis.mode = all.Mode.on;
        \\load("tweak", "struct Box { u32 n; }");
        \\const box = load("tweak", "struct Box { u32 n; u32 m; }").Box;
        \\globalThis.loaded = sizeOf("Box") + " " + typeOf(box.at(addressOf(m)));
    ;
    const lua_source =
        \\local schema = require("schema")
        \\local sal = require("salamander")
        \\local GameManager = schema.GameManager
        \\local m = GameManager.instance
        \\m.health = 40
        \\m:bump()
        \\m:bump()
        \\m.name = "hi"
        \\m.flags.speed = 5
        \\schema.frames = schema.frames + 1
        \\local again = GameManager.at(sal.addressOf(m))
        \\out = table.concat({ m:hello(2), GameManager.hello(m, 3), m.level, m.name, sal.typeOf(m), tostring(m.other),
        \\    again.health, m.flags.speed, tostring(m.flags.paused), schema.frames, tostring(sal.sizeOf("GameManager") > 0),
        \\    tostring(sal.at("GameManager", 0)) }, " ")
        \\local copy = sal.snapshot(m)
        \\copy.level = 9
        \\copy.flags.speed = 2
        \\copy.name = "nope"
        \\saved = sal.save(copy) .. " " .. sal.save(copy) .. " " .. tostring(copy.other == nil)
        \\sal.edit(m, function(c) c.health = 41 end)
        \\mode = schema.Mode.on
        \\sal.load("tweak", "struct Box { u32 n; }")
        \\local box = sal.load("tweak", "struct Box { u32 n; u32 m; }").Box
        \\loaded = sal.sizeOf("Box") .. " " .. sal.typeOf(box.at(sal.addressOf(m)))
    ;
    const sources = [_][]const u8{ js, lua_source };
    const want = [_][]const u8{ "42 43 2 hi GameManager  40 5 false hi 8 true ", "42 43 2 hi GameManager nil 40.0 5 false 8 true nil" };
    for (&cases, sources, want) |*case, text, expected| {
        Game.reset();
        var files: Files = .{ .case = case };
        const s = try hosts.create(case.language, .{
            .gpa = testing.allocator,
            .resolver = .{ .ctx = &files, .resolve = Files.resolve, .read = Files.read },
            .report = .{ .f = onReport },
            .schema_options = .{ .any_namespace = true },
            .locator = .{ .address = Game.address, .read = Game.read, .write = Game.write },
        });
        defer s.deinit();
        _ = try s.schema(Game.schema);
        s.run(text, "views") catch |e| {
            std.debug.print("{t}: {s}\n", .{ case.language, s.lastError() });
            return e;
        };
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings(expected, s.eval("out", &buf).value);
        // Only what changed went back, twice is nothing more, and text's left alone
        try testing.expectEqualStrings("2 0 true", s.eval("saved", &buf).value);
        // Enums' values by name, to combine flags
        try testing.expectEqualStrings("4", s.eval("mode", &buf).value);
        // Loading by a name again replaces what was loaded by it
        try testing.expectEqualStrings("8 Box", s.eval("loaded", &buf).value);
        try testing.expectEqual(41, Game.main.health);
        try testing.expectEqual(9, Game.main.level);
        try testing.expectEqual(2 << 1, Game.main.flags);
        try testing.expectEqualStrings("hi", std.mem.sliceTo(&Game.main.name, 0));
        try testing.expectEqual(8, Game.frames);
    }
}

test "JS requires CommonJS files once, through the resolver" {
    const Lib = struct {
        fn resolve(_: ?*anyopaque, buf: []u8, from: []const u8, name: []const u8) ?[]const u8 {
            if (!std.mem.eql(u8, name, "util") and !std.mem.eql(u8, name, "broken")) return null;
            return engine.relative(buf, from, name);
        }

        fn read(_: ?*anyopaque, gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
            if (std.mem.eql(u8, name, "broken")) return gpa.dupe(u8, "\nthrow new Error('broke')") catch null;
            return gpa.dupe(u8, "globalThis.runs = (globalThis.runs || 0) + 1;\nexports.twice = (x) => x * 2;") catch null;
        }
    };
    const s = try hosts.create(.js, .{
        .gpa = testing.allocator,
        .resolver = .{ .resolve = Lib.resolve, .read = Lib.read },
        .report = .{ .f = onReport },
    });
    defer s.deinit();
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("4 1", s.eval("require('util').twice(2) + ' ' + (require('util'), runs)", &buf).value);
    try testing.expect(std.mem.indexOf(u8, s.eval("require('nope')", &buf).thrown, "can't require 'nope'") != null);
    // Where it threw is its own line
    try testing.expect(std.mem.indexOf(u8, s.eval("require('broken')", &buf).thrown, "broken:2") != null);
}

test "what goes wrong comes back as text, or to the report" {
    for (&cases) |*case| {
        var files: Files = undefined;
        const s = try make(case, &files);
        defer s.deinit();
        try testing.expectError(error.Thrown, s.run(case.broken, "broken"));
        try testing.expect(s.lastError().len > 0);

        const before = reported;
        try s.run(case.stray, "stray");
        s.pump();
        try testing.expectEqual(before + 1, reported);

        var buf: [256]u8 = undefined;
        try testing.expect(s.eval("1 +", &buf) == .thrown);
        try testing.expectEqualStrings("2", s.eval("1 + 1", &buf).value);
    }
}

test "another thread can interrupt a script" {
    for (&cases) |*case| {
        var files: Files = undefined;
        const s = try make(case, &files);
        defer s.deinit();
        const Stopper = struct {
            fn stop(target: hosts.Script) void {
                std.Io.sleep(testing.io, .fromMilliseconds(50), .awake) catch {};
                target.interrupt();
            }
        };
        const thread = try std.Thread.spawn(.{}, Stopper.stop, .{s});
        defer thread.join();
        try testing.expectError(error.Thrown, s.run(case.forever, "forever"));
        try testing.expect(std.mem.indexOf(u8, s.lastError(), "interrupted") != null);
        // And it runs again after
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("3", s.eval("1 + 2", &buf).value);
    }
}

test "take says when main doesn't export it" {
    const mains = [_][]const u8{ "export const other = {};", "return { other = {} }" };
    for (&cases, mains) |*case, text| {
        var files: Files = undefined;
        const s = try make(case, &files);
        defer s.deinit();
        const types = try s.schema(source);
        try s.run(text, "main");
        try testing.expectError(error.Thrown, s.take("plugin", types, "Plugin"));
        try testing.expect(std.mem.indexOf(u8, s.lastError(), "plugin") != null);
    }
}

fn runOn(plugin: rt.Object(Plugin), greeter: rt.Object(Greeter), out: *std.atomic.Value(i32)) void {
    out.store(plugin.run(greeter, 5), .release);
}

fn started(case: *const Case, files: *Files, policy: ?engine.Options.Policy) !struct { hosts.Script, rt.Object(Plugin) } {
    files.* = .{ .case = case };
    const s = try hosts.create(case.language, .{
        .gpa = testing.allocator,
        .resolver = .{ .ctx = files, .resolve = Files.resolve, .read = Files.read },
        .report = .{ .f = onReport },
        .policy = policy,
    });
    errdefer s.deinit();
    const types = try s.schema(source);
    try s.module("app", &.{.{ .name = "greeter", .schema = types, .trait = "Greeter", .obj = .of(sharedGreeter()) }});
    try s.run(case.main, "main");
    return .{ s, (try s.take("plugin", types, "Plugin")).as(rt.Object(Plugin)) };
}

var shared_hello: Hello = .{};

fn sharedGreeter() rt.Object(Greeter) {
    return .init(&shared_hello, rt.implement(Greeter, Hello));
}

test "any thread can call into a script, one at a time" {
    for (&cases) |*case| {
        var files: Files = undefined;
        const s, const plugin = try started(case, &files, null);
        defer s.deinit();
        defer plugin.release();
        const greeted = shared_hello.greeted;

        // Nobody's in, so another thread just goes in
        var out: std.atomic.Value(i32) = .init(-1);
        (try std.Thread.spawn(.{}, runOn, .{ plugin, sharedGreeter(), &out })).join();
        try testing.expectEqual(10 + @as(i32, @intCast(greeted)), out.load(.acquire));

        // Held by this thread, the other waits till it's let go
        out.store(-1, .release);
        s.enter();
        const t = try std.Thread.spawn(.{}, runOn, .{ plugin, sharedGreeter(), &out });
        std.Io.sleep(testing.io, .fromMilliseconds(30), .awake) catch {};
        try testing.expectEqual(-1, out.load(.acquire));
        s.leave();
        t.join();
        try testing.expectEqual(10 + @as(i32, @intCast(greeted)), out.load(.acquire));
    }
}

fn never(_: ?*anyopaque) engine.Gate.How {
    return .try_;
}

test "a policy can have callers give up rather than wait" {
    for (&cases) |*case| {
        var files: Files = undefined;
        const s, const plugin = try started(case, &files, .{ .how = never });
        defer s.deinit();
        defer plugin.release();

        var out: std.atomic.Value(i32) = .init(-1);
        s.enter();
        // Busy, so it gets the method's zero straight away
        (try std.Thread.spawn(.{}, runOn, .{ plugin, sharedGreeter(), &out })).join();
        try testing.expectEqual(0, out.load(.acquire));
        s.leave();
        (try std.Thread.spawn(.{}, runOn, .{ plugin, sharedGreeter(), &out })).join();
        try testing.expect(out.load(.acquire) >= 10);
    }
}

test "scripts pick their language by file name" {
    try testing.expectEqual(.js, hosts.Language.of("main.js"));
    try testing.expectEqual(.lua, hosts.Language.of("init.lua"));
    try testing.expectEqual(null, hosts.Language.of("notes.txt"));
}
