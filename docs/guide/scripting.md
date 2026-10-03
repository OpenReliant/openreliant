# Scripting

Mods can include scripts, written in [Luau](https://luau.org), a version of Lua 5.1. Load scripts
change the game's records, such as a gun's damage, at startup. Global and mission scripts run as the
game plays: they react to what happens and change it through hooks on the game's functions and
events. This page explains how to write them; [Hooks](hooks.md) is the reference of everything they
can hook, and [`examples/mods`](../../examples/mods) holds complete example mods.

**Improvement:** the original has no scripting apart from its mission scripts.

## A first script

Scripts live in a mod ([Modding](modding.md)); a folder mod is the easiest to work on. This one
makes the player's ship tougher. Make the folder `mods/tough` in the game folder, with this
manifest, `mod.ini`:

```ini
[Mod]
Name=Tough
OpenReliant=0.7

[Scripts]
Global=tough.luau
```

and this script, `tough.luau`:

```lua
local hooks = require("openreliant.hooks")

-- Every hit on the player's ship lands at half strength.
hooks.after("damage_by_difficulty", function(e)
    if e.object.is_player then
        e.result *= 0.5
    end
end)
```

Start OpenReliant from a terminal and fly a mission (`--mission 0` flies the sandbox at once). The
log in the terminal shows `info(scripts): tough: started tough.luau`, and the player's ship takes
half the damage.

What a script prints with `print`, and its errors, go to the log after the mod's name. OpenReliant
reads a folder mod's scripts again each time a game starts, so after changing one, go back to the
main menu and start again. After changing `mod.ini` or adding a file, start OpenReliant again.

## Kinds of scripts

| Kind | In `mod.ini` | When it runs | What it's for |
|---|---|---|---|
| Load | `Load=` under `[Scripts]` | Once, when OpenReliant starts, before the main menu | Changing [the records](#the-records) |
| Global | `Global=` under `[Scripts]` | For the whole game | [Hooks](#hooks) on the game's functions and events |
| Mission | The mission's file name under `[Missions]` | While that mission runs | Hooks for one mission |

```ini
[Scripts]
Load=balance.luau
Global=rules.luau, wingmen.luau

[Missions]
mission2.dte=escort.luau
```

- A key can list several scripts, separated by commas. They run in that order, after the scripts of
  the mods before ([Load order](modding.md#load-order)).
- A game starts when you start a campaign, load a saved game, or fly a mission on its own (INSTANT
  ACTION, the simulator or `--mission`), and ends at the main menu. Global scripts start afresh
  with each game.
- `[Missions]` matches the mission's file name in any case: `mission2.dte` is mission 2, and
  `mission251.dte` the second part of mission 25. A mission script starts as its mission begins,
  before its ships appear, and stops as it ends. Each attempt starts it afresh.
- Each script has its own global variables.
- Later versions add player, menu and object scripts
  ([#557](https://github.com/OpenReliant/openreliant/issues/557)); this version skips them, and says
  so in the log.

## Engine handlers

A script returns a table, whose `engine_handlers` holds the functions OpenReliant calls. Each one is
optional.

| Handler | Kinds | When it's called |
|---|---|---|
| `on_records_loaded()` | Load | After every mod's load scripts have run |
| `on_init()` | Global, mission | When the script starts |
| `on_mission_start(mission)` | Global, mission | When a mission has started and its first ships are there |
| `on_update(seconds)` | Global, mission | Each frame in which game time passes, after the ships' orders, with the seconds it covers |
| `on_step()` | Global, mission | Each simulation step, 25 a second, after everything has moved |
| `on_mission_end(outcome)` | Global, mission | When the mission ends, for whatever reason |
| `on_object_added(object)` | Global, mission | When an [object](#objects) is added to the mission |
| `on_object_removed(object)` | Global, mission | When an object leaves the mission, such as once it has blown up |

`mission.number` is the mission's number and `mission.file` its file's name. `outcome.ending` says
how the mission ended for the player ([Ending](hooks.md#ending): `"playing"` if the player's ship
was still flying), and `outcome.rating` how its script rated it ([Rating](hooks.md#rating)).

Handlers of all scripts are called in load order. A handler that raises an error is logged and isn't
called again.

## The records

`require("openreliant.records")` gives the game's records. Load scripts can change them; other
scripts can only read them.

| Table | Contents | First number | Names |
|---|---|---|---|
| `ships` | Ship stats, `shipstats.bin` | 0 | The ship types OpenReliant has names for, such as `predator` |
| `guns` | Gun stats, `gunstats.bin` | 1 | `laser_cannon`, `pulse_cannon` and the rest |
| `missiles` | Missile stats, `missilestats.bin` | 0 | `screamer`, `raptor` and the rest |
| `pilots` | Pilot stats, `pilotstats.bin` | 0 | |
| `text` | The game's text, `language.dll`, by string id | 1 | |
| `itac_text` | The ITAC's text, `itaclang.dll`, by string id | 1 | |

Records are looked up by number or by name, with the field names of the [stat
tables](../formats/stats.md):

```lua
local records = require("openreliant.records")

records.guns.laser_cannon.damage.hull = 30   -- by name
records.ships[12].max_speed *= 1.1           -- by number
records.pilots[66].skill = "high"            -- values with names use their names
records.text[568] = "Laser Cannon Mk II"     -- text is a string

for number, missile in records.missiles do  -- every record, in order
    missile.lock_time *= 0.8
end
```

- Assigning a table to a record changes only the fields in it. With a `template` record, the record
  is first copied from the template: `records.guns[2] = { template = records.guns[1], speed = 5 }`.
- A wrong field name or a value of the wrong type is an error.
- Text is UTF-8; characters the game can't show become `?`.
- Records can't be removed, because missions refer to them by number, and adding new ones isn't
  supported yet ([#560](https://github.com/OpenReliant/openreliant/issues/560)).

A load script that fails has its changes undone, and the next one runs.

## Hooks

Global and mission scripts add handlers to hooks with `require("openreliant.hooks")`. A hook is one
of:

- **a function of the original game**, under its name, such as `object_damage` or `bullet_fire`.
  The [developer documentation](../README.md) describes them;
- **an event of the mission**, one its triggers can wait for, such as `destroyed` or `launched`;
- **an event of the engine**, such as `mission_started` or `object_added`.

[Hooks](hooks.md), or `openreliant hooks` in a terminal, lists them with the fields each handler
sees. Later versions add hooks on more of the game
([#581](https://github.com/OpenReliant/openreliant/issues/581)).

### Adding a handler

```lua
local hooks = require("openreliant.hooks")

-- Each enemy the player destroys makes the player's shots hit 10% harder.
local bonus = 1
hooks.add("destroyed", function(e)
    local by_player = e.attacker and e.attacker.is_player
    if e.component == nil and by_player and e.object.side == "hostile" then
        bonus += 0.1
    end
end)
hooks.add("object_damage", function(e)
    if e.kind == "bullet" and e.attacker.is_player then
        e.value *= bonus
    end
end)
```

A handler gets one value, `e`, with the hook's fields. `e` can only be used while the handler runs.

### Changing a function

For a function, `e` holds its arguments, and changing a field changes what it does. A handler that
returns `false` stops the call: the function doesn't run, and neither do the handlers after it.

```lua
-- Shields take twice the damage, but the player's shields take none from collisions.
hooks.add("object_damage", function(e)
    if e.object.is_player and e.kind == "collision" then
        return false
    end
    e.value *= 2
end)
```

`hooks.after` adds a handler that runs after the function. For a function with a result, it sees
the result in `e.result` and can change it. A handler added with `hooks.add` that stops the call can
set `e.result` too, which is then the function's result.

```lua
-- Hits on the player's ship land softer.
hooks.after("damage_by_difficulty", function(e)
    if e.object.is_player then
        e.result *= 0.75
    end
end)
```

`e:original()` runs the rest of the call at once (the handlers after this one, then the function,
with the values in `e`) and returns the function's result, so a handler can do something both
before and after it. The function runs only once.

An event's fields can only be read, and its handler returning `false` only stops the handlers after
it. Events have no `hooks.after`.

### Filters

A third argument limits a handler to the objects it's for. The engine checks it without calling the
handler, so the game doesn't slow down for the rest:

```lua
hooks.add("order_run_away", function(e)
    return false
end, { side = "hostile", class = "fighter" })
```

The filter takes `object` (a handle), `type`, `class` and `side`, each a name or a list of names;
every test given must hold. It tests the hook's main object: `object` for most hooks, `owner` for
`bullet_fire` and `launcher` for `missile_launch` ([Hooks](hooks.md)). A filter can also be a
function, which gets `e` and returns `true` for a call the handler is for.

### Order, removal and errors

- Handlers run newest mod first (the mod that loads last), and within a mod in the order they were
  added. So a later mod's handler that returns `false` stops an earlier mod's.
- `hooks.add` and `hooks.after` return a handle, and `handle:remove()` removes the handler.
- A handler that raises an error is logged with its file and line, and removed, and the changes it
  made to `e` are undone.

## Objects

Scripts see objects (ships, stations, nav points) as handles, such as `e.object`. Their fields, such
as `type`, `side` and `position`, can only be read in this version ([Objects](hooks.md#objects)).

- The same object always gives the same handle, so `==` compares objects, and handles work as table
  keys.
- A handle is valid until its object leaves the mission or the mission ends; reading a field of one
  that isn't is an error. `object:is_valid()` tells which.

## Values

- Numbers use the game's units ([developer documentation](../README.md)). Positions and velocities
  are Luau vectors, a velocity being the distance moved in a simulation step.
- Values OpenReliant has names for are strings, such as `"fighter"` or `"laser_cannon"`; one without
  a name is a number ([Names of values](hooks.md#names-of-values)).
- `math.random` gives the same numbers on every computer for the same game: it starts again as each
  mission starts, from the game's own random numbers. `math.randomseed` and `os` aren't there.

## Packages

`require("name")` runs another script of the same mod once and returns what it returns; the name is
the file name, with or without `.luau`, in any case. `require("openreliant.<name>")` gives one of
OpenReliant's packages:

| Package | Kinds | What it gives |
|---|---|---|
| `openreliant.core` | All | `version`, the OpenReliant version |
| `openreliant.records` | All | [The records](#the-records); only load scripts can change them |
| `openreliant.hooks` | Global, mission | [Hooks](#hooks): `add` and `after` |

Later versions add more, and requiring one of those now gives an error that says so.

## Editors

[luau-lsp](https://github.com/JohnnyMorganz/luau-lsp), the Luau language server, gives editors such
as VS Code completion and type checks:

1. Install its extension, and set its platform to Standard (`luau-lsp.platform.type`).
2. Add `openreliant.d.luau` to its definition files (`luau-lsp.types.definitionFiles`). It comes
   with each release, and is in [`docs/guide`](openreliant.d.luau).
3. Give each package's variable its type:

   ```lua
   local hooks: Hooks = require("openreliant.hooks")
   ```

The editor then knows every hook with the fields of its `e`, and the fields of objects and records.
It may report that it can't find the packages themselves, which OpenReliant provides.

## Limits

Scripts run in a sandbox: they can't open files, use the network or run programs. A call into a
script may run for at most 1 second in a load script and 100 milliseconds in a global or mission
script, and each mod's scripts may use at most 64 MiB of memory. An error in a script never stops
the game: it's logged with the file and the line, and the game carries on.

## When something goes wrong

| In the log | What to check |
|---|---|
| `skipping the mod ...: it needs OpenReliant 0.7.0` | OpenReliant is older than the mod's `OpenReliant=` |
| No `started` line for the script | `mod.ini` lists it under `[Scripts]`, with the file's exact name |
| `there's no hook named '...'` | The hook's name ([Hooks](hooks.md)) |
| `... has no field '...'` or `expected a number, got string` | The field's name and type |
| `e can only be used while its handler runs` | Keep values from `e` in variables, not `e` itself |
| `... is an event, whose fields can't be changed` | Events can only be read |
| `the object is no longer in the mission` | `object:is_valid()` before using a handle kept from earlier |
| `script timed out` | A loop that doesn't end, or does too much at once |
| `... is not available to load scripts` | Load scripts can't use that package |
