//! Every language salamander hosts, behind one engine interface. Pick one by name or extension.

const script = @import("salamander_script");
const js = @import("salamander_js");
const lua = @import("salamander_lua");

pub const engine = script.engine;
pub const Script = engine.Script;
pub const Language = engine.Language;
pub const Options = engine.Options;
pub const Export = engine.Export;
pub const Resolver = engine.Resolver;
pub const Report = engine.Report;
pub const relative = engine.relative;

pub fn create(language: Language, options: Options) !Script {
    return switch (language) {
        .js => js.create(options),
        .lua => lua.create(options),
    };
}

test {
    _ = @import("tests.zig");
}
