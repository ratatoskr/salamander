//! Reads `.sal` text into a `Schema`, at runtime into an arena or at comptime.
//! Types read left to right, so `Item*[8]` is eight pointers. `?` and `[]` go in front and cover the rest, `!E` goes last.
//! A struct field without an offset goes after the one before, aligned like C.

const std = @import("std");

const Schema = @import("Schema.zig");
const check = @import("check.zig").check;

const Ref = Schema.Ref;

pub const Namespace = struct {
    name: []const u8,
    /// Null takes any name.
    annotations: ?[]const []const u8 = null,
};

/// A tool's annotation that marks a struct as a global, like `[Instance("..")] struct Player`. The
/// struct gets `static Player* instance`, whose annotations are the struct's with this one renamed to
/// `as`, so the tool finds it like any other static.
pub const InstanceTag = struct {
    namespace: []const u8,
    name: []const u8,
    as: []const u8,
};

pub const Options = struct {
    pointer_size: u8 = @sizeOf(usize),
    /// See `InstanceTag`.
    instances: []const InstanceTag = &.{},
    /// Namespaces tools registered, like `game`.
    namespaces: []const Namespace = &.{},
    /// In scope without a `use`, so a tool's own files can say `[Sig]`.
    uses: []const []const u8 = &.{},
    /// Take any namespace, for tools that only read files.
    any_namespace: bool = false,
};

pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    schema: Schema,
    /// What positions point into.
    source: []const u8,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

pub const Error = error{ OutOfMemory, InvalidSchema };

pub fn parse(gpa: std.mem.Allocator, source: []const u8, options: Options, diagnostic: ?*Schema.Diagnostic) Error!Parsed {
    var scratch: Schema.Diagnostic = .{};
    const diag = diagnostic orelse &scratch;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const text = try arena.allocator().dupe(u8, source);
    var p: Parser = .init(text, diag, options, arena.allocator());
    var schema = try p.file();
    try p.layout(&schema);
    try check(schema, text, diag);
    return .{ .arena = arena, .schema = schema, .source = text };
}

/// A type written on its own, like `Player*[4]`. Names in it aren't checked. Kept in `arena`.
pub fn parseType(arena: std.mem.Allocator, text: []const u8, diagnostic: ?*Schema.Diagnostic) Error!Ref {
    var scratch: Schema.Diagnostic = .{};
    const diag = diagnostic orelse &scratch;
    var p: Parser = .init(try arena.dupe(u8, text), diag, .{}, arena);
    const r = try p.typeRef();
    if (p.tok.tag != .eof) return p.unexpected("the end of the type");
    return r;
}

const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    const Tag = enum { ident, number, string, l_bracket, r_bracket, l_paren, r_paren, l_brace, r_brace, comma, semicolon, colon, equal, star, minus, question, bang, dot, eof, invalid };
};

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn scan(source: []const u8, at: usize) Token {
    var i = at;
    while (i < source.len) {
        const c = source[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            i += 1;
        } else if (std.mem.startsWith(u8, source[i..], "//")) {
            i = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
        } else if (std.mem.startsWith(u8, source[i..], "/*")) {
            const close = std.mem.indexOfPos(u8, source, i + 2, "*/") orelse return .{ .tag = .invalid, .start = i, .end = source.len };
            i = close + 2;
        } else break;
    }
    if (i >= source.len) return .{ .tag = .eof, .start = source.len, .end = source.len };
    const start = i;
    const c = source[i];
    if (std.ascii.isDigit(c)) {
        while (i < source.len and isIdentChar(source[i])) i += 1;
        // Like 1.5
        if (i + 1 < source.len and source[i] == '.' and std.ascii.isDigit(source[i + 1])) {
            i += 1;
            while (i < source.len and isIdentChar(source[i])) i += 1;
        }
        return .{ .tag = .number, .start = start, .end = i };
    }
    if (std.ascii.isAlphabetic(c) or c == '_') {
        while (i < source.len and isIdentChar(source[i])) i += 1;
        return .{ .tag = .ident, .start = start, .end = i };
    }
    if (c == '"') {
        i += 1;
        while (i < source.len and source[i] != '"' and source[i] != '\n') : (i += 1) {
            if (source[i] == '\\') i += 1;
        }
        if (i >= source.len or source[i] != '"') return .{ .tag = .invalid, .start = start, .end = i };
        return .{ .tag = .string, .start = start, .end = i + 1 };
    }
    const tag: Token.Tag = switch (c) {
        '[' => .l_bracket,
        ']' => .r_bracket,
        '(' => .l_paren,
        ')' => .r_paren,
        '{' => .l_brace,
        '}' => .r_brace,
        ',' => .comma,
        ';' => .semicolon,
        ':' => .colon,
        '=' => .equal,
        '*' => .star,
        '-' => .minus,
        '?' => .question,
        '!' => .bang,
        '.' => .dot,
        else => .invalid,
    };
    return .{ .tag = tag, .start = start, .end = start + 1 };
}

/// Annotations the format itself knows.
const Core = enum {
    offset,
    size,
    bit,
    virtual,
    cdecl,
    stdcall,
    thiscall,
    fastcall,
    winapi,
    x64,
    x86,

    const names = [_][]const u8{ "Offset", "Size", "Bit", "Virtual", "Cdecl", "Stdcall", "Thiscall", "Fastcall", "Winapi", "X64", "X86" };

    fn of(text: []const u8) ?Core {
        for (names, 0..) |n, i| if (std.mem.eql(u8, n, text)) return @fromBackingInt(@intCast(i));
        return null;
    }

    fn name(self: Core) []const u8 {
        return names[@backingInt(self)];
    }

    fn conv(self: Core) ?Schema.Conv {
        return switch (self) {
            .cdecl => .cdecl,
            .stdcall => .stdcall,
            .thiscall => .thiscall,
            .fastcall => .fastcall,
            .winapi => .winapi,
            else => null,
        };
    }
};

const convs = [_]Core{ .cdecl, .stdcall, .thiscall, .fastcall, .winapi };

const Anns = struct {
    at: [Core.names.len]?usize = @splat(null),
    offset: usize = 0,
    size: usize = 0,
    bit: u16 = 0,
    virtual: usize = 0,
    conv: ?Schema.Conv = null,
    /// From `[X64]` or `[X86]`.
    pointer_size: ?u8 = null,
    extra: []const Schema.Annotation = &.{},

    fn has(self: Anns, c: Core) bool {
        return self.at[@backingInt(c)] != null;
    }
};

const Parser = struct {
    const P = @This();

    source: []const u8,
    tok: Token,
    diag: *Schema.Diagnostic,
    opts: Options,
    arena: std.mem.Allocator,
    uses: []const []const u8 = &.{},

    fn init(source: []const u8, diag: *Schema.Diagnostic, opts: Options, arena: std.mem.Allocator) P {
        return .{ .source = source, .tok = scan(source, 0), .diag = diag, .opts = opts, .arena = arena };
    }

    fn List(comptime T: type) type {
        return struct {
            list: std.ArrayList(T) = .empty,

            fn append(self: *@This(), p: *P, item: T) Error!void {
                try self.list.append(p.arena, item);
            }

            fn all(self: *const @This()) []const T {
                return self.list.items;
            }

            fn truncate(self: *@This(), n: usize) void {
                self.list.shrinkRetainingCapacity(n);
            }

            fn done(self: *@This(), p: *P) Error![]const T {
                return self.list.toOwnedSlice(p.arena);
            }
        };
    }

    fn box(p: *P, comptime T: type, value: T) Error!*const T {
        const ptr = try p.arena.create(T);
        ptr.* = value;
        return ptr;
    }

    fn dotted(p: *P, a: []const u8, b: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(p.arena, "{s}.{s}", .{ a, b });
    }

    fn fail(p: *P, at: usize, comptime format: []const u8, args: anytype) Error {
        return p.diag.fail(p.source, at, format, args);
    }

    fn text(p: *const P, tok: Token) []const u8 {
        return p.source[tok.start..tok.end];
    }

    fn advance(p: *P) Token {
        const t = p.tok;
        p.tok = scan(p.source, t.end);
        return t;
    }

    fn peek(p: *const P) Token {
        return scan(p.source, p.tok.end);
    }

    fn expect(p: *P, tag: Token.Tag, comptime what: []const u8) Error!Token {
        if (p.tok.tag != tag) return p.unexpected(what);
        return p.advance();
    }

    fn unexpected(p: *P, comptime what: []const u8) Error {
        return switch (p.tok.tag) {
            .eof => p.fail(p.tok.start, "expected " ++ what ++ ", found the end of the file", .{}),
            .invalid => p.fail(p.tok.start, "expected " ++ what ++ ", found something that isn't valid here (an unclosed string or comment?)", .{}),
            else => p.fail(p.tok.start, "expected " ++ what ++ ", found '{s}'", .{p.text(p.tok)}),
        };
    }

    fn isKeyword(p: *const P, word: []const u8) bool {
        return p.tok.tag == .ident and std.mem.eql(u8, p.text(p.tok), word);
    }

    fn name(p: *P, comptime what: []const u8) Error![]const u8 {
        return p.text(try p.expect(.ident, what));
    }

    fn number(p: *P, comptime T: type, comptime what: []const u8) Error!T {
        const tok = try p.expect(.number, what);
        const n = std.fmt.parseInt(u64, p.text(tok), 0) catch return p.fail(tok.start, "'{s}' isn't a whole number", .{p.text(tok)});
        return std.math.cast(T, n) orelse p.fail(tok.start, what ++ " {d} is out of range", .{n});
    }

    fn int(p: *P, comptime what: []const u8) Error!i128 {
        const negative = p.tok.tag == .minus;
        if (negative) _ = p.advance();
        const tok = try p.expect(.number, what);
        const n = std.fmt.parseInt(i128, p.text(tok), 0) catch return p.fail(tok.start, "'{s}' isn't a whole number", .{p.text(tok)});
        return if (negative) -n else n;
    }

    fn string(p: *P, comptime what: []const u8) Error![]const u8 {
        const tok = try p.expect(.string, what);
        return p.source[tok.start + 1 .. tok.end - 1];
    }

    fn optionalSemicolon(p: *P) void {
        if (p.tok.tag == .semicolon) _ = p.advance();
    }

    fn registered(p: *const P, ns: []const u8) ?Namespace {
        for (p.opts.namespaces) |n| if (std.mem.eql(u8, n.name, ns)) return n;
        return null;
    }

    fn takes(p: *const P, ns: []const u8, ann: []const u8) bool {
        const n = p.registered(ns) orelse return p.opts.any_namespace;
        const list = n.annotations orelse return true;
        for (list) |a| if (std.mem.eql(u8, a, ann)) return true;
        return false;
    }

    fn useNamespace(p: *P, list: *List([]const u8), at: usize, ns: []const u8) Error!void {
        if (p.registered(ns) == null and !p.opts.any_namespace) return p.fail(at, "there's no namespace '{s}'. Tools register theirs", .{ns});
        for (list.all()) |u| if (std.mem.eql(u8, u, ns)) return;
        try list.append(p, ns);
    }

    // Annotations

    fn anns(p: *P) Error!Anns {
        var a: Anns = .{};
        var extra: List(Schema.Annotation) = .{};
        // `[]T` is a slice type, not an annotation
        while (p.tok.tag == .l_bracket and p.peek().tag != .r_bracket) {
            _ = p.advance();
            while (true) {
                try p.annotation(&a, &extra);
                if (p.tok.tag == .comma) {
                    _ = p.advance();
                    continue;
                }
                _ = try p.expect(.r_bracket, "',' or ']'");
                break;
            }
        }
        a.extra = try extra.done(p);
        return a;
    }

    fn annotation(p: *P, a: *Anns, extra: *List(Schema.Annotation)) Error!void {
        const tok = p.tok;
        if (tok.tag == .number) {
            if (a.has(.offset)) return p.fail(tok.start, "there's already an offset", .{});
            a.offset = try p.number(usize, "an offset");
            a.at[@backingInt(Core.offset)] = tok.start;
            return;
        }
        const first = try p.name("an annotation");
        var ns: []const u8 = "";
        var n = first;
        if (p.tok.tag == .dot) {
            _ = p.advance();
            ns = first;
            n = try p.name("the annotation's name");
        }
        if (ns.len == 0) if (Core.of(n)) |c| return p.core(a, c, tok);

        if (ns.len > 0) {
            if (p.registered(ns) == null and !p.opts.any_namespace) return p.fail(tok.start, "there's no namespace '{s}'. Tools register theirs", .{ns});
            if (!p.takes(ns, n)) return p.fail(tok.start, "there's no [{s}.{s}]", .{ ns, n });
        } else {
            for (p.uses) |u| if (p.takes(u, n)) {
                if (ns.len > 0) return p.fail(tok.start, "[{s}] could be {s}.{s} or {s}.{s}. Write the one you mean", .{ n, ns, n, u, n });
                ns = u;
            };
            if (ns.len == 0) return p.fail(tok.start, "there's no [{s}]. The core ones are Offset, Size, Bit, Virtual, X64, X86 and the calling conventions. Others need their namespace, like [wraith.{s}], or a `use`", .{ n, n });
        }
        const list = if (p.tok.tag == .l_paren) try p.argList() else &.{};
        try extra.append(p, .{ .namespace = ns, .name = n, .args = list, .at = @intCast(tok.start) });
    }

    fn core(p: *P, a: *Anns, c: Core, tok: Token) Error!void {
        if (a.has(c)) return p.fail(tok.start, "there's already a [{s}]", .{c.name()});
        a.at[@backingInt(c)] = tok.start;
        if (c.conv()) |conv| {
            if (a.conv != null) return p.fail(tok.start, "there's already a calling convention", .{});
            a.conv = conv;
            return;
        }
        if (c == .x64 or c == .x86) {
            if (a.pointer_size != null) return p.fail(tok.start, "there's already an [X64] or [X86]", .{});
            a.pointer_size = if (c == .x64) 8 else 4;
            return;
        }
        _ = try p.expect(.l_paren, "'('");
        switch (c) {
            .offset => a.offset = try p.number(usize, "an offset"),
            .size => a.size = try p.number(usize, "a size"),
            .bit => a.bit = try p.number(u16, "a bit"),
            .virtual => a.virtual = try p.number(usize, "a vtable slot"),
            else => unreachable,
        }
        _ = try p.expect(.r_paren, "')'");
    }

    fn argList(p: *P) Error![]const Schema.Arg {
        _ = try p.expect(.l_paren, "'('");
        var list: List(Schema.Arg) = .{};
        while (p.tok.tag != .r_paren) {
            try list.append(p, try p.arg());
            if (p.tok.tag == .comma) _ = p.advance() else if (p.tok.tag != .r_paren) return p.unexpected("',' or ')'");
        }
        _ = p.advance();
        return list.done(p);
    }

    fn arg(p: *P) Error!Schema.Arg {
        switch (p.tok.tag) {
            .string => return .{ .string = try p.string("a string") },
            .minus, .number => return switch (try p.literal()) {
                .int => |n| .{ .int = n },
                .float => |f| .{ .float = f },
                else => unreachable,
            },
            .ident => {
                const n = p.text(p.advance());
                if (p.tok.tag == .l_paren) return .{ .call = .{ .name = n, .args = try p.argList() } };
                return .{ .ident = n };
            },
            else => return p.unexpected("a number, a string or a name"),
        }
    }

    fn allow(p: *P, a: Anns, allowed: []const Core, what: []const u8) Error!void {
        outer: for (a.at, 0..) |at, i| {
            const pos = at orelse continue;
            for (allowed) |ok| if (@backingInt(ok) == i) continue :outer;
            const which: Core = @fromBackingInt(@intCast(i));
            return p.fail(pos, "{s} can't have [{s}]", .{ what, which.name() });
        }
    }

    // Types

    fn typeRef(p: *P) Error!Ref {
        var r = try p.typeNoResult();
        if (p.tok.tag == .bang) {
            _ = p.advance();
            const ok = try p.box(Ref, r);
            r = .{ .result = .{ .ok = ok, .err = try p.name("an error set's name, like 'T!LoadError'") } };
        }
        return r;
    }

    fn typeNoResult(p: *P) Error!Ref {
        if (p.tok.tag == .question) {
            _ = p.advance();
            return .{ .optional = try p.box(Ref, try p.typeNoResult()) };
        }
        if (p.tok.tag == .l_bracket) {
            _ = p.advance();
            _ = try p.expect(.r_bracket, "']' for a slice. Arrays go after the type, like u8[4]");
            return .{ .slice = try p.box(Ref, try p.typeNoResult()) };
        }
        if (p.isKeyword("fn")) {
            _ = p.advance();
            const params = try p.paramList();
            const ret = try p.typeRef();
            return .{ .func = try p.box(Schema.Signature, .{ .params = params, .ret = ret }) };
        }
        const tok = try p.expect(.ident, "a type");
        const t = p.text(tok);
        var r: Ref = if (std.meta.stringToEnum(Schema.Prim, t)) |prim| .{ .prim = prim } else .{ .named = t };
        while (true) switch (p.tok.tag) {
            .star => {
                _ = p.advance();
                const child = try p.box(Ref, r);
                r = .{ .pointer = child };
            },
            .l_bracket => {
                if (p.peek().tag == .r_bracket) return p.fail(p.tok.start, "a slice's [] goes in front, like []u8", .{});
                _ = p.advance();
                const len = try p.number(usize, "an array length");
                _ = try p.expect(.r_bracket, "']'");
                const child = try p.box(Ref, r);
                r = .{ .array = .{ .len = len, .child = child } };
            },
            else => break,
        };
        return r;
    }

    fn paramList(p: *P) Error![]const Schema.Param {
        _ = try p.expect(.l_paren, "'(' and the parameters");
        var list: List(Schema.Param) = .{};
        while (p.tok.tag != .r_paren) {
            const at = p.tok.start;
            const keep = p.isKeyword("keep");
            if (keep) _ = p.advance();
            const inout = p.isKeyword("inout");
            if (inout) _ = p.advance();
            const plain = try p.typeRef();
            // Crosses as a pointer to it, which the callee can change, or null for `inout ?T`
            const ty: Ref = if (!inout) plain else if (plain == .optional)
                .{ .optional = try p.box(Ref, .{ .pointer = plain.optional }) }
            else
                .{ .pointer = try p.box(Ref, plain) };
            const n = try p.name("the parameter's name");
            try list.append(p, .{ .name = n, .type = ty, .at = @intCast(at), .keep = keep, .inout = inout });
            if (p.tok.tag == .comma) _ = p.advance() else if (p.tok.tag != .r_paren) return p.unexpected("',' or ')'");
        }
        _ = p.advance();
        return list.done(p);
    }

    const Literal = Schema.Constant.Value;

    fn literal(p: *P) Error!Literal {
        if (p.isKeyword("true") or p.isKeyword("false")) return .{ .bool = p.text(p.advance())[0] == 't' };
        if (p.tok.tag == .string) return .{ .string = try p.string("a string") };
        const negative = p.tok.tag == .minus;
        if (negative) _ = p.advance();
        const tok = try p.expect(.number, "a value");
        const t = p.text(tok);
        const is_hex = t.len > 1 and (t[1] == 'x' or t[1] == 'X');
        if (!is_hex and (std.mem.indexOfAny(u8, t, ".eE") != null)) {
            const f = std.fmt.parseFloat(f64, t) catch return p.fail(tok.start, "'{s}' isn't a number", .{t});
            return .{ .float = if (negative) -f else f };
        }
        const n = std.fmt.parseInt(i128, t, 0) catch return p.fail(tok.start, "'{s}' isn't a number", .{t});
        return .{ .int = if (negative) -n else n };
    }

    // Declarations

    /// The `use`s at the top of a file, or of each file in a bundle, after a tool's own.
    fn uses_(p: *P) Error!void {
        var uses: List([]const u8) = .{};
        for (p.opts.uses) |u| try p.useNamespace(&uses, 0, u);
        while (p.isKeyword("use")) {
            const at = p.advance().start;
            const ns = try p.name("a namespace");
            try p.useNamespace(&uses, at, ns);
            _ = try p.expect(.semicolon, "';'");
        }
        p.uses = try uses.done(p);
    }

    fn file(p: *P) Error!Schema {
        if (p.isKeyword("file")) try p.fileMarker();
        try p.uses_();
        const first_uses = p.uses;

        var types: List(Schema.Type) = .{};
        var traits: List(Schema.Trait) = .{};
        var impls: List(Schema.Impl) = .{};
        var constants: List(Schema.Constant) = .{};
        var functions: List(Schema.Method) = .{};
        var statics: List(Schema.Static) = .{};
        while (p.tok.tag != .eof) {
            var a = try p.anns();
            // Declarations for the other kind of code are parsed, then dropped
            const only = a.pointer_size;
            a.at[@backingInt(Core.x64)] = null;
            a.at[@backingInt(Core.x86)] = null;
            const before = .{ types.all().len, traits.all().len, impls.all().len, constants.all().len, functions.all().len, statics.all().len };
            defer if (only) |size| if (size != p.opts.pointer_size) {
                types.truncate(before[0]);
                traits.truncate(before[1]);
                impls.truncate(before[2]);
                constants.truncate(before[3]);
                functions.truncate(before[4]);
                statics.truncate(before[5]);
            };
            if (p.isKeyword("struct") or p.isKeyword("union")) {
                try types.append(p, try p.structDef(a, &types));
            } else if (p.isKeyword("enum")) {
                try types.append(p, try p.enumDef(a));
            } else if (p.isKeyword("bitfield")) {
                try types.append(p, try p.bitfieldDef(a));
            } else if (p.isKeyword("error")) {
                try types.append(p, try p.errorDef(a));
            } else if (p.isKeyword("opaque")) {
                const kw = p.advance();
                try p.allow(a, &.{}, "an opaque type");
                const n = try p.name("the type's name");
                _ = try p.expect(.semicolon, "';'");
                try types.append(p, .{ .name = n, .at = @intCast(kw.start), .annotations = a.extra, .kind = .@"opaque" });
            } else if (p.isKeyword("fn")) {
                // A named function type, like `fn void Task(u32 id);`
                const kw = p.advance();
                try p.allow(a, &convs, "a function type");
                const ret = try p.typeRef();
                const n = try p.name("the function type's name");
                const params = try p.paramList();
                _ = try p.expect(.semicolon, "';'");
                try types.append(p, .{ .name = n, .at = @intCast(kw.start), .annotations = a.extra, .kind = .{ .func = .{ .params = params, .ret = ret, .conv = a.conv orelse .c } } });
            } else if (p.isKeyword("trait")) {
                try traits.append(p, try p.traitDef(a));
            } else if (p.isKeyword("impl")) {
                try impls.append(p, try p.implDef(a));
            } else if (p.isKeyword("const")) {
                try constants.append(p, try p.constDef(a));
            } else if (p.isKeyword("file")) {
                // The next file in a bundle, with its own `use`s
                try p.allow(a, &.{}, "a file");
                try p.fileMarker();
                try p.uses_();
            } else if (p.isKeyword("use")) {
                return p.fail(p.tok.start, "`use` goes at the top of the file, before anything else", .{});
            } else if (p.isKeyword("static")) {
                // A global in existing code, like `[Sig("..")] static Player* player;`
                const at = p.advance().start;
                const ty = try p.typeRef();
                const n = try p.name("the static's name");
                try statics.append(p, try p.gameStatic(a, ty, n, at));
            } else if (p.tok.tag == .ident or p.tok.tag == .question) {
                // A function in existing code, like `[Sig("..")] i32 spawn(u32 kind);`
                const at = p.tok.start;
                const ret = try p.typeRef();
                const n = try p.name("the function's name");
                if (p.tok.tag != .l_paren) return p.fail(at, "expected struct, union, enum, bitfield, error, opaque, fn, trait, impl, const, static or a function like 'i32 spawn(u32 kind);'", .{});
                try functions.append(p, try p.gameMethod(a, ret, n, at, false, true));
            } else {
                return p.unexpected("struct, union, enum, bitfield, error, opaque, fn, trait, impl, const, static or a function");
            }
        }
        return .{
            .pointer_size = p.opts.pointer_size,
            .uses = first_uses,
            .types = try types.done(p),
            .traits = try traits.done(p),
            .impls = try impls.done(p),
            .constants = try constants.done(p),
            .functions = try functions.done(p),
            .statics = try statics.done(p),
        };
    }

    /// `file "name.sal";`, which a bundle puts before each file.
    fn fileMarker(p: *P) Error!void {
        _ = p.advance();
        _ = try p.expect(.string, "the file's name, in quotes");
        _ = try p.expect(.semicolon, "';'");
    }

    /// A field's own bitfield goes in `types` too.
    fn structDef(p: *P, a: Anns, types: *List(Schema.Type)) Error!Schema.Type {
        const is_union = p.isKeyword("union");
        const kw = p.advance();
        try p.allow(a, &.{.size}, if (is_union) "a union" else "a struct");
        const type_name = try p.name("the type's name");
        var s: Schema.Struct = .{};
        if (p.tok.tag == .colon) {
            if (is_union) return p.fail(p.tok.start, "a union can't have a base", .{});
            _ = p.advance();
            s.base = try p.name("a base type");
        }
        _ = try p.expect(.l_brace, "'{{'");
        var fields: List(Schema.Field) = .{};
        var methods: List(Schema.Method) = .{};
        var statics: List(Schema.Static) = .{};
        while (p.tok.tag != .r_brace) {
            const fa = try p.anns();
            const at = p.tok.start;
            if (p.isKeyword("static")) {
                if (is_union) return p.fail(at, "{s}: a union only holds data", .{type_name});
                _ = p.advance();
                const ty = try p.typeRef();
                const n = try p.name("the static's name");
                if (p.tok.tag == .l_paren) {
                    try methods.append(p, try p.gameMethod(fa, ty, n, at, true, true));
                } else {
                    try statics.append(p, try p.gameStatic(fa, ty, n, at));
                }
                continue;
            }
            const ty = try p.typeRef();
            const n = try p.name("the field's name");
            if (p.tok.tag == .l_paren) {
                if (is_union) return p.fail(at, "{s}: a union only holds data", .{type_name});
                try methods.append(p, try p.gameMethod(fa, ty, n, at, true, false));
                continue;
            }
            try p.allow(fa, if (is_union) &.{} else &.{.offset}, if (is_union) "a union field" else "a field");
            const offset = if (fa.has(.offset)) fa.offset else Schema.Type.auto;
            if (p.tok.tag == .l_brace) {
                // Its own bitfield, like `u8 flags { bool alive; [Bit(4)] bool dead; }`
                const backing: ?Schema.Prim = switch (ty) {
                    .prim => |prim| if (prim.isInt() and !prim.isSigned()) prim else null,
                    else => null,
                };
                if (backing == null) return p.fail(at, "{s}.{s}: a field with bits is an unsigned int, not {f}", .{ type_name, n, ty });
                const bits_name = try p.dotted(type_name, n);
                try types.append(p, .{ .name = bits_name, .at = @intCast(at), .nested = true, .kind = .{ .bitfield = .{ .backing = backing.?, .members = try p.bitsBody(bits_name) } } });
                try fields.append(p, .{ .name = n, .type = .{ .named = bits_name }, .offset = offset, .at = @intCast(at), .annotations = fa.extra });
                continue;
            }
            _ = try p.expect(.semicolon, "';'");
            try fields.append(p, .{ .name = n, .type = ty, .offset = offset, .at = @intCast(at), .annotations = fa.extra });
        }
        _ = p.advance();
        p.optionalSemicolon();
        if (try p.instanceOf(a, type_name, is_union)) |v| try statics.append(p, v);
        s.fields = try fields.done(p);
        s.methods = try methods.done(p);
        s.statics = try statics.done(p);
        return .{
            .name = type_name,
            .at = @intCast(kw.start),
            .size = if (a.has(.size)) a.size else Schema.Type.auto,
            .annotations = a.extra,
            .kind = if (is_union) .{ .@"union" = s } else .{ .@"struct" = s },
        };
    }

    /// A function in existing code, after its return type and name. A struct's can be `[Virtual(n)]`.
    fn gameMethod(p: *P, a: Anns, ret: Ref, n: []const u8, at: usize, in_struct: bool, static: bool) Error!Schema.Method {
        try p.allow(a, if (in_struct and !static) &(convs ++ [_]Core{.virtual}) else &convs, if (static and in_struct) "a static method" else if (in_struct) "a method" else "a function");
        const params = try p.paramList();
        _ = try p.expect(.semicolon, "';'");
        return .{
            .name = n,
            .signature = .{ .params = params, .ret = ret, .conv = a.conv orelse .c },
            .static = static or !in_struct,
            .virtual = if (a.has(.virtual)) a.virtual else null,
            .at = @intCast(at),
            .annotations = a.extra,
        };
    }

    /// `Type.instance` for a struct tagged with one of `opts.instances`.
    fn instanceOf(p: *P, a: Anns, type_name: []const u8, is_union: bool) Error!?Schema.Static {
        for (a.extra, 0..) |ann, i| for (p.opts.instances) |tag| {
            if (!std.mem.eql(u8, ann.namespace, tag.namespace) or !std.mem.eql(u8, ann.name, tag.name)) continue;
            if (is_union) return p.fail(ann.at, "[{s}] goes on a struct, and {s} is a union", .{ tag.name, type_name });
            const annotations = try p.arena.dupe(Schema.Annotation, a.extra);
            annotations[i].name = tag.as;
            const self = try p.arena.create(Ref);
            self.* = .{ .named = type_name };
            return .{ .name = "instance", .type = .{ .pointer = self }, .at = ann.at, .annotations = annotations };
        };
        return null;
    }

    /// A global in existing code, after its type and name.
    fn gameStatic(p: *P, a: Anns, ty: Ref, n: []const u8, at: usize) Error!Schema.Static {
        try p.allow(a, &.{}, "a static");
        _ = try p.expect(.semicolon, "';' or '(' and its parameters");
        return .{ .name = n, .type = ty, .at = @intCast(at), .annotations = a.extra };
    }

    fn backingType(p: *P, comptime example: []const u8) Error!Schema.Prim {
        _ = try p.expect(.colon, "':' and its backing type, like '" ++ example ++ "'");
        const tok = try p.expect(.ident, "a backing type");
        const prim = std.meta.stringToEnum(Schema.Prim, p.text(tok));
        if (prim == null or !prim.?.isInt()) return p.fail(tok.start, "a backing type is an int, not {s}", .{p.text(tok)});
        return prim.?;
    }

    fn enumDef(p: *P, a: Anns) Error!Schema.Type {
        const kw = p.advance();
        try p.allow(a, &.{}, "an enum");
        const type_name = try p.name("the type's name");
        const backing = try p.backingType("enum Job : u8");
        _ = try p.expect(.l_brace, "'{{'");
        var values: List(Schema.Enum.Value) = .{};
        var next: i128 = 0;
        while (p.tok.tag != .r_brace) {
            const at = p.tok.start;
            const n = try p.name("a value's name");
            if (p.tok.tag == .equal) {
                _ = p.advance();
                next = try p.int("a value");
            }
            try values.append(p, .{ .name = n, .value = next, .at = @intCast(at) });
            next += 1;
            if (p.tok.tag == .comma) _ = p.advance() else if (p.tok.tag != .r_brace) return p.unexpected("',' or '}}'");
        }
        _ = p.advance();
        p.optionalSemicolon();
        return .{ .name = type_name, .at = @intCast(kw.start), .annotations = a.extra, .kind = .{ .@"enum" = .{ .backing = backing, .values = try values.done(p) } } };
    }

    fn bitfieldDef(p: *P, a: Anns) Error!Schema.Type {
        const kw = p.advance();
        try p.allow(a, &.{}, "a bitfield");
        const type_name = try p.name("the type's name");
        const backing = try p.backingType("bitfield Flags : u32");
        if (backing.isSigned()) return p.fail(kw.start, "{s}: a bitfield's backing type is unsigned", .{type_name});
        return .{ .name = type_name, .at = @intCast(kw.start), .annotations = a.extra, .kind = .{ .bitfield = .{ .backing = backing, .members = try p.bitsBody(type_name) } } };
    }

    fn bitsBody(p: *P, type_name: []const u8) Error![]const Schema.Bits {
        _ = try p.expect(.l_brace, "'{{'");
        var members: List(Schema.Bits) = .{};
        var next: u16 = 0;
        while (p.tok.tag != .r_brace) {
            const ma = try p.anns();
            try p.allow(ma, &.{.bit}, "a bitfield member");
            const type_tok = try p.expect(.ident, "a type: bool, an unsigned int or an enum");
            const ty = p.text(type_tok);
            const n = try p.name("the member's name");
            var width: ?u16 = null;
            if (p.tok.tag == .colon) {
                _ = p.advance();
                width = try p.number(u16, "a width in bits");
            }
            _ = try p.expect(.semicolon, "';'");

            var member: Schema.Bits.Member = undefined;
            var bits: u16 = undefined;
            if (std.meta.stringToEnum(Schema.Prim, ty)) |prim| {
                if (prim == .bool) {
                    member = .bool;
                    bits = width orelse 1;
                } else if (prim.isInt() and !prim.isSigned()) {
                    member = .uint;
                    const max: u16 = @intCast(prim.size(p.opts.pointer_size) * 8);
                    bits = width orelse max;
                    if (bits > max) return p.fail(type_tok.start, "{s}.{s}: a {s} is {d} bits, not {d}", .{ type_name, n, ty, max, bits });
                } else {
                    return p.fail(type_tok.start, "{s}.{s}: a bitfield member is a bool, an unsigned int or an enum, not {s}", .{ type_name, n, ty });
                }
            } else {
                member = .{ .@"enum" = ty };
                bits = width orelse return p.fail(type_tok.start, "{s}.{s}: an enum member needs a width, like '{s} {s} : 4;'", .{ type_name, n, ty, n });
            }
            if (bits == 0) return p.fail(type_tok.start, "{s}.{s} needs at least one bit", .{ type_name, n });
            const bit = if (ma.has(.bit)) ma.bit else next;
            try members.append(p, .{ .name = n, .bit = bit, .bits = bits, .type = member, .at = @intCast(type_tok.start) });
            next = bit +| bits;
        }
        _ = p.advance();
        p.optionalSemicolon();
        return members.done(p);
    }

    fn errorDef(p: *P, a: Anns) Error!Schema.Type {
        const kw = p.advance();
        try p.allow(a, &.{}, "an error set");
        const type_name = try p.name("the error set's name");
        _ = try p.expect(.l_brace, "'{{'");
        var errors: List(Schema.ErrorSet.Error) = .{};
        var next: u32 = 1;
        while (p.tok.tag != .r_brace) {
            const at = p.tok.start;
            const n = try p.name("an error's name");
            if (p.tok.tag == .equal) {
                _ = p.advance();
                next = try p.number(u32, "an error code");
            }
            try errors.append(p, .{ .name = n, .code = next, .at = @intCast(at) });
            next +|= 1;
            if (p.tok.tag == .comma) _ = p.advance() else if (p.tok.tag != .r_brace) return p.unexpected("',' or '}}'");
        }
        _ = p.advance();
        p.optionalSemicolon();
        return .{ .name = type_name, .at = @intCast(kw.start), .annotations = a.extra, .kind = .{ .@"error" = .{ .errors = try errors.done(p) } } };
    }

    fn traitDef(p: *P, a: Anns) Error!Schema.Trait {
        const kw = p.advance();
        try p.allow(a, &.{}, "a trait");
        const trait_name = try p.name("the trait's name");
        var bases: List([]const u8) = .{};
        if (p.tok.tag == .colon) {
            _ = p.advance();
            while (true) {
                try bases.append(p, try p.name("a base trait"));
                if (p.tok.tag != .comma) break;
                _ = p.advance();
            }
        }
        _ = try p.expect(.l_brace, "'{{'");
        var methods: List(Schema.Method) = .{};
        while (p.tok.tag != .r_brace) {
            const ma = try p.anns();
            const at = p.tok.start;
            try p.allow(ma, &convs, "a method");
            var static = false;
            var is_async = false;
            while (true) {
                if (p.isKeyword("static")) {
                    if (static) return p.fail(p.tok.start, "there's already a `static`", .{});
                    static = true;
                } else if (p.isKeyword("async")) {
                    if (is_async) return p.fail(p.tok.start, "there's already an `async`", .{});
                    is_async = true;
                } else break;
                _ = p.advance();
            }
            const ret = try p.typeRef();
            const n = try p.name("the method's name");
            if (p.tok.tag != .l_paren) return p.fail(at, "{s}.{s}: a trait only has methods, like '{f} {s}();'. Data goes in a struct", .{ trait_name, n, ret, n });
            const params = try p.paramList();
            _ = try p.expect(.semicolon, "';'");
            try methods.append(p, .{
                .name = n,
                .signature = .{ .params = params, .ret = ret, .conv = ma.conv orelse .c },
                .static = static,
                .async = is_async,
                .at = @intCast(at),
                .annotations = ma.extra,
            });
        }
        _ = p.advance();
        p.optionalSemicolon();
        return .{ .name = trait_name, .at = @intCast(kw.start), .bases = try bases.done(p), .methods = try methods.done(p), .annotations = a.extra };
    }

    fn implDef(p: *P, a: Anns) Error!Schema.Impl {
        const kw = p.advance();
        try p.allow(a, &convs, "an impl");
        const trait = try p.name("the trait's name");
        if (!p.isKeyword("for")) return p.unexpected("'for' and a struct, like 'impl Damageable for Player'");
        _ = p.advance();
        const for_type = try p.name("the struct's name");
        var items: List(Schema.Item) = .{};
        if (p.tok.tag == .semicolon) {
            _ = p.advance();
        } else {
            _ = try p.expect(.l_brace, "'{{' or ';'");
            while (p.tok.tag != .r_brace) try items.append(p, try p.implItem());
            _ = p.advance();
            p.optionalSemicolon();
        }
        return .{ .trait = trait, .@"for" = for_type, .items = try items.done(p), .conv = a.conv, .at = @intCast(kw.start), .annotations = a.extra };
    }

    fn implItem(p: *P) Error!Schema.Item {
        const ia = try p.anns();
        const at = p.tok.start;
        const n = try p.name("a method's name");
        var source: Schema.Source = undefined;
        if (p.tok.tag == .equal) {
            _ = p.advance();
            try p.allow(ia, &.{}, "a method mapped with '='");
            if (p.isKeyword("field")) {
                _ = p.advance();
                const first = try p.expect(.ident, "a field's name");
                var end = first.end;
                while (p.tok.tag == .dot) {
                    _ = p.advance();
                    end = (try p.expect(.ident, "a field's name")).end;
                }
                source = .{ .field = p.source[first.start..end] };
            } else if (p.isKeyword("fn")) {
                _ = p.advance();
                source = .{ .alias = try p.name("a method's name") };
            } else return p.unexpected("'field' or 'fn', like 'health = field hp;'");
        } else {
            try p.allow(ia, &(convs ++ [_]Core{.virtual}), "an impl's method");
            source = if (ia.has(.virtual))
                .{ .virtual = ia.virtual }
            else if (ia.extra.len > 0)
                .external
            else
                return p.fail(at, "{s} needs to say where it is: [Virtual(n)], a tool's annotation, '= field f' or '= fn other'. Leave it out if the struct doesn't have it", .{n});
        }
        _ = try p.expect(.semicolon, "';'");
        return .{ .method = n, .source = source, .conv = ia.conv, .at = @intCast(at), .annotations = ia.extra };
    }

    fn constDef(p: *P, a: Anns) Error!Schema.Constant {
        _ = p.advance();
        try p.allow(a, &.{}, "a constant");
        const at = p.tok.start;
        const ty = try p.typeRef();
        const n = try p.name("the constant's name");
        _ = try p.expect(.equal, "'=' and its value");
        const value = try p.literal();
        _ = try p.expect(.semicolon, "';'");
        return .{ .name = n, .type = ty, .value = value, .at = @intCast(at), .annotations = a.extra };
    }

    // Layout

    const visiting = std.math.maxInt(u16);

    fn layout(p: *P, s: *Schema) Error!void {
        try p.layoutAll(s.*, @constCast(s.types));
    }

    fn layoutAll(p: *P, s: Schema, types: []Schema.Type) Error!void {
        var view = s;
        view.types = types;
        for (0..types.len) |i| try p.layoutType(view, types, i);
    }

    fn typeIndex(types: []const Schema.Type, n: []const u8) ?usize {
        for (types, 0..) |t, i| if (std.mem.eql(u8, t.name, n)) return i;
        return null;
    }

    fn layoutType(p: *P, s: Schema, types: []Schema.Type, i: usize) Error!void {
        const t = &types[i];
        if (t.alignment == visiting) return p.fail(t.at, "{s} contains itself. Use a pointer", .{t.name});
        if (t.alignment != 0) return;
        const ps = s.pointer_size;
        switch (t.kind) {
            .@"enum" => |e| {
                t.size = e.backing.size(ps);
                t.alignment = @intCast(e.backing.alignment(ps));
            },
            .bitfield => |b| {
                t.size = b.backing.size(ps);
                t.alignment = @intCast(b.backing.alignment(ps));
            },
            .@"error", .@"opaque" => {
                t.size = 0;
                t.alignment = 1;
            },
            .func => {
                t.size = 2 * @as(usize, ps);
                t.alignment = ps;
            },
            .@"struct", .@"union" => |st| {
                const is_union = t.kind == .@"union";
                t.alignment = visiting;
                var cursor: usize = 0;
                var end: usize = 0;
                var max_align: usize = 1;
                if (st.base) |b| {
                    const bi = typeIndex(types, b) orelse return p.fail(t.at, "{s}'s base {s} isn't a type", .{ t.name, b });
                    if (types[bi].kind != .@"struct") return p.fail(t.at, "{s}'s base {s} isn't a struct", .{ t.name, b });
                    if (types[bi].alignment == visiting) return p.fail(t.at, "{s}'s bases go in a circle", .{t.name});
                    try p.layoutType(s, types, bi);
                    cursor = types[bi].size;
                    end = cursor;
                    max_align = types[bi].alignment;
                }
                var fields: List(Schema.Field) = .{};
                for (st.fields) |f| {
                    try p.layoutRef(s, types, f.type, f.at);
                    const m = s.memory(f.type) orelse return p.fail(f.at, "{s}.{s}: {s}", .{ t.name, f.name, P.whyNotMemory(f.type) });
                    var out = f;
                    if (is_union) {
                        out.offset = 0;
                    } else if (out.offset == Schema.Type.auto) {
                        out.offset = std.mem.alignForward(usize, cursor, m.alignment);
                    }
                    cursor = out.offset + m.size;
                    end = @max(end, cursor);
                    max_align = @max(max_align, m.alignment);
                    try fields.append(p, out);
                }
                var done = st;
                done.fields = try fields.done(p);
                t.kind = if (is_union) .{ .@"union" = done } else .{ .@"struct" = done };
                if (t.size == Schema.Type.auto) {
                    t.size = std.mem.alignForward(usize, end, max_align);
                } else if (t.size < end) {
                    return p.fail(t.at, "{s} is [Size(0x{x})], but its fields need 0x{x}", .{ t.name, t.size, end });
                }
                // Like Zig's extern struct, each field only counts as far as its offset and the size allow
                var a: usize = 1;
                var chain: ?*const Schema.Type = t;
                while (chain) |cur| : (chain = if (cur.kind == .@"struct") (if (cur.kind.@"struct".base) |b| &types[typeIndex(types, b).?] else null) else null) {
                    for (switch (cur.kind) {
                        .@"struct", .@"union" => |x| x.fields,
                        else => unreachable,
                    }) |f| a = @max(a, Schema.fitAlign((s.memory(f.type) orelse unreachable).alignment, f.offset, t.size));
                }
                t.alignment = @intCast(a);
            },
        }
    }

    fn whyNotMemory(r: Ref) []const u8 {
        return switch (r) {
            .named => "an opaque type only goes behind a pointer, and an error set after a '!'",
            .optional => "in memory, ? only goes on pointers, traits and fn types. Use a bool next to it",
            .result => "a result like 'T!E' is only for returns",
            .prim => "void is only for returns and pointers, like void*",
            .array => |a| whyNotMemory(a.child.*),
            else => "that can't be kept in memory",
        };
    }

    /// Lays out what `r` holds by value first.
    fn layoutRef(p: *P, s: Schema, types: []Schema.Type, r: Ref, at: usize) Error!void {
        switch (r) {
            .named => |n| {
                if (typeIndex(types, n)) |i| return p.layoutType(s, types, i);
                if (s.findTrait(n) == null) return p.fail(at, "there's no type or trait named {s}", .{n});
            },
            .array => |a| try p.layoutRef(s, types, a.child.*, at),
            .optional => |c| try p.layoutRef(s, types, c.*, at),
            else => {},
        }
    }
};
