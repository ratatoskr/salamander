//! hostfxr, .NET's host library, and the delegates it hands out. From hostfxr.h and
//! coreclr_delegates.h in dotnet/runtime.

const std = @import("std");
const builtin = @import("builtin");

/// What hostfxr's strings are made of, UTF-16 on Windows and UTF-8 elsewhere.
pub const Char = if (builtin.os.tag == .windows) u16 else u8;
pub const Str = [*:0]const Char;

/// How hostfxr's delegates are called. Stdcall on 32-bit Windows, which .NET picked. They only
/// return ints, so Zig's trouble with stdcall struct returns doesn't reach them.
pub const delegate_cc: std.builtin.CallingConvention = if (builtin.os.tag == .windows and builtin.cpu.arch == .x86) .{ .x86_stdcall = .{} } else .c;

pub const Handle = *opaque {};

pub const InitParameters = extern struct {
    size: usize = @sizeOf(InitParameters),
    host_path: ?Str = null,
    dotnet_root: ?Str = null,
};

pub const DelegateType = enum(c_int) {
    com_activation = 0,
    load_in_memory_assembly = 1,
    winrt_activation = 2,
    com_register = 3,
    com_unregister = 4,
    load_assembly_and_get_function_pointer = 5,
    get_function_pointer = 6,
    load_assembly = 7,
    load_assembly_bytes = 8,
};

pub const ErrorWriter = *const fn (message: Str) callconv(.c) void;

/// The `hostfxr_` exports, by name without it.
pub const Api = struct {
    initialize_for_runtime_config: *const fn (config: Str, params: ?*const InitParameters, handle: *?Handle) callconv(.c) i32,
    get_runtime_delegate: *const fn (handle: Handle, kind: DelegateType, delegate: *?*const anyopaque) callconv(.c) i32,
    close: *const fn (handle: Handle) callconv(.c) i32,
    set_error_writer: *const fn (writer: ?ErrorWriter) callconv(.c) ?ErrorWriter,
};

/// Passed as the delegate type for an `[UnmanagedCallersOnly]` method.
pub const unmanaged_callers_only: *const anyopaque = @ptrFromInt(std.math.maxInt(usize));

pub const LoadAssemblyAndGetFunctionPointer = *const fn (assembly: Str, type_name: Str, method: Str, delegate_type: ?*const anyopaque, reserved: ?*anyopaque, out: *?*const anyopaque) callconv(delegate_cc) i32;
pub const GetFunctionPointer = *const fn (type_name: Str, method: Str, delegate_type: ?*const anyopaque, load_context: ?*anyopaque, reserved: ?*anyopaque, out: *?*const anyopaque) callconv(delegate_cc) i32;
pub const LoadAssembly = *const fn (assembly: Str, load_context: ?*anyopaque, reserved: ?*anyopaque) callconv(delegate_cc) i32;
pub const LoadAssemblyBytes = *const fn (assembly: [*]const u8, len: usize, symbols: ?[*]const u8, symbols_len: usize, load_context: ?*anyopaque, reserved: ?*anyopaque) callconv(delegate_cc) i32;

/// hostfxr's status codes we tell apart. The rest are errors too, all with the top bit set.
pub const status = struct {
    pub const success: i32 = 0;
    /// Joined a runtime already running
    pub const host_already_initialized: i32 = 1;
    /// Joined, but its properties differ from what the config asked for
    pub const different_runtime_properties: i32 = 2;

    pub const invalid_config_file: i32 = code(0x80008093);
    pub const framework_missing: i32 = code(0x80008096);
    pub const host_invalid_state: i32 = code(0x800080a3);
    pub const host_incompatible_config: i32 = code(0x800080a5);
    pub const host_api_unsupported_scenario: i32 = code(0x800080a6);

    fn code(c: u32) i32 {
        return @bitCast(c);
    }

    pub fn ok(s: i32) bool {
        return s >= 0;
    }
};

/// hostfxr's file name.
pub const library_name = switch (builtin.os.tag) {
    .windows => "hostfxr.dll",
    .macos => "libhostfxr.dylib",
    else => "libhostfxr.so",
};

/// The runtime's own library, there once a runtime's started.
pub const coreclr_name = switch (builtin.os.tag) {
    .windows => "coreclr.dll",
    .macos => "libcoreclr.dylib",
    else => "libcoreclr.so",
};

/// hostfxr's strings from UTF-8. Free with `a`.
pub fn str(a: std.mem.Allocator, text: []const u8) error{ OutOfMemory, InvalidUtf8 }![:0]const Char {
    if (Char == u8) return a.dupeSentinel(u8, text, 0);
    return std.unicode.wtf8ToWtf16LeAllocZ(a, text) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidUtf8,
    };
}

/// hostfxr's strings to UTF-8. Free with `a`.
pub fn utf8(a: std.mem.Allocator, s: Str) error{OutOfMemory}![]u8 {
    if (Char == u8) return a.dupe(u8, std.mem.span(s));
    return std.unicode.wtf16LeToWtf8Alloc(a, std.mem.span(s));
}
