# Scripting

OpenReliant runs scripts from mods, written in [Luau](https://luau.org). The design follows OpenMW's
Lua scripting and is described in full in
[#498](https://github.com/OpenReliant/openreliant/issues/498). This version supports load scripts,
which change the game's records (stats and text) at startup, and global scripts, which hook the
game's functions and events as it plays. The [scripting guide](../guide/scripting.md) explains how
to write them; this page explains how they run.

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
Global scripts run in another, which lasts for a game ([Global scripts](#global-scripts)). If no
mod has a script of the kind, no state is created for it.

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

| Limit | Load scripts | Global scripts | How it works |
|---|---|---|---|
| Time | 1 second per call | 100 milliseconds per call | Luau's interrupt callback checks the clock every 64 safe points and raises an error when the limit is passed |
| Memory | 64 MiB per mod | 64 MiB per mod | Each mod's allocations are counted in their own memory category (`lua_setmemcat`), and the allocator refuses any allocation that would take the mod over its limit |

After any failed call, the error is logged and a full garbage collection runs, so a script that hit
the memory limit doesn't leave its garbage to block the next one. Mods past the 255th share the last
memory category.

A call can run inside another: a hook's handler can run the game's function (`e:original()`), whose
own hooks call other handlers. Each call starts its own time limit and counts its allocations
against its own mod, and the call it interrupted gets its limit and its mod back when it returns
(`Runtime.begin`).

`Runtime.call` only pushes arguments that take no memory: references, numbers and booleans. What
does take memory, such as `e` or the table `on_mission_start` gets, is made beforehand in protected
mode (`Runtime.make`), where running out of memory is an error the engine handles, rather than one
Luau can't recover from. These count against no mod.

## Binding

[`bind.zig`](../../src/scripting/bind.zig) exposes Zig values to scripts by reflecting over their
declarations at compile time:

- Numbers are numbers, `bool` is a boolean, and enums are their tag names. An enum value without a
  name, or whose tag starts with an underscore (one not understood yet), is shown as its number
  ([`values.zig`](../../src/scripting/values.zig) converts every value of this kind).
- Byte arrays are strings, such as a record's name.
- Structs and other arrays are proxies: userdata that read and write the value in place. Struct
  fields use their Zig names, except fields starting with an underscore, which are hidden (they hold
  unknown or unused data). Array elements are indexed from 1, as usual in Lua.
- Writes are checked: a number for a number field, a finite number for floats, an integer in range
  for integer fields, a tag name or valid number for enums. Unknown field names are errors, so typos
  are reported instead of ignored.
- Two proxies of the same value compare equal, and a proxy can be iterated over its fields or
  elements in order.

Field names are part of the scripting API, so the definitions file pins every name the records
expose ([The reference](#the-reference)). Renaming a field breaks the mods that use it.

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
- The packages, which families may require each one, and which are implemented in this version:
  `core`, `records` and `hooks`. `Kind.runs` says which kinds of script run: load and global.

## Global scripts

[`game.zig`](../../src/scripting/game.zig) runs the scripts that decide what happens in the game,
while a game runs. The driver starts them as the front end starts a campaign, loads a saved game or
flies a mission on its own, or as `--mission` starts one, and stops them as the front end's main
menu comes back, or the game quits. Each game gets a new Luau state.

- A mod's `Global` scripts start with the game, in load order, each mod's in the order its manifest
  lists them. Each runs as `require` runs it, its returned table is checked as a load script's is,
  and its `on_init` is called.
- `[Missions]` matches a mission's file name (`winmain.missionFileName`) to its keys, in any case.
  As the mission begins, each mod with scripts for it is opened again (`Runtime.open`), so that
  every attempt starts them afresh, and the scripts start as the global ones do. As the mission
  ends, their handlers are removed and the mod is closed (`Runtime.close`).
- An engine handler that fails is logged and not called again.

The engine calls the game side through `engine.hooks.Scripts`, which `create.Objects.scripts` holds
while a game runs, null otherwise:

| Call | Where | Handlers |
|---|---|---|
| `begin` | `main.startMission`, before the script's start part makes the mission's ships | The mission's scripts start, and `math.random` starts again |
| `started` | The end of `main.startMission` | `on_mission_start`, then the hook `mission_started` |
| `update` | `main.missionFrame`, after the orders (`aigeneric.ordersUpdate`), in a frame whose `frame_duration` isn't 0 | `on_update`, with `frame_duration` in seconds |
| `step` | The end of `gameobj.simulationStep` | `on_step` |
| `ended` | `main.endMission`, as the driver lets a mission go | `on_mission_end`, then the hook `mission_ended`; the mission's scripts stop |
| `call` | The hooks ([Hooks](#hooks)) | `on_object_added` and `on_object_removed`, then the hooks' handlers |

`math.random` starts again from a seed made of the C runtime's `rand` seed as the mission begins
(`libcmt.Rand`, which it doesn't draw from) and the mission's number, so the game's own numbers stay
as they are and every machine draws the same. Before the first mission it starts from load
scripts' fixed seed. The original seeds `rand` with the time as each mission starts, which
OpenReliant doesn't port yet ([#582](https://github.com/OpenReliant/openreliant/issues/582)).

## Hooks

[`engine/hooks.zig`](../../src/engine/hooks.zig) declares what scripts can hook, and the engine
calls the hooks where they happen. [`scripting/hooks.zig`](../../src/scripting/hooks.zig) runs the
handlers mods add. [Hooks](../guide/hooks.md) lists every hook.

### Declarations

`Hook` is an enum built at compile time from these lists:

- **Functions** (`functions`): each declared with its address, its fields (`Fields`), its result,
  the field that holds the object it concerns (`subject`, which filters test) and a sentence for the
  reference. A test in `ghidragen` checks each name against `ghidra/names/LANCER.EXE.tsv`.
- **The order table's routines** (`routine_hooks`), named as `ghidragen` names them
  (`ai.routines`): `order_` and the order's name, with `_init` or `_exit`, or the names table's own
  name where it has one (`player_controls`, `order_first_step_init`). Their fields are
  `RoutineFields`.
- **Events**: the mission's (`mission_events`), which must each be a `dte.Condition`, and the
  engine's (`engine_events`).

A function's fields are its parameters after the first, the world or the orders' context, in order,
with a slot as an `Object`. A field whose name starts with `_` passes its parameter through without
scripts seeing it. The build checks that the fields follow the function's parameters and that the
result is the function's. So OpenReliant's code can change around a hook, but what scripts see of
it only changes where its declaration does.

### Calling them

A hooked function starts with one line:

```zig
if (hooks.enter(.object_damage, damage, .{ world, index, struck, value, factor, attacker, kind })) |done| return done;
```

`enter` returns null at once without scripts, or while no handler hooks the function
(`Scripts.hooked`). Otherwise it copies the arguments into the fields and calls the handlers through
`Scripts`. To run the function itself, as the handlers have it (`Call.original`), the arguments are
read back from the fields, and the function is called again with `Scripts.passing` set to the hook,
which the first line takes as the sign to run the body. The order routines are hooked where
`aigeneric` runs them (`runInit`, `runUpdate`, `runExit`, through `enterRoutine`), which finds the
routine's hook from the order. Events are told with `hooks.tell`, where the engine posts them:
the mission's in `mission/events.zig`, as each posting routine takes them, `object_added` in
`create_object`, `object_removed` in `object_reset` and `create.retire`, `order_started` and
`order_ended` where an order's `init` and `exit` run, and `trigger_fired` in `vm.triggers.match`.

### Running the handlers

Each hook's handlers are kept in the order they run: newest mod first, then in the order added. A
run of a hook (`Dispatch`):

1. Calls the handlers added with `hooks.add`, each that its filter lets through, until one returns
   `false`. A filter's object, types, classes and sides are tested in Zig before calling into Luau.
2. Runs the function, unless a handler stopped it or already ran it. `e:original()` continues the
   same run from the next handler, then runs the function, and returns its result.
3. Calls the handlers added with `hooks.after`, with the result in `e.result`, until one returns
   `false`.

`e` is userdata that points to the run, made for the first handler that runs. Its fields are read
and written through each hook's `Access`, which is generated at compile time, and values are
checked as they're written (`values.zig`). Once the run is over, `e` no longer points anywhere, so a
script that kept it gets an error. Before each handler, the fields and the result are saved; if it
fails, they're put back, unless the function ran inside it, and the handler is removed.

While any hook runs, handlers that are added wait, and removed ones are only marked, so that no
list changes under a run. Once the outermost run ends, the lists are brought up to date, and so is
`Scripts.hooked`.

## Object handles

[`objects.zig`](../../src/scripting/objects.zig) gives scripts objects as handles: a slot, and the
slot's count of reuses when the handle was made (`create.Objects.reuses`). The count goes up as
`create_object` fills a slot, as `object_reset` and `create.retire` remove its object, and for
every slot as a mission starts. A handle is valid while its count matches. The state keeps one
handle per slot in a table with weak values, so the same object always gives the same handle while
a script holds it.

## The reference

[`reference.zig`](../../src/scripting/reference.zig) generates, from the declarations above, the
definitions file for luau-lsp ([`openreliant.d.luau`](../guide/openreliant.d.luau)), the reference
page [Hooks](../guide/hooks.md), and what `openreliant hooks` prints. The first two are committed,
and tests check that they match what the code generates. Everything scripts see is in them: the
hooks and their fields, the names of enum values, and the fields of objects and records. So a change
that would change the scripting API fails the tests, and the API only changes on purpose; `make
definitions` then writes both files again. Each enum scripts see needs a name in the definitions
(`reference.enum_names`), which the build asks for.
