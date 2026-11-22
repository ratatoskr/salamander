//! Zig for `.sal` files. `write` makes a `.zig` file with the types and methods, laid out by `plan`.
//! Projects get it through `zigModule` in the build helper.

pub const plan = @import("salamander_schema").plan;

const writer = @import("write.zig");
pub const write = writer.write;
pub const WriteOptions = writer.Options;
pub const Alias = writer.Alias;
pub const WriteError = writer.Error;

test {
    _ = writer;
}
