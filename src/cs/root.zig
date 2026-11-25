//! C# for `.sal` files, over `Salamander.cs`.

const writer = @import("write.zig");
pub const write = writer.write;
pub const Options = writer.Options;
pub const Error = writer.Error;

/// The hand-written base every generated file uses.
pub const base_file = @embedFile("Salamander.cs");

test {
    _ = writer;
}
