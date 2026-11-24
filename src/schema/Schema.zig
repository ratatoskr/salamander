//! A parsed `.sal` file. Only slices and plain values, so it's the same at comptime and runtime.

const std = @import("std");

const Schema = @This();

pointer_size: u8 = @sizeOf(usize),
/// Namespaces from `use`, so `[Sig]` can mean `[game.Sig]`.
uses: []const []const u8 = &.{},
types: []const Type = &.{},
traits: []const Trait = &.{},
impls: []const Impl = &.{},
constants: []const Constant = &.{},
/// Existing code's functions, like a game's, found by a tool's annotations like `[Sig]`.
functions: []const Method = &.{},
/// Existing code's globals, found the same way.
statics: []const Static = &.{},
/// Indices of the first `type_order.len` types, sorted by name, so `findType` needn't look at each.
/// Types after them are looked at one by one.
type_order: []const u32 = &.{},

/// Byte offset into the source, for messages.
pub const Pos = u32;

/// What starts each file in a bundle, followed by its name and `";`.
pub const bundle_marker = "file \"";

/// The bundled file `at` is in, like `plugin/game.sal`. Empty outside a bundle.
pub fn fileOf(source: []const u8, at: usize) []const u8 {
    return Diagnostic.fileAt(source, at).name;
}

pub const Diagnostic = struct {
    len: u32 = 0,
    buf: [256]u8 = undefined,

    pub fn print(self: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        var w: std.Io.Writer = .fixed(&self.buf);
        w.print(fmt, args) catch {};
        self.len = @intCast(w.end);
    }

    /// Prints with `line:column: ` in front, or `file:line:column: ` in a bundle.
    pub fn fail(self: *Diagnostic, source: []const u8, at: usize, comptime fmt: []const u8, args: anytype) error{InvalidSchema} {
        const end = @min(at, source.len);
        const f = fileAt(source, end);
        var line: usize = 1;
        var line_start: usize = f.start;
        for (source[f.start..end], f.start..) |c, i| if (c == '\n') {
            line += 1;
            line_start = i + 1;
        };
        if (f.name.len > 0) {
            self.print("{s}:{d}:{d}: " ++ fmt, .{ f.name, line, end - line_start + 1 } ++ args);
        } else {
            self.print("{d}:{d}: " ++ fmt, .{ line, end - line_start + 1 } ++ args);
        }
        return error.InvalidSchema;
    }

    /// The bundled file `at` is in, and where its text starts. No name outside a bundle.
    fn fileAt(source: []const u8, at: usize) struct { name: []const u8, start: usize } {
        var i = at;
        while (i > 0) {
            i -= 1;
            if (i != 0 and source[i - 1] != '\n') continue;
            if (!std.mem.startsWith(u8, source[i..], bundle_marker)) continue;
            const name_start = i + bundle_marker.len;
            const name_end = std.mem.indexOfScalarPos(u8, source, name_start, '"') orelse continue;
            const line_end = std.mem.indexOfScalarPos(u8, source, name_end, '\n') orelse source.len;
            if (line_end >= at) continue;
            return .{ .name = source[name_start..name_end], .start = line_end + 1 };
        }
        return .{ .name = "", .start = 0 };
    }

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }
};

/// `utf8`/`utf16` are inline game text, `string` is borrowed UTF-8 `{ptr, len}`.
/// `object` is any trait object `{data, table}`, like the host's registry.
pub const Prim = enum {
    u8,
    u16,
    u32,
    u64,
    i8,
    i16,
    i32,
    i64,
    f32,
    f64,
    bool,
    usize,
    isize,
    utf8,
    utf16,
    string,
    object,
    void,
    /// Bytes kept by a count, see the runtime's `Blob`. Last so older hashes stay the same.
    blob,
    /// C's `const char*`, UTF-8 up to a zero or null. Borrowed for the call.
    cstring,

    pub fn size(self: Prim, pointer_size: u8) usize {
        return switch (self) {
            .u8, .i8, .bool, .utf8 => 1,
            .u16, .i16, .utf16 => 2,
            .u32, .i32, .f32 => 4,
            .u64, .i64, .f64 => 8,
            .usize, .isize, .cstring => pointer_size,
            .string, .object, .blob => 2 * @as(usize, pointer_size),
            .void => 0,
        };
    }

    pub fn alignment(self: Prim, pointer_size: u8) usize {
        return switch (self) {
            .string, .object, .blob => pointer_size,
            .void => 1,
            else => self.size(pointer_size),
        };
    }

    pub fn isInt(self: Prim) bool {
        return switch (self) {
            .u8, .u16, .u32, .u64, .i8, .i16, .i32, .i64, .usize, .isize => true,
            else => false,
        };
    }

    pub fn isSigned(self: Prim) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .isize => true,
            else => false,
        };
    }

    pub fn isFloat(self: Prim) bool {
        return self == .f32 or self == .f64;
    }
};

/// A type as written. `?` and `[]` cover everything after them, `!E` comes last.
pub const Ref = union(enum) {
    prim: Prim,
    named: []const u8,
    pointer: *const Ref,
    array: Array,
    slice: *const Ref,
    optional: *const Ref,
    result: Result,
    func: *const Signature,

    pub const Array = struct {
        len: usize,
        child: *const Ref,
        /// `T[count]`, a struct field whose length is the field `count` next to it, read when it's
        /// used. Its `len` is 0, so what doesn't read it sees an empty array.
        count: ?[]const u8 = null,

        /// As long as `n`, now it's been read.
        pub fn sized(a: Array, n: usize) Array {
            return .{ .len = n, .child = a.child };
        }
    };

    pub const Result = struct {
        ok: *const Ref,
        /// An `error` set's name.
        err: []const u8,
    };

    const Tag = std.meta.Tag(Ref);

    fn eqlName(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null or b == null) return a == null and b == null;
        return std.mem.eql(u8, a.?, b.?);
    }

    pub fn eql(a: Ref, b: Ref) bool {
        if (@as(Tag, a) != @as(Tag, b)) return false;
        return switch (a) {
            .prim => |p| p == b.prim,
            .named => |n| std.mem.eql(u8, n, b.named),
            .pointer => |c| c.eql(b.pointer.*),
            .array => |x| x.len == b.array.len and x.child.eql(b.array.child.*) and eqlName(x.count, b.array.count),
            .slice => |c| c.eql(b.slice.*),
            .optional => |c| c.eql(b.optional.*),
            .result => |r| std.mem.eql(u8, r.err, b.result.err) and r.ok.eql(b.result.ok.*),
            .func => |f| f.eql(b.func.*),
        };
    }

    /// Back in `.sal` syntax.
    pub fn format(self: Ref, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .prim => |p| try w.writeAll(@tagName(p)),
            .named => |n| try w.writeAll(n),
            .pointer => |c| try w.print("{f}*", .{c.*}),
            .array => |a| if (a.count) |n| try w.print("{f}[{s}]", .{ a.child.*, n }) else try w.print("{f}[{d}]", .{ a.child.*, a.len }),
            .slice => |c| try w.print("[]{f}", .{c.*}),
            .optional => |c| try w.print("?{f}", .{c.*}),
            .result => |r| try w.print("{f}!{s}", .{ r.ok.*, r.err }),
            .func => |f| try w.print("fn{f}", .{f.*}),
        }
    }
};

/// `.c` is the platform's own. `.winapi` is stdcall on x86 and the Windows ABI elsewhere.
pub const Conv = enum { c, cdecl, stdcall, thiscall, fastcall, winapi };

pub const Param = struct {
    name: []const u8,
    type: Ref,
    at: Pos = 0,
    /// The objects in it outlive the call. Otherwise they're borrowed for it, like strings.
    keep: bool = false,
    /// `inout T` crosses as a `T*` the callee can change. Scripts see their own object written back after,
    /// or a `{ value }` box for non-objects. `inout ?T` is `?T*` so scripts can pass null.
    inout: bool = false,

    /// What an `inout` one points at.
    pub fn inoutType(p: Param) ?Ref {
        if (!p.inout) return null;
        return switch (p.type) {
            .pointer => |c| c.*,
            .optional => |o| o.pointer.*,
            else => unreachable,
        };
    }

    pub fn nullable(p: Param) bool {
        return p.inout and p.type == .optional;
    }
};

pub const Signature = struct {
    params: []const Param = &.{},
    ret: Ref = .{ .prim = .void },
    conv: Conv = .c,

    /// Parameter names don't count.
    pub fn eql(a: Signature, b: Signature) bool {
        if (a.conv != b.conv or a.params.len != b.params.len or !a.ret.eql(b.ret)) return false;
        for (a.params, b.params) |x, y| if (x.keep != y.keep or x.inout != y.inout or !x.type.eql(y.type)) return false;
        return true;
    }

    /// `(f32 dt, Vec3 p) void`
    pub fn format(self: Signature, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("(");
        for (self.params, 0..) |p, i| {
            if (i > 0) try w.writeAll(", ");
            if (p.inoutType()) |t| {
                try w.print("inout {s}{f} {s}", .{ if (p.nullable()) "?" else "", t, p.name });
            } else try w.print("{s}{f} {s}", .{ if (p.keep) "keep " else "", p.type, p.name });
        }
        try w.print(") {f}", .{self.ret});
    }
};

/// One a tool registered, like `[game.Sig("48 8B ..", Offset(3))]`. Core ones become fields instead.
pub const Annotation = struct {
    namespace: []const u8,
    name: []const u8,
    args: []const Arg = &.{},
    at: Pos = 0,
};

pub const Arg = union(enum) {
    int: i128,
    float: f64,
    string: []const u8,
    ident: []const u8,
    call: Call,

    /// A name written bare or quoted, like `count` or `"count"`.
    pub fn name(self: Arg) ?[]const u8 {
        return switch (self) {
            .ident, .string => |n| n,
            else => null,
        };
    }
};

pub const Call = struct {
    name: []const u8,
    args: []const Arg = &.{},
};

pub fn findAnnotation(list: []const Annotation, namespace: []const u8, name: []const u8) ?*const Annotation {
    for (list) |*a| if (std.mem.eql(u8, a.namespace, namespace) and std.mem.eql(u8, a.name, name)) return a;
    return null;
}

pub const Type = struct {
    name: []const u8,
    at: Pos = 0,
    /// From `[Size(n)]`, or worked out by layout.
    size: usize = auto,
    /// 0 until laid out.
    alignment: u16 = 0,
    /// A field's own bitfield, named `Struct.field`.
    nested: bool = false,
    annotations: []const Annotation = &.{},
    kind: Kind,

    pub const auto = std.math.maxInt(usize);

    pub const Kind = union(enum) {
        @"struct": Struct,
        @"union": Struct,
        @"enum": Enum,
        bitfield: Bitfield,
        @"error": ErrorSet,
        /// `opaque Owner;`, only ever behind a pointer.
        @"opaque",
        /// `fn void Task();`, a named function value's type.
        func: Signature,
    };
};

pub const Struct = struct {
    base: ?[]const u8 = null,
    fields: []const Field = &.{},
    /// Its existing code's methods, an impl of its own. Each is a `[Virtual(n)]` slot or found by a
    /// tool's annotations, and takes `this` first unless static.
    methods: []const Method = &.{},
    /// Globals that belong with it, like `Player.instance`.
    statics: []const Static = &.{},
};

/// A global in existing code, like `[Sig("..")] static Player* player;`, found by a tool's annotations.
pub const Static = struct {
    name: []const u8,
    type: Ref,
    at: Pos = 0,
    annotations: []const Annotation = &.{},
};

pub const Field = struct {
    name: []const u8,
    type: Ref,
    /// `Type.auto` until laid out.
    offset: usize = Type.auto,
    at: Pos = 0,
    annotations: []const Annotation = &.{},
};

pub const Enum = struct {
    backing: Prim,
    values: []const Value,

    pub const Value = struct {
        name: []const u8,
        value: i128,
        at: Pos = 0,
    };
};

pub const Bitfield = struct {
    backing: Prim,
    members: []const Bits,
};

pub const Bits = struct {
    name: []const u8,
    bit: u16,
    bits: u16,
    type: Member,
    at: Pos = 0,

    pub const Member = union(enum) {
        uint,
        bool,
        @"enum": []const u8,
    };
};

/// An enum on the wire. 0 is success, and the top three codes are `Cancelled`, `Unsupported` and `Gone`.
pub const ErrorSet = struct {
    errors: []const Error,

    pub const Error = struct {
        name: []const u8,
        code: u32,
        at: Pos = 0,
    };
};

pub const Trait = struct {
    name: []const u8,
    at: Pos = 0,
    bases: []const []const u8 = &.{},
    methods: []const Method = &.{},
    annotations: []const Annotation = &.{},
};

pub const Method = struct {
    name: []const u8,
    signature: Signature,
    /// No `this`.
    static: bool = false,
    async: bool = false,
    /// A struct's method in slot `n` of its vtable, from `[Virtual(n)]`.
    virtual: ?usize = null,
    at: Pos = 0,
    annotations: []const Annotation = &.{},
};

/// `impl Trait for Struct`, saying where an existing struct's methods are.
pub const Impl = struct {
    trait: []const u8,
    @"for": []const u8,
    items: []const Item = &.{},
    /// Default for items that don't say.
    conv: ?Conv = null,
    at: Pos = 0,
    annotations: []const Annotation = &.{},
};

pub const Item = struct {
    method: []const u8,
    source: Source,
    conv: ?Conv = null,
    at: Pos = 0,
    annotations: []const Annotation = &.{},
};

pub const Source = union(enum) {
    /// `[Virtual(n)]`, slot `n` of the vtable at the start of the struct.
    virtual: usize,
    /// `= field pos.x`, a getter or a setter.
    field: []const u8,
    /// `= fn other`
    alias: []const u8,
    /// Only namespaced annotations, like `[game.Sig(...)]`. Their tool finds it.
    external,
};

pub const Constant = struct {
    name: []const u8,
    type: Ref,
    value: Value,
    at: Pos = 0,
    annotations: []const Annotation = &.{},

    pub const Value = union(enum) {
        int: i128,
        float: f64,
        bool: bool,
        string: []const u8,
    };
};

/// Every result can also fail with these, at the top of the code range.
pub const builtin_errors = [_][]const u8{ "Cancelled", "Unsupported", "Gone" };
pub const cancelled_code: u32 = std.math.maxInt(u32) - 2;
pub const unsupported_code: u32 = std.math.maxInt(u32) - 1;
pub const gone_code: u32 = std.math.maxInt(u32);

/// Where `name`'s namespace ends, like the last dot in `Scene.Node`, skipping dots in a generic's
/// `<..>`. Null for a name at the top.
pub fn namespaceEnd(name: []const u8) ?usize {
    var depth: usize = 0;
    var i = name.len;
    while (i > 0) {
        i -= 1;
        switch (name[i]) {
            '>' => depth += 1,
            '<' => depth -|= 1,
            '.' => if (depth == 0) return i,
            else => {},
        }
    }
    return null;
}

/// A name as one identifier, for languages without namespaces or generics. `Game.Player` is
/// `Game_Player` and `StdVector<Item*, u32[4]>` is `StdVector_ItemPtr_u32_4`. Plain names stay as they are.
pub fn writeFlatName(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        const c = name[i];
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            try w.writeByte(c);
            continue;
        }
        switch (c) {
            '*' => try w.writeAll("Ptr"),
            '?' => try w.writeAll("Opt_"),
            '!' => try w.writeAll("_Or_"),
            '>', ']', ' ' => {},
            '[' => if (i + 1 < name.len and name[i + 1] == ']') {
                try w.writeAll("Slice_");
                i += 1;
            } else try w.writeByte('_'),
            ',' => {
                try w.writeByte('_');
                while (i + 1 < name.len and name[i + 1] == ' ') i += 1;
            },
            else => try w.writeByte('_'),
        }
    }
}

/// `writeFlatName`'s, or `name` itself when it's already one identifier.
pub fn flatName(gpa: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') break;
    } else return name;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    writeFlatName(&out.writer, name) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

const Fnv = struct {
    h: u64 = 0xcbf29ce484222325,

    fn bytes(f: *Fnv, b: []const u8) void {
        for (b) |c| f.h = (f.h ^ c) *% 0x100000001b3;
        f.h = (f.h ^ 0xff) *% 0x100000001b3;
    }

    fn int(f: *Fnv, v: u64) void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, v, .little);
        for (buf) |c| f.h = (f.h ^ c) *% 0x100000001b3;
    }

    fn ref(f: *Fnv, r: Ref) void {
        f.int(@backingInt(@as(Ref.Tag, r)));
        switch (r) {
            .prim => |p| f.int(@backingInt(p)),
            .named => |n| f.bytes(n),
            .pointer, .slice, .optional => |c| f.ref(c.*),
            .array => |a| {
                f.int(a.len);
                f.ref(a.child.*);
                if (a.count) |n| f.bytes(n);
            },
            .result => |res| {
                f.ref(res.ok.*);
                f.bytes(res.err);
            },
            .func => |sig| f.signature(sig.*),
        }
    }

    fn signature(f: *Fnv, sig: Signature) void {
        f.int(@backingInt(sig.conv));
        f.int(sig.params.len);
        for (sig.params) |p| {
            // Only when set, so hashes from before `keep` stay the same
            if (p.keep) f.int(0x6b656570);
            if (p.inout) f.int(0x696e6f7574);
            f.ref(p.type);
        }
        f.ref(sig.ret);
    }
};

/// A `fn(...)` value's, which is the same as a plain method's with that signature.
pub fn signatureHash(sig: Signature) u64 {
    var f: Fnv = .{};
    f.int(0);
    f.signature(sig);
    return f.h;
}

/// A method's signature without its name. Callers match on name and this, so a changed one counts as missing.
/// Only what's written goes in, so every language and pointer size agrees.
pub fn methodHash(m: *const Method) u64 {
    var f: Fnv = .{};
    f.int(@as(u64, @intFromBool(m.static)) | (@as(u64, @intFromBool(m.async)) << 1));
    f.signature(m.signature);
    return f.h;
}

/// Covers its bases and its methods' names and signatures, so callers notice a trait that changed.
pub fn traitHash(s: Schema, t: *const Trait) u64 {
    var f: Fnv = .{};
    f.bytes(t.name);
    for (t.bases) |b| if (s.findTrait(b)) |base| f.int(s.traitHash(base));
    for (t.methods) |m| {
        f.bytes(m.name);
        f.int(@as(u64, @intFromBool(m.static)) | (@as(u64, @intFromBool(m.async)) << 1));
        f.signature(m.signature);
    }
    return f.h;
}

pub fn findType(s: Schema, name: []const u8) ?*const Type {
    const order = s.type_order;
    var lo: usize = 0;
    var hi: usize = order.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const t = &s.types[order[mid]];
        switch (std.mem.order(u8, t.name, name)) {
            .eq => return t,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    for (s.types[order.len..]) |*t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

/// Where the type `path` starts with ends, the longest that is one, like `Game.Party` in
/// `Game.Party.members.count`. Null if it doesn't start with one followed by a `.`.
pub fn typePrefix(s: Schema, path: []const u8) ?usize {
    var end = path.len;
    while (std.mem.lastIndexOfScalar(u8, path[0..end], '.')) |dot| : (end = dot) {
        if (s.findType(path[0..dot]) != null) return dot;
    }
    return null;
}

/// A trait object, a function value, `object` or `blob`, which all have their own null.
pub fn isObject(s: Schema, r: Ref) bool {
    return switch (r) {
        .func => true,
        .prim => |p| p == .object or p == .blob,
        .named => |n| s.findTrait(n) != null or s.isFuncType(n),
        else => false,
    };
}

/// Whether `r` has a trait object, function value or `object` in it, through structs, arrays and slices.
pub fn holdsObject(s: Schema, r: Ref) bool {
    return s.holdsObjectIn(r, 0);
}

fn holdsObjectIn(s: Schema, r: Ref, depth: usize) bool {
    if (depth > s.types.len + 4) return false;
    if (s.isObject(r)) return true;
    return switch (r) {
        .optional, .slice => |c| s.holdsObjectIn(c.*, depth + 1),
        .array => |a| s.holdsObjectIn(a.child.*, depth + 1),
        .named => |n| {
            const t = s.findType(n) orelse return false;
            var at: ?*const Type = t;
            while (at) |cur| : (at = s.baseOf(cur)) {
                const st = switch (cur.kind) {
                    .@"struct", .@"union" => |st| st,
                    else => return false,
                };
                for (st.fields) |f| if (s.holdsObjectIn(f.type, depth + 1)) return true;
                if (cur.kind != .@"struct") break;
            }
            return false;
        },
        else => false,
    };
}

pub fn isFuncType(s: Schema, name: []const u8) bool {
    const t = s.findType(name) orelse return false;
    return t.kind == .func;
}

pub fn findTrait(s: Schema, name: []const u8) ?*const Trait {
    for (s.traits) |*t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

pub fn findConstant(s: Schema, name: []const u8) ?*const Constant {
    for (s.constants) |*c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

pub fn findImpl(s: Schema, trait: []const u8, for_type: []const u8) ?*const Impl {
    for (s.impls) |*i| if (std.mem.eql(u8, i.trait, trait) and std.mem.eql(u8, i.@"for", for_type)) return i;
    return null;
}

/// A function in existing code, top-level or a struct's.
pub const Function = struct {
    /// The struct it was asked for, like `Player` in `Player.update`. Null for top-level ones.
    in: ?*const Type = null,
    /// The one that has it, which can be a base of `in`.
    owner: ?*const Type = null,
    method: *const Method,

    pub fn hasThis(f: Function) bool {
        return f.in != null and !f.method.static;
    }
};

/// `spawn` or `Player.heal`, where a struct's comes from it or its bases. Names can be in
/// namespaces, like `Game.spawn` or `Game.Player.heal`.
pub fn findFunction(s: Schema, name: []const u8) ?Function {
    for (s.functions) |*f| if (std.mem.eql(u8, f.name, name)) return .{ .method = f };
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    return s.methodOf(s.findType(name[0..dot]) orelse return null, name[dot + 1 ..]);
}

/// A method of `in` or its bases, virtual or not.
pub fn methodOf(s: Schema, in: *const Type, name: []const u8) ?Function {
    var at: ?*const Type = in;
    var depth: usize = 0;
    while (at) |cur| : (at = s.baseOf(cur)) {
        depth += 1;
        if (depth > s.types.len) return null;
        const st = switch (cur.kind) {
            .@"struct" => |st| st,
            else => return null,
        };
        for (st.methods) |*m| if (std.mem.eql(u8, m.name, name)) return .{ .in = in, .owner = cur, .method = m };
    }
    return null;
}

pub const FoundStatic = struct {
    owner: ?*const Type = null,
    static: *const Static,
};

/// `player` or `Player.instance`, where a struct's comes from it or its bases.
pub fn findStatic(s: Schema, name: []const u8) ?FoundStatic {
    for (s.statics) |*v| if (std.mem.eql(u8, v.name, name)) return .{ .static = v };
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    return s.staticOf(s.findType(name[0..dot]) orelse return null, name[dot + 1 ..]);
}

/// A static of `in` or its bases.
pub fn staticOf(s: Schema, in: *const Type, member: []const u8) ?FoundStatic {
    var at: ?*const Type = in;
    var depth: usize = 0;
    while (at) |cur| : (at = s.baseOf(cur)) {
        depth += 1;
        if (depth > s.types.len) return null;
        const st = switch (cur.kind) {
            .@"struct" => |st| st,
            else => return null,
        };
        for (st.statics) |*v| if (std.mem.eql(u8, v.name, member)) return .{ .owner = cur, .static = v };
    }
    return null;
}

/// What calling `f` takes, with `this` first as a pointer to the struct it was asked for.
pub fn callSignature(f: Function, gpa: std.mem.Allocator) error{OutOfMemory}!Signature {
    var sig = f.method.signature;
    if (!f.hasThis()) return sig;
    const params = try gpa.alloc(Param, sig.params.len + 1);
    const self_type = try gpa.create(Ref);
    self_type.* = .{ .named = f.in.?.name };
    params[0] = .{ .name = "self", .type = .{ .pointer = self_type } };
    @memcpy(params[1..], sig.params);
    sig.params = params;
    return sig;
}

pub fn baseOf(s: Schema, t: *const Type) ?*const Type {
    const st = switch (t.kind) {
        .@"struct" => |st| st,
        else => return null,
    };
    return s.findType(st.base orelse return null);
}

/// A field of a struct or its bases.
pub fn findField(s: Schema, t: *const Type, name: []const u8) ?Field {
    var at: ?*const Type = t;
    var depth: usize = 0;
    while (at) |cur| : (at = s.baseOf(cur)) {
        depth += 1;
        if (depth > s.types.len) return null;
        const st = switch (cur.kind) {
            .@"struct", .@"union" => |st| st,
            else => return null,
        };
        for (st.fields) |f| if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

/// The struct or base that has `name`, and the field.
pub const FoundField = struct {
    owner: *const Type,
    field: *const Field,
};

pub fn fieldOf(s: Schema, t: *const Type, name: []const u8) ?FoundField {
    var at: ?*const Type = t;
    var depth: usize = 0;
    while (at) |cur| : (at = s.baseOf(cur)) {
        depth += 1;
        if (depth > s.types.len) return null;
        const st = switch (cur.kind) {
            .@"struct", .@"union" => |st| st,
            else => return null,
        };
        for (st.fields) |*f| if (std.mem.eql(u8, f.name, name)) return .{ .owner = cur, .field = f };
    }
    return null;
}

pub fn findBits(t: *const Type, name: []const u8) ?*const Bits {
    const b = switch (t.kind) {
        .bitfield => |b| b,
        else => return null,
    };
    for (b.members) |*m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

pub fn enumName(t: *const Type, value: i128) ?[]const u8 {
    const e = switch (t.kind) {
        .@"enum" => |e| e,
        else => return null,
    };
    for (e.values) |v| if (v.value == value) return v.name;
    return null;
}

pub fn enumValue(t: *const Type, name: []const u8) ?i128 {
    const e = switch (t.kind) {
        .@"enum" => |e| e,
        else => return null,
    };
    for (e.values) |v| if (std.mem.eql(u8, v.name, name)) return v.value;
    return null;
}

/// Bytes it takes in memory. Null for what isn't kept there, like `void`.
pub fn sizeOf(s: Schema, r: Ref) ?usize {
    return (s.memory(r) orelse return null).size;
}

/// `pos.x` through structs held by value, with the offset from `t`'s start.
pub fn fieldPath(s: Schema, t: *const Type, path: []const u8) ?Field {
    var parts = std.mem.splitScalar(u8, path, '.');
    var cur = t;
    var offset: usize = 0;
    var found: ?Field = null;
    while (parts.next()) |part| {
        if (found) |f| cur = s.findType(switch (f.type) {
            .named => |n| n,
            else => return null,
        }) orelse return null;
        var f = s.findField(cur, part) orelse return null;
        offset += f.offset;
        f.offset = offset;
        found = f;
    }
    return found;
}

pub const Found = struct {
    trait: *const Trait,
    method: *const Method,
};

/// A trait's own method, or the first base's that has it.
pub fn findMethod(s: Schema, trait: *const Trait, name: []const u8) ?Found {
    return s.findMethodIn(trait, name, 0);
}

fn findMethodIn(s: Schema, trait: *const Trait, name: []const u8, depth: usize) ?Found {
    if (depth > s.traits.len) return null;
    for (trait.methods) |*m| if (std.mem.eql(u8, m.name, name)) return .{ .trait = trait, .method = m };
    for (trait.bases) |b| {
        const base = s.findTrait(b) orelse continue;
        if (s.findMethodIn(base, name, depth + 1)) |f| return f;
    }
    return null;
}

/// Whether `from` is `to` or extends it.
pub fn extends(s: Schema, from: *const Trait, to: *const Trait) bool {
    return s.extendsIn(from, to, 0);
}

fn extendsIn(s: Schema, from: *const Trait, to: *const Trait, depth: usize) bool {
    if (from == to) return true;
    if (depth > s.traits.len) return false;
    for (from.bases) |b| {
        const base = s.findTrait(b) orelse continue;
        if (s.extendsIn(base, to, depth + 1)) return true;
    }
    return false;
}

/// The most of `natural` a field at `offset` in something `size` bytes can have.
pub fn fitAlign(natural: usize, offset: usize, size: usize) usize {
    var a = natural;
    while (a > 1 and (offset % a != 0 or size % a != 0)) a /= 2;
    return a;
}

pub const Memory = struct {
    size: usize,
    alignment: usize,
};

/// Size and alignment in memory once laid out. Null for what isn't kept there, like `void` or `T!E`.
pub fn memory(s: Schema, r: Ref) ?Memory {
    const ps = s.pointer_size;
    const thin: Memory = .{ .size = ps, .alignment = ps };
    const fat: Memory = .{ .size = 2 * @as(usize, ps), .alignment = ps };
    return switch (r) {
        .prim => |p| if (p == .void) null else .{ .size = p.size(ps), .alignment = p.alignment(ps) },
        .named => |n| if (s.findType(n)) |t| switch (t.kind) {
            .@"error", .@"opaque" => null,
            .func => fat,
            else => if (t.alignment == 0) null else .{ .size = t.size, .alignment = t.alignment },
        } else if (s.findTrait(n) != null) fat else null,
        .pointer => thin,
        .array => |a| {
            const c = s.memory(a.child.*) orelse return null;
            return .{ .size = c.size * a.len, .alignment = c.alignment };
        },
        .slice, .func => fat,
        .optional => |c| switch (c.*) {
            .pointer => thin,
            .func => fat,
            .named => |n| if (s.findTrait(n) != null or s.isFuncType(n)) fat else null,
            else => null,
        },
        .result => null,
    };
}
