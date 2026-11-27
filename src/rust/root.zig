//! Rust modules for `.sal` files, over the `salamander` crate in this folder.

const writer = @import("write.zig");
pub const write = writer.write;
pub const Options = writer.Options;
pub const Alias = writer.Alias;
pub const Error = writer.Error;

test {
    _ = writer;
}
