//! `salamander-gen zig <out.zig> <in> [--pointer-size N] [--runtime NAME] [--use NS]... [--with NAME DIR]... [--check]`
//! `salamander-gen c <out.h> <in> [--pointer-size N] [--prefix P] [--core] [--check]`
//! `salamander-gen bundle <out.sal> <in>`
//! `<in>` is a `.sal` file or a folder whose `.sal` files, nested too, make one schema.
//! `--use NS` puts a tool's namespace in scope, like a `use` in every file.
//! `--with NAME DIR` adds another folder's `.sal` files, named `NAME/...`, like a dependency's.
//! `--check` writes nothing and fails if the output isn't what it would write.

const std = @import("std");
const salamander_schema = @import("salamander_schema");
const salamander_zig = @import("salamander_zig");
const salamander_c = @import("salamander_c");

const Schema = salamander_schema.Schema;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    const lang = args.next() orelse return usage();
    const is_c = std.mem.eql(u8, lang, "c");
    const is_bundle = std.mem.eql(u8, lang, "bundle");
    if (!is_c and !is_bundle and !std.mem.eql(u8, lang, "zig")) return usage();
    const out_path = args.next() orelse return usage();
    const in_path = args.next() orelse return usage();
    var pointer_size: u8 = @sizeOf(usize);
    var runtime: []const u8 = "salamander_runtime";
    var check = false;
    var prefix: []const u8 = "";
    var core = false;
    var uses: std.ArrayList([]const u8) = .empty;
    var with: std.ArrayList([2][]const u8) = .empty;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--pointer-size")) {
            pointer_size = std.fmt.parseInt(u8, args.next() orelse return usage(), 10) catch return usage();
        } else if (std.mem.eql(u8, arg, "--runtime")) {
            runtime = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (std.mem.eql(u8, arg, "--prefix")) {
            prefix = args.next() orelse return usage();
        } else if (std.mem.eql(u8, arg, "--core")) {
            core = true;
        } else if (std.mem.eql(u8, arg, "--use")) {
            try uses.append(arena, args.next() orelse return usage());
        } else if (std.mem.eql(u8, arg, "--with")) {
            const name = args.next() orelse return usage();
            try with.append(arena, .{ name, args.next() orelse return usage() });
        } else return usage();
    }

    var files: std.ArrayList(salamander_schema.File) = .empty;
    for (with.items) |w| try readFolder(arena, io, w[1], w[0], &files);
    const source, const is_dir = try read(arena, io, in_path, &files);
    if (is_bundle) return std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = source });
    var diag: Schema.Diagnostic = .{};
    // Annotations are for tools, so any namespace is fine here
    var parsed = salamander_schema.parse(arena, source, .{ .pointer_size = pointer_size, .any_namespace = true, .uses = uses.items }, &diag) catch |err| switch (err) {
        error.InvalidSchema => fail(in_path, is_dir, diag.message()),
        else => return err,
    };
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(arena);
    const label = std.fs.path.basename(in_path);
    const written = if (is_c)
        salamander_c.write(arena, parsed.schema, &out.writer, .{ .label = label, .prefix = prefix, .core = core }, &diag)
    else
        salamander_zig.write(arena, parsed.schema, &out.writer, .{ .label = label, .runtime = runtime }, &diag);
    written catch |err| switch (err) {
        error.NameClash => fail(in_path, is_dir, diag.message()),
        else => return err,
    };
    const text = if (is_c) out.written() else try formatted(arena, out.written());
    if (check) {
        const have = std.Io.Dir.cwd().readFileAlloc(io, out_path, arena, .limited(16 << 20)) catch "";
        if (!std.mem.eql(u8, std.mem.trim(u8, have, "\r\n"), std.mem.trim(u8, text, "\r\n"))) {
            std.debug.print("{s} is out of date with {s}. Write it again, with `zig build core` for the runtime's.\n", .{ out_path, in_path });
            std.process.exit(1);
        }
        return;
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = text });
}

/// Like `zig fmt` leaves it, so the file stays the same after it.
fn formatted(arena: std.mem.Allocator, source: []const u8) ![]const u8 {
    var tree = try std.zig.Ast.parse(arena, try arena.dupeSentinel(u8, source, 0), .{});
    defer tree.deinit(arena);
    if (tree.errors.len > 0) {
        std.debug.print("the Zig written doesn't parse, at token {d}\n", .{tree.errors[0].token});
        return error.InvalidZig;
    }
    return tree.renderAlloc(arena);
}

/// A file's text, or a folder's `.sal` files bundled, by path so it's the same every time. `extra`
/// goes first, like `--with` folders.
fn read(arena: std.mem.Allocator, io: std.Io, path: []const u8, extra: *std.ArrayList(salamander_schema.File)) !struct { []const u8, bool } {
    const cwd = std.Io.Dir.cwd();
    const start = extra.items.len;
    readFolder(arena, io, path, "", extra) catch |err| switch (err) {
        error.NotDir => {
            const text = try cwd.readFileAlloc(io, path, arena, .limited(16 << 20));
            if (start == 0) return .{ text, false };
            try extra.append(arena, .{ .name = std.fs.path.basename(path), .text = text });
            return .{ try salamander_schema.bundle(arena, extra.items), true };
        },
        else => return err,
    };
    return .{ try salamander_schema.bundle(arena, extra.items), true };
}

/// A folder's `.sal` files, nested too, sorted and named by path, after `prefix/` if there is one.
fn readFolder(arena: std.mem.Allocator, io: std.Io, path: []const u8, prefix: []const u8, files: *std.ArrayList(salamander_schema.File)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    const start = files.items.len;
    var walker = try dir.walk(arena);
    defer walker.deinit(io);
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".sal")) continue;
        const name = if (prefix.len > 0) try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.path }) else try arena.dupe(u8, entry.path);
        // The same on every platform
        std.mem.replaceScalar(u8, name, '\\', '/');
        try files.append(arena, .{ .name = name, .text = try dir.readFileAlloc(io, entry.path, arena, .limited(16 << 20)) });
    }
    std.mem.sort(salamander_schema.File, files.items[start..], {}, struct {
        fn lessThan(_: void, a: salamander_schema.File, b: salamander_schema.File) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

fn usage() error{Usage} {
    std.debug.print(
        \\usage: salamander-gen zig <out.zig> <in> [--pointer-size N] [--runtime NAME] [--use NS]... [--with NAME DIR]... [--check]
        \\       salamander-gen c <out.h> <in> [--pointer-size N] [--prefix P] [--core] [--check]
        \\       salamander-gen bundle <out.sal> <in>
        \\<in> is a .sal file, or a folder of them that make one schema.
        \\
    , .{});
    return error.Usage;
}

/// A bundle's messages start with the file they're in, so they go under the folder.
fn fail(path: []const u8, is_dir: bool, message: []const u8) noreturn {
    const sep = if (is_dir) "/" else if (message.len > 0 and std.ascii.isDigit(message[0])) ":" else ": ";
    std.debug.print("{s}{s}{s}\n", .{ path, sep, message });
    std.process.exit(1);
}
