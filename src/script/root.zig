//! What every language host shares. Ties script values to native objects, plus memory helpers and the engine interface.

const core = @import("core.zig");

pub const Core = core.Core;
pub const Gate = core.Gate;
pub const Policy = core.Policy;
pub const Resume = core.Resume;
pub const Module = core.Module;
pub const SpinLock = core.SpinLock;
pub const TraitError = core.TraitError;
pub const errorName = core.errorName;
pub const errorCode = core.errorCode;
pub const singletonName = core.singletonName;
pub const withExplanation = core.withExplanation;
pub const explainThrown = core.explainThrown;
pub const inoutBoxed = core.inoutBoxed;
pub const payload = core.payload;
pub const isResult = core.isResult;
pub const isVoid = core.isVoid;
pub const memory = @import("memory.zig");
pub const views = @import("views.zig");
pub const engine = @import("engine.zig");

test {
    _ = core;
    _ = memory;
    _ = views;
    _ = engine;
    _ = @import("Gate.zig");
}
