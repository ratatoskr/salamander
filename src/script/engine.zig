//! How embedders run a script, whatever its language. Any thread can use one, one at a time.
//! Don't wait on a thread that's waiting to get into a script you're in, or neither moves.

const std = @import("std");
const rt = @import("salamander_runtime");
const core = @import("core.zig");

const Allocator = std.mem.Allocator;

pub const Module = core.Module;
pub const Gate = core.Gate;

pub const Language = enum {
    js,
    lua,

    /// By extension.
    pub fn of(path: []const u8) ?Language {
        if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".mjs")) return .js;
        if (std.mem.endsWith(u8, path, ".lua")) return .lua;
        return null;
    }
};

/// Gets errors nobody else would see, like ones from a callback or a task.
pub const Report = struct {
    ctx: ?*anyopaque = null,
    f: *const fn (ctx: ?*anyopaque, message: []const u8) void,
};

/// Finds script modules a script imports. Native ones from `module` come first.
pub const Resolver = struct {
    ctx: ?*anyopaque = null,
    /// `name` imported from `from`, in `buf`. `relative` does what most embedders want.
    resolve: *const fn (ctx: ?*anyopaque, buf: []u8, from: []const u8, name: []const u8) ?[]const u8,
    /// In `gpa`.
    read: *const fn (ctx: ?*anyopaque, gpa: Allocator, name: []const u8) ?[]u8,
};

pub const Options = struct {
    gpa: Allocator,
    host: ?rt.Host = null,
    resolver: ?Resolver = null,
    report: ?Report = null,
    /// JS only for now.
    memory_limit: ?usize = null,
    /// In bytes. JS only.
    stack_size: usize = 256 * 1024,
    /// Null waits.
    policy: ?Policy = null,
    /// Where it carries on once a native promise settles. Null is its own queue, from `pump`.
    resume_on: ?Resume = null,
    schema_options: SchemaOptions = .{},
    /// For the `schema` module.
    locator: ?Locator = null,

    pub const Policy = core.Policy;
    pub const Resume = core.Resume;
    pub const Locator = core.Locator;
    pub const SchemaOptions = @import("salamander_schema").Options;
};

/// `trait` is in `schema`.
pub const Export = struct {
    name: []const u8,
    schema: *const Module,
    trait: []const u8,
    obj: rt.AnyObject,
};

pub const Evaluated = union(enum) {
    /// As text.
    value: []const u8,
    thrown: []const u8,
};

/// `Thrown` leaves what went wrong for `lastError`.
pub const Error = error{ Thrown, OutOfMemory };

/// See `Core.Scope`.
pub const Scope = opaque {};

pub const Script = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        schema: *const fn (ptr: *anyopaque, source: []const u8) Error!*const Module,
        expose: *const fn (ptr: *anyopaque, name: []const u8, export_: Export) Error!void,
        module: *const fn (ptr: *anyopaque, name: []const u8, exports: []const Export) Error!void,
        globals: *const fn (ptr: *anyopaque, roots: []const Export) Error!void,
        run: *const fn (ptr: *anyopaque, source: []const u8, name: []const u8) Error!void,
        eval: *const fn (ptr: *anyopaque, source: []const u8, buf: []u8) Evaluated,
        take: *const fn (ptr: *anyopaque, name: []const u8, schema: *const Module, trait: []const u8) Error!rt.AnyObject,
        pump: *const fn (ptr: *anyopaque) void,
        pumpQueue: *const fn (ptr: *anyopaque, queue: rt.Queue, wait: bool) bool,
        interrupt: *const fn (ptr: *anyopaque) void,
        openScope: *const fn (ptr: *anyopaque, name: []const u8) Error!*Scope,
        closeScope: *const fn (ptr: *anyopaque, scope: *Scope) void,
        useScope: *const fn (ptr: *anyopaque, scope: ?*Scope) void,
        lastError: *const fn (ptr: *anyopaque) []const u8,
        enter: *const fn (ptr: *anyopaque) void,
        tryEnter: *const fn (ptr: *anyopaque) bool,
        leave: *const fn (ptr: *anyopaque) void,
    };

    pub fn deinit(self: Script) void {
        self.vtable.deinit(self.ptr);
    }

    /// Kept while the script lives. The same text gives the same one.
    pub fn schema(self: Script, source: []const u8) Error!*const Module {
        return self.vtable.schema(self.ptr, source);
    }

    pub fn expose(self: Script, name: []const u8, export_: Export) Error!void {
        return self.vtable.expose(self.ptr, name, export_);
    }

    /// A native module scripts import by `name`. Copied.
    pub fn module(self: Script, name: []const u8, exports: []const Export) Error!void {
        return self.vtable.module(self.ptr, name, exports);
    }

    /// Each namespace at the top of the loaded schemas as a global, like `Wraith` and `Kai`, with
    /// what's in it. Each of `roots` is a `[Root]` trait's object: its accessors are functions on its
    /// namespace, like `Wraith.tweaks()`, and the traits they give get `instance()`. Fails with
    /// nothing set if a namespace would hide one of the language's own globals, like `Math`.
    pub fn globals(self: Script, roots: []const Export) Error!void {
        return self.vtable.globals(self.ptr, roots);
    }

    /// As a task so it can await at the top, then pumps.
    pub fn run(self: Script, source: []const u8, name: []const u8) Error!void {
        return self.vtable.run(self.ptr, source, name);
    }

    /// For consoles. The result goes in `buf` as text.
    pub fn eval(self: Script, source: []const u8, buf: []u8) Evaluated {
        return self.vtable.eval(self.ptr, source, buf);
    }

    /// What the main script exports as `name`, as a `trait` object. JS reads the main module's
    /// exports, Lua the table main returns. Kept in the current scope. `release` it when done.
    pub fn take(self: Script, name: []const u8, s: *const Module, trait: []const u8) Error!rt.AnyObject {
        return self.vtable.take(self.ptr, name, s, trait);
    }

    /// Runs promise jobs and waiting tasks. Call often, like once a frame.
    pub fn pump(self: Script) void {
        self.vtable.pump(self.ptr);
    }

    /// Like `pump`, from `queue`, one a `Resume` posts to, on whatever thread pumps it. Without
    /// `wait` it gives up if another thread's in, and gives false.
    pub fn pumpQueue(self: Script, queue: rt.Queue, wait: bool) bool {
        return self.vtable.pumpQueue(self.ptr, queue, wait);
    }

    /// From any thread. Lasts till `run`, `eval` or `pump` returns.
    pub fn interrupt(self: Script) void {
        self.vtable.interrupt(self.ptr);
    }

    pub fn openScope(self: Script, name: []const u8) Error!*Scope {
        return self.vtable.openScope(self.ptr, name);
    }

    pub fn closeScope(self: Script, scope: *Scope) void {
        self.vtable.closeScope(self.ptr, scope);
    }

    /// Null for the script's own scope.
    pub fn useScope(self: Script, scope: ?*Scope) void {
        self.vtable.useScope(self.ptr, scope);
    }

    /// Use inside `enter`, since another thread's call can change it.
    pub fn lastError(self: Script) []const u8 {
        return self.vtable.lastError(self.ptr);
    }

    /// Holds the script across several calls, waiting for whoever's in.
    pub fn enter(self: Script) void {
        self.vtable.enter(self.ptr);
    }

    pub fn tryEnter(self: Script) bool {
        return self.vtable.tryEnter(self.ptr);
    }

    pub fn leave(self: Script) void {
        self.vtable.leave(self.ptr);
    }

    /// From `T`'s methods of the same names.
    pub fn of(comptime T: type, ptr: *T) Script {
        const Thunks = struct {
            fn self_(p: *anyopaque) *T {
                return @ptrCast(@alignCast(p));
            }
            fn deinit_(p: *anyopaque) void {
                self_(p).deinit();
            }
            fn schema_(p: *anyopaque, source: []const u8) Error!*const Module {
                return self_(p).schema(source);
            }
            fn expose_(p: *anyopaque, name: []const u8, e: Export) Error!void {
                return self_(p).expose(name, e);
            }
            fn module_(p: *anyopaque, name: []const u8, exports: []const Export) Error!void {
                return self_(p).module(name, exports);
            }
            fn globals_(p: *anyopaque, roots: []const Export) Error!void {
                return self_(p).globals(roots);
            }
            fn run_(p: *anyopaque, source: []const u8, name: []const u8) Error!void {
                return self_(p).run(source, name);
            }
            fn eval_(p: *anyopaque, source: []const u8, buf: []u8) Evaluated {
                return self_(p).eval(source, buf);
            }
            fn take_(p: *anyopaque, name: []const u8, s: *const Module, trait: []const u8) Error!rt.AnyObject {
                return self_(p).take(name, s, trait);
            }
            fn pump_(p: *anyopaque) void {
                self_(p).pump();
            }
            fn pumpQueue_(p: *anyopaque, queue: rt.Queue, wait: bool) bool {
                return self_(p).pumpQueue(queue, wait);
            }
            fn interrupt_(p: *anyopaque) void {
                self_(p).interrupt();
            }
            fn openScope_(p: *anyopaque, name: []const u8) Error!*Scope {
                const c = &self_(p).binder.core;
                c.enter();
                defer c.leave();
                return @ptrCast(try c.openScope(name));
            }
            fn closeScope_(p: *anyopaque, scope: *Scope) void {
                const c = &self_(p).binder.core;
                c.enter();
                defer c.leave();
                c.closeScope(@ptrCast(@alignCast(scope)));
            }
            fn useScope_(p: *anyopaque, scope: ?*Scope) void {
                const c = &self_(p).binder.core;
                c.enter();
                defer c.leave();
                c.current = if (scope) |s| @ptrCast(@alignCast(s)) else c.root;
            }
            fn enter_(p: *anyopaque) void {
                self_(p).binder.core.enter();
            }
            fn tryEnter_(p: *anyopaque) bool {
                return self_(p).binder.core.tryEnter();
            }
            fn leave_(p: *anyopaque) void {
                self_(p).binder.core.leave();
            }
            fn lastError_(p: *anyopaque) []const u8 {
                return self_(p).last_error.items;
            }
            const vtable: VTable = .{
                .deinit = deinit_,
                .schema = schema_,
                .expose = expose_,
                .module = module_,
                .globals = globals_,
                .run = run_,
                .eval = eval_,
                .take = take_,
                .pump = pump_,
                .pumpQueue = pumpQueue_,
                .interrupt = interrupt_,
                .openScope = openScope_,
                .closeScope = closeScope_,
                .useScope = useScope_,
                .lastError = lastError_,
                .enter = enter_,
                .tryEnter = tryEnter_,
                .leave = leave_,
            };
        };
        return .{ .ptr = ptr, .vtable = &Thunks.vtable };
    }
};

/// Copied, for a language's `Script` to keep.
pub const Natives = struct {
    list: std.ArrayList(Native) = .empty,

    pub const Native = struct {
        name: []const u8,
        exports: []Export,
    };

    pub fn add(n: *Natives, gpa: Allocator, name: []const u8, exports: []const Export) error{OutOfMemory}!void {
        const copy = try gpa.alloc(Export, exports.len);
        var made: usize = 0;
        errdefer {
            for (copy[0..made]) |e| {
                gpa.free(e.name);
                gpa.free(e.trait);
            }
            gpa.free(copy);
        }
        for (exports, copy) |e, *to| {
            const n_ = try gpa.dupe(u8, e.name);
            const t = gpa.dupe(u8, e.trait) catch |err| {
                gpa.free(n_);
                return err;
            };
            to.* = .{ .name = n_, .schema = e.schema, .trait = t, .obj = e.obj };
            made += 1;
        }
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        try n.list.append(gpa, .{ .name = owned, .exports = copy });
    }

    pub fn find(n: *const Natives, name: []const u8) ?*const Native {
        for (n.list.items) |*m| if (std.mem.eql(u8, m.name, name)) return m;
        return null;
    }

    pub fn deinit(n: *Natives, gpa: Allocator) void {
        for (n.list.items) |m| {
            for (m.exports) |e| {
                gpa.free(e.name);
                gpa.free(e.trait);
            }
            gpa.free(m.exports);
            gpa.free(m.name);
        }
        n.list.deinit(gpa);
    }
};

/// Relative to `from`'s folder for `./` or `../`, else to the root. Null if it'd leave the root.
/// Lua's dots are left alone for the resolver to map.
pub fn relative(buf: []u8, from: []const u8, name: []const u8) ?[]const u8 {
    var parts: [64][]const u8 = undefined;
    var n: usize = 0;
    const rel = std.mem.startsWith(u8, name, "./") or std.mem.startsWith(u8, name, "../");
    if (rel) {
        var it = std.mem.tokenizeAny(u8, from, "/\\");
        while (it.next()) |p| {
            if (n == parts.len) return null;
            parts[n] = p;
            n += 1;
        }
        // The importing module's own file name
        if (n > 0) n -= 1;
    }
    var it = std.mem.tokenizeAny(u8, name, "/\\");
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (n == 0) return null;
            n -= 1;
            continue;
        }
        if (n == parts.len) return null;
        parts[n] = p;
        n += 1;
    }
    if (n == 0) return null;
    var w: std.Io.Writer = .fixed(buf);
    for (parts[0..n], 0..) |p, i| {
        if (i != 0) w.writeByte('/') catch return null;
        w.writeAll(p) catch return null;
    }
    return w.buffered();
}

test "relative paths stay under the root" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("util.js", relative(&buf, "main.js", "./util.js").?);
    try std.testing.expectEqualStrings("lib/b.js", relative(&buf, "lib/a.js", "./b.js").?);
    try std.testing.expectEqualStrings("c.js", relative(&buf, "lib/a.js", "../c.js").?);
    try std.testing.expectEqualStrings("lib/x.js", relative(&buf, "lib/a.js", "lib/x.js").?);
    try std.testing.expectEqual(null, relative(&buf, "main.js", "../outside.js"));
}
