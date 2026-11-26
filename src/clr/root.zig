//! .NET's CoreCLR through hostfxr. Joins the runtime already in the process or starts one, then gets `[UnmanagedCallersOnly]` methods.
//! A process gets one runtime, joinable only by the hostfxr that started it. .NET 10 or newer.
//! On Linux a Zig host wants `.signal_stack_size = null` in its `std_options`, since .NET's 256KB threads can't fit Zig's signal stack.

const std = @import("std");
const sys = @import("salamander_sys");
pub const fxr = @import("fxr.zig");
pub const dotnet = @import("dotnet.zig");

/// How salamander calls C# methods, cdecl everywhere via `CallConvCdecl`, since Zig gets 32-bit Windows stdcall's small struct returns wrong.
pub const cc: std.builtin.CallingConvention = .c;

pub const Error = error{
    OutOfMemory,
    InvalidUtf8,
    /// `join_only`, and no runtime is running
    NotRunning,
    /// A runtime's running, but something other than hostfxr started it, so it can't be joined
    NotHostedByFxr,
    /// No installed .NET to start a runtime from
    NoDotnet,
    LoadFailed,
    MissingExport,
    /// hostfxr wouldn't start or join, see `lastStatus`. Like a config for a newer .NET than is running.
    InitFailed,
    /// A delegate hostfxr should have, but wouldn't give
    NoDelegate,
    /// The runtime couldn't find or load that, see `lastStatus`
    NotFound,
};

pub const Options = struct {
    /// Our `.runtimeconfig.json`. Picks the .NET to start, or must be satisfied by the running one to join it.
    runtime_config: []const u8,
    /// Where .NET's installed, to start one from. Found if null.
    dotnet_root: ?[]const u8 = null,
    /// Don't start a runtime, only join one already running.
    join_only: bool = false,
    /// Gets hostfxr's own messages about what went wrong, a line each.
    messages: ?*std.Io.Writer = null,
};

/// Whether a CoreCLR is running in this process.
pub fn running() bool {
    return sys.library.find(fxr.coreclr_name) != null;
}

/// hostfxr's or the runtime's status code from this thread's last failed call, an HRESULT.
pub fn lastStatus() i32 {
    return last_status;
}

threadlocal var last_status: i32 = 0;

pub const Host = struct {
    api: fxr.Api,
    io: std.Io,
    /// It joined a runtime that was already running, rather than starting one.
    joined: bool,
    load_and_get: fxr.LoadAssemblyAndGetFunctionPointer,
    get: fxr.GetFunctionPointer,
    load_assembly: fxr.LoadAssembly,
    load_assembly_bytes: fxr.LoadAssemblyBytes,

    pub fn open(a: std.mem.Allocator, io: std.Io, options: Options) Error!Host {
        var dotnet_root: ?[]u8 = null;
        defer if (dotnet_root) |r| a.free(r);
        const lib = sys.library.find(fxr.library_name) orelse lib: {
            if (running()) return error.NotHostedByFxr;
            if (options.join_only) return error.NotRunning;
            dotnet_root = if (options.dotnet_root) |r| try a.dupe(u8, r) else try dotnet.root(a, io);
            const path = try dotnet.hostfxr(a, io, dotnet_root orelse return error.NoDotnet) orelse return error.NoDotnet;
            defer a.free(path);
            break :lib try sys.library.load(path);
        };
        // hostfxr's loaded, but not started yet. Starting it here would take over from whoever's about to.
        if (options.join_only and !running()) return error.NotRunning;
        const api = try loadApi(lib);

        const config = try fullPath(a, io, options.runtime_config);
        defer a.free(config);
        const root_str = if (dotnet_root) |r| try fxr.str(a, r) else null;
        defer if (root_str) |r| a.free(r);
        const params: fxr.InitParameters = .{ .dotnet_root = if (root_str) |r| r.ptr else null };

        const writing: Messages = .{ .a = a, .out = options.messages };
        const previous_messages = messages;
        messages = if (options.messages != null) writing else null;
        const previous_writer = api.set_error_writer(if (options.messages != null) writeMessage else null);
        defer {
            _ = api.set_error_writer(previous_writer);
            messages = previous_messages;
        }

        var handle: ?fxr.Handle = null;
        const s = api.initialize_for_runtime_config(config.ptr, &params, &handle);
        if (!fxr.status.ok(s) or handle == null) {
            last_status = s;
            return error.InitFailed;
        }
        // The delegates outlive the context
        defer _ = api.close(handle.?);
        return .{
            .api = api,
            .io = io,
            .joined = s == fxr.status.host_already_initialized or s == fxr.status.different_runtime_properties,
            .load_and_get = @ptrCast(@alignCast(try delegate(api, handle.?, .load_assembly_and_get_function_pointer))),
            .get = @ptrCast(@alignCast(try delegate(api, handle.?, .get_function_pointer))),
            .load_assembly = @ptrCast(@alignCast(try delegate(api, handle.?, .load_assembly))),
            .load_assembly_bytes = @ptrCast(@alignCast(try delegate(api, handle.?, .load_assembly_bytes))),
        };
    }

    /// Loads `assembly`, a DLL path, into the default load context. Loading one twice does nothing.
    pub fn load(self: *const Host, a: std.mem.Allocator, assembly: []const u8) Error!void {
        const path = try fullPath(a, self.io, assembly);
        defer a.free(path);
        try check(self.load_assembly(path.ptr, null, null));
    }

    /// Like `load`, from the DLL's bytes and optionally its PDB's.
    pub fn loadBytes(self: *const Host, assembly: []const u8, symbols: ?[]const u8) Error!void {
        const s = symbols orelse &.{};
        try check(self.load_assembly_bytes(assembly.ptr, assembly.len, if (symbols != null) s.ptr else null, s.len, null, null));
    }

    /// A static `[UnmanagedCallersOnly]` method by assembly-qualified type name, like `Game.Exports, Game`. `F` is its pointer type, called with `cc`.
    pub fn function(self: *const Host, comptime F: type, a: std.mem.Allocator, type_name: []const u8, method: []const u8) Error!F {
        comptime checkFn(F);
        const t = try fxr.str(a, type_name);
        defer a.free(t);
        const m = try fxr.str(a, method);
        defer a.free(m);
        var out: ?*const anyopaque = null;
        try check(self.get(t.ptr, m.ptr, fxr.unmanaged_callers_only, null, null, &out));
        return @ptrCast(@alignCast(out orelse return error.NotFound));
    }

    /// Like `function`, from `assembly` loaded once into its own load context, apart from the app's code and its copies of dependencies.
    pub fn isolatedFunction(self: *const Host, comptime F: type, a: std.mem.Allocator, assembly: []const u8, type_name: []const u8, method: []const u8) Error!F {
        comptime checkFn(F);
        const path = try fullPath(a, self.io, assembly);
        defer a.free(path);
        const t = try fxr.str(a, type_name);
        defer a.free(t);
        const m = try fxr.str(a, method);
        defer a.free(m);
        var out: ?*const anyopaque = null;
        try check(self.load_and_get(path.ptr, t.ptr, m.ptr, fxr.unmanaged_callers_only, null, &out));
        return @ptrCast(@alignCast(out orelse return error.NotFound));
    }
};

fn loadApi(lib: *anyopaque) Error!fxr.Api {
    const info = @typeInfo(fxr.Api).@"struct";
    var api: fxr.Api = undefined;
    inline for (info.field_names) |name| {
        const at = sys.library.symbol(lib, "hostfxr_" ++ name) orelse return error.MissingExport;
        @field(api, name) = @ptrCast(@alignCast(at));
    }
    return api;
}

// The runtime only takes full paths, and only some of its calls say so
fn fullPath(a: std.mem.Allocator, io: std.Io, path: []const u8) Error![:0]const fxr.Char {
    const full = std.Io.Dir.cwd().realPathFileAlloc(io, path, a) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotFound,
    };
    defer a.free(full);
    return fxr.str(a, full);
}

fn delegate(api: fxr.Api, handle: fxr.Handle, kind: fxr.DelegateType) Error!*const anyopaque {
    var out: ?*const anyopaque = null;
    const s = api.get_runtime_delegate(handle, kind, &out);
    if (!fxr.status.ok(s)) {
        last_status = s;
        return error.NoDelegate;
    }
    return out orelse error.NoDelegate;
}

fn check(s: i32) Error!void {
    if (fxr.status.ok(s)) return;
    last_status = s;
    return error.NotFound;
}

fn checkFn(comptime F: type) void {
    const ptr = @typeInfo(F);
    if (ptr != .pointer or @typeInfo(ptr.pointer.child) != .@"fn") @compileError("a C# method's type is a function pointer, not " ++ @typeName(F));
}

const Messages = struct { a: std.mem.Allocator, out: ?*std.Io.Writer };

// hostfxr's writer has no context, and it's per thread, so these are too
threadlocal var messages: ?Messages = null;

fn writeMessage(message: fxr.Str) callconv(.c) void {
    const m = messages orelse return;
    const out = m.out orelse return;
    const text = fxr.utf8(m.a, message) catch return;
    defer m.a.free(text);
    out.print("{s}\n", .{text}) catch {};
}

test {
    _ = dotnet;
    _ = @import("tests.zig");
}
