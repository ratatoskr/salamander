//! What every language host shares. Traits from schemas, objects made for script values, and how long they live.
//! A binder embeds `Core(L)` as `core`. `L` gives `Value`, `initTrait`, `deinitTrait`, `forget`, `dispatch`, and maybe `TraitData` and `entered`.
//! Records are only freed in `deinit`, so a late call or release still lands on one.

const std = @import("std");
const salamander_schema = @import("salamander_schema");
const rt = @import("salamander_runtime");
const bind = @import("salamander_bind");

const Schema = salamander_schema.Schema;
const Ref = Schema.Ref;
const Allocator = std.mem.Allocator;
const memory = @import("memory.zig");
const views = @import("views.zig");

pub const Gate = @import("Gate.zig");

/// How a thread outside the script gets in. Asked on that thread.
pub const Policy = struct {
    ctx: ?*anyopaque = null,
    how: *const fn (ctx: ?*anyopaque) Gate.How,
};

/// Held briefly, and never while calling out.
pub const SpinLock = struct {
    held: std.atomic.Value(u32) = .init(0),

    pub fn lock(l: *SpinLock) void {
        while (l.held.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.Thread.yield() catch {};
    }

    pub fn unlock(l: *SpinLock) void {
        l.held.store(0, .release);
    }
};

/// A parsed `.sal`, kept while the binder is.
pub const Module = struct {
    source: []const u8,
    parsed: salamander_schema.Parsed,
    /// Made for a signature, not a base for others.
    signature: bool = false,
    /// Loading again by this name replaces it.
    name: []const u8 = "",
    /// What was made from it still works, but nothing new is.
    replaced: bool = false,

    pub fn schema(self: *const Module) Schema {
        return self.parsed.schema;
    }
};

pub const TraitError = error{ OutOfMemory, NoSuchTrait, TooManyMethods };

/// Finds code a schema declares in existing code, like a game's. Failures go through the host's `explain`.
pub const Locator = struct {
    ctx: ?*anyopaque = null,
    /// Like `spawn`, `Player.heal` or `Player.local`.
    address: *const fn (ctx: ?*anyopaque, name: []const u8) anyerror!usize,
    /// False if the memory isn't there.
    read: *const fn (ctx: ?*anyopaque, address: usize, out: []u8) bool,
    write: *const fn (ctx: ?*anyopaque, address: usize, bytes: []const u8) bool,
};

pub const LocateError = anyerror;

pub fn Core(comptime L: type) type {
    return struct {
        const Self = @This();
        const LangTrait = if (@hasDecl(L, "TraitData")) L.TraitData else struct {};

        gpa: Allocator,
        host: rt.Host,
        /// Async results and tidying, polled inside the gate.
        queue: rt.Queue,
        gate: Gate = .{},
        /// Null waits.
        policy: ?Policy = null,
        schema_options: salamander_schema.Options = .{},
        /// Without it the `schema` module finds nothing.
        locator: ?Locator = null,
        /// Kept objects go in `current`.
        root: *Scope,
        current: *Scope,
        scopes: std.ArrayList(*Scope) = .empty,
        /// Closed during a call into the script, so freed later by `tidy`.
        closing: std.ArrayList(*Scope) = .empty,
        /// Guards `released` and `flush`, which other threads touch.
        lock: SpinLock = .{},
        /// Released from any thread, waiting for `tidy`. In `smp_allocator`.
        released: std.ArrayList(usize) = .empty,
        flush: ?*Flush = null,
        /// Our tables, so their objects go back to the script as the values they were made for.
        ours: std.AutoHashMapUnmanaged(usize, void) = .empty,
        spare: std.ArrayList(*Impl) = .empty,
        /// Set while converting a borrowed argument.
        lent: ?*std.ArrayList(*Impl) = null,
        modules: std.ArrayList(*Module) = .empty,
        traits: std.ArrayList(*Trait) = .empty,
        /// By their text.
        signatures: std.StringHashMapUnmanaged(Signature) = .empty,
        /// Calls into the script under way.
        depth: u32 = 0,

        /// A trait or function type as scripts see it.
        pub const Trait = struct {
            schema: Schema,
            decl: *const Schema.Trait,
            sig: ?*const Schema.Signature = null,
            bound: *const bind.Trait,
            /// In table order.
            methods: []const *const Schema.Method,
            lang: LangTrait = .{},
            /// A function type's made-up trait.
            fn_methods: [1]Schema.Method = undefined,
            fn_decl: Schema.Trait = undefined,
        };

        pub const Signature = struct {
            trait: *Trait,
            function: *const bind.Function,
        };

        pub const SignatureError = salamander_schema.SignatureError || TraitError || error{Unsupported};

        /// Kept objects let go together. Closing its owner stops calls before anything's freed.
        /// The owner and tables stay in host memory for good, so don't make these too often.
        pub const Scope = struct {
            owner: *rt.Owner,
            tables: std.AutoHashMapUnmanaged(*Trait, *const anyopaque) = .empty,
            impls: std.ArrayList(*Impl) = .empty,
        };

        /// Behind a native object made for the script. Its record is the object's data.
        pub const Impl = struct {
            record: bind.Record,
            core: *Self,
            trait: *Trait,
            value: L.Value,
            /// So a call waiting to get in gives up once it closes.
            owner: *rt.Owner,
            live: bool = true,
            /// Kept ones' scope, and native code's holds on them.
            scope: ?*Scope = null,
            count: u32 = 0,
        };

        /// In `smp_allocator`, since other threads make it.
        const Flush = struct {
            core: ?*Self,
        };

        fn lang(self: *Self) *L {
            return @fieldParentPtr("core", self);
        }

        /// In place, since the host keeps a pointer to it.
        pub fn init(self: *Self, gpa: Allocator, host: rt.Host, queue: rt.Queue) error{OutOfMemory}!void {
            const root = try gpa.create(Scope);
            errdefer gpa.destroy(root);
            root.* = .{ .owner = try host.owner("script") };
            errdefer root.owner.close();
            self.* = .{
                .gpa = gpa,
                .host = host,
                .queue = queue,
                .root = root,
                .current = root,
            };
            try host.releasable(root.owner, .init(self, onRelease));
        }

        /// Before the language's state goes. Calls waiting to get in give up as their owners close.
        pub fn deinit(self: *Self) void {
            self.root.owner.drain();
            while (self.scopes.items.len > 0) self.closeScope(self.scopes.items[self.scopes.items.len - 1]);
            self.freeClosing();
            self.freeScope(self.root);
            self.lock.lock();
            if (self.flush) |fl| fl.core = null;
            self.lock.unlock();
            self.released.deinit(std.heap.smp_allocator);
            for (self.spare.items) |impl| self.gpa.destroy(impl);
            for (self.traits.items) |t| {
                L.deinitTrait(self.lang(), t);
                self.gpa.free(t.methods);
                self.gpa.destroy(t);
            }
            for (self.modules.items) |m| {
                m.parsed.deinit();
                self.gpa.free(m.source);
                if (m.name.len > 0) self.gpa.free(m.name);
                self.gpa.destroy(m);
            }
            self.spare.deinit(self.gpa);
            self.scopes.deinit(self.gpa);
            self.closing.deinit(self.gpa);
            self.ours.deinit(self.gpa);
            self.traits.deinit(self.gpa);
            self.modules.deinit(self.gpa);
            var keys = self.signatures.keyIterator();
            while (keys.next()) |k| self.gpa.free(k.*);
            self.signatures.deinit(self.gpa);
        }

        // Schemas and traits

        /// The same text again gives the one already loaded.
        pub fn load(self: *Self, source: []const u8, diagnostic: ?*Schema.Diagnostic) !*Module {
            for (self.modules.items) |m| if (std.mem.eql(u8, m.source, source)) return m;
            const m = try self.gpa.create(Module);
            errdefer self.gpa.destroy(m);
            const copy = try self.gpa.dupe(u8, source);
            errdefer self.gpa.free(copy);
            m.* = .{ .source = copy, .parsed = try salamander_schema.parse(self.gpa, copy, self.schema_options, diagnostic) };
            errdefer m.parsed.deinit();
            try self.modules.append(self.gpa, m);
            return m;
        }

        /// Replaces what was loaded as `name` before, like a tweak's types as it grows.
        pub fn loadNamed(self: *Self, name: []const u8, source: []const u8, diagnostic: ?*Schema.Diagnostic) !*Module {
            for (self.modules.items) |m| if (!m.replaced and std.mem.eql(u8, m.name, name) and std.mem.eql(u8, m.source, source)) return m;
            const m = try self.gpa.create(Module);
            errdefer self.gpa.destroy(m);
            const copy = try self.gpa.dupe(u8, source);
            errdefer self.gpa.free(copy);
            const owned_name = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(owned_name);
            // Without the one it replaces, so their names don't clash
            var parsed = try salamander_schema.parse(self.gpa, copy, self.schema_options, diagnostic);
            errdefer parsed.deinit();
            m.* = .{ .source = copy, .parsed = parsed, .name = owned_name };
            try self.modules.append(self.gpa, m);
            for (self.modules.items) |o| if (o != m and std.mem.eql(u8, o.name, name)) {
                o.replaced = true;
            };
            // Signatures read before may name what's gone
            var keys = self.signatures.keyIterator();
            while (keys.next()) |k| self.gpa.free(k.*);
            self.signatures.clearRetainingCapacity();
            return m;
        }

        /// Like `[Thiscall] fn i32 (Actor* self, f32 amount)`. Every loaded schema is in scope.
        pub fn signature(self: *Self, text: []const u8, diagnostic: ?*Schema.Diagnostic) SignatureError!Signature {
            if (self.signatures.get(text)) |found| return found;
            var base: std.ArrayList(u8) = .empty;
            defer base.deinit(self.gpa);
            for (self.modules.items, 0..) |m, i| {
                if (m.signature or m.replaced) continue;
                if (!std.mem.startsWith(u8, m.source, Schema.bundle_marker)) try base.print(self.gpa, Schema.bundle_marker ++ "schema{d}\";\n", .{i});
                try base.appendSlice(self.gpa, m.source);
                try base.append(self.gpa, '\n');
            }
            const m = try self.gpa.create(Module);
            errdefer self.gpa.destroy(m);
            m.* = .{ .source = try self.gpa.dupe(u8, text), .parsed = undefined, .signature = true };
            errdefer self.gpa.free(m.source);
            m.parsed = try salamander_schema.parseSignature(self.gpa, base.items, text, self.schema_options, diagnostic);
            errdefer m.parsed.deinit();
            try self.modules.append(self.gpa, m);
            const s = m.schema();
            const sig = &s.findType(salamander_schema.signature_name).?.kind.func;
            const found: Signature = .{
                .trait = try self.fnOf(s, sig),
                .function = bind.Function.init(self.host, s, sig.*) catch |e| return switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.Unsupported => error.Unsupported,
                },
            };
            const key = try self.gpa.dupe(u8, text);
            errdefer self.gpa.free(key);
            try self.signatures.put(self.gpa, key, found);
            return found;
        }

        pub fn trait(self: *Self, m: *const Module, name: []const u8) TraitError!*Trait {
            const s = m.schema();
            return self.traitOf(s, s.findTrait(name) orelse return error.NoSuchTrait);
        }

        // Existing code that loaded schemas declare, as scripts' `schema` module

        pub const Declared = union(enum) {
            function: struct { schema: Schema, found: Schema.Function },
            static: struct { schema: Schema, found: Schema.FoundStatic },
        };

        /// `spawn`, `Player.heal` or `Player.local`, from the first schema that declares it.
        pub fn declared(self: *Self, name: []const u8) ?Declared {
            for (self.modules.items) |m| {
                if (m.signature or m.replaced) continue;
                const s = m.schema();
                if (s.findFunction(name)) |f| return .{ .function = .{ .schema = s, .found = f } };
                if (s.findStatic(name)) |v| return .{ .static = .{ .schema = s, .found = v } };
            }
            return null;
        }

        /// Not ones made for signatures.
        pub fn declaring(self: *Self) DeclaringIterator {
            return .{ .modules = self.modules.items };
        }

        pub const DeclaringIterator = struct {
            modules: []const *Module,
            i: usize = 0,

            pub fn next(it: *DeclaringIterator) ?Schema {
                while (it.i < it.modules.len) {
                    const m = it.modules[it.i];
                    it.i += 1;
                    if (!m.signature and !m.replaced) return m.schema();
                }
                return null;
            }
        };

        /// A [Virtual(n)] one's found through `this`'s vtable.
        pub fn declaredAddress(self: *Self, name: []const u8, f: Schema.Function, this: usize) LocateError!usize {
            const l = self.locator orelse return error.NoLocator;
            if (f.method.virtual) |slot| {
                const table = try self.readWord(this);
                return self.readWord(table + slot * @sizeOf(usize));
            }
            return l.address(l.ctx, name);
        }

        /// Like `Player` or `u32[4]`, with every loaded schema in scope.
        pub fn typeOf(self: *Self, text: []const u8, diagnostic: ?*Schema.Diagnostic) SignatureError!struct { Schema, Ref } {
            var buf: [256]u8 = undefined;
            // Behind a pointer, since arrays can't be parameters
            const sig_text = std.fmt.bufPrint(&buf, "fn void ({s}* v)", .{text}) catch return error.NotASignature;
            const sig = try self.signature(sig_text, diagnostic);
            return .{ sig.trait.schema, sig.trait.sig.?.params[0].type.pointer.* };
        }

        pub fn staticMember(self: *Self, name: []const u8, s: Schema, v: *const Schema.Static) LocateError!views.Member {
            const l = self.locator orelse return error.NoLocator;
            return views.place(s, v.type, try l.address(l.ctx, name));
        }

        /// Copies memory that might not be there.
        pub fn readMemory(self: *Self, at: usize, out: []u8) LocateError!void {
            const l = self.locator orelse return error.NoLocator;
            if (!l.read(l.ctx, at, out)) return self.host.explain(error.Unreadable, "can't read 0x{x}", .{at});
        }

        pub fn writeMemory(self: *Self, at: usize, bytes: []const u8) LocateError!void {
            const l = self.locator orelse return error.NoLocator;
            if (!l.write(l.ctx, at, bytes)) return self.host.explain(error.Unreadable, "can't write 0x{x}", .{at});
        }

        /// Errors on null.
        fn readWord(self: *Self, at: usize) LocateError!usize {
            var word: usize = 0;
            try self.readMemory(at, std.mem.asBytes(&word));
            if (word == 0) return self.host.explain(error.Unreadable, "0x{x} is null", .{at});
            return word;
        }

        /// Copied into memory from `a`, to convert.
        pub fn readPlace(self: *Self, s: Schema, p: views.Place, a: Allocator) LocateError![*]u8 {
            const shape = memory.shapeOf(s, p.type);
            const mem = memory.alloc(a, shape) catch return error.OutOfMemory;
            try self.readMemory(p.address, mem[0..shape.size]);
            return mem;
        }

        /// A `T[count]` array as long as its count says now. None if that can't be read.
        pub fn sized(self: *Self, v: views.View) views.View {
            const at = v.count orelse return v;
            const p = if (at.type == .prim) at.type.prim else return v.sized(0);
            const n = p.size(v.schema.pointer_size);
            if (n > 8) return v.sized(0);
            var bytes: [8]u8 = @splat(0);
            self.readMemory(at.address, bytes[0..n]) catch return v.sized(0);
            const raw = std.mem.readInt(u64, &bytes, .little);
            const len: u64 = if (p.isSigned()) @intCast(@max(memory.signed(raw, n), 0)) else raw;
            return v.sized(@intCast(@min(len, views.max_count)));
        }

        /// Can be 0.
        pub fn readPointer(self: *Self, at: usize) LocateError!usize {
            var word: usize = 0;
            try self.readMemory(at, std.mem.asBytes(&word));
            return word;
        }

        /// Read once, for a script's plain copy to save back later.
        pub fn takeCopy(self: *Self, v: views.View) LocateError!*views.Copy {
            const bytes = self.gpa.alloc(u8, v.size()) catch return error.OutOfMemory;
            errdefer self.gpa.free(bytes);
            try self.readMemory(v.address, bytes);
            const out = self.gpa.create(views.Copy) catch return error.OutOfMemory;
            out.* = .{ .gpa = self.gpa, .view = v, .original = bytes };
            return out;
        }

        /// Up to the terminator, as UTF-8 in `a`.
        pub fn readText(self: *Self, kind: Schema.Prim, at: usize, a: Allocator) LocateError![]const u8 {
            const unit: usize = if (kind == .utf16) 2 else 1;
            var raw: std.ArrayList(u8) = .empty;
            var chunk: [64]u8 = undefined;
            outer: while (raw.items.len < views.max_text) {
                const at_now = at + raw.items.len;
                // Not past the page, which might be the last one there
                const room = std.mem.alignForward(usize, at_now + 1, 4096) - at_now;
                const n = @min(chunk.len, room);
                try self.readMemory(at_now, chunk[0..n]);
                var i: usize = 0;
                while (i + unit <= n) : (i += unit) {
                    if (std.mem.allEqual(u8, chunk[i .. i + unit], 0)) {
                        raw.appendSlice(a, chunk[0..i]) catch return error.OutOfMemory;
                        break :outer;
                    }
                }
                raw.appendSlice(a, chunk[0..n]) catch return error.OutOfMemory;
            }
            if (kind == .utf8) return raw.items;
            const out = a.alloc(u8, raw.items.len * 2 + 4) catch return error.OutOfMemory;
            return memory.utf16Text(raw.items.ptr, raw.items.len / 2, out);
        }

        pub fn traitOf(self: *Self, s: Schema, decl: *const Schema.Trait) TraitError!*Trait {
            for (self.traits.items) |t| if (t.decl == decl) return t;
            const t = try self.gpa.create(Trait);
            errdefer self.gpa.destroy(t);
            t.* = .{ .schema = s, .decl = decl, .bound = undefined, .methods = &.{} };
            try self.finish(t);
            return t;
        }

        /// Made up, with one method `call`.
        pub fn fnOf(self: *Self, s: Schema, sig: *const Schema.Signature) TraitError!*Trait {
            for (self.traits.items) |t| if (t.sig == sig) return t;
            const t = try self.gpa.create(Trait);
            errdefer self.gpa.destroy(t);
            t.* = .{ .schema = s, .decl = undefined, .sig = sig, .bound = undefined, .methods = &.{} };
            t.fn_methods = .{.{ .name = "call", .signature = sig.* }};
            t.fn_decl = .{ .name = "fn", .methods = &t.fn_methods };
            t.decl = &t.fn_decl;
            try self.finish(t);
            return t;
        }

        fn finish(self: *Self, t: *Trait) TraitError!void {
            t.bound = try bind.Trait.init(self.host, t.schema, t.decl);
            var buf: [salamander_schema.plan.max_methods]*const Schema.Method = undefined;
            const ms = salamander_schema.plan.methods(t.schema, t.decl, &buf);
            t.methods = try self.gpa.dupe(*const Schema.Method, ms);
            errdefer self.gpa.free(t.methods);
            try L.initTrait(self.lang(), t);
            errdefer L.deinitTrait(self.lang(), t);
            try self.traits.append(self.gpa, t);
        }

        // Objects made for the script

        /// Null unless it's ours and still around.
        pub fn ourImpl(self: *Self, obj: rt.AnyObject) ?*Impl {
            if (!self.ours.contains(@intFromPtr(obj.table))) return null;
            const impl = implOf(obj.data);
            return if (impl.live) impl else null;
        }

        fn implOf(data: usize) *Impl {
            const record: *bind.Record = @ptrFromInt(data);
            return @alignCast(@fieldParentPtr("record", record));
        }

        pub fn objectOf(impl: *Impl, table: *const anyopaque) rt.AnyObject {
            return .{ .data = @intFromPtr(&impl.record), .table = table };
        }

        /// Native code got a kept one again. Borrowing doesn't count.
        pub fn hold(self: *Self, impl: *Impl) void {
            if (self.lent == null) impl.count +|= 1;
        }

        pub const Made = struct {
            obj: rt.AnyObject,
            impl: *Impl,
            /// The language links `value` to it for next time.
            kept: bool,
        };

        /// Takes `value`. Borrowed while converting a borrowed argument, else kept in `current` with one hold.
        pub fn make(self: *Self, t: *Trait, value: L.Value) error{OutOfMemory}!Made {
            const scope = if (self.lent == null) self.current else self.root;
            const table = try self.tableFor(scope, t);
            const impl = if (self.spare.pop()) |x| x else try self.gpa.create(Impl);
            impl.* = .{ .record = .{ .trait = t.bound, .ctx = @intFromPtr(impl), .dispatch = dispatch }, .core = self, .trait = t, .value = value, .owner = scope.owner };
            errdefer {
                L.forget(self.lang(), impl);
                self.toSpare(impl);
            }
            if (self.lent) |list| {
                try list.append(self.gpa, impl);
                return .{ .obj = objectOf(impl, table), .impl = impl, .kept = false };
            }
            impl.scope = scope;
            impl.count = 1;
            try scope.impls.append(self.gpa, impl);
            return .{ .obj = objectOf(impl, table), .impl = impl, .kept = true };
        }

        fn toSpare(self: *Self, impl: *Impl) void {
            impl.live = false;
            impl.scope = null;
            impl.count = 0;
            // Lost if this fails, but it can't be freed while owners are open
            self.spare.append(self.gpa, impl) catch {};
        }

        /// Borrowed objects go in `list`, or are kept with null. Put the old one back after.
        pub fn lending(self: *Self, list: ?*std.ArrayList(*Impl)) ?*std.ArrayList(*Impl) {
            const was = self.lent;
            self.lent = list;
            return was;
        }

        pub fn giveBack(self: *Self, list: *std.ArrayList(*Impl)) void {
            for (list.items) |impl| {
                L.forget(self.lang(), impl);
                self.toSpare(impl);
            }
            list.deinit(self.gpa);
        }

        fn tableFor(self: *Self, s: *Scope, t: *Trait) error{OutOfMemory}!*const anyopaque {
            if (s.tables.get(t)) |table| return table;
            const table = try bind.table(self.host, t.bound, s.owner);
            try s.tables.put(self.gpa, t, table);
            errdefer _ = s.tables.remove(t);
            try self.ours.put(self.gpa, @intFromPtr(table), {});
            return table;
        }

        /// Native code calling one of ours.
        fn dispatch(ctx: usize, method: u32, args: []const [*]u8, value: [*]u8) u32 {
            const impl: *Impl = @ptrFromInt(ctx);
            // A borrowed one whose call's over, or one released
            if (!impl.live) return rt.gone_code;
            const self = impl.core;
            const how: Gate.How = if (self.policy) |p| p.how(p.ctx) else .block;
            if (!self.gate.enter(how, impl.owner)) return if (impl.owner.isOpen()) rt.unsupported_code else rt.gone_code;
            defer self.gate.leave();
            if (self.gate.depth == 1) self.entered();
            if (calls_in == 0) if (returns) |*a| {
                _ = a.reset(.{ .retain_with_limit = keep_returns });
            };
            calls_in += 1;
            defer calls_in -= 1;
            self.depth += 1;
            defer self.depth -= 1;
            return L.dispatch(self.lang(), impl, method, args, value);
        }

        /// For returns or settled values the script hands native code.
        pub fn returned(_: *Self) std.mem.Allocator {
            if (returns == null) returns = .init(std.heap.page_allocator);
            return returns.?.allocator();
        }

        fn entered(self: *Self) void {
            if (@hasDecl(L, "entered")) L.entered(self.lang());
        }

        /// Waits for whoever's in. For embedders, around anything that touches the script.
        pub fn enter(self: *Self) void {
            _ = self.gate.enter(.block, null);
            if (self.gate.depth == 1) self.entered();
        }

        pub fn tryEnter(self: *Self) bool {
            if (!self.gate.enter(.try_, null)) return false;
            if (self.gate.depth == 1) self.entered();
            return true;
        }

        pub fn leave(self: *Self) void {
            self.gate.leave();
        }

        // Scopes

        /// Set `current` to it to keep objects in it.
        pub fn openScope(self: *Self, name: []const u8) error{OutOfMemory}!*Scope {
            const s = try self.gpa.create(Scope);
            errdefer self.gpa.destroy(s);
            s.* = .{ .owner = try self.host.owner(name) };
            errdefer s.owner.close();
            try self.host.releasable(s.owner, .init(self, onRelease));
            try self.scopes.append(self.gpa, s);
            return s;
        }

        /// Lets its objects go, held or not. During a call into the script that waits till the queue's
        /// polled. Calls waiting to get in give up, so it never waits on them.
        pub fn closeScope(self: *Self, s: *Scope) void {
            std.debug.assert(s != self.root);
            const at = std.mem.indexOfScalar(*Scope, self.scopes.items, s) orelse return;
            _ = self.scopes.swapRemove(at);
            if (self.current == s) self.current = self.root;
            s.owner.close();
            if (self.depth == 0) {
                s.owner.drain();
                return self.freeScope(s);
            }
            // Never freed if this fails, which beats freeing what a call's using
            self.closing.append(self.gpa, s) catch return;
            self.later();
        }

        fn freeClosing(self: *Self) void {
            while (self.closing.pop()) |s| {
                s.owner.drain();
                self.freeScope(s);
            }
        }

        /// Owner drained. Records go to `spare`, since a release could still come in through another table.
        fn freeScope(self: *Self, s: *Scope) void {
            self.applyReleased();
            for (s.impls.items) |impl| {
                L.forget(self.lang(), impl);
                self.toSpare(impl);
            }
            var it = s.tables.valueIterator();
            while (it.next()) |t| _ = self.ours.remove(@intFromPtr(t.*));
            s.impls.deinit(self.gpa);
            s.tables.deinit(self.gpa);
            self.gpa.destroy(s);
        }

        // Releases and tidying

        /// Fine from any thread.
        fn later(self: *Self) void {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.flush != null) return;
            const fl = std.heap.smp_allocator.create(Flush) catch return;
            fl.* = .{ .core = self };
            self.queue.post(fl, tidy) catch return std.heap.smp_allocator.destroy(fl);
            self.flush = fl;
        }

        /// On the script's thread, outside any call into it.
        fn tidy(fl: *Flush) void {
            const self = fl.core orelse return std.heap.smp_allocator.destroy(fl);
            // Polled from inside a call, so try again next time
            if (self.depth > 0) {
                self.queue.post(fl, tidy) catch {};
                return;
            }
            self.lock.lock();
            self.flush = null;
            self.lock.unlock();
            std.heap.smp_allocator.destroy(fl);
            self.applyReleased();
            self.freeClosing();
        }

        /// Native code let go of a kept object. From any thread.
        fn onRelease(self: *Self, data: usize) void {
            {
                self.lock.lock();
                defer self.lock.unlock();
                // Lost if this fails, so the object lives till its scope closes
                self.released.append(std.heap.smp_allocator, data) catch return;
            }
            self.later();
        }

        fn applyReleased(self: *Self) void {
            var list = blk: {
                self.lock.lock();
                defer self.lock.unlock();
                const l = self.released;
                self.released = .empty;
                break :blk l;
            };
            defer list.deinit(std.heap.smp_allocator);
            for (list.items) |data| {
                const impl = implOf(data);
                // Borrowed, or let go already
                if (!impl.live or impl.count == 0) continue;
                const s = impl.scope orelse continue;
                impl.count -= 1;
                if (impl.count > 0) continue;
                if (std.mem.indexOfScalar(*Impl, s.impls.items, impl)) |at| _ = s.impls.swapRemove(at);
                L.forget(self.lang(), impl);
                self.toSpare(impl);
            }
        }
    };
}

/// Per thread, so another thread calling in can't free it before the caller's copied it.
/// Good till the thread's next call into any script.
threadlocal var returns: ?std.heap.ArenaAllocator = null;
/// Across every binder.
threadlocal var calls_in: u32 = 0;
const keep_returns = 256 << 10;

// Errors

/// From the error set, or a built-in one.
pub fn errorName(schema: ?Schema, errors: []const u8, code: u32) []const u8 {
    if (schema) |s| if (s.findType(errors)) |t| if (t.kind == .@"error") {
        for (t.kind.@"error".errors) |e| if (e.code == code) return e.name;
    };
    return switch (code) {
        Schema.cancelled_code => "Cancelled",
        Schema.unsupported_code => "Unsupported",
        Schema.gone_code => "Gone",
        else => "Error",
    };
}

threadlocal var explained_buf: [1100]u8 = undefined;

/// `name` with why, if the failed call explained. Good till the thread's next one.
pub fn withExplanation(host: rt.Host, name: []const u8) []const u8 {
    const why = host.explanation(name);
    if (why.len == 0) return name;
    return std.fmt.bufPrint(&explained_buf, "{s}: {s}", .{ name, why }) catch name;
}

/// Whether scripts get an `inout` value in a `{ value }` box. Structs, unions and arrays are objects
/// already, so they're written back into.
pub fn inoutBoxed(s: Schema, r: Schema.Ref) bool {
    return switch (r) {
        .named => |n| if (s.findType(n)) |t| !(t.kind == .@"struct" or t.kind == .@"union") else true,
        .array => |a| memory.isText(a) != null,
        else => true,
    };
}

/// A message that's just the error's name adds nothing, and one like `Shy: not today` isn't named twice.
pub fn explainThrown(host: rt.Host, schema: ?Schema, errors: ?[]const u8, code: u32, message: []const u8) void {
    const name = errorName(schema, errors orelse "", code);
    var why = message;
    if (std.mem.startsWith(u8, why, name) and std.mem.startsWith(u8, why[name.len..], ": ")) why = why[name.len + 2 ..];
    if (why.len == 0 or std.mem.eql(u8, why, name)) return;
    host.raw().explain(name, why);
}

/// `Unsupported` for names nobody knows.
pub fn errorCode(schema: Schema, errors: ?[]const u8, name: []const u8) u32 {
    if (errors) |set| if (schema.findType(set)) |t| if (t.kind == .@"error") {
        for (t.kind.@"error".errors) |e| if (std.mem.eql(u8, e.name, name)) return e.code;
    };
    for (Schema.builtin_errors, [_]u32{ Schema.cancelled_code, Schema.unsupported_code, Schema.gone_code }) |n, cd| {
        if (std.mem.eql(u8, n, name)) return cd;
    }
    return rt.unsupported_code;
}

/// What a method gives or settles with, and its errors.
pub fn payload(m: *const Schema.Method) struct { Ref, ?[]const u8 } {
    return switch (m.signature.ret) {
        .result => |r| .{ r.ok.*, r.err },
        else => |r| .{ r, null },
    };
}

/// Whether the caller gets a code back rather than a value.
pub fn isResult(m: *const Schema.Method) bool {
    return !m.async and m.signature.ret == .result;
}

pub fn isVoid(r: Ref) bool {
    return r == .prim and r.prim == .void;
}
