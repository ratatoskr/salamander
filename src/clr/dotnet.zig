//! Finding an installed .NET and its hostfxr, like nethost's `get_hostfxr_path` does.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("salamander_sys");
const fxr = @import("fxr.zig");

/// Where .NET's installed: `DOTNET_ROOT_<ARCH>` or `DOTNET_ROOT`, the installer's record, then the usual place. Free with `a`.
pub fn root(a: std.mem.Allocator, io: std.Io) error{OutOfMemory}!?[]u8 {
    const arch: ?[]const u8 = switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .x86 => "x86",
        .aarch64 => "arm64",
        .arm => "arm",
        else => null,
    };
    var buf: [64]u8 = undefined;
    if (arch) |name| {
        var upper: [8]u8 = undefined;
        const variable = std.fmt.bufPrint(&buf, "DOTNET_ROOT_{s}", .{std.ascii.upperString(&upper, name)}) catch unreachable;
        if (try sys.env.get(a, variable)) |r| return r;
    }
    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86) if (try sys.env.get(a, "DOTNET_ROOT(x86)")) |r| return r;
    if (try sys.env.get(a, "DOTNET_ROOT")) |r| return r;
    if (arch) |name| if (try installed(a, io, name)) |r| return r;

    if (builtin.os.tag == .windows) {
        // A 32-bit process gets Program Files (x86) here, where the x86 .NET goes
        const programs = try sys.env.get(a, "ProgramFiles") orelse return null;
        defer a.free(programs);
        const path = try std.fs.path.join(a, &.{ programs, "dotnet" });
        if (exists(io, path)) return path;
        a.free(path);
        return null;
    }
    const usual: []const []const u8 = if (builtin.os.tag == .macos)
        &.{"/usr/local/share/dotnet"}
    else
        &.{ "/usr/share/dotnet", "/usr/lib/dotnet", "/usr/lib64/dotnet", "/usr/local/share/dotnet" };
    for (usual) |path| if (exists(io, path)) return try a.dupe(u8, path);
    return null;
}

/// Where the installer recorded it: the 32-bit registry view on Windows, else `/etc/dotnet/install_location[_<arch>]`.
fn installed(a: std.mem.Allocator, io: std.Io, arch: []const u8) error{OutOfMemory}!?[]u8 {
    var buf: [64]u8 = undefined;
    if (builtin.os.tag == .windows) {
        const key = std.fmt.bufPrint(&buf, "SOFTWARE\\dotnet\\Setup\\InstalledVersions\\{s}", .{arch}) catch unreachable;
        const path = try sys.registry.string(a, .local_machine, key, "InstallLocation", .bits32) orelse return null;
        if (exists(io, path)) return path;
        a.free(path);
        return null;
    }
    const files = [_][]const u8{ std.fmt.bufPrint(&buf, "/etc/dotnet/install_location_{s}", .{arch}) catch unreachable, "/etc/dotnet/install_location" };
    for (files) |file| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(4096)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer a.free(text);
        const line = std.mem.trim(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len], " \t\r");
        if (line.len > 0 and exists(io, line)) return try a.dupe(u8, line);
    }
    return null;
}

/// The newest `host/fxr/<version>/hostfxr` under `dotnet_root`. Free with `a`.
pub fn hostfxr(a: std.mem.Allocator, io: std.Io, dotnet_root: []const u8) error{OutOfMemory}!?[]u8 {
    const fxr_dir = try std.fs.path.join(a, &.{ dotnet_root, "host", "fxr" });
    defer a.free(fxr_dir);
    var dir = std.Io.Dir.openDirAbsolute(io, fxr_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var best: ?std.SemanticVersion = null;
    var best_name: std.ArrayList(u8) = .empty;
    defer best_name.deinit(a);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        const version = std.SemanticVersion.parse(e.name) catch continue;
        if (best) |b| if (version.order(b) != .gt) continue;
        // The parsed version points into the name, which the next entry overwrites
        best_name.clearRetainingCapacity();
        try best_name.appendSlice(a, e.name);
        best = std.SemanticVersion.parse(best_name.items) catch unreachable;
    }
    if (best == null) return null;
    const path = try std.fs.path.join(a, &.{ fxr_dir, best_name.items, fxr.library_name });
    if (exists(io, path)) return path;
    a.free(path);
    return null;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

test "the newest hostfxr wins, previews and all" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "8.0.11", "10.0.0-rc.2", "10.0.1", "9.0.0", "not-a-version" }) |v| {
        const sub = try std.fs.path.join(a, &.{ "host", "fxr", v });
        defer a.free(sub);
        try tmp.dir.createDirPath(io, sub);
        const file = try std.fs.path.join(a, &.{ sub, fxr.library_name });
        defer a.free(file);
        try tmp.dir.writeFile(io, .{ .sub_path = file, .data = "" });
    }
    const dotnet_root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dotnet_root);
    const got = (try hostfxr(a, io, dotnet_root)).?;
    defer a.free(got);
    const want = try std.fs.path.join(a, &.{ dotnet_root, "host", "fxr", "10.0.1", fxr.library_name });
    defer a.free(want);
    try std.testing.expectEqualStrings(want, got);
}
