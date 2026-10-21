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

## Drawing resources

**Improvement:** scripted HUD/UI drawing uses mod PNG pictures, the current game's sprite set or
one a script names, and selected bitmap or outline fonts (#590). `drawing.Assets` caches the mods'
pictures and fonts by script context and file name, and the game's sprite sets that scripts name, by
their name in `resource.hog` (`ShapeStyle.sprites`). The sets are read with the mods' copies and
pictures, as the front end reads its own, while `drawing.View` borrows the current game's fonts,
sprite set and rasterizer. A named set's shapes are drawn from it directly. The layer's own set is
looked up when the layer draws, since its screen can change the set between the scripts' frame and
the drawing. Custom outline fonts reuse `hud.outline.Fit` and its atlas path. Measurement uses
the same bitmap layout as drawing. When a new picture or font needs room, the pictures drawn
longest ago are taken out of the cache, but never one drawn in the last two frames, and freed at
the next draw, which hands their textures back to the device. Fonts, and the rest at shutdown,
are released before the rasterizer and the renderer; a reload makes new entries for the new
contexts without invalidating earlier frames.

## Registries and built-in interfaces

**Improvement:** `registries.zig` owns presentation registrations by context and qualified name
(#558). It calls handlers through the protected runtime and validates camera return values in
a protected boundary. Camera selection uses unnamed view values after the original table; an
original view change releases the custom selection. Camera subjects use reuse-counted object
handles. HUD displays and selected screens record commands through the existing drawing layer.
Context shutdown and failed loads invalidate registrations and release callback references.

A HUD display's `replaces` and `layout` give each of the game's instruments a placement
(`Registry.placements`, `hud.Placement`), and its `parts` each of their parts one
(`Registry.partPlacements`, `hud.parts.Placement`), from the displays that are on, a later one
winning. Once
the scripts' frame has run, the driver keeps them for the frame
(`Presentation.instrumentPlacements`): the flight display draws each instrument through a device
of its own that moves, scales or hides it (`hud.Placings`), and the radar's backing in the scene
follows the radar. The driver also passes the flight display's state and the player's
(`Presentation.Host.flight`), which [`instruments.zig`](../../src/scripting/instruments.zig) reads
for `openreliant.hud`: as the instruments last drew, since the scripts run first.

`builtin_interfaces.zig` groups existing API declarations. `interfaces.zig` supplies these tables
as fallback bases, while keeping normal scope/override behavior. Generated definitions follow
the same declarations rather than a second list of function signatures.

## Post effects

[`postprocessing.zig`](../../src/scripting/postprocessing.zig) is the `openreliant.postprocessing`
package and the registry of the effects (`Runtime.post_effects`), on the presentation side.

- `register` reads the shader with `Mod.readFile` and hands it to the effect host
  (`postprocessing.EffectHost`), which the driver gives the presentation side
  (`Presentation.setEffectHost`). The host compiles it, or reads it from the shader cache
  (`platform.shader_cache`), and adds it to the GPU (`platform.gpu.Gpu.addEffect`). A compile
  error is raised in the script. Without a host, as in the tests, an effect registers and draws
  nothing.
- Each entry keeps its script's context, its qualified name, its stage, its order, its four
  parameters, whether it is on, and the host's effect. `Runtime.close` and a failed load
  (`Runtime.run`) remove a context's effects, and the host removes them from the GPU.
- The driver's [`mod_shaders.zig`](../../src/openreliant/mod_shaders.zig) is the host. It is the
  GPU's effect source (`Gpu.effect_source`): as each frame is finished, it gives the GPU the passes
  of the enabled effects (`Registry.passes`), sorted by stage, then order, then registration. The
  driver removes the host before the GPU is destroyed.

## Surface and lighting functions

[`shaders.zig`](../../src/scripting/shaders.zig) is the `openreliant.shaders` package and the
registry of the functions (`Runtime.mod_shaders`), on the presentation side, set up as the post
effects' is.

- `register_surface` and `register_lighting` read the function's file and hand it to the shader
  host (`shaders.ShaderHost`, `Presentation.setShaderHost`), which compiles it on its own in a
  variant of the device shader to find its mistakes, and keeps it. A compile error is raised in
  the script.
- After each change (a registration, `set_enabled`, `set_parameters`, a removal), the registry
  gives the host every function it has, in the order they were registered (`ShaderHost.update`).
  The driver's host (`mod_shaders.zig`) compiles the variants the lighting function that draws
  needs, gives the textures named their surface function by `srtexture.Table.find`, and sets the
  surface function of every lit surface.
- `object:set_surface` sets the surface function and parameters of each part of the object's model
  (`srapiext.MeshObject.surface`). An object whose function is removed draws without it.
- `Runtime.close` and a failed load remove a context's functions, as they remove its effects.

## Luau implementation

`deps/luau` builds Luau 0.740 from source as two static libraries, split as Luau's `Sources.cmake`
splits it: `luau-ast`, the parser (`Luau.Common` and `Luau.Ast`), and `luau` on top of it, the
bytecode builder, the compiler and the VM (`Luau.Bytecode`, `Luau.Compiler` and `Luau.VM`). The
build matches Luau's `LUAU_EXTERN_C` option: the C API is `extern "C"`, and Luau errors use
`longjmp` instead of C++ exceptions, because exceptions can't unwind through Zig code. Luau is
always built optimized, like FreeType.

Because errors use `longjmp`, a Zig function called from Luau must free anything it allocated before
it calls something that can raise an error. Zig `defer`s don't run when a `longjmp` skips the frame.

The scripting code is a separate module, [`src/scripting.zig`](../../src/scripting.zig), linked into
the game only. [`luau.zig`](../../src/scripting/luau.zig) wraps the C API. sltool links the parser
alone, to read mission source ([Reading the text](../formats/mission-source.md#reading-the-text)).
The other tools don't link Luau.

## The Luau state

[`runtime.zig`](../../src/scripting/runtime.zig) sets up a Luau state for scripts. There are two
kinds of state:

| State | Scripts | Differences |
|---|---|---|
| Game | Load, global and object scripts, which affect what happens in the game | No `os` library. `math.random` uses a seeded generator so that every machine gets the same numbers, and `math.randomseed` is removed. |
| Presentation | Player and menu scripts, which affect what the player sees and hears | Luau's standard libraries |

The split is the one a network game needs
([#55](https://github.com/OpenReliant/openreliant/issues/55)): global and object scripts will run
only where the game is hosted, load scripts on every machine, and the presentation on each player's.
The presentation reaches the game only through events to the global scripts, which wait until the
game next runs and then have their data copied into the game's state (`Presentation.sendEvents`,
`data.transfer`), and it can't change objects (`objects.mayChange`) or records. The rules mods keep
for it are in the scripting guide ([In a network game](../guide/scripting.md#in-a-network-game)).

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

Neither side has `getfenv` or `setfenv` (`Runtime.withheld`). A function's environment is the
global table of the script that made it, so with them a mod could read and change another mod's
globals through any function that mod's interface hands it. The metatables of handles and of
packages are locked (`State.lockMetatable`): `getmetatable` gives "The metatable is locked" in
their place, so a script can't call their metamethods by hand.

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
available to that kind of script raises an error saying which.

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
(`Runtime.begin`). Its clock moves on by the time the inner call took, so that time spent in the
handlers it ran, other mods' included, doesn't count against it (`Runtime.end`).

A call can be slow once for reasons that aren't its own, such as the system or a collection. So a
function the scripts register goes at once where a call raises an error, but where a call runs out
of time, only once three of its calls in a row have (`runtime.Timeouts`). That holds for a hook's
handler and its filter, an engine handler, a custom order, and a registered camera view, HUD
display or screen; event handlers and timers only log their errors. Many handlers that each keep to
the limit can still hold up a frame; a budget for each frame across all of them isn't kept yet
([#1077](https://github.com/OpenReliant/openreliant/issues/1077)).

`Runtime.call` only pushes arguments that take no memory: references, numbers and booleans. What
does take memory, such as `e` or the table `on_mission_start` gets, is made beforehand in protected
mode (`Runtime.make`), where running out of memory is an error the engine handles, rather than one
Luau can't recover from. These count against no mod. Every call runs with the same error handler,
which adds the traceback: a reference made as the state starts (`Runtime.traceback`), so that
nothing takes memory between the mod's limit taking hold and the protected call
(`State.protectedCallWith`). A value a call returns is kept once the call has ended
(`Runtime.callResult`). Opening a mod's context makes its thread and its tables in protected mode
as the engine's work (`Runtime.protect`), since a script can open one (`object:add_script`). An
error that no protected call catches is a bug of OpenReliant's: it's logged before Luau aborts
(`State.setPanic`).

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
([Stat tables](../formats/stats.md)), of the strings in `language.dll` and the ITAC's
`itaclang.dll`, of the campaign's order (`gameflow.Order`), and of what the campaign makes of each
mission (`gameflow.CampaignMission`). After the load scripts run, the game reads its stats and text
from these copies, and the driver installs the order and the missions (`gameflow.install`,
`gameflow.installMissions`). The package holds the tables, and its metatable gives `campaign`:
`__index` pushes a new list each time, and `__newindex` takes a load script's list, since Luau calls
it for a key the read-only table doesn't hold. `missions` gives a proxy for each mission
([`records/missions.zig`](../../src/scripting/records/missions.zig)), whose fields load scripts
change in place.
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
may give is `on_records_loaded`. The log reports keys in `[Scripts]` that aren't a script kind.

## Script definitions

[`script.zig`](../../src/scripting/script.zig) defines the whole scripting API, including the parts
that don't run yet, so that scripts written now keep working as later versions fill them in:

- The script kinds that `[Scripts]` accepts: `Load`, `Global`, `Player`, `Menu`, each object class
  (`create.ShipCombat.Class`), `Missile`, `Turret`, and an object type as `Type.` followed by its
  name or number. The build fails if an object class has no matching kind.
- The script families, which decide what a script may do: load, global, object, player and menu.
- The keys of the table a script returns: `engine_handlers`, `event_handlers`, `interface_name` and
  `interface`.
- The engine handlers, which families may use each one, what the engine passes each
  (`Handler.Arguments`), and what it takes from what each returns (`Handler.Result`).
- The packages, which families may require each one, and which are implemented in this version
  (`Package.ready`): all of them.

## Declarations

What scripts see of a package or a handle is declared once, in Zig, and the bindings and the
reference are made from it at compile time ([`api.zig`](../../src/scripting/api.zig)):

- `Field` declares a field: its type, a sentence for the reference, a getter, and a setter for a
  field scripts can change.
- `Function` declares a function: a sentence and its parameters' names. Its Zig parameters give
  their types: the first is the `Call` (the state, the calling context and what the script
  called), and the rest are read with `values.read`. Its result is pushed with `values.push`. The
  build checks that every parameter has a name.
- `Native` declares a function that takes the `Call` and reads what it's passed itself from the
  call's state, such as one that takes a script's function, with its Luau types written out for
  the reference.

A call is labelled with what the script called: a package's function or field by the package's
name and its own, such as `hud.text`, and a handle's by the handle's kind, such as
`object:give_order` for a method and `object.throttle` for a field. Each error the call raises
starts with the label, which comes from the declaration's name where it's pushed, so no message
types it by hand.

The call also gives the names of what mods register. `Call.qualified` makes the qualified name of
something the calling mod registers. `Call.named` turns a name a script gives for something
registered into the qualified name: the calling mod's own name gets the mod's prefix, and a
qualified name of any mod stays as it is. The functions that look up what any mod registered, such
as `camera.set_view`, go through `Call.named`, and the ones that reach only the calling mod's own,
such as `postprocessing.set_enabled`, through `Call.qualified`.

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
- Missile scripts start and stop the same way with each missile's flight, through the engine events
  `missile_added`, as `missile_launch` and `missile_launch_turret` finish, and `missile_removed`,
  as `missile_end` begins. A context runs on an object, a missile or a turret (`RunsOn`), which
  `self`, `nearby`, the interfaces' scope and what a script may change follow. A missile's handle
  ([`missiles.zig`](../../src/scripting/missiles.zig)) holds its record and the record's count of
  reuses (`Linked.reuses`, OpenReliant's own), as an object's holds its slot's. Each missile notes
  its launcher slot's count as it's launched (`Missile.launcher_reuses`), so that its `launcher`
  is nil once that object has left, and `missile_end` runs once even where a script sets the
  missile off as it hears of its end (`Missile.ending`).
- Turret scripts start as an object is added, after its own scripts, on each of its guns that is a
  turret (`turrets.isTurret`: any but a fixed gun), each turret with the mod opened for it. They
  run in the object's list, so they stop with its scripts. A turret's handle
  ([`turrets.zig`](../../src/scripting/turrets.zig)) holds its object's handle and the gun's place
  among the object's guns (`create.Slot.guns`), and stays valid while the object does, a turret
  destroyed with its base (`guns.Turret.gone`) included.
- As a script stops, its handlers, hooks and interfaces go, and so does its context once none of
  the mod's scripts on it runs (`Runner.closeUnused`), as does a context none of whose scripts
  started. While engine handlers are being called, a stopped script only gets marked, and leaves
  its list once they're done (`Game.sweep`), so no list changes under a call.
- A script can stop its own scripts while it runs, such as a missile's script that sets off its
  missile. A context closed while calls run keeps its thread and its tables until no call runs
  (`Runtime.close`), so that Luau doesn't collect a thread in the middle of a call.
- An engine handler that fails, or runs out of time three times in a row, is logged and not called
  again.

The orders the scripts give run against the world the mission's start hands them (`Scripts.begin`),
then against the world as each frame has it (`Scripts.frame`), since some of the world's pointers,
such as the cockpit's model, change between frames.

The engine handlers get their arguments as `Handler.Arguments` declares them: numbers as they are,
and handles and tables made beforehand in protected mode (`Runtime.make`). They're called in the
order the scripts started: the global and mission scripts', then each object's, by slot, then each
missile's, by record.

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

A script that returns `interface_name` and `interface` offers a read-only copy of the table under
that name ([`interfaces.zig`](../../src/scripting/interfaces.zig)), taken as the script starts
(`Context.offerOf`), so no other script can change what it offers. An interface is seen within its
scope: the global and mission scripts', or one object's scripts'. `openreliant.interfaces` is one
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
| `update` | `main.missionFrame`, after the orders (`aigeneric.ordersUpdate`), in each game frame, once a tick ([Game frames and drawn frames](../engine/loop.md#game-frames-and-drawn-frames)) | The events waiting, then `on_update`, with `frame_duration` in seconds |
| `step` | The end of `gameobj.simulationStep` | `on_step` |
| `ended` | `main.endMission`, as the driver lets a mission go | `on_mission_end`, then the hook `mission_ended`; the objects' and the mission's scripts stop |
| `call` | The hooks ([Hooks](#hooks)) | For `object_added`, the object's scripts start, then `on_object_added`; for `object_removed`, `on_object_removed`, then the object's scripts get `on_removed` and stop. Then the hooks' handlers |

`math.random` starts again from a seed made from the state of the game's random number generator
when the mission begins (`Random.fingerprint`, which reads the state without drawing a number) and
the mission's number, so the game's own numbers don't change and every machine gets the same.
Before the first mission it starts from load scripts' fixed seed. As in the original, the mission's
start first seeds the game's generator from the clock, so both differ from one start to the next;
`--seed` fixes the seed for a run that comes out the same each time
([Configuration](../guide/configuration.md)).

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

A function's fields are its parameters after the first, the world, the orders' context or the
mission's script, in order, with a slot as an `Object` and an order's or a missile's target as a
`Target`, which gives back the game's own target unchanged where the scripts leave it alone
(`Target.aimed`). A field whose name starts with `_` passes its parameter through without scripts
seeing it. An array of numbers, such as a command's arguments, is a read-only list that a handler
replaces. The build checks that the fields follow the function's parameters and that the result is
the function's. So OpenReliant's code can change around a hook, but what scripts see of it only
changes where its declaration does. Where a handler stops a function, its result is the result
type's `stopped` where the type declares one, and zero otherwise.

`vm_command` (`0x0045BEA0`) pops a command's arguments and stores its result as the original does,
and runs the command itself in `Machine.runCommand`, the hooked function, on a copy of the
arguments padded with zeros to the most any command takes (`executor.Arguments`). The command is a
`MissionCommand`, the catalogue's names in snake case, and its result a `CommandResult`, whose
`stopped` is `run_on`. A handler's `hold`, a value no command gives, has `Machine.command` put the
arguments back on the stack and step back over the command instruction, as the game's waiting
commands do (`Call.againItself`), so the thread runs the command again the next time it runs.

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
the mission's in `mission/events.zig`, as each posting routine takes them, the proximity events as
the watches' scan (`0x0045B170`) finds a ship close by, with the distance before it's truncated, `object_added` in
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
fails, they're put back, unless the function ran inside it, and the handler is removed, or, where it
ran out of time, once it has three times in a row ([Limits](#limits)).

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
  since the last pass, the devices, the window size, the camera, the sound system, the scene for 3D
  sounds during a mission (`Host.scene`), the view each drawing layer draws on, and the player's
  place in the rooms while they're on screen (`Host.rooms`). It reports a new window size
  (`on_window_resized`), a new view or place in the rooms (`on_room_changed`), a new piece of
  music (`on_music_changed`, comparing paths case-insensitively) and, in flight, the actions whose
  controls were just pressed (`on_action`, from `Devices.active`, without consuming the press).
  Then it calls `on_frame`.
- Each loop of the rooms' driver says what it shows as it runs the scripts' frame
  (`Driver.pump`): the rooms, a place's screen, or a screen outside them, such as the in-game
  options. `openreliant.rooms` reads the last frame's (`rooms.zig`). The host holds only values,
  never a screen: `rooms.set_cd_player_page` leaves a request that the CD player's loop takes after
  the scripts' frame (`Presentation.takeCdPlayerPage`), so a script called between frames can't
  reach a CD player that has closed.
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

### Sound

[`audio.zig`](../../src/scripting/audio.zig) plays script sounds on the game's voices
([Script sounds](../engine/sound.md#script-sounds)). `audio.Sounds` caches the mod sound files the
scripts play, by mod and name, decoded into WAVE files on first use (`recordings.decode`), up to
64 MiB. When the cache is full, it evicts the least recently played files that aren't playing. A
playing file can't be evicted, because the software mixer reads the samples straight from it.
`audio.Sounds` also tracks the sounds the scripts started, by ID (`hog_snd.Starter`) and script
family, and drops them once they end. It stops the player scripts' sounds when the game ends, and
the menu scripts' sounds when the menu scripts reload.

### Events to the game

`core.send_global_event` from a player or menu script copies its plain data a second time, from
the presentation state into the game's (`data.transfer`), as an event would be sent to another
machine. Handles cross as handles of the same object, and a handle that's no longer valid stays so.

The rooms, the movies and the loading screens have loops of their own, which run the player and
menu scripts too (`src/openreliant/script_frames.zig`): each hands them the keys its window reads,
runs their frame before it draws, with their user interface layer in the menus' small font at the
front end's scale, and draws that layer last over the screen.

## Saved games

[`snapshot.zig`](../../src/scripting/snapshot.zig) keeps the scripts' state with a saved game, in a
file beside it, `saves\<call sign>GAME<slot>.scripts` (`save.companionName`). The saves folder
tells the driver as a game is saved, loaded or removed (`save.Extra`, which `GameScripts` in the
driver implements), and the driver writes, reads or removes the file. The file is written before
the save itself, and if it can't be written, the game isn't saved
([Saved games](../formats/save.md#in-openreliant)). The game is saved between
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
- Loading reads a file of up to `snapshot.max_size`, 256 MiB, and `snapshot.take` keeps within it.
  It gathers the state first (`Gathered.gather`), then measures each mod's share of the file: its
  game sections (`Storage.measureGame`), what its scripts saved and its timers. Where the file
  would pass the limit, the mod with the largest share is left out, then the next, until the rest
  fits (`Gathered.fit`), and each is logged. Their scripts get `on_init` when the game is loaded.
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

A mod's scripts may keep up to `storage.max_storage`, just under 15 MiB, in each place, counted as
the memory the mod's sections take: each section, each field, and what the values hold
(`stored.Value.footprint`), which their binary form never passes. A change that would take a mod
past it is refused, unless it makes the sections smaller. What the engine keeps for a mod, its
options and its game modes' progress, and what a file holds as it's read back, aren't counted. So a
file of global sections always fits in the 16 MiB that reading takes, and one that wouldn't is left
unwritten (`Storage.writeGlobal`).

A value is checked before it's copied out of Luau (`stored.capture`), counting what the copy would
take. A value that holds the same table twice is copied twice, so a few tables can stand for
millions: the check stops past 16 MiB (`stored.max_kept`), which bounds its time as well as the
copy, since it runs in Zig, where the time limit doesn't reach.

Together, the mods' game sections and what their scripts save can take far more than one mod may
keep, so the file kept with a saved game has a limit of its own, past which the mods that keep the
most are left out ([Saved games](#saved-games)).

## Options

[`options.zig`](../../src/scripting/options.zig) is the `openreliant.options` package and the
registry of the mods' pages (`options.Registry`), which the driver makes with the storage and
reaches both Luau states through `runtime.Shared`.

- `register_page` reads a table of lists and values: `values.read` takes a `values.List` as a
  table of values in order, at most its capacity, and a union of a boolean, a number and a string as
  whichever the value is (`mod_options.Value`). The page is checked (`mod_options.Option.problem`
  and the keys' being unique) and copied into the registry's arena, as the mod's page
  (`mod_options.Page`). Load and menu scripts can register, until the driver closes the registry
  once the menu scripts have started (`Registry.close`).
- The values are the mod's global storage section `options` (`options.section_name`), written by
  `Storage.put`. A value that is the option's default takes the field out. Reading goes through
  `Option.fit`, which gives the default for a value that doesn't suit the option, and a choice's
  own copy of its value, so that what the screen holds lasts as long as the page.
- The mods screen reaches the pages and values through `mod_options.Pages`, whose three functions
  `Registry.pages` fills in, as the settings screen reaches OpenReliant's options through
  `settings.Own`. A change is also noted in the registry (`Registry.takeChange`). The driver takes
  the changes after each pass of the front end and tells the mod's menu scripts
  (`Presentation.optionChanged`, `Runner.callMod`): the screen is the front end's, so no game
  scripts run then.

## Game modes and the menu flow

[`game_modes.zig`](../../src/scripting/game_modes.zig) is the registry of the mods' game modes
(`game_modes.Registry`), which the driver makes with the storage and reaches both Luau states
through `runtime.Shared`. [`front_end.zig`](../../src/scripting/front_end.zig) holds the menu
scripts' side of the front end.

- `core.register_game_mode` reads its table into a `game_modes.Definition`, checks it, and copies
  it into the registry's arena, with the list the game modes screen shows (`Registry.shown`). Load
  and menu scripts can register until the driver closes the registry once the menu scripts have
  started (`Registry.close`), which also reads each campaign's progress.
- The driver starts the mode the screen chose (`Registry.start`) before the game's scripts start, so
  that they read it (`core.game_mode`, `core.game_mode_mission`). As each mission ends,
  `Registry.goesOn` gives the next mission from how it ended and how its script rated it, or none
  where the mode is over. A campaign's progress is the mod's global storage section `campaigns`
  (`game_modes.progress_section`), keyed by the mode's own name.
- Between a mode's missions the driver shows the front end's `mode_briefing` with the game's
  scripts still running (`Flow.toBriefing`), and stops them as the mode ends.
- `front_end.scripted` gives the front end its `interf.Scripted`: whether a mod's screen stands in
  for a screen (the ones `ui.replace_screen` set, and for `mode_briefing` the running mode's
  briefing), selecting it as the front end shows it, and the request it made since the last pass
  (`front_end.Standing`). The front end takes one request a pass.
- `ui.play_movie` keeps the movie's name until the driver takes it after the front end's pass
  (`Presentation.takeMovie`) and plays it on a cleared screen.

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

[`vfs.zig`](../../src/scripting/vfs.zig) reads files for scripts, which can't write files.
`vfs.read_mod` reads the calling mod's own file (`Mod.readFile`). `vfs.read` looks a name up in three
places (`vfs.find`):

1. A mod's copy, found by the last part of the name.
2. The game folder's loose file, found by its whole path in any case (`Mods.readLoose`, with the
   folder in `runtime.Shared.game`). A folder is not a file.
3. The member of `resource.hog` (`runtime.Shared.files`).

A file is read up to what the mod's scripts have left of their memory (`Runtime.memoryLeft`), since
a copy goes into the script's string. The string is made in protected mode, so that the bytes read
are freed where it can't be made (`vfs.pushBytes`).

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
  stands in the pause menu's place. In the front end, the screen's pass is left out. The Reliant's
  rooms and the briefing have loops of their own, which run the console's pass too
  (`openreliant/rooms.zig`): F11 brings the console up once the screen is drawn, and until it's
  taken away, a loop of its own draws it over that screen, whose pass is left out. The room's clock
  and sounds go on meanwhile. The movies and the loading screens don't bring it up. Its pass
  (`console/screen.zig`) takes the characters typed and the keys, and the player and menu scripts
  hear no key pressed meanwhile, nor F11.

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
`motion.afterburner_throttle`). The setters do what the game's own code does for the same change:
`position` and `orientation` place the object as `SnapToPoint` does (`objects.setPosition`,
`objects.setOrientation`), the orientation's axes squared up first (`math.orthonormalize`);
`armor` works out its conditions again (`main.armorConditions`); and the flags set what the
mission's commands set, through the same routines where a command does more than set its flag
(`cloak.set`, `ai.setTargetable`, `executor.setLights`). Shields and armour go up to what
`create.makeWhole` gives a ship. The same goes for `give_order`, which gives an order as the
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
from the declarations, through fields, lists, optionals and the variants of a union. Each takes its
type's own name, or the name its `script_name` gives where that isn't clear enough on its own
(`gameobj.Type` is `ShipType`, and a missile type's record is `MissileRecord`, so that it isn't
taken for the `Missile` handle). The build fails if two of these types, records and handles
included, would take the same name, or if the definitions name a type they don't declare.

The definitions file is written for current luau-lsp: the handles, the records and the hooks' `e`
are extern types (`declare extern type`), the other types are exported so that scripts can annotate
with them, and the descriptions are `---` comments, which luau-lsp shows on hover. A test parses the
file with Luau's own parser, as luau-lsp reads a definitions file
([`source_parser.zig`](../../src/source_parser.zig)).

`hooks.add`, `hooks.after` and an object's `hook` take the hook's name from a union of the names
they accept (`HookName`, `FunctionHookName` and `ObjectHookName`, from `hooks.Names`), and give the
handler an `e` of type `any`, which scripts annotate with the hook's type. Luau types a handler's
parameters only from a single signature without generics: one overload per hook, or a type
function from a hook's name to its type, leaves `e` untyped in both of Luau's type solvers
([luau#3045](https://github.com/luau-lang/luau/issues/3045),
[luau#2373](https://github.com/luau-lang/luau/issues/2373)). The new solver also refuses an
intersection of more than eight such overloads, and then ignores the whole file
([luau#1853](https://github.com/luau-lang/luau/issues/1853)). So the file loads in both solvers, and beside mission source's definitions in one folder
([Editors](../guide/missions.md#editors)): a test checks that the names both files declare are
declared the same way in each.
