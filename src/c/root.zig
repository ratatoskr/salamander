//! C headers for `.sal` files, over `salamander.h`.

const writer = @import("write.zig");
pub const write = writer.write;
pub const Options = writer.Options;
pub const Error = writer.Error;
pub const core_prefix = writer.core_prefix;

/// The hand-written base every generated header includes.
pub const base_header = @embedFile("salamander.h");

test {
    _ = writer;
}
