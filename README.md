# Salamander

[![CI](https://img.shields.io/github/actions/workflow/status/ratatoskr/salamander/main_ci.yml?branch=main&label=CI)](https://github.com/ratatoskr/salamander/actions/workflows/main_ci.yml)
[![License](https://img.shields.io/github/license/ratatoskr/salamander)](https://github.com/ratatoskr/salamander/blob/main/LICENSE)
[![Zig](https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fraw.githubusercontent.com%2Fratatoskr%2Fsalamander%2Fmain%2Fbuild.zig.zon&search=minimum_zig_version%5Cs%2A%3D%5Cs%2A%22%28%5B%5E%22%2B%5D%2B%29&replace=%241&label=zig&color=f7a41d&logo=zig&logoColor=white)](https://github.com/ratatoskr/salamander/blob/main/build.zig.zon)

Typed interfaces between Zig, C, JavaScript and Lua. Write your API once in a `.sal` schema, and plugins, scripts and native code all call each other through it. C++, Rust and C# are being considered next.

Pre-release. Expect breaking changes.

## Features

- `.sal` schemas: structs, enums, bitfields, errors, and traits with plain, async and failing methods.
- Generates Zig, with plain types and their wire forms, and C headers.
- TypeScript and LuaLS typings for scripts' editors.
- Trait objects that cross DLLs, checked by hash, and stop when their owner goes.
- JavaScript (QuickJS-ng) and Lua 5.5 scripts call traits and implement them.
- Calls and detours for signatures only known at runtime.
- Describes code that already exists too, like a game's structs, vtables and functions.
- Edits `.sal` text in place, for editors and tools.
- Windows and Linux on x64, x86 and ARM64, and macOS.

## Building

You need the Zig version in `build.zig.zon` under `minimum_zig_version`. Then:

```
zig build test
```

`zig build build-test` builds the test programs into `zig-out/bin` without running them. Pass `-Dtarget=` to build for another platform, like `x86_64-linux-musl`.

`src/runtime/core.zig` is generated from `core.sal`. After changing it, run `zig build core`.

Want to help? See [CONTRIBUTING.md](https://github.com/ratatoskr/.github/blob/main/CONTRIBUTING.md). Found a security problem? See [SECURITY.md](https://github.com/ratatoskr/.github/blob/main/SECURITY.md).

## License

Copyright (c) 2026 Asgard. Salamander is under the MIT License, see [LICENSE](LICENSE).

Third-party notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
