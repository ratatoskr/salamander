const std = @import("std");

const Import = std.Build.Module.Import;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "Run tests");
    const build_test_step = b.step("build-test", "Build tests without running");
    const test_filters = b.option([]const []const u8, "test-filter", "Only run tests whose names contain this (repeatable)") orelse &.{};
    const ctx: Context = .{ .b = b, .target = target, .optimize = optimize, .test_step = test_step, .build_test_step = build_test_step, .test_filters = test_filters };

    // Each layer only imports the ones below it
    // Platform pieces, copied in so salamander stands alone
    const dyn = ctx.addModule("dyn", &.{});
    // Zig's own x64 backend skips global assembly, so SysV x64's is a file of its own
    if (target.result.cpu.arch == .x86_64 and target.result.os.tag != .windows) dyn.addAssemblyFile(b.path("src/dyn/sysv64.S"));
    const sys = ctx.addModule("sys", &.{});
    const schema = ctx.addModule("schema", &.{});
    const runtime = ctx.addModule("runtime", &.{});
    _ = ctx.addModule("zig", &.{
        .{ .name = "salamander_schema", .module = schema },
        .{ .name = "salamander_runtime", .module = runtime },
    });
    _ = ctx.addModule("c", &.{.{ .name = "salamander_schema", .module = schema }});
    // Typings for scripts' editors
    _ = ctx.addModule("types", &.{.{ .name = "salamander_schema", .module = schema }});
    // The engines, so everything using salamander shares one of each
    const quickjs_c = quickjs.cApi(b, target, optimize);
    const lua_c = lua.cApi(b, target, optimize);
    // Raw, for embedders that use the engine directly
    b.modules.put(b.graph.arena, "quickjs", quickjs_c) catch @panic("OOM");
    b.modules.put(b.graph.arena, "lua", lua_c) catch @panic("OOM");

    // Calling and implementing traits from a schema parsed while running, for script hosts
    const bind = ctx.addModule("bind", &.{
        .{ .name = "salamander_schema", .module = schema },
        .{ .name = "salamander_runtime", .module = runtime },
        .{ .name = "salamander_dyn", .module = dyn },
    });
    // What every language host shares, then the hosts
    const script = ctx.addModule("script", &.{
        .{ .name = "salamander_sys", .module = sys },
        .{ .name = "salamander_schema", .module = schema },
        .{ .name = "salamander_runtime", .module = runtime },
        .{ .name = "salamander_bind", .module = bind },
    });
    const js = ctx.addModule("js", &.{
        .{ .name = "quickjs", .module = quickjs_c },
        .{ .name = "salamander_schema", .module = schema },
        .{ .name = "salamander_runtime", .module = runtime },
        .{ .name = "salamander_bind", .module = bind },
        .{ .name = "salamander_script", .module = script },
    });
    const lua_host = ctx.addModule("lua", &.{
        .{ .name = "lua", .module = lua_c },
        .{ .name = "salamander_schema", .module = schema },
        .{ .name = "salamander_runtime", .module = runtime },
        .{ .name = "salamander_bind", .module = bind },
        .{ .name = "salamander_script", .module = script },
    });
    const hosts = ctx.addModule("hosts", &.{
        .{ .name = "salamander_script", .module = script },
        .{ .name = "salamander_js", .module = js },
        .{ .name = "salamander_lua", .module = lua_host },
        .{ .name = "salamander_runtime", .module = runtime },
    });

    // Runs while building, so it's built for the host
    const host: Context = .{ .b = b, .target = b.graph.host, .optimize = .ReleaseSafe, .test_step = test_step, .build_test_step = build_test_step, .test_filters = test_filters };
    const host_schema = host.module("schema", &.{});
    const host_zig = host.module("zig", &.{
        .{ .name = "salamander_schema", .module = host_schema },
        .{ .name = "salamander_runtime", .module = host.module("runtime", &.{}) },
    });
    const gen = b.addExecutable(.{
        .name = "salamander-gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "salamander_schema", .module = host_schema },
                .{ .name = "salamander_zig", .module = host_zig },
                .{ .name = "salamander_c", .module = host.module("c", &.{.{ .name = "salamander_schema", .module = host_schema }}) },
            },
        }),
    });
    b.installArtifact(gen);

    // salamander.h and the core traits' header, for C
    const base_headers = baseHeaders(b, gen);
    b.installDirectory(.{ .source_dir = base_headers, .install_dir = .header, .install_subdir = "" });

    // The runtime's own traits are generated too, kept in the repo since the runtime can't use the generator
    const core_update = b.addRunArtifact(gen);
    core_update.addArgs(&.{ "zig", "src/runtime/core.zig", "src/runtime/core.sal", "--runtime", "root.zig" });
    core_update.setCwd(b.path("."));
    b.step("core", "Write src/runtime/core.zig again from core.sal").dependOn(&core_update.step);
    const core_check = b.addRunArtifact(gen);
    core_check.addArgs(&.{ "zig", "src/runtime/core.zig", "src/runtime/core.sal", "--runtime", "root.zig", "--check" });
    core_check.setCwd(b.path("."));
    core_check.addFileInput(b.path("src/runtime/core.sal"));
    core_check.addFileInput(b.path("src/runtime/core.zig"));
    test_step.dependOn(&core_check.step);
    build_test_step.dependOn(&core_check.step);

    // Each test's schema as generated Zig, like a project using salamander gets it
    inline for (.{ .{ bind, "bind" }, .{ js, "js" }, .{ lua_host, "lua" }, .{ hosts, "hosts" } }) |t| {
        t[0].addImport("test_schema", generate(b, gen, runtime, .{ .source = b.path("src/" ++ t[1] ++ "/test.sal"), .target = target }));
    }

    // The generated Zig, C and the schema have to agree on everything
    const generated = generate(b, gen, runtime, .{ .source = b.path("src/schema/test.sal"), .target = target });
    const agree = b.createModule(.{
        .root_source_file = b.path("src/agree.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "salamander_schema", .module = schema },
            .{ .name = "salamander_runtime", .module = runtime },
            .{ .name = "generated", .module = generated },
            .{ .name = "plain", .module = generate(b, gen, runtime, .{ .source = b.path("src/zig/plain.sal"), .target = target }) },
        },
    });
    // And C's view of the same schema has to match both
    agree.addIncludePath(cHeadersWith(b, gen, base_headers, .{ .source = b.path("src/schema/test.sal"), .target = target, .name = "test_schema.h" }));
    agree.addCSourceFile(.{ .file = b.path("src/c/test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    ctx.addTests("agree", agree);
}

pub const CHeaderOptions = struct {
    /// A `.sal` file.
    source: std.Build.LazyPath,
    /// Gives the schema its pointer size.
    target: std.Build.ResolvedTarget,
    /// What to `#include`.
    name: []const u8,
    /// Goes in front of every name, since C has no namespaces.
    prefix: []const u8 = "",
};

/// A folder with `salamander.h`, `salamander_core.h` and a header for `source`, for `addIncludePath`, like
/// `module.addIncludePath(salamander.cHeaders(dep, .{ .source = b.path("game.sal"), .target = target, .name = "game.h" }));`
pub fn cHeaders(dep: *std.Build.Dependency, options: CHeaderOptions) std.Build.LazyPath {
    const gen = dep.artifact("salamander-gen");
    return cHeadersWith(dep.builder, gen, baseHeaders(dep.builder, gen), options);
}

/// `salamander.h`, and `salamander_core.h` made from `core.sal`.
fn baseHeaders(b: *std.Build, gen: *std.Build.Step.Compile) std.Build.LazyPath {
    const run = b.addRunArtifact(gen);
    run.addArg("c");
    const core_h = run.addOutputFileArg("salamander_core.h");
    run.addFileArg(b.path("src/runtime/core.sal"));
    run.addArgs(&.{ "--prefix", "sal_", "--core" });
    const files = b.addWriteFiles();
    _ = files.addCopyFile(b.path("src/c/salamander.h"), "salamander.h");
    _ = files.addCopyFile(core_h, "salamander_core.h");
    return files.getDirectory();
}

fn cHeadersWith(b: *std.Build, gen: *std.Build.Step.Compile, base: std.Build.LazyPath, options: CHeaderOptions) std.Build.LazyPath {
    const run = b.addRunArtifact(gen);
    run.addArg("c");
    const header = run.addOutputFileArg(options.name);
    run.addFileArg(options.source);
    run.addArgs(&.{ "--pointer-size", b.fmt("{d}", .{options.target.result.ptrBitWidth() / 8}) });
    if (options.prefix.len > 0) run.addArgs(&.{ "--prefix", options.prefix });
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(base, "", .{});
    _ = files.addCopyFile(header, options.name);
    return files.getDirectory();
}

pub const ZigOptions = struct {
    /// A `.sal` file. Or use `folder`.
    source: ?std.Build.LazyPath = null,
    /// A folder of `.sal` files that make one schema, like a `schemas` folder.
    folder: ?std.Build.LazyPath = null,
    /// Gives the schema its pointer size.
    target: std.Build.ResolvedTarget,
    /// Tools' namespaces in scope in every file, like `&.{"wraith"}` so they can say `[Sig]`.
    uses: []const []const u8 = &.{},
    /// Other folders of `.sal` files in the same schema, each named, like a dependency's.
    with: []const With = &.{},
    /// Tags that make a struct a global, like `wraith.Instance=Sig`. See the parser's `InstanceTag`.
    instances: []const []const u8 = &.{},
    /// What files starting with `prefix` declare comes from `module` instead, imported as `name`.
    /// Like a `with` folder whose Zig another module already has.
    aliases: []const Alias = &.{},

    pub const With = struct { name: []const u8, folder: std.Build.LazyPath };
    pub const Alias = struct { prefix: []const u8, name: []const u8, module: *std.Build.Module };
};

/// A folder of `.sal` files bundled into one, for `@embedFile` and comptime binding, like
/// `mod.addAnonymousImport("game.sal", .{ .root_source_file = salamander.bundle(dep, b.path("schemas")) });`
pub fn bundle(dep: *std.Build.Dependency, folder: std.Build.LazyPath) std.Build.LazyPath {
    const run = dep.builder.addRunArtifact(dep.artifact("salamander-gen"));
    run.addArg("bundle");
    const out = run.addOutputFileArg("schema.sal");
    run.addDirectoryArg(folder);
    trackSal(run, folder);
    return out;
}

/// A directory argument doesn't rerun when its contents change, so each `.sal` goes in as an input too.
/// The build script lists the folder, so it reruns when a file's added or removed. Folders in a source
/// tree, the build's own or a dependency's.
fn trackSal(run: *std.Build.Step.Run, folder: std.Build.LazyPath) void {
    const owner, const sub_path = switch (folder) {
        .src_path => |s| .{ s.owner, s.sub_path },
        .dependency => |d| .{ d.dependency.builder, d.sub_path },
        else => return,
    };
    const at: std.Build.LazyPath = .{ .src_path = .{ .owner = owner, .sub_path = sub_path } };
    owner.dependOnDirectoryMetadata(at);
    const io = owner.graph.io;
    var dir = owner.root.openDir(io, sub_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.walk(owner.allocator) catch return;
    defer walker.deinit(io);
    while (walker.next(io) catch return) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".sal")) continue;
        run.addFileInput(.{ .src_path = .{ .owner = owner, .sub_path = owner.pathJoin(&.{ sub_path, entry.path }) } });
    }
}

/// A `.sal` file as a Zig module, for a project using salamander, like
/// `const game = salamander.zigModule(dep, .{ .source = b.path("game.sal"), .target = target });`
pub fn zigModule(dep: *std.Build.Dependency, options: ZigOptions) *std.Build.Module {
    return generate(dep.builder, dep.artifact("salamander-gen"), dep.module("salamander_runtime"), options);
}

fn generate(b: *std.Build, gen: *std.Build.Step.Compile, runtime: *std.Build.Module, options: ZigOptions) *std.Build.Module {
    const run = b.addRunArtifact(gen);
    run.addArg("zig");
    const out = run.addOutputFileArg("schema.zig");
    if (options.folder) |f| {
        run.addDirectoryArg(f);
        trackSal(run, f);
    } else run.addFileArg(options.source.?);
    run.addArgs(&.{ "--pointer-size", b.fmt("{d}", .{options.target.result.ptrBitWidth() / 8}) });
    for (options.uses) |u| run.addArgs(&.{ "--use", u });
    for (options.instances) |i| run.addArgs(&.{ "--instance", i });
    for (options.with) |w| {
        run.addArgs(&.{ "--with", w.name });
        run.addDirectoryArg(w.folder);
        trackSal(run, w.folder);
    }
    var imports: std.ArrayList(std.Build.Module.Import) = .empty;
    imports.append(b.allocator, .{ .name = "salamander_runtime", .module = runtime }) catch @panic("OOM");
    for (options.aliases) |a| {
        run.addArgs(&.{ "--alias", b.fmt("{s}={s}", .{ a.prefix, a.name }) });
        const listed = for (imports.items) |i| {
            if (std.mem.eql(u8, i.name, a.name)) break true;
        } else false;
        if (!listed) imports.append(b.allocator, .{ .name = a.name, .module = a.module }) catch @panic("OOM");
    }
    return b.createModule(.{
        .root_source_file = out,
        .imports = imports.items,
    });
}

const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    build_test_step: *std.Build.Step,
    test_filters: []const []const u8,

    /// Adds `salamander_<name>` from `src/<name>/root.zig` with its tests.
    fn addModule(self: Context, comptime name: []const u8, imports: []const Import) *std.Build.Module {
        const mod = self.b.addModule("salamander_" ++ name, .{
            .root_source_file = self.b.path("src/" ++ name ++ "/root.zig"),
            .target = self.target,
            .optimize = self.optimize,
            .imports = imports,
        });
        self.addTests(name, mod);
        return mod;
    }

    /// One that isn't exported or tested, like the host's copies.
    fn module(self: Context, comptime name: []const u8, imports: []const Import) *std.Build.Module {
        return self.b.createModule(.{
            .root_source_file = self.b.path("src/" ++ name ++ "/root.zig"),
            .target = self.target,
            .optimize = self.optimize,
            .imports = imports,
        });
    }

    fn addTests(self: Context, comptime name: []const u8, mod: *std.Build.Module) void {
        const tests = self.b.addTest(.{ .name = "salamander_" ++ name ++ "_tests", .root_module = mod, .filters = self.test_filters });
        const run_artifact = self.b.addRunArtifact(tests);
        run_artifact.has_side_effects = true;
        self.test_step.dependOn(&run_artifact.step);
        self.build_test_step.dependOn(&self.b.addInstallArtifact(tests, .{}).step);
    }
};

/// QuickJS-ng, built without its libc.
const quickjs = struct {
    fn flags(target: std.Build.ResolvedTarget) []const []const u8 {
        const common = .{
            "-DQUICKJS_NG_BUILD",
            "-D_GNU_SOURCE",
            // The engine does stuff UBSan hates, like tagged pointers and unaligned reads
            "-fno-sanitize=undefined",
        };
        const windows = .{ "-DWIN32_LEAN_AND_MEAN", "-D_WIN32_WINNT=0x0601", "-D_CRT_SECURE_NO_WARNINGS", "-D_CRT_NONSTDC_NO_DEPRECATE" };
        return if (target.result.os.tag == .windows) &(common ++ windows) else &common;
    }

    /// Its C API, linked with the library.
    fn cApi(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
        const src = b.dependency("quickjs", .{});
        const t = b.addTranslateC(.{
            .root_source_file = src.path("quickjs.h"),
            .target = target,
            .optimize = optimize,
        });
        t.addIncludePath(src.path("."));
        const mod = t.createModule();
        mod.linkLibrary(library(b, src, target, optimize));
        return mod;
    }

    fn library(b: *std.Build, src: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
        const lib = b.addLibrary(.{
            .name = "quickjs",
            .linkage = .static,
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
        });
        lib.root_module.addIncludePath(src.path("."));
        lib.root_module.addCSourceFiles(.{ .root = src.path("."), .files = &.{ "quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c" }, .flags = flags(target) });
        return lib;
    }
};

/// Lua 5.5. Just the core and the libraries it opens, no lua.c, luac.c or onelua.c.
const lua = struct {
    fn flags(target: std.Build.ResolvedTarget) []const []const u8 {
        const common = .{
            "-std=gnu99",
            // It leans on wrapping integer math in places
            "-fno-sanitize=undefined",
        };
        // POSIX's mkstemp and popen, without dlopen since there's no package library
        return if (target.result.os.tag == .windows) &(common ++ .{"-D_CRT_SECURE_NO_WARNINGS"}) else &(common ++ .{"-DLUA_USE_POSIX"});
    }

    const files: []const []const u8 = &.{
        "lapi.c",     "lcode.c",   "lctype.c",  "ldebug.c",   "ldo.c",      "ldump.c",    "lfunc.c",    "lgc.c",
        "llex.c",     "lmem.c",    "lobject.c", "lopcodes.c", "lparser.c",  "lstate.c",   "lstring.c",  "ltable.c",
        "ltm.c",      "lundump.c", "lvm.c",     "lzio.c",     "lauxlib.c",  "lbaselib.c", "lcorolib.c", "ldblib.c",
        "lmathlib.c", "loslib.c",  "lstrlib.c", "ltablib.c",  "lutf8lib.c",
    };

    /// Its C API with the aux and standard libraries, linked with the library.
    fn cApi(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
        const src = b.dependency("lua", .{});
        const header = b.addWriteFiles().add("lua_api.h",
            \\#include "lua.h"
            \\#include "lauxlib.h"
            \\#include "lualib.h"
            \\
        );
        const t = b.addTranslateC(.{
            .root_source_file = header,
            .target = target,
            .optimize = optimize,
        });
        t.addIncludePath(src.path("."));
        const mod = t.createModule();
        mod.linkLibrary(library(b, src, target, optimize));
        return mod;
    }

    fn library(b: *std.Build, src: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
        const lib = b.addLibrary(.{
            .name = "lua",
            .linkage = .static,
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
        });
        lib.root_module.addIncludePath(src.path("."));
        lib.root_module.addCSourceFiles(.{ .root = src.path("."), .files = files, .flags = flags(target) });
        return lib;
    }
};
