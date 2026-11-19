//! Bytes kept by a count, `core.Blob`. The host makes them so any binary or language can hold one.
//! Each holder releases its count. Schemas call it `blob`.

const std = @import("std");

const rt = @import("root.zig");
const core = rt.core;

pub const Blob = core.Blob;

/// `size` bytes, zeroed, with one count for the caller.
pub fn make(size: usize) error{OutOfMemory}!Blob {
    const b = rt.host().raw().blob(size);
    if (b.table == null) return error.OutOfMemory;
    return b;
}

/// A copy of `bytes`, with one count for the caller.
pub fn copy(bytes: []const u8) error{OutOfMemory}!Blob {
    const b = try make(bytes.len);
    @memcpy(mutable(b)[0..bytes.len], bytes);
    return b;
}

/// For filling one before it's handed out.
pub fn mutable(b: Blob) []u8 {
    return @constCast(b.bytes());
}

/// The host's blobs, a count then the bytes.
const Header = struct {
    refs: std.atomic.Value(u32) = .init(1),
    len: usize,

    const bytes_offset = std.mem.alignForward(usize, @sizeOf(Header), 16);
    const allocator = std.heap.smp_allocator;

    fn whole(h: *Header) []align(16) u8 {
        const base: [*]align(16) u8 = @ptrCast(@alignCast(h));
        return base[0 .. bytes_offset + h.len];
    }

    pub fn bytes(h: *Header) []const u8 {
        return h.whole()[bytes_offset..];
    }

    pub fn retain(h: *Header) void {
        _ = h.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(h: *Header) void {
        if (h.refs.fetchSub(1, .acq_rel) != 1) return;
        allocator.free(h.whole());
    }
};

const table = rt.implement(Blob, Header);

/// The host's side. No table out of memory.
pub fn hostMake(size: usize) Blob {
    const mem = Header.allocator.alignedAlloc(u8, .@"16", Header.bytes_offset + size) catch return .{};
    @memset(mem, 0);
    const h: *Header = @ptrCast(mem.ptr);
    h.* = .{ .len = size };
    return .{ .data = @intFromPtr(h), .table = table };
}

test "counted, and gone with the last" {
    const b = try copy("hello");
    try std.testing.expectEqualStrings("hello", b.bytes());
    b.retain();
    b.release();
    try std.testing.expectEqualStrings("hello", b.bytes());
    b.release();
    const empty = try make(0);
    try std.testing.expectEqual(0, empty.bytes().len);
    empty.release();
}
