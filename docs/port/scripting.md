# Scripting

OpenReliant runs scripts from mods, written in [Luau](https://luau.org). The design follows OpenMW's
Lua scripting and is described in full in
[#498](https://github.com/OpenReliant/openreliant/issues/498). This version supports load scripts,
which change the game's records (stats and text) at startup, global scripts, which hook the game's
functions and events as it plays, object scripts, which run on the mission's objects, and player
and menu scripts, which draw over the flight display and the menus and hear the keys. Scripts send
each other events and offer each other interfaces. The [scripting guide](../guide/scripting.md)
explains how to write them; this page explains how they run.

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
Global and object scripts run in another, which lasts for a game ([The game's
scripts](#the-games-scripts)). Player and menu scripts run in a presentation state, which lasts
from startup until OpenReliant quits ([The presentation side](#the-presentation-side)). If no mod
has a script of the kind, no state is created for it.

### Sandbox

The state opens Luau's standard libraries, adds OpenReliant's `require` and `print`, and then calls
`luaL_sandbox`, which makes the globals and libraries read-only. Luau's sandbox has no `io`,
`package`, `dofile`, `loadfile` or `string.dump`, and doesn't load precompiled bytecode. `print`
writes to the log, prefixed with the mod's name.

### Loading a mod's scripts

The first time a mod is opened (`Runtime.open`), every `.luau` file in it is compiled, and the
bytecode is kept for the rest of the state's life (`Code`), or until the scripts are reloaded
(`Runtime.recompileFolders`, [Reloading](#reloading)). If a script fails to compile, the error
is logged then, and again if a script requires it. Each opening of the mod is a context
(`Context`): one for its global scripts, one for each mission it has scripts for, and one for each
object its object scripts run on. A context loads its own copy of a script as it requires it, with
its own global table (`luaL_sandboxthread`), so scripts can't see each other's globals, and the
scripts on one object can't see another object's. Each context's calls run on a thread of its own
that records the context, so `require` and OpenReliant's functions know which mod, and which
object, is calling. Coroutines created by a script inherit this.

`require(name)` runs a script from the same mod once for its context and returns its result, or
`true` if it returns nothing. Requiring it again returns the same value. The name is the file name,
with or without the `.luau` extension, in any case. Circular requires are an error. Names starting
with `openreliant.` load a package ([`script.Package`](../../src/scripting/script.zig)), and
`openreliant.self` gives the handle of the context's object. Requiring a package that isn't
available to that kind of script, or isn't implemented yet, raises an error saying which.

### Limits

| Limit | Load scripts | Other scripts | How it works |
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
- The engine handlers, which families may use each one, what the engine passes each
  (`Handler.Arguments`), and what it takes from what each returns (`Handler.Result`).
- The packages, which families may require each one, and which are implemented in this version
  (`Package.ready`): all but `postprocessing` and `shaders`.
  `Kind.runs` says which kinds of script run: load, global, and the object kinds but `Missile` and
  `Turret`, whose objects aren't objects in the mission's slots
  ([#587](https://github.com/OpenReliant/openreliant/issues/587)).

## Declarations

What scripts see of a package or a handle is declared once, in Zig, and the bindings and the
reference are made from it at compile time ([`api.zig`](../../src/scripting/api.zig)):

- `Field` declares a field: its type, a sentence for the reference, a getter, and a setter for a
  field scripts can change.
- `Function` declares a function: a sentence and its parameters' names. Its Zig parameters give
  their types: the first is the `Call` (the state and the calling context), and the rest are read
  with `values.read`. Its result is pushed with `values.push`. The build checks that every
  parameter has a name.
- `Native` declares a function that reads what it's passed itself, such as one that takes a
  script's function, with its Luau types written out for the reference.

A struct is a table of its fields ([`values.zig`](../../src/scripting/values.zig)). One a function
returns is read-only; one a script passes must name each field that has no default, and may leave
out the rest. A list (`values.List`), such as the objects `world.objects` gives, is a table of its
values in order. The reference shows a table as one scripts give, with its defaults, where a
declared function takes it.

A package made this way is a namespace of these declarations
([`packages.zig`](../../src/scripting/packages.zig) says which namespace declares which package),
pushed as a read-only table of its functions, whose metatable reads its fields. A handle's fields
and methods are declared the same way (`objects.fields`, `objects.methods`).

## The game's scripts

[`game.zig`](../../src/scripting/game.zig) runs the scripts that decide what happens in the game,
while a game runs. The driver starts them as the front end starts a campaign, loads a saved game or
flies a mission on its own, or as `--mission` starts one, and stops them as the front end's main
menu comes back, or the game quits. Each game gets a new Luau state.

- A mod's `Global` scripts start with the game, in load order, each mod's in the order its manifest
  lists them. Each runs as `require` runs it, the table it returns is checked
  (`Context.offerOf`), and its `on_init` is called.
- `[Missions]` matches a mission's file name (`winmain.missionFileName`) to its keys, in any case.
  As the mission begins, each mod with scripts for it is opened again (`Runtime.open`), so that
  every attempt starts them afresh, and the scripts start as the global ones do. As the mission
  ends, they stop and the mod is closed (`Runtime.close`).
- Object scripts start as an object is added (`object_added`): each mod whose manifest names the
  object's class or type is opened for the object, and each script it lists for them starts there,
  with `on_init` and then `on_added`. A global script starts one on an object with
  `object:add_script`. As the object leaves the mission (`object_removed`), its scripts get
  `on_removed` and stop; as the mission ends or the next begins, the objects' scripts stop without
  it.
- As a script stops, its handlers, hooks and interfaces go, and so does its context once none of
  the mod's scripts on it runs. While engine handlers are being called, a stopped script only gets
  marked, and leaves its list once they're done (`Game.sweep`), so no list changes under a call.
- An engine handler that fails is logged and not called again.

The engine handlers get their arguments as `Handler.Arguments` declares them: numbers as they are,
and handles and tables made beforehand in protected mode (`Runtime.make`). They're called in the
order the scripts started: the global and mission scripts', then each object's, by slot.

### Events

`core.send_global_event` and `object:send_event` copy their value as plain data
([`data.zig`](../../src/scripting/data.zig)): nil, booleans, numbers, strings, vectors, handles, and
tables of these, at most 32 deep. The copy and the event's name wait in a queue
([`events.zig`](../../src/scripting/events.zig)) until the next update, which delivers them before
any `on_update`, in the order they were sent. Each script with a handler for the event's name in its
`event_handlers` gets it, newest mod first, and within a mod in the order the scripts started; a
handler that returns `false` stops the rest. Events sent while the queue is delivered wait for the
next update.

### Interfaces

A script that returns `interface_name` and `interface` offers the table under that name
([`interfaces.zig`](../../src/scripting/interfaces.zig)). An interface is seen within its scope:
the global and mission scripts', or one object's scripts'. `openreliant.interfaces` is one
userdata for every script, whose `__index` looks up the latest interface of the name in the calling
script's scope. A script that offers an interface of a name already offered in its scope gets the
earlier one in `on_interface_override`. As a script stops, its interfaces go, and the earlier ones
are seen again.

The engine calls the game side through `engine.hooks.Scripts`, which `create.Objects.scripts` holds
while a game runs, null otherwise:

| Call | Where | Handlers |
|---|---|---|
| `begin` | `main.startMission`, before the script's start part makes the mission's ships | The objects' and the last mission's scripts stop, the mission's scripts start, `math.random` starts again, and the mission's order context is kept for the functions that give orders |
| `started` | The end of `main.startMission` | `on_mission_start`, then the hook `mission_started` |
| `update` | `main.missionFrame`, after the orders (`aigeneric.ordersUpdate`), in a frame whose `frame_duration` isn't 0 | The events waiting, then `on_update`, with `frame_duration` in seconds |
| `step` | The end of `gameobj.simulationStep` | `on_step` |
| `ended` | `main.endMission`, as the driver lets a mission go | `on_mission_end`, then the hook `mission_ended`; the objects' and the mission's scripts stop |
| `call` | The hooks ([Hooks](#hooks)) | For `object_added`, the object's scripts start, then `on_object_added`; for `object_removed`, `on_object_removed`, then the object's scripts get `on_removed` and stop. Then the hooks' handlers |

`math.random` starts again from a seed made of the C runtime's `rand` seed as the mission begins
(`libcmt.Rand`, which it doesn't draw from) and the mission's number, so the game's own numbers stay
as they are and every machine draws the same. Before the first mission it starts from load
scripts' fixed seed. The original seeds `rand` with the time as each mission starts, which
OpenReliant doesn't port yet ([#582](https://github.com/OpenReliant/openreliant/issues/582)).

## Hooks

[`engine/hooks.zig`](../../src/engine/hooks.zig) declares what scripts can hook, and the engine
calls the hooks where they happen. [`scripting/hooks.zig`](../../src/scripting/hooks.zig) runs the
handlers mods add. The [scripting reference](../guide/reference.md) lists every hook.

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

## The presentation side

[`presentation.zig`](../../src/scripting/presentation.zig) runs player and menu scripts in their
own state, created at startup where a mod has either. The scripts of both sides share the code that
starts, calls and stops them ([`running.zig`](../../src/scripting/running.zig)).

- Menu scripts start at once and run until OpenReliant quits. Player scripts start as a game
  starts and stop as it ends, with the global scripts (`GameScripts` in the driver).
- Each pass of the driver's loop, before anything is drawn, `Presentation.frame` gets the seconds
  since the last pass, the devices, the window's size, the camera and the sound, and what each
  drawing layer is drawn on. It tells the scripts of a new window size (`on_viewport_resized`) and,
  in flight, of the actions whose controls have just been used (`on_action`, from
  `Devices.active` without taking the press), then calls `on_frame`.
- The window's key events reach `Presentation.key`, which tells `on_key_press` and
  `on_key_release` as a key's state changes, so a key the window repeats is told once.
- The driver tells both kinds as each mission starts and ends (`Play.start`, `Play.end`), with the
  same mission and outcome the game's scripts get (`main.scriptMission`, `main.scriptOutcome`).

### Drawing

What the scripts draw in a frame is recorded in a layer
([`drawing.zig`](../../src/scripting/drawing.zig)): `hud` over the flight display, and `ui` over
the front end's screens or the pause menu. The layers
are cleared as each frame starts, and drawn after the game's own display or menu: the flight
display's and the pause menu's in `Display.drawOverlay`, the front end's in `FrontEndDisplay.draw`.
At most 4096 things and 64 KiB of text can be drawn on a layer in a frame. Text is converted to the
game's code page and drawn with `hud.drawText`, in the menus' small font over the front end, and
over the flight display and the pause menu in a ramped copy of the display's font, so that it takes
the colour the script gives. The debug's lines and text are placed in the world and projected
where the camera sees them (`hud.Sight`).

### Events to the game

`core.send_global_event` from a player or menu script copies its plain data a second time, from
the presentation state into the game's (`data.transfer`), as an event would be sent to another
machine. Handles cross as handles of the same object, and a handle that's no longer valid stays so.

Not ported yet: menu scripts in the rooms, the movies and the loading screens, which have loops of
their own ([#589](https://github.com/OpenReliant/openreliant/issues/589)); and pictures, shapes
and a choice of fonts for the drawing packages
([#590](https://github.com/OpenReliant/openreliant/issues/590)).

## Saved games

[`snapshot.zig`](../../src/scripting/snapshot.zig) keeps the scripts' state with a saved game, in a
file beside it, `saves\<call sign>GAME<slot>.scripts` (`save.companionName`). The saves folder
tells the driver as a game is saved, loaded or removed (`save.Extra`, which `GameScripts` in the
driver implements), and the driver writes, reads or removes the file. The game is saved between
missions, so the file holds what lasts a whole game: the storage's game sections, each global and
player script that runs with what its `on_save` returned, and those scripts' timers. Mission and
object scripts don't run then, and menu scripts run across games.

The form, little-endian:

| Part | What it holds |
|---|---|
| Magic | `ORSV`, then the form's version as a `u16`, 1 |
| Game sections | Their count as a `u32`, then for each its mod's name, its name, the count of its fields as a `u32`, and each field's name and value (`Storage.encodeGame`) |
| Scripts | Their count as a `u32`, then for each its mod's name, its family as a byte (`script.Family`), its file's name, and what its `on_save` returned, nil where it has none |
| Timers | Their count as a `u32`, then for each its mod's name, its family, the name of its function, the seconds left as an `f64`, and its data |

Names and values are written in [`stored.zig`](../../src/scripting/stored.zig)'s form: each value
starts with its kind as a byte (`stored.Kind`); a number is an `f64`, a string its length as a `u32`
and its bytes, a vector three `f32`s, a handle the object's slot as a `u16` and its count of reuses
as a `u32`, and a table its count of pairs as a `u32`, then each key and value. A handle comes back
as one that isn't valid, since the game is saved between missions.

- As a game is loaded, `GameScripts` reads the file and starts the scripts with `loading` set, so
  that they don't get `on_init` (`Game.start`, `Presentation.startGame`), then `snapshot.restore`
  puts the state back. The game sections come back first; then each script the file holds gets
  `on_load` with what it saved, matched by its mod, its family and its file's name; then the timers
  start again. The scripts the file doesn't hold, such as a new mod's, get `on_init`. A load from the
  front end starts the scripts as the game goes into the rooms; a load in the rooms starts them again
  at once. A saved game without the file starts them as a new game.
- A file of another version, or a damaged one, is logged, and what's left of it goes unread.
- The restart point keeps the same state in memory (`Saving.restartPoint`), and a replay or the
  pause menu's RESTART starts the scripts again from it. RESTART ends the mission first, so that the
  scripts don't hear the end of a mission they never saw start.
- With no scripts at all, nothing is written, and a file left from an earlier save in the slot is
  removed.

## Storage

[`storage.zig`](../../src/scripting/storage.zig) holds the mods' storage: sections of plain data,
by mod and by name, each a game section or a global section (`storage.Scope`). The driver makes one
`Storage` as OpenReliant starts, and both Luau states reach it through `runtime.Shared`, so a
mod's scripts see the same sections on either side. A section's handle is a userdata whose
`__index` copies a field's value out as Luau values (`stored.push`), whose `__newindex` copies a
value in (`stored.capture`) and whose `__iter` goes through a copy of the fields made as the loop
starts, so that the loop can change the section. Load, player and menu scripts can't change game
sections.

- Game sections are kept with the saved game and the restart point. As a game starts, they're
  emptied rather than freed (`Storage.clearGame`), since scripts may still hold their handles.
- Global sections are kept in the game folder, one file per mod: `storage\<mod>.data`, where the mod
  is named as its archive or folder is. The file holds `ORST`, the form's version as a `u16`, 1, and
  the mod's global sections as the scripts' state file holds game sections. They're read as
  OpenReliant starts (`Storage.readGlobal`), and the files of the mods whose sections changed are
  written at most every 2 seconds and as OpenReliant quits (`Storage.flush`).

## Timers

[`async.zig`](../../src/scripting/async.zig) runs a mod's functions after a while.
`async.register_timer` keeps a function in a table of its context (`Context.callbacks`) under a
name, and `async.after` adds a timer that names it (`Runner.addTimer`, at most 4096 waiting). A
timer names its function rather than holding it, so that it can be written to a file.

`Runner.advance` counts the timers down and runs those whose time is up, the most overdue first. A
timer added while timers run waits for the next round, so a timer that starts itself again with no
delay doesn't run for ever. The game side advances them in `update`, after the events and
before `on_update`, with game time; the presentation side in `Presentation.frame`, before
`on_frame`, with real time. A timer whose function isn't registered is logged and dropped. As a
context closes, its timers go.

## Files

[`vfs.zig`](../../src/scripting/vfs.zig) reads files for scripts. `vfs.read` reads through the
same `bigfile.Hog` as the game's resources, a mod's file first (`runtime.Shared.files`), and
`vfs.read_mod` reads the calling mod's own file (`Mod.readFile`). Scripts can't write files. Not
ported: reading the game's loose files
([#592](https://github.com/OpenReliant/openreliant/issues/592)).

## The console

[`console.zig`](../../src/scripting/console.zig) holds the console: its output, the line typed and
the lines typed before, and what a line runs as. The driver ([`openreliant/console.zig`](../../src/openreliant/console.zig))
creates it in the developer mode (`DeveloperMode`, `--developer-mode`) where a mod has a `.luau`
file, brings it up and takes it away with F11, and draws it last over the frame.

- **The output** keeps the latest 512 lines, of at most 256 bytes each, and is locked while it
  changes, since the log writes to it from any thread. The driver's log function
  (`std_options.logFn`) writes each message of the `scripts` scope to it as well as to the
  terminal: errors red, warnings gold, the rest blue.
- **A line** runs as one of the console's commands (`console.Command`), or, in Luau mode, as Luau in
  the context of a mod's global, player or menu scripts (`console.Mode`), looked up again for each
  line, since contexts close and open as games start and scripts reload. `Runtime.evaluate` compiles
  the line as `return` and the line, and failing that as the line, and runs it on the context's
  thread within the time limit, with a thread of its own for globals (`Context.console`), which the
  context keeps for the next line. Each value it returns is shown as `tostring` gives it, in
  protected mode. Any other line goes to `on_console_command` where a player or menu script has it.
- **`help`** writes from the same declarations as the reference (`reference.writeHelp`): a package's
  fields and functions, an engine handler, or a hook as `openreliant hooks` lists it.
- **While it's up** in flight, the mission is paused as the pause menu pauses it, and the console
  stands in the pause menu's place; in the front end, the screen's pass is left out. Its pass
  (`console/screen.zig`) takes the characters typed and the keys, and the player and menu scripts
  hear no key pressed meanwhile, nor F11. Not yet: the console in the Reliant's rooms and the
  briefing, which have loops of their own
  ([#589](https://github.com/OpenReliant/openreliant/issues/589)).

The screen is laid out on the front end's screen as the settings screen is
([`console/screen.zig`](../../src/scripting/console/screen.zig)): its title on the row of the
settings screen's tabs, the output in a frame from x 45, 520 wide, with the controls list's arrows
right of its top, the line typed in a frame below it with the saved games' blinking cursor, and
RUN, CLOSE, CLEAR and RELOAD in the places of the settings screen's buttons, with their shapes. The
text is in the front end's small font, the title in its large font. Over the front end, what's
behind it is darkened enough that the menus' labels don't show through; over the paused mission,
only as much as the pause menu darkens it behind the settings screen (`hudoptions.shade`), so the
mission shows through.

### Reloading

The scripts reload as the console asks, and in the developer mode as a folder mod's script is
saved: the driver looks at when each folder mod's scripts last changed once a second
(`console.Watch`). `GameScripts.reload`
in the driver:

1. takes the scripts' state where a game runs, as a save takes it (`snapshot.take`);
2. reads the folder mods' scripts again in the presentation state and starts the menu scripts again
   (`Presentation.reload`);
3. starts the game's scripts and the player scripts again from that state, in a new game state,
   which reads the scripts again as it opens each mod (`GameScripts.startFrom`);
4. partway through a mission, starts its mission scripts and the scripts of each object in it
   (`Game.resumeMission`), as the mission's start would, without `on_mission_start` or
   `on_object_added`.

Load scripts and the manifests are read only as OpenReliant starts.

## Object handles

[`objects.zig`](../../src/scripting/objects.zig) gives scripts objects as handles: a slot, and the
slot's count of reuses when the handle was made (`create.Objects.reuses`). The count goes up as
`create_object` fills a slot, as `object_reset` and `create.retire` remove its object, and for
every slot as a mission starts. A handle is valid while its count matches. The state keeps one
handle per slot in a table with weak values, so the same object always gives the same handle while
a script holds it.

Every script can read a handle's fields. A field with a setter can be changed by a global script on
any object, and by an object's own scripts on their object (`objects.mayChange`); the setter checks
the value's range, such as the throttle's (`motion.reverse_throttle` to
`motion.afterburner_throttle`). The same goes for `give_order`, which gives an order as the
mission's `SetAI` does (`aigeneric.give`), and for `hook`, which adds a handler whose filter names
the object. `add_script` and `remove_script` are for global scripts only, and act on the calling
mod's scripts.

## The reference

[`reference.zig`](../../src/scripting/reference.zig) generates, from the declarations above, the
definitions file for luau-lsp ([`openreliant.d.luau`](../guide/openreliant.d.luau)), the
[scripting reference](../guide/reference.md), and what `openreliant hooks` prints. The first two are
committed, and tests check that they match what the code generates. Everything scripts see is in
them: the engine handlers, the packages, the fields and methods of objects, the hooks and their
fields, the records, and the names of enum values. So a change that would change the scripting API
fails the tests, and the API only changes on purpose; `make definitions` then writes both files
again.

The enums and the tables the reference lists are found by following every type scripts can reach
from the declarations. Each takes its type's own name, or the name its `script_name` gives where
that isn't clear enough on its own (`gameobj.Type` is `ShipType`); the build fails if two types
would take the same name.
