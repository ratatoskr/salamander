//! A C ABI function with any number of parameters whose body takes them as a tuple.
//! Zig can't make a function body for a reified type, so there's one shape per arity.

const std = @import("std");

pub const max = 16;

pub fn Raw(comptime P: []const type, comptime R: type, comptime cc: std.lang.CallingConvention) type {
    return @Fn(P, &@as([P.len]std.lang.Type.Fn.ParamAttributes, @splat(.{})), R, .{ .@"callconv" = cc });
}

/// `body` takes `@Tuple(P)` and returns `R`.
pub fn make(comptime P: []const type, comptime R: type, comptime cc: std.lang.CallingConvention, comptime body: anytype) *const Raw(P, R, cc) {
    return switch (P.len) {
        0 => &struct {
            fn f() callconv(cc) R {
                return body(.{});
            }
        }.f,
        1 => &struct {
            fn f(a0: P[0]) callconv(cc) R {
                return body(.{a0});
            }
        }.f,
        2 => &struct {
            fn f(a0: P[0], a1: P[1]) callconv(cc) R {
                return body(.{ a0, a1 });
            }
        }.f,
        3 => &struct {
            fn f(a0: P[0], a1: P[1], a2: P[2]) callconv(cc) R {
                return body(.{ a0, a1, a2 });
            }
        }.f,
        4 => &struct {
            fn f(a0: P[0], a1: P[1], a2: P[2], a3: P[3]) callconv(cc) R {
                return body(.{ a0, a1, a2, a3 });
            }
        }.f,
        5 => &struct {
            fn f(a0: P[0], a1: P[1], a2: P[2], a3: P[3], a4: P[4]) callconv(cc) R {
                return body(.{ a0, a1, a2, a3, a4 });
            }
        }.f,
        6 => &struct {
            fn f(a0: P[0], a1: P[1], a2: P[2], a3: P[3], a4: P[4], a5: P[5]) callconv(cc) R {
                return body(.{ a0, a1, a2, a3, a4, a5 });
            }
        }.f,
        7 => &struct {
            fn f(a0: P[0], a1: P[1], a2: P[2], a3: P[3], a4: P[4], a5: P[5], a6: P[6]) callconv(cc) R {
                return body(.{ a0, a1, a2, a3, a4, a5, a6 });
            }
        }.f,
        8 => &struct {
            fn f(a0: P[0], a1: P[1], a2: P[2], a3: P[3], a4: P[4], a5: P[5], a6: P[6], a7: P[7]) callconv(cc) R {
                return body(.{ a0, a1, a2, a3, a4, a5, a6, a7 });
            }
        }.f,
        9 => &struct {
            fn f(a0: P[0], a1: P[1], a2: P[2], a3: P[3], a4: P[4], a5: P[5], a6: P[6], a7: P[7], a8: P[8]) callconv(cc) R {
                return body(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8 });
            }
        }.f,
        10 => &struct {
            fn f(a0: P[0], a1: P[1], a2: P[2], a3: P[3], a4: P[4], a5: P[5], a6: P[6], a7: P[7], a8: P[8], a9: P[9]) callconv(cc) R {
                return body(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9 });
            }
        }.f,
        11 => &struct {
            fn f(a0: P[0], a1: P[1], a2: P[2], a3: P[3], a4: P[4], a5: P[5], a6: P[6], a7: P[7], a8: P[8], a9: P[9], a10: P[10]) callconv(cc) R {
                return body(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10 });
            }
        }.f,
        12 => &struct {
            fn f(a0: P[0], a1: P[1], a2: P[2], a3: P[3], a4: P[4], a5: P[5], a6: P[6], a7: P[7], a8: P[8], a9: P[9], a10: P[10], a11: P[11]) callconv(cc) R {
                return body(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11 });
            }
        }.f,
        13 => &struct {
            fn f(a0: P[0], a1: P[1], a2: P[2], a3: P[3], a4: P[4], a5: P[5], a6: P[6], a7: P[7], a8: P[8], a9: P[9], a10: P[10], a11: P[11], a12: P[12]) callconv(cc) R {
                return body(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12 });
            }
        }.f,
        14 => &struct {
            fn f(a0: P[0], a1: P[1], a2: P[2], a3: P[3], a4: P[4], a5: P[5], a6: P[6], a7: P[7], a8: P[8], a9: P[9], a10: P[10], a11: P[11], a12: P[12], a13: P[13]) callconv(cc) R {
                return body(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13 });
            }
        }.f,
        15 => &struct {
            fn f(a0: P[0], a1: P[1], a2: P[2], a3: P[3], a4: P[4], a5: P[5], a6: P[6], a7: P[7], a8: P[8], a9: P[9], a10: P[10], a11: P[11], a12: P[12], a13: P[13], a14: P[14]) callconv(cc) R {
                return body(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14 });
            }
        }.f,
        16 => &struct {
            fn f(a0: P[0], a1: P[1], a2: P[2], a3: P[3], a4: P[4], a5: P[5], a6: P[6], a7: P[7], a8: P[8], a9: P[9], a10: P[10], a11: P[11], a12: P[12], a13: P[13], a14: P[14], a15: P[15]) callconv(cc) R {
                return body(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 });
            }
        }.f,
        else => @compileError("salamander: a function can have at most 16 parameters"),
    };
}
