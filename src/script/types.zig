//! `core.TypeInfo` for a schema's types, made while scripts run, for `any`. Kept till the binder goes.

const std = @import("std");
const salamander_schema = @import("salamander_schema");
const rt = @import("salamander_runtime");

const Schema = salamander_schema.Schema;
const Ref = Schema.Ref;
const plan = salamander_schema.plan;
const TypeInfo = rt.core.raw.TypeInfo;

pub const Infos = struct {
    arena: std.heap.ArenaAllocator,
    by_hash: std.AutoHashMapUnmanaged(u64, *TypeInfo) = .empty,

    pub fn init(gpa: std.mem.Allocator) Infos {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Infos) void {
        self.arena.deinit();
    }

    /// `r`'s info, made the first time. Names are copied, so they outlive the schema.
    pub fn of(self: *Infos, s: Schema, r: Ref) error{OutOfMemory}!*TypeInfo {
        const a = self.arena.allocator();
        const i = plan.info(s, r);
        const gop = try self.by_hash.getOrPut(a, i.hash);
        if (gop.found_existing) return gop.value_ptr.*;
        const info = try a.create(TypeInfo);
        // In first, so one that reaches itself finds it
        gop.value_ptr.* = info;
        info.* = .{ .kind = std.meta.stringToEnum(rt.core.TypeKind, i.kind).?, .name = .init(try a.dupe(u8, i.name)), .hash = i.hash, .size = i.size, .alignment = i.alignment, .len = i.len };
        if (i.child) |c| info.child = try self.of(s, c);
        var fields: std.ArrayList(rt.core.raw.FieldInfo) = .empty;
        var fit: plan.InfoFields = .init(s, r);
        while (fit.next()) |f| try fields.append(a, .{ .name = .init(try a.dupe(u8, f.name)), .type = try self.of(s, f.type), .offset = f.offset, .bit = f.bit, .bits = f.bits });
        info.fields = .init(fields.items);
        var values: std.ArrayList(rt.core.raw.EnumValue) = .empty;
        var vit: plan.InfoValues = .init(s, r);
        while (vit.next()) |v| try values.append(a, .{ .name = .init(try a.dupe(u8, v.name)), .value = v.value });
        info.values = .init(values.items);
        return info;
    }
};

test "made from a schema, the same as generated Zig's" {
    var diag: Schema.Diagnostic = .{};
    var parsed = try salamander_schema.parse(std.testing.allocator, "struct Node { []Node children; u32 id; utf8[4] tag; Kind kind; } enum Kind : u8 { leaf = 1, branch }", .{ .pointer_size = @sizeOf(usize) }, &diag);
    defer parsed.deinit();
    var infos: Infos = .init(std.testing.allocator);
    defer infos.deinit();
    const node = try infos.of(parsed.schema, .{ .named = "Node" });
    try std.testing.expectEqual(node, try infos.of(parsed.schema, .{ .named = "Node" }));
    try std.testing.expectEqualStrings("Node", node.name.get());
    const fields = node.fields.get();
    try std.testing.expectEqual(4, fields.len);
    // Reaches itself through the slice
    try std.testing.expectEqual(node, fields[0].type.?.child.?);
    try std.testing.expectEqual(rt.core.TypeKind.array, fields[2].type.?.kind);
    try std.testing.expectEqualStrings("branch", fields[3].type.?.values.get()[1].name.get());
}
