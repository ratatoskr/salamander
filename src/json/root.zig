//! A schema as JSON, for docs and tools that don't parse `.sal`.

const writer = @import("write.zig");
pub const write = writer.write;
pub const Options = writer.Options;
pub const Error = writer.Error;
pub const format_version = writer.format_version;

test {
    _ = writer;
}
