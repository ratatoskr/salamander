//! C++ headers for `.sal` files, over `salamander.hpp`.

const writer = @import("write.zig");
pub const write = writer.write;
pub const Options = writer.Options;
pub const Alias = writer.Alias;
pub const Error = writer.Error;

/// The hand-written base every generated header includes.
pub const base_header = @embedFile("salamander.hpp");
/// What plugins use over the core traits, included by generated headers.
pub const runtime_header = @embedFile("salamander_runtime.hpp");

test {
    _ = writer;
}
