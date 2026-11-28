# Salamander

[![CI](https://img.shields.io/github/actions/workflow/status/ratatoskr/salamander/main_ci.yml?branch=main&label=CI)](https://github.com/ratatoskr/salamander/actions/workflows/main_ci.yml)
[![License](https://img.shields.io/github/license/ratatoskr/salamander)](https://github.com/ratatoskr/salamander/blob/main/LICENSE)
[![Zig](https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fraw.githubusercontent.com%2Fratatoskr%2Fsalamander%2Fmain%2Fbuild.zig.zon&search=minimum_zig_version%5Cs%2A%3D%5Cs%2A%22%28%5B%5E%22%2B%5D%2B%29&replace=%241&label=zig&color=f7a41d&logo=zig&logoColor=white)](https://github.com/ratatoskr/salamander/blob/main/build.zig.zon)

Typed interfaces between Zig, C, C++, Rust, C#, JavaScript and Lua. Write your API once in a `.sal` schema, and plugins, scripts and native code all call each other through it.

Pre-release. Expect breaking changes.

## Features

- Schemas with structs, unions, tagged unions, enums, bitfields, errors, generics, namespaces, and traits with plain, async and failing methods.
- Generates Zig, C, C++20, Rust and C# (JIT or NativeAOT), each with idiomatic types over a shared ABI.
- JavaScript (QuickJS-ng) and Lua 5.5 scripts call and implement traits, with TypeScript and LuaLS typings.
- Trait objects that cross DLLs and languages, checked by hash, and stop when their owner goes.
- The same JSON of values in every language, and `any` parameters that carry a value's type.
- Describes existing code too, like a game's structs, vtables and functions, with calls and detours for signatures known only at runtime.
- Hosts .NET 10+ through hostfxr.
- JSON of a whole schema for docs and tools, and in-place `.sal` editing.
- Windows and Linux on x64, x86 and ARM64, and macOS.

## Example

A trait in a `.sal` schema:

```
// greeter.sal
trait Greeter {
    string greet(string who);
    u32 count();
}
```

Turn it into a Zig module in `build.zig`:

```zig
const greeter = salamander.zigModule(dep, .{ .source = b.path("greeter.sal"), .target = target });
exe.root_module.addImport("greeter", greeter);
```

Implement it in Zig, and hand it to a script as the module `app`:

```zig
const rt = @import("salamander_runtime");
const hosts = @import("salamander_hosts");
const Greeter = @import("greeter").Greeter;

const Hello = struct {
    greeted: u32 = 0,
    buf: [64]u8 = undefined,

    pub fn greet(self: *Hello, who: []const u8) []const u8 {
        self.greeted += 1;
        return std.fmt.bufPrint(&self.buf, "hello {s}", .{who}) catch "hello";
    }

    pub fn count(self: *Hello) u32 {
        return self.greeted;
    }
};

var hello: Hello = .{};
const obj: rt.Object(Greeter) = .init(&hello, rt.implement(Greeter, Hello));

const script = try hosts.create(.js, .{ .gpa = gpa });
defer script.deinit();
const types = try script.schema(@embedFile("greeter.sal"));
try script.module("app", &.{.{ .name = "greeter", .schema = types, .trait = "Greeter", .obj = .of(obj) }});
try script.run(source, "main.js");
```

Then the script calls it, typed by the same schema:

```js
import { greeter } from "app";
globalThis.greeting = `${greeter.greet("js")}, ${greeter.count()} so far`;
```

```lua
local app = require("app")
greeting = app.greeter:greet("lua") .. ", " .. app.greeter:count() .. " so far"
```

Scripts can implement traits too, and Zig takes them with `script.take`.

## JSON

Every language writes a value's JSON the same way:
- Structs and bitfields are objects, and enums are their names.
- Tagged unions are `{"member": value}`, or just `"member"` when it holds nothing.
- `blob` is base64.
- 64-bit integers past ±2^53 are strings, and NaN and infinities are `"NaN"`, `"Infinity"` and `"-Infinity"`.

Untagged unions, pointers and objects have no JSON. Reading ignores unknown fields and keeps defaults for missing ones. Zig has `rt.json`; other languages use the host's `toJson` and `fromJson`.

## Tagged unions

```
enum ShapeKind : u8 { circle, box, none }

union Shape : ShapeKind {
    f32 circle;
    Vec3 box;
    void none;
}
```

Each enum value needs a member, with `void` for one that holds nothing. On the wire it's `tag`, then a `payload` union. Zig gets a `union(enum)`, and scripts see `{ circle: 2 }`.

## Any

```
trait Saves {
    void save(string path, any value);
}
```

An `any` is a value borrowed for the call, with its `TypeInfo` from `core.sal`: its fields, layout and a hash. Every language makes one from a generated type, and gets the value back only if the hash matches. For example, Zig has `rt.Any.from` and `any.lift`, C++ has `sal::Any::of` and `any.as<T>()`, and scripts use `any("Vec3", v)`.

## Building

You need the Zig version in `build.zig.zon` under `minimum_zig_version`. Then:

```
zig build test
```

Pass `-Dtarget=` for another platform, like `x86_64-linux-musl`.

Want to help? See [CONTRIBUTING.md](https://github.com/ratatoskr/.github/blob/main/CONTRIBUTING.md). Found a security problem? See [SECURITY.md](https://github.com/ratatoskr/.github/blob/main/SECURITY.md).

## License

Copyright (c) 2026 Asgard. Salamander is under the MIT License, see [LICENSE](LICENSE).

Third-party notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
