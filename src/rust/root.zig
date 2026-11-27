//! Rust modules for `.sal` files, over the `salamander` crate in this folder.

const writer = @import("write.zig");
pub const write = writer.write;
pub const Options = writer.Options;
pub const Alias = writer.Alias;
pub const Error = writer.Error;
pub const Names = writer.Names;
/// Like `set_speed` for `setSpeed`, how namespaces name their modules.
pub const snake = writer.snake;

test {
    _ = writer;
}

/// The `salamander` crate's files by path, for tools that write it out beside what they generate.
pub const crate_files = [_]struct { []const u8, []const u8 }{
    .{ "Cargo.toml", @embedFile("Cargo.toml") },
    .{ "src/lib.rs", @embedFile("src/lib.rs") },
    .{ "src/sal_core.rs", @embedFile("src/sal_core.rs") },
};
