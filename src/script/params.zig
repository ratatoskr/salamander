//! The parameter names of a JS function, from its source. Hosts use them to hand values over by name.

const std = @import("std");

/// Over `source`, a function's text like `(a, b) => a`, `function f(a) {}` or `x => x`. Each is a
/// name, or "" for one that isn't a plain name like `{ a, b }`. A default or `...` is dropped.
pub fn params(source: []const u8) Iterator {
    var s = std.mem.trimStart(u8, source, " \t\r\n");
    if (std.mem.startsWith(u8, s, "async")) s = std.mem.trimStart(u8, s["async".len..], " \t\r\n");
    if (s.len > 0 and s[0] != '(') {
        if (std.mem.indexOfScalar(u8, s, '(')) |open| {
            const arrow = std.mem.indexOf(u8, s, "=>");
            // `x => x` has no list, so its one name is all there is
            if (arrow == null or open < arrow.?) return .{ .list = inside(s[open..]) };
        }
        const end = std.mem.indexOf(u8, s, "=>") orelse return .{ .list = "" };
        return .{ .list = s[0..end] };
    }
    return .{ .list = inside(s) };
}

/// What's in the brackets `s` starts with.
fn inside(s: []const u8) []const u8 {
    var depth: usize = 0;
    for (s, 0..) |ch, i| switch (ch) {
        '(', '[', '{' => depth += 1,
        ')', ']', '}' => {
            depth -= 1;
            if (depth == 0) return s[1..i];
        },
        else => {},
    };
    return "";
}

pub const Iterator = struct {
    list: []const u8,
    at: usize = 0,

    pub fn next(it: *Iterator) ?[]const u8 {
        if (it.at >= it.list.len) return null;
        var depth: usize = 0;
        var i = it.at;
        while (i < it.list.len) : (i += 1) switch (it.list[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            ',' => if (depth == 0) break,
            else => {},
        };
        const one = it.list[it.at..i];
        it.at = i + 1;
        const trimmed = std.mem.trim(u8, one, " \t\r\n");
        if (trimmed.len == 0) return if (it.at >= it.list.len) null else "";
        return name(trimmed);
    }

    fn name(p: []const u8) []const u8 {
        var n = p;
        if (std.mem.startsWith(u8, n, "...")) n = n[3..];
        if (std.mem.indexOfScalar(u8, n, '=')) |eq| n = n[0..eq];
        n = std.mem.trim(u8, n, " \t\r\n");
        for (n) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$')) return "";
        return n;
    }
};

fn expectParams(source: []const u8, want: []const []const u8) !void {
    var it = params(source);
    for (want) |w| try std.testing.expectEqualStrings(w, it.next() orelse return error.TooFew);
    try std.testing.expectEqual(null, it.next());
}

test "parameter names from a function's source" {
    try expectParams("(hook, self, amount) => hook.original()(self, 0)", &.{ "hook", "self", "amount" });
    try expectParams("function (self, amount) { return 0; }", &.{ "self", "amount" });
    try expectParams("function spend(context, self = 1, ...rest) {}", &.{ "context", "self", "rest" });
    try expectParams("async (a, { b, c }, [d]) => {}", &.{ "a", "", "" });
    try expectParams("hook => hook", &.{"hook"});
    try expectParams("() => 0", &.{});
    try expectParams("spend(hook, self) { return 0; }", &.{ "hook", "self" });
    try expectParams("(a, b = (1, 2),) => a", &.{ "a", "b" });
}
