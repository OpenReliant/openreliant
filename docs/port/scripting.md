# Scripting

OpenReliant runs scripts from mods, written in [Luau](https://luau.org). The design follows OpenMW's
Lua scripting and is described in full in
[#498](https://github.com/OpenReliant/openreliant/issues/498). This version supports load scripts,
which change the game's records (stats and text) at startup. The [modding
guide](../guide/modding.md#scripts) explains how to write them; this page explains how they run.

**Improvement:** the original has no scripting apart from its mission scripts.

## Luau

`deps/luau` builds Luau 0.740 from source as a static library. It includes the VM and the
compiler, using the source files listed in Luau's `Sources.cmake` for `Luau.Common`, `Luau.Ast`,
`Luau.Bytecode`, `Luau.Compiler` and `Luau.VM`. The build matches Luau's `LUAU_EXTERN_C` option: the
C API is `extern "C"`, and Luau errors use `longjmp` instead of C++ exceptions, because exceptions
can't unwind through Zig code. Luau is always built optimized, like FreeType.

Because errors use `longjmp`, a Zig function called from Luau must free anything it allocated before
it calls something that can raise an error. Zig `defer`s don't run when a `longjmp` skips the frame.

The scripting code is a separate module, [`src/scripting.zig`](../../src/scripting.zig), linked into
the game only. sltool and the other tools don't link Luau.
[`luau.zig`](../../src/scripting/luau.zig) wraps the C API.

## The Luau state

[`runtime.zig`](../../src/scripting/runtime.zig) sets up a Luau state for scripts. There are two
kinds of state:

| State | Scripts | Differences |
|---|---|---|
| Game | Load, global and object scripts, which affect what happens in the game | No `os` library. `math.random` uses a seeded generator so that every machine gets the same numbers, and `math.randomseed` is removed. |
| Presentation | Player and menu scripts, which affect what the player sees and hears | Luau's standard libraries |

Load scripts run in their own game state, which is created at startup and closed once they finish.
If no mod has a load script, no state is created.

### Sandbox

The state opens Luau's standard libraries, adds OpenReliant's `require` and `print`, and then calls
`luaL_sandbox`, which makes the globals and libraries read-only. Luau's sandbox has no `io`,
`package`, `dofile`, `loadfile` or `string.dump`, and doesn't load precompiled bytecode. `print`
writes to the log, prefixed with the mod's name.

### Loading a mod's scripts

When a mod is opened (`Runtime.open`), every `.luau` file in it is compiled and loaded with its own
global table (`luaL_sandboxthread`), so scripts can't see each other's globals. If a script fails to
compile, the error is logged when the mod is opened, and again if another script requires it. Each
mod's calls run on a dedicated thread that records which mod is running, so `require` knows where to
look. Coroutines created by a script inherit this.

`require(name)` runs a script from the same mod once and returns its result, or `true` if it returns
nothing. Requiring it again returns the same value. The name is the file name, with or without the
`.luau` extension, in any case. Circular requires are an error. Names starting with `openreliant.`
load a package ([`script.Package`](../../src/scripting/script.zig)). Requiring a package that isn't
available to that kind of script, or isn't implemented yet, raises an error saying which.

### Limits

| Limit | Load scripts | How it works |
|---|---|---|
| Time | 1 second per call | Luau's interrupt callback checks the clock every 64 safe points and raises an error when the limit is passed |
| Memory | 64 MiB per mod | Each mod's allocations are counted in their own memory category (`lua_setmemcat`), and the allocator refuses any allocation that would take the mod over its limit |

After any failed call, the error is logged and a full garbage collection runs, so a script that hit
the memory limit doesn't leave its garbage to block the next one. Mods past the 255th share the last
memory category.

## Binding

[`bind.zig`](../../src/scripting/bind.zig) exposes Zig values to scripts by reflecting over their
declarations at compile time:

- Numbers are numbers, `bool` is a boolean, and enums are their tag names. An open enum value
  without a name is shown as its number.
- Byte arrays are strings, such as a record's name.
- Structs and other arrays are proxies: userdata that read and write the value in place. Struct
  fields use their Zig names, except fields starting with an underscore, which are hidden (they hold
  unknown or unused data). Array elements are indexed from 1, as usual in Lua.
- Writes are checked: a number for a number field, a finite number for floats, an integer in range
  for integer fields, a tag name or valid number for enums. Unknown field names are errors, so typos
  are reported instead of ignored.
- Two proxies of the same value compare equal, and a proxy can be iterated over its fields or
  elements in order.

Field names are part of the scripting API, so a test in `records.zig` fixes every name the records
expose. Renaming a field breaks the mods that use it.

## Records

[`records.zig`](../../src/scripting/records.zig) holds copies of the stat tables
([Stat tables](../formats/stats.md)) and of the strings in `language.dll` and the ITAC's
`itaclang.dll`. After the load scripts run, the game reads its stats and text from these copies.
Each table exposes as many records as the game reads from its file. Before each load script and each
`on_records_loaded` handler, the records are saved, and they are restored if it fails, so a failed
script leaves no changes behind.

Text is stored in the game's code page (Windows-1252) and converted to UTF-8 for scripts. Text from
a script is converted back, with characters the code page doesn't have replaced by `?`.

## Load scripts

[`load.zig`](../../src/scripting/load.zig) runs the load scripts at startup, before the window
opens. Mods run in load order, and each mod's scripts in the order its manifest lists them. After
all of them, each script's `on_records_loaded` handler runs, in the same order. The table a script
returns is checked: a load script may only return `engine_handlers`, and the only engine handler it
may give is `on_records_loaded`. Scripts of other kinds, which this version doesn't run yet, and
unknown kinds are reported in the log.

## Script definitions

[`script.zig`](../../src/scripting/script.zig) defines the complete scripting API from #498, so
scripts written now keep working as later versions fill it in:

- The script kinds that `[Scripts]` accepts: `Load`, `Global`, `Player`, `Menu`, each object class
  (`create.ShipCombat.Class`), `Missile`, `Turret`, and an object type as `Type.` followed by its
  name or number. The build fails if an object class has no matching kind.
- The script families, which decide what a script may do: load, global, object, player and menu.
- The keys of the table a script returns: `engine_handlers`, `event_handlers`, `interface_name` and
  `interface`.
- The engine handlers, and which families may use each one.
- The packages, which families may require each one, and which are implemented in this version.
