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
    _ = ctx.addModule("cpp", &.{.{ .name = "salamander_schema", .module = schema }});
    _ = ctx.addModule("rust", &.{.{ .name = "salamander_schema", .module = schema }});
    // C#, with the runtime's own core.sal so tools can write its C# too
    ctx.addModule("cs", &.{.{ .name = "salamander_schema", .module = schema }}).addAnonymousImport("core.sal", .{ .root_source_file = b.path("src/runtime/core.sal") });
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
    // .NET's CoreCLR, joined or started through hostfxr
    const clr_imports: []const Import = &.{.{ .name = "salamander_sys", .module = sys }};
    const clr = b.addModule("salamander_clr", .{ .root_source_file = b.path("src/clr/root.zig"), .target = target, .optimize = optimize, .imports = clr_imports });
    // Only its tests need the probe, so using it doesn't need the dotnet SDK. They get it once the generator's there.
    const clr_tests = ctx.module("clr", clr_imports);
    clr_tests.addImport("salamander_runtime", runtime);
    // dlopen and getenv
    if (target.result.os.tag != .windows) {
        clr.link_libc = true;
        clr_tests.link_libc = true;
    }
    ctx.addTestsWith("clr", clr_tests, noSignalStackRunner(b));
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
                .{ .name = "salamander_cpp", .module = host.module("cpp", &.{.{ .name = "salamander_schema", .module = host_schema }}) },
                .{ .name = "salamander_rust", .module = host.module("rust", &.{.{ .name = "salamander_schema", .module = host_schema }}) },
                .{ .name = "salamander_cs", .module = blk: {
                    const cs = host.module("cs", &.{.{ .name = "salamander_schema", .module = host_schema }});
                    cs.addAnonymousImport("core.sal", .{ .root_source_file = b.path("src/runtime/core.sal") });
                    break :blk cs;
                } },
            },
        }),
    });
    b.installArtifact(gen);

    // salamander.h and the core traits' header, for C
    const base_headers = baseHeaders(b, gen);
    b.installDirectory(.{ .source_dir = base_headers, .install_dir = .header, .install_subdir = "" });
    // And C++'s
    const base_cpp = baseCppHeaders(b, gen);
    b.installDirectory(.{ .source_dir = base_cpp, .install_dir = .header, .install_subdir = "" });

    // The runtime's own traits are generated too, kept in the repo since the runtime can't use the generator
    const core_update = b.addRunArtifact(gen);
    core_update.addArgs(&.{ "zig", "src/runtime/core.zig", "src/runtime/core.sal", "--runtime", "root.zig" });
    core_update.setCwd(b.path("."));
    const core_step = b.step("core", "Write src/runtime/core.zig and the Rust crate's sal_core.rs again from core.sal");
    core_step.dependOn(&core_update.step);
    const rust_core_update = b.addRunArtifact(gen);
    rust_core_update.addArgs(&.{ "rust", "src/rust/src/sal_core.rs", "src/runtime/core.sal", "--core" });
    rust_core_update.setCwd(b.path("."));
    core_step.dependOn(&rust_core_update.step);
    const rust_core_check = b.addRunArtifact(gen);
    rust_core_check.addArgs(&.{ "rust", "src/rust/src/sal_core.rs", "src/runtime/core.sal", "--core", "--check" });
    rust_core_check.setCwd(b.path("."));
    rust_core_check.addFileInput(b.path("src/runtime/core.sal"));
    rust_core_check.addFileInput(b.path("src/rust/src/sal_core.rs"));
    test_step.dependOn(&rust_core_check.step);
    build_test_step.dependOn(&rust_core_check.step);
    const core_check = b.addRunArtifact(gen);
    core_check.addArgs(&.{ "zig", "src/runtime/core.zig", "src/runtime/core.sal", "--runtime", "root.zig", "--check" });
    core_check.setCwd(b.path("."));
    core_check.addFileInput(b.path("src/runtime/core.sal"));
    core_check.addFileInput(b.path("src/runtime/core.zig"));
    test_step.dependOn(&core_check.step);
    build_test_step.dependOn(&core_check.step);

    // Each test's schema as generated Zig, like a project using salamander gets it
    inline for (.{ .{ bind, "bind" }, .{ js, "js" }, .{ lua_host, "lua" }, .{ hosts, "hosts" }, .{ clr_tests, "clr" } }) |t| {
        t[0].addImport("test_schema", generate(b, gen, runtime, .{ .source = b.path("src/" ++ t[1] ++ "/test.sal"), .target = target }));
    }
    // And as C#, built into the probe
    clr_tests.addImport("clr_test", clrProbe(b, csFilesWith(b, gen, .{ .source = b.path("src/clr/test.sal"), .target = target, .name = "TestSchema.cs", .namespace = "Probe.Sal" })));

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
            .{ .name = "salamander_sys", .module = sys },
            // And Rust's, built by cargo into a library the tests load
            .{ .name = "rust_test", .module = rustProbe(b, gen, target) },
        },
    });
    // And C's view of the same schema has to match both
    agree.addIncludePath(cHeadersWith(b, gen, base_headers, .{ .source = b.path("src/schema/test.sal"), .target = target, .name = "test_schema.h" }));
    agree.addCSourceFile(.{ .file = b.path("src/c/test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    // And C++'s
    agree.addIncludePath(cppHeadersWith(b, gen, base_cpp, .{ .source = b.path("src/schema/test.sal"), .target = target, .name = "test_schema.hpp" }));
    // Zig says -nostdinc++ without its libc++, which MSVC's headers make unused
    agree.addCSourceFile(.{ .file = b.path("src/cpp/test.cpp"), .flags = &.{ "-std=c++20", "-Wall", "-Wextra", "-Werror", "-Wno-unused-command-line-argument" } });
    // Zig's libc++ doesn't build for MSVC, whose own C++ library comes with its C one
    if (target.result.abi == .msvc) agree.linkSystemLibrary("msvcprt", .{}) else agree.link_libcpp = true;
    ctx.addTests("agree", agree);
}

/// Zig's test runner without its per-thread signal stack, which .NET's 256KB threads can't fit on Linux.
fn noSignalStackRunner(b: *std.Build) std.Build.Step.Compile.TestRunner {
    const files = b.addWriteFiles();
    _ = files.addCopyFile(std.Build.LazyPath.zig_lib.path(b, "compiler/test_runner.zig"), "zig_test_runner.zig");
    const root = files.add("runner.zig",
        \\const std = @import("std");
        \\const runner = @import("zig_test_runner.zig");
        \\
        \\pub const std_options: std.Options = blk: {
        \\    var o = runner.std_options;
        \\    o.signal_stack_size = null;
        \\    break :blk o;
        \\};
        \\pub const main = runner.main;
        \\pub const fuzz = runner.fuzz;
        \\
    );
    return .{ .path = root, .mode = .server };
}

/// The Rust the agree tests call, built by cargo from `src/rust/test` with `test.sal`'s Rust. For this machine,
/// or 32-bit Windows on 64-bit with its target installed (`rustup target add i686-pc-windows-msvc`).
/// Without cargo or the target, the path's empty and the tests skip. Only looked for in a root build.
fn rustProbe(b: *std.Build, gen: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) *std.Build.Module {
    const options = b.addOptions();
    const host = b.graph.host.result;
    // Cargo's Linux libraries are glibc's, which a static musl test can't load
    const loads = target.result.os.tag != .linux or target.result.abi.isGnu();
    const native = target.result.cpu.arch == host.cpu.arch and target.result.os.tag == host.os.tag and loads;
    const cargo = (if (b.isRoot()) b.findProgram(.{ .names = &.{"cargo"} }) else null) orelse return noRust(options);
    // Null builds for this machine
    const triple: ?[]const u8 = if (native) null else if (host.os.tag == .windows and host.cpu.arch == .x86_64 and target.result.os.tag == .windows and target.result.cpu.arch == .x86)
        "i686-pc-windows-msvc"
    else
        return noRust(options);
    if (triple) |t| if (!hasRustTarget(b, t)) return noRust(options);
    const schema = b.addRunArtifact(gen);
    schema.addArg("rust");
    const schema_rs = schema.addOutputFileArg("schema.rs");
    schema.addFileArg(b.path("src/schema/test.sal"));
    schema.addArgs(&.{ "--pointer-size", b.fmt("{d}", .{target.result.ptrBitWidth() / 8}) });
    // The test crate, with its schema and the salamander crate beside it
    const manifest =
        \\[package]
        \\name = "salamander_test"
        \\version = "0.0.0"
        \\edition = "2024"
        \\publish = false
        \\
        \\[lib]
        \\path = "src/lib.rs"
        \\crate-type = ["cdylib"]
        \\
        \\[dependencies]
        \\salamander = { path = "salamander" }
        \\
    ;
    const files = b.addWriteFiles();
    _ = files.add("Cargo.toml", manifest);
    _ = files.addCopyFile(b.path("src/rust/test/src/lib.rs"), "src/lib.rs");
    _ = files.addCopyFile(schema_rs, "schema.rs");
    _ = files.addCopyFile(b.path("src/rust/Cargo.toml"), "salamander/Cargo.toml");
    _ = files.addCopyDirectory(b.path("src/rust/src"), "salamander/src", .{});
    const run = b.addSystemCommand(&.{ cargo, "build", "--release", "--quiet", "--manifest-path" });
    run.addFileArg(files.getDirectory().path(b, "Cargo.toml"));
    if (triple) |t| run.addArgs(&.{ "--target", t });
    run.addArg("--target-dir");
    const out = run.addOutputDirectoryArg("target");
    run.stdio = .inherit;
    const name = switch (host.os.tag) {
        .windows => "salamander_test.dll",
        .macos => "libsalamander_test.dylib",
        else => "libsalamander_test.so",
    };
    const dir = if (triple) |t| b.fmt("{s}/release", .{t}) else "release";
    options.addOptionPath("library", out.path(b, b.fmt("{s}/{s}", .{ dir, name })));
    return options.createModule();
}

fn noRust(options: *std.Build.Step.Options) *std.Build.Module {
    options.addOption([]const u8, "library", "");
    return options.createModule();
}

/// Whether rustup has the standard library for `triple`.
fn hasRustTarget(b: *std.Build, triple: []const u8) bool {
    var code: u8 = 0;
    const out = b.runAllowFail(&.{ "rustc", "--print", "target-libdir", "--target", triple }, &code, .ignore) catch return false;
    const dir = std.mem.trim(u8, out, " \r\n");
    std.Io.Dir.cwd().access(b.graph.io, dir, .{}) catch return false;
    return true;
}

/// The C# the clr tests call, built with the dotnet SDK. Without it the paths are empty and the tests skip.
/// Only looked for in a root build, since looking reconfigures every build.
fn clrProbe(b: *std.Build, schema: std.Build.LazyPath) *std.Build.Module {
    const options = b.addOptions();
    const dotnet = (if (b.isRoot()) b.findProgram(.{ .names = &.{"dotnet"} }) else null) orelse {
        options.addOption([]const u8, "dll", "");
        options.addOption([]const u8, "runtime_config", "");
        return options.createModule();
    };
    const run = b.addSystemCommand(&.{ dotnet, "build" });
    run.addFileArg(b.path("src/clr/test/Probe.csproj"));
    run.addArgs(&.{ "--nologo", "-v", "quiet", "-clp:ErrorsOnly;NoSummary", "-c", "Release", "-o" });
    const out = run.addOutputDirectoryArg("probe");
    // Keeps obj out of the source tree
    run.addArg("--artifacts-path");
    _ = run.addOutputDirectoryArg("artifacts");
    run.addPrefixedDirectoryArg("-p:SalamanderDir=", schema);
    run.addFileInput(b.path("src/clr/test/Probe.cs"));
    run.addFileInput(b.path("src/clr/test/Traits.cs"));
    run.setEnvironmentVariable("DOTNET_CLI_TELEMETRY_OPTOUT", "1");
    run.setEnvironmentVariable("DOTNET_NOLOGO", "1");
    // dotnet writes its errors to stdout
    run.stdio = .inherit;
    options.addOptionPath("dll", out.path(b, "Probe.dll"));
    options.addOptionPath("runtime_config", out.path(b, "Probe.runtimeconfig.json"));
    return options.createModule();
}

pub const CsOptions = struct {
    /// A `.sal` file.
    source: std.Build.LazyPath,
    /// Gives the schema its pointer size. The C# only works in processes with that size.
    target: std.Build.ResolvedTarget,
    /// What to call the file.
    name: []const u8,
    /// The file's namespace. None if empty.
    namespace: []const u8 = "",
    /// The static class for its constants.
    class: []const u8 = "Schema",
};

/// A folder with `Salamander.cs`, `SalamanderCore.cs` and C# for `source`, to compile into a C# project.
/// The project needs `AllowUnsafeBlocks` and .NET 8 or newer.
pub fn csFiles(dep: *std.Build.Dependency, options: CsOptions) std.Build.LazyPath {
    return csFilesWith(dep.builder, dep.artifact("salamander-gen"), options);
}

fn csFilesWith(b: *std.Build, gen: *std.Build.Step.Compile, options: CsOptions) std.Build.LazyPath {
    const pointer_size = b.fmt("{d}", .{options.target.result.ptrBitWidth() / 8});
    const core = b.addRunArtifact(gen);
    core.addArg("cs");
    const core_cs = core.addOutputFileArg("SalamanderCore.cs");
    core.addFileArg(b.path("src/runtime/core.sal"));
    core.addArgs(&.{ "--pointer-size", pointer_size, "--core" });
    const run = b.addRunArtifact(gen);
    run.addArg("cs");
    const out = run.addOutputFileArg(options.name);
    run.addFileArg(options.source);
    run.addArgs(&.{ "--pointer-size", pointer_size, "--class", options.class });
    if (options.namespace.len > 0) run.addArgs(&.{ "--namespace", options.namespace });
    const files = b.addWriteFiles();
    _ = files.addCopyFile(b.path("src/cs/Salamander.cs"), "Salamander.cs");
    _ = files.addCopyFile(core_cs, "SalamanderCore.cs");
    _ = files.addCopyFile(out, options.name);
    return files.getDirectory();
}

pub const CHeaderOptions = struct {
    /// A `.sal` file. Or use `folder`.
    source: ?std.Build.LazyPath = null,
    /// A folder of `.sal` files that make one schema, like a `schemas` folder.
    folder: ?std.Build.LazyPath = null,
    /// Gives the schema its pointer size.
    target: std.Build.ResolvedTarget,
    /// What to `#include`.
    name: []const u8,
    /// Goes in front of every name, since C has no namespaces.
    prefix: []const u8 = "",
    /// Tools' namespaces in scope in every file, like `&.{"wraith"}` so they can say `[Sig]`.
    uses: []const []const u8 = &.{},
    /// Where files that don't say a namespace go, like a plugin's own. Empty is the top.
    namespace: []const u8 = "",
    /// Annotations that stand for a static, like `wraith.Instance=Sig`, see `ZigOptions.instances`.
    instances: []const []const u8 = &.{},
    /// Namespaces every file uses the types of by their short names, like `&.{"Wraith"}`.
    global_uses: []const []const u8 = &.{},
    /// Like `freecam/=Freecam`, see `ZigOptions.file_namespaces`.
    file_namespaces: []const []const u8 = &.{},
    /// Other folders' `.sal` files, named `name/...`, like a dependency's.
    with: []const ZigOptions.With = &.{},
    /// What files starting with `prefix` declare comes from header `include` instead of being written again.
    aliases: []const Alias = &.{},

    pub const Alias = struct { prefix: []const u8, include: []const u8 };
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
    if (options.folder) |f| {
        run.addDirectoryArg(f);
        trackSal(run, f);
    } else run.addFileArg(options.source orelse @panic("cHeaders needs a source or a folder"));
    run.addArgs(&.{ "--pointer-size", b.fmt("{d}", .{options.target.result.ptrBitWidth() / 8}) });
    if (options.prefix.len > 0) run.addArgs(&.{ "--prefix", options.prefix });
    for (options.uses) |u| run.addArgs(&.{ "--use", u });
    for (options.global_uses) |u| run.addArgs(&.{ "--global-use", u });
    if (options.namespace.len > 0) run.addArgs(&.{ "--default-namespace", options.namespace });
    for (options.file_namespaces) |f| run.addArgs(&.{ "--file-namespace", f });
    for (options.instances) |i| run.addArgs(&.{ "--instance", i });
    for (options.with) |w| {
        run.addArgs(&.{ "--with", w.name });
        run.addDirectoryArg(w.folder);
        trackSal(run, w.folder);
    }
    for (options.aliases) |a| run.addArgs(&.{ "--alias", b.fmt("{s}={s}", .{ a.prefix, a.include }) });
    const files = b.addWriteFiles();
    _ = files.addCopyDirectory(base, "", .{});
    _ = files.addCopyFile(header, options.name);
    return files.getDirectory();
}

pub const CppHeaderOptions = struct {
    /// A `.sal` file. Or use `folder`.
    source: ?std.Build.LazyPath = null,
    /// A folder of `.sal` files that make one schema, like a `schemas` folder.
    folder: ?std.Build.LazyPath = null,
    /// Gives the schema its pointer size.
    target: std.Build.ResolvedTarget,
    /// What to `#include`.
    name: []const u8,
    /// Where what has no namespace goes in C++, like `Game`. The top if empty.
    home: []const u8 = "",
    /// Tools' namespaces in scope in every file, like `&.{"wraith"}` so they can say `[Sig]`.
    uses: []const []const u8 = &.{},
    /// Where files that don't say a namespace go, like a plugin's own. Empty is the top.
    namespace: []const u8 = "",
    /// Annotations that stand for a static, like `wraith.Instance=Sig`, see `ZigOptions.instances`.
    instances: []const []const u8 = &.{},
    /// Namespaces every file uses the types of by their short names, like `&.{"Wraith"}`.
    global_uses: []const []const u8 = &.{},
    /// Like `freecam/=Freecam`, see `ZigOptions.file_namespaces`.
    file_namespaces: []const []const u8 = &.{},
    /// Other folders' `.sal` files, named `name/...`, like a dependency's.
    with: []const ZigOptions.With = &.{},
    /// What files starting with `prefix` declare comes from header `include` instead of being written again.
    aliases: []const CHeaderOptions.Alias = &.{},
};

/// A folder with `salamander.hpp`, `salamander_runtime.hpp`, `salamander_core.hpp` and a header for `source`,
/// for `addIncludePath`. Needs C++20.
pub fn cppHeaders(dep: *std.Build.Dependency, options: CppHeaderOptions) std.Build.LazyPath {
    const gen = dep.artifact("salamander-gen");
    return cppHeadersWith(dep.builder, gen, baseCppHeaders(dep.builder, gen), options);
}

/// `salamander.hpp`, `salamander_runtime.hpp`, and `salamander_core.hpp` made from `core.sal`.
fn baseCppHeaders(b: *std.Build, gen: *std.Build.Step.Compile) std.Build.LazyPath {
    const run = b.addRunArtifact(gen);
    run.addArg("cpp");
    const core_h = run.addOutputFileArg("salamander_core.hpp");
    run.addFileArg(b.path("src/runtime/core.sal"));
    run.addArg("--core");
    const files = b.addWriteFiles();
    _ = files.addCopyFile(b.path("src/cpp/salamander.hpp"), "salamander.hpp");
    _ = files.addCopyFile(b.path("src/cpp/salamander_runtime.hpp"), "salamander_runtime.hpp");
    _ = files.addCopyFile(core_h, "salamander_core.hpp");
    return files.getDirectory();
}

fn cppHeadersWith(b: *std.Build, gen: *std.Build.Step.Compile, base: std.Build.LazyPath, options: CppHeaderOptions) std.Build.LazyPath {
    const run = b.addRunArtifact(gen);
    run.addArg("cpp");
    const header = run.addOutputFileArg(options.name);
    if (options.folder) |f| {
        run.addDirectoryArg(f);
        trackSal(run, f);
    } else run.addFileArg(options.source orelse @panic("cppHeaders needs a source or a folder"));
    run.addArgs(&.{ "--pointer-size", b.fmt("{d}", .{options.target.result.ptrBitWidth() / 8}) });
    if (options.home.len > 0) run.addArgs(&.{ "--namespace", options.home });
    for (options.uses) |u| run.addArgs(&.{ "--use", u });
    for (options.global_uses) |u| run.addArgs(&.{ "--global-use", u });
    if (options.namespace.len > 0) run.addArgs(&.{ "--default-namespace", options.namespace });
    for (options.file_namespaces) |f| run.addArgs(&.{ "--file-namespace", f });
    for (options.instances) |i| run.addArgs(&.{ "--instance", i });
    for (options.with) |w| {
        run.addArgs(&.{ "--with", w.name });
        run.addDirectoryArg(w.folder);
        trackSal(run, w.folder);
    }
    for (options.aliases) |a| run.addArgs(&.{ "--alias", b.fmt("{s}={s}", .{ a.prefix, a.include }) });
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
    /// Namespaces every file uses the types of by their short names, like `&.{"Wraith"}`.
    global_uses: []const []const u8 = &.{},
    /// Where files that don't say a namespace go, like a plugin's own. Empty is the top.
    namespace: []const u8 = "",
    /// Files whose names start with a prefix go in its namespace instead, like `freecam/=Freecam`.
    file_namespaces: []const []const u8 = &.{},
    /// Other folders of `.sal` files in the same schema, each named, like a dependency's.
    with: []const With = &.{},
    /// Tags that make a struct a global, like `wraith.Instance=Sig`. See the parser's `InstanceTag`.
    instances: []const []const u8 = &.{},
    /// What files starting with `prefix` declare comes from `module` instead, imported as `name`.
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

/// Each `.sal` is an input too, since a directory argument doesn't rerun when its contents change.
/// The build script lists the folder, so it reruns when a file's added or removed.
fn trackSal(run: *std.Build.Step.Run, folder: std.Build.LazyPath) void {
    if (folder == .cwd_relative) return trackSalAt(run, folder.cwd_relative);
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

fn trackSalAt(run: *std.Build.Step.Run, path: []const u8) void {
    const b = run.step.owner;
    b.dependOnDirectoryMetadata(.{ .cwd_relative = path });
    const io = b.graph.io;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch return;
    defer walker.deinit(io);
    while (walker.next(io) catch return) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".sal")) continue;
        run.addFileInput(.{ .cwd_relative = b.pathJoin(&.{ path, entry.path }) });
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
    for (options.global_uses) |u| run.addArgs(&.{ "--global-use", u });
    if (options.namespace.len > 0) run.addArgs(&.{ "--default-namespace", options.namespace });
    for (options.file_namespaces) |f| run.addArgs(&.{ "--file-namespace", f });
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
        self.addTestsWith(name, mod, null);
    }

    fn addTestsWith(self: Context, comptime name: []const u8, mod: *std.Build.Module, runner: ?std.Build.Step.Compile.TestRunner) void {
        const tests = self.b.addTest(.{ .name = "salamander_" ++ name ++ "_tests", .root_module = mod, .filters = self.test_filters, .test_runner = runner });
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
