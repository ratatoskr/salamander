//! C# for `.sal` files, over `Salamander.cs`.

const std = @import("std");
const salamander_schema = @import("salamander_schema");
const writer = @import("write.zig");
pub const write = writer.write;
pub const Options = writer.Options;
pub const Alias = writer.Alias;
pub const Error = writer.Error;

/// The hand-written base every generated file uses.
pub const base_file = @embedFile("Salamander.cs");

/// The runtime's own traits, which `base_file` and every generated file use.
pub const core_sal = @embedFile("core.sal");

/// `core_sal` as C#, `SalamanderCore.cs`, for `pointer_size`.
pub fn writeCore(gpa: std.mem.Allocator, w: *std.Io.Writer, pointer_size: u8) (Error || salamander_schema.SignatureError)!void {
    var parsed = try salamander_schema.parse(gpa, core_sal, .{ .pointer_size = pointer_size }, null);
    defer parsed.deinit();
    try write(gpa, parsed.schema, w, .{ .label = "core.sal", .core = true }, null);
}

test {
    _ = writer;
}

test "the core writes" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeCore(std.testing.allocator, &out.writer, 8);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "namespace Salamander.Raw") != null);
}
