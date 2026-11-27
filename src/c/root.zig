//! C headers for `.sal` files, over `salamander.h`.

const std = @import("std");
const salamander_schema = @import("salamander_schema");
const writer = @import("write.zig");
pub const write = writer.write;
pub const Options = writer.Options;
pub const Alias = writer.Alias;
pub const Error = writer.Error;
pub const core_prefix = writer.core_prefix;

/// The hand-written base every generated header includes.
pub const base_header = @embedFile("salamander.h");

/// The runtime's own traits, which every generated header uses.
pub const core_sal = @embedFile("core.sal");

/// `core_sal` as C, `salamander_core.h`, for `pointer_size`.
pub fn writeCore(gpa: std.mem.Allocator, w: *std.Io.Writer, pointer_size: u8) (Error || salamander_schema.SignatureError)!void {
    var parsed = try salamander_schema.parse(gpa, core_sal, .{ .pointer_size = pointer_size }, null);
    defer parsed.deinit();
    try write(gpa, parsed.schema, w, .{ .label = "core.sal", .prefix = core_prefix, .core = true }, null);
}

test {
    _ = writer;
}
