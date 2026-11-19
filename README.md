# Salamander

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

## License

Copyright (c) 2026 Asgard. Salamander is under the MIT License, see [LICENSE](LICENSE).

Third-party notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
