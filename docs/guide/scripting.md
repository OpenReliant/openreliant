# Scripting

Mods can include scripts, written in [Luau](https://luau.org), a version of Lua 5.1:

- **Load scripts** change the game's records, such as a gun's damage, as OpenReliant starts.
- **Global and mission scripts** run as the game plays. They react to what happens and change it,
  through hooks on the game's functions and events.
- **Object scripts** run on the ships and other objects of a mission, each on its own object;
  **missile scripts** on each missile in flight; and **turret scripts** on each turret.
- **Player and menu scripts** decide what the player sees, hears and does. They draw over the flight
  display and the menus, react to the keys, and add camera views, game modes and shader effects.

This page explains how to write them. The [scripting reference](reference.md) lists everything
they can use, [What mods can do](what-mods-can-do.md) shows each feature with an example, and
[`examples/mods`](../../examples/mods) holds example mods for mod makers, which show how the
scripting works and aren't supported mods.

New to scripting? Start with [a first script](#a-first-script), then read
[Kinds of scripts](#kinds-of-scripts) and the example closest to what you want to do.
[Luau's website](https://luau.org) explains the language itself. The sections after that can be read
in any order, as you need them.

**Improvement:** the original has no scripting apart from its mission scripts.

- [A first script](#a-first-script)
- [Kinds of scripts](#kinds-of-scripts)
- [Packages](#packages) and [values](#values)
- [Engine handlers](#engine-handlers)
- [Hooks](#hooks)
- [Objects](#objects) and [object scripts](#object-scripts)
- [Orders](#orders)
- [Events](#events) and [interfaces](#interfaces)
- [The records](#the-records)
- [Saved games](#saved-games), [storage](#storage) and [timers](#timers)
- [Player and menu scripts](#player-and-menu-scripts)
- [Menus, game modes and campaigns](#menus-game-modes-and-campaigns) and [options](#options)
- [Post effects](#post-effects), [surface and lighting functions](#surface-and-lighting-functions)
  and [replacing OpenReliant's shaders](#replacing-openreliants-shaders)
- [Files](#files)
- [The console](#the-console) and [editors](#editors)
- [Limits](#limits) and [when something goes wrong](#when-something-goes-wrong)

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

`print` output and script errors go to the log, after the mod's name. In the developer mode, they
go to the console too, and a folder mod's scripts reload as soon as one is saved, carrying on from
where they were ([The console](#the-console)). Otherwise, go back to the main menu and start a game
again. After changing `mod.ini`, adding a file or changing a load script, restart OpenReliant.

### The example mods

Each example mod shows one part of the scripting, with comments in its files:

| Example | What it shows |
|---|---|
| [`arena`](../../examples/mods/arena) | A [game mode](#game-modes) with its own rules, a [HUD display](#hud-displays) fed from [storage](#storage), and the [`radio_say`](#changing-what-the-radio-says) hook |
| [`balance`](../../examples/mods/balance) | [The records](#the-records), changed from a load script |
| [`bananas`](../../examples/mods/bananas) | A mod's own gun, missile, pilot and ship type, tuned in [the records](#the-records), and a [pilot set](#objects) on enemy ships |
| [`campaign`](../../examples/mods/campaign) | A [campaign](#campaigns) with a briefing screen and a movie |
| [`cel-shading`](../../examples/mods/cel-shading) | [Surface and lighting functions](#surface-and-lighting-functions) |
| [`crt`](../../examples/mods/crt) | A [post effect](#post-effects) |
| [`custom-order`](../../examples/mods/custom-order) | A [custom AI order](#custom-ai-orders) started by a [mod action](#keys-and-actions) |
| [`drawing-assets`](../../examples/mods/drawing-assets) | A mod's [pictures, the game's shapes and fonts](#pictures-shapes-and-fonts) |
| [`dvd`](../../examples/mods/dvd) | A menu script that [draws](#drawing) over the menus |
| [`interceptor`](../../examples/mods/interceptor) | A mod's ship type, flown in a [game mode](#game-modes) |
| [`main-menu`](../../examples/mods/main-menu) | [Replacing a screen](#replacing-a-screen) of the front end |
| [`rules`](../../examples/mods/rules) | [Hooks](#hooks) on the game's functions |
| [`strafe-run`](../../examples/mods/strafe-run) | A custom order, a [HUD display](#hud-displays), a [camera view](#camera-views), a [screen](#screens) and [actions](#keys-and-actions), through the [built-in interfaces](#built-in-interfaces) |
| [`tally`](../../examples/mods/tally) | [Saved games](#saved-games), [storage](#storage) and [timers](#timers) |
| [`teapot`](../../examples/mods/teapot) | A mod's ship type with its own model, and the [`radio_say`](#changing-what-the-radio-says) hook |
| [`trent`](../../examples/mods/trent) | The game's text in [the records](#the-records), changed from a load script, beside face films that replace the game's |
| [`wingmen`](../../examples/mods/wingmen) | [Object scripts](#object-scripts), [events](#events), [interfaces](#interfaces), `nearby` and an [options](#options) page |

## Kinds of scripts

| Kind | In `mod.ini` | When it runs | What it's for |
|---|---|---|---|
| Load | `Load=` under `[Scripts]` | Once, when OpenReliant starts, before the main menu | Changing [the records](#the-records), declaring [options](#options) and [game modes](#game-modes) |
| Global | `Global=` under `[Scripts]` | For the whole game | [Hooks](#hooks), [orders](#orders) and the mission's objects |
| Mission | The mission's file name under `[Missions]` | While that mission runs | The same as global scripts, for one mission |
| Object | A class, such as `Fighter=`, or a type, such as `Type.predator=`, under `[Scripts]` | On each object of that class or type, while it's in the mission | [Object scripts](#object-scripts) |
| Missile | `Missile=` under `[Scripts]` | On each missile, from its launch to the end of its flight | [Missile scripts](#missile-scripts) |
| Turret | `Turret=` under `[Scripts]` | On each turret of each object, while the object is in the mission | [Turret scripts](#turret-scripts) |
| Player | `Player=` under `[Scripts]` | For the whole game, even while it's paused | [What the player sees and does](#player-and-menu-scripts) in flight |
| Menu | `Menu=` under `[Scripts]` | From OpenReliant's start until it quits: in the menus, the rooms, the movies and the loading screens, and over the missions | [Drawing over the menus](#player-and-menu-scripts), [replacing screens](#replacing-a-screen), [actions](#keys-and-actions), options and game modes |

```ini
[Scripts]
Load=balance.luau
Global=rules.luau, wingmen.luau
Fighter=wingman.luau
Type.reliant=reliant.luau

[Missions]
mission2.dte=escort.luau
```

- A key can list several scripts, separated by commas. They run in that order, after the scripts of
  the mods before ([Load order](modding.md#load-order)).
- A game starts when you start a campaign, load a saved game, or fly a mission on its own (INSTANT
  ACTION, the simulator, a game mode or `--mission`), and ends at the main menu. Global scripts
  start again with each game. For a loaded game, they start from the state they saved with it
  ([Saved games](#saved-games)).
- `[Missions]` matches the mission's file name in any case: `mission2.dte` is mission 2, and
  `mission251.dte` the second part of mission 25. A mission script starts as its mission begins,
  before its ships appear, and stops as it ends. Each attempt starts it again. Mission scripts are
  global scripts in everything else.
- The classes are `Fighter`, `Capital`, `Support`, `Torpedo`, `Mine`, `Planet`, `Debris` and
  `Other`. A type is `Type.` and its name ([ShipType](reference.md#shiptype)) or its number, such as
  `Type.12`. A ship type a mod adds is named by its qualified name, `Type.teapot:teapot`, or in
  the mod that adds it by its own name, `Type.teapot`. Its number changes with the mods that are
  on, so don't name it by number.
- Each script has its own global variables, and the scripts on each object have their own.

Some functions only work in some kinds of script:

| Function | Scripts |
|---|---|
| `core.register_game_mode`, `settings.register_page` | Load and menu, as OpenReliant starts |
| `input.register_action`, `ui.replace_screen`, `ui.go_to` and the other front end functions | Menu |
| `ui.register_screen` | Player and menu |
| `camera.register_view`, `hud.register_display`, `postprocessing`, `shaders`, `debug` | Player |
| `orders.register`, `object:add_script`, `object:remove_script` | Global and mission |
| Changing records | Load |

[Packages](reference.md#packages) lists which scripts can use each package.

## Packages

`require("name")` runs another script of the same mod once and returns what it returns. The name is
the file name, with or without `.luau`, in any case. `require("openreliant.<name>")` gives one of
OpenReliant's packages, such as `openreliant.hooks` or `openreliant.world`.
[Packages](reference.md#packages) lists them, with what each holds and the kinds of script that can
use it. `require("openreliant.core").version` is OpenReliant's version, such as `"0.7.0"`, for a mod
that needs to know which features it has.

## Values

- Numbers use the game's units ([developer documentation](../README.md)). Positions and velocities
  are Luau vectors, and a velocity is the distance moved in a simulation step, of which there are 25
  a second.
- Values OpenReliant has names for are strings, such as `"fighter"` or `"laser_cannon"`. One
  without a name is a number ([Names of values](reference.md#names-of-values)).
- `math.random` gives the same numbers on every computer for the same game: it is seeded again as
  each mission starts, from the game's random numbers. `math.randomseed` and `os` aren't there.

### Qualified names

What a mod registers or adds gets a qualified name: the mod's folder name, or its archive's name
without `.hog`, a colon, and the name the mod gave it. A gun `banana_gun` in the mod folder
`bananas`, or in `bananas.hog`, is `bananas:banana_gun`, and the camera view `chase` of the mod
`strafe-run` is `strafe-run:chase`. A mod's names stay the same whether it's packed or not.

- Two mods can use the same name for their own things; the qualified names keep them apart.
- The functions that register something return its qualified name. Within the mod, most of them
  also take the name without the prefix.
- Other mods use the qualified name.
- Keep names, not numbers. The numbers OpenReliant gives what mods add change with the mods that
  are on.

## Engine handlers

A script returns a table, whose `engine_handlers` holds the functions OpenReliant calls, such as
`on_update` each frame, or `on_mission_start`. Each one is optional:

```lua
return {
    engine_handlers = {
        on_mission_start = function(mission)
            print("mission " .. mission.number .. " starts")
        end,
        on_update = function(seconds) end,
    },
}
```

| Handler | Scripts | When |
|---|---|---|
| `on_init(data)` | Global, object, player, menu | The script starts |
| `on_save()`, `on_load(saved)` | Global, player | The game is saved, or loaded ([Saved games](#saved-games)) |
| `on_records_loaded()` | Load | Every mod's load scripts have run |
| `on_update(seconds)` | Global, object | Each frame in which game time passes |
| `on_step()` | Global, object | Each simulation step, 25 a second |
| `on_frame(seconds)` | Player, menu | Each frame drawn, even while paused |
| `on_mission_start(mission)`, `on_mission_end(outcome)` | Global, player, menu | A mission starts or ends |
| `on_object_added(object)`, `on_object_removed(object)` | Global | An object joins or leaves the mission |
| `on_added()`, `on_removed()` | Object | The script's object joins or leaves the mission |
| `on_key_press(key)`, `on_key_release(key)`, `on_action(action)` | Player, menu | [Keys and actions](#keys-and-actions) |
| `on_console_command(text)` | Player, menu | A line typed in [the console](#the-console) that isn't one of its commands |
| `on_viewport_resized(width, height)` | Player, menu | The window changes size |
| `on_interface_override(base)` | Global, object, player, menu | [Interfaces](#interfaces) |
| `on_setting_changed(key, value)` | Menu | The player sets one of the mod's [options](#options) |

[Engine handlers](reference.md#engine-handlers) says what each one gets. They're called in the order
the scripts started: the global and mission scripts' first, in load order, then each object's. A
handler that raises an error is logged and isn't called again.

`on_mission_end` gets the mission's `outcome`: its `ending` for the player, such as `"destroyed"` or
`"left"` ([Ending](reference.md#ending)), and the `rating` the mission's script gave it, such as
`"success"` ([Rating](reference.md#rating)).

## Hooks

Global, mission and object scripts add handlers to hooks with `require("openreliant.hooks")`. A hook
is one of:

- **a function of the original game**, by its name, such as `object_damage` or `bullet_fire`.
  The [developer documentation](../README.md) describes them.
- **an order routine**: what a ship does each frame for an order, such as `order_fight`.
- **a mission event**, which a mission's triggers can wait for, such as `destroyed` or `launched`.
- **an engine event**, such as `mission_started` or `object_added`.

The [scripting reference](reference.md#the-games-functions), or `openreliant hooks` in a terminal,
lists them with the fields each handler sees.

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
[`examples/mods/rules`](../../examples/mods/rules) has more.

### Changing a function

For a function, `e` holds its arguments, and changing a field changes what it does. A handler that
returns `false` stops the call: the function doesn't run, and neither do the handlers after it.

```lua
-- Every hit does twice the damage, but collisions don't damage the player's ship at all.
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

The game's functions that have hooks:

| Hook | What it is | Filter tests |
|---|---|---|
| `object_damage` | Damage to an object's shield, and what gets through to its armour | `object` |
| `object_armor_damage` | Damage to an object's armour, once its shield is down | `object` |
| `component_damage` | Damage to a component, such as a capital ship's turret | `object` |
| `damage_by_difficulty` | How hard damage lands at the game's difficulty; its result is the damage | `object` |
| `object_destroyed` | An object's pilot ejects, or it explodes | `object` |
| `bullet_fire` | A ship fires a shot | `owner` |
| `missile_launch` | A ship launches a missile at a target | `launcher` |
| `missile_launch_turret` | A missile turret launches a Screamer at a target | `object` |
| `order_push` | An object is given an order, aimed at a target; its result says whether it took | `object` |
| `order_pop` | An object ends the order it runs; its result says whether it had one | `object` |
| `object_orders` | An object runs its order, as it does each frame | `object` |
| `order_retaliate` | A fighter turns on whoever last hit it | `object` |
| `radio_say` | The radio says a line | Only a function filter |
| `vm_command` | The mission's script runs one of its commands; its result is what the command gives | Only a function filter |

### Targets

An order's or a missile's target is a table ([Target](reference.md#target)): `object` and
`component` for a ship, whole where `component` is nil, or the index of one of the mission's
`flight_group`s or `squad`s, and every field nil for nothing. The table can't be changed in place;
a handler sets the field to a new one.

```lua
local hooks = require("openreliant.hooks")

-- Missiles fired at the player's ship are aimed at nothing instead.
hooks.add("missile_launch", function(e)
    if e.target.object and e.target.object.is_player then
        e.target = {}
    end
end)

-- No ship is told to run away.
hooks.add("order_push", function(e)
    if e.order == "run_away" then
        return false
    end
end)
```

`order_push`'s result is `"taken"`, `"refused"` or `"conflict"` ([OrderPushed](reference.md#orderpushed)).
A handler that stops it leaves `"refused"`, and the object's orders stay as they were.

### Changing what the radio says

`radio_say` runs as the radio says a line: from a mission's script, the simulator or the game's
chatter. `e.speech` is the file of the line, such as `ms_hudtr_001.ut`, and `e.film` the film of
the speaker's face. `e.mode` says when it's said: `"now"`, `"queued"` after the lines before it, or
`"if_idle"`, only if the radio has nothing else to say.

- Changing `speech` or `film` says another line, or shows another face.
- Returning `false` drops the line. Whatever waits for it, such as a mission script that waits for
  each line to end, carries on at once.

```lua
local core = require("openreliant.core")
local hooks = require("openreliant.hooks")

-- The simulator's talk about the display (ms_hudtr_001.ut and the lines after it) is skipped in
-- this mod's game mode.
hooks.add("radio_say", function(e)
    if core.game_mode == "teapot:arena" and e.speech:find("ms_hudtr", 1, true) then
        return false
    end
end)
```

[`examples/mods/arena`](../../examples/mods/arena) and [`examples/mods/teapot`](../../examples/mods/teapot)
do this.

### The mission script's commands

`vm_command` runs as a mission's script runs one of its commands. `e.command` names it, such as
`"set_invulnerability"` or `"play_music"` ([MissionCommand](reference.md#missioncommand)), and
`e.arguments` holds its arguments, the first first, with 0 past the ones it takes.

- Returning `false` stops the command, and the script goes on after it.
- The arguments are the script's own values. A ship or a text is the place of its record in the
  mission's file, so most handlers only look at `e.command`, or change a number such as a time.
  The list can't be changed in place; a handler sets `e.arguments` to a new one.
- `e.result` is what the command gives: `"run_on"`, `"wait"`, which ends the script's run until it
  runs next, or a number, the command's value
  ([MissionCommandResult](reference.md#missioncommandresult)).

```lua
local hooks = require("openreliant.hooks")

-- The missions' scripts can't make ships invulnerable.
hooks.add("vm_command", function(e)
    if e.command == "set_invulnerability" then
        return false
    end
end)
```

### Order routines

Each order a ship follows runs routines of the original game: an init as the order starts, an
update each frame, and for a few an exit as it ends. Each routine is a hook, named after the order:
`order_fight_init`, `order_fight` and so on ([The order routines](reference.md#the-order-routines)).
Their handlers see the ship as `e.object`, and `e.object.order` is the order.

```lua
-- Hostile fighters never run away: their Run Away routine does nothing.
hooks.add("order_run_away", function(e)
    return false
end, { side = "hostile", class = "fighter" })
```

- Returning `false` from an update skips the routine for that frame. The ship keeps the order.
- Launching, landing, docking, jumps, gates and explosions are all orders, so their routines'
  hooks change them, such as `order_jump_out_init` or `order_explode`. `order_push` can refuse
  the order before it starts.
- Where OpenReliant doesn't run a routine yet, its handlers still run.
- These hooks change the game's orders. To add an order of your own, see
  [Custom AI orders](#custom-ai-orders).

### Mission and engine events

An event's fields can only be read, and a handler returning `false` only stops the handlers after
it. Events have no `hooks.after`.

- **Mission events** ([The mission's events](reference.md#the-missions-events)), such as
  `destroyed`, `launched` and `docked`, come for the ships the mission's file lists, whether or not
  a trigger waits for them. The exceptions are `proximity_close` and `proximity_general`, which
  tell of a ship close to another: the game looks for them once a second, and only while one of
  the ship's triggers waits for them.
- **Engine events** ([The engine's events](reference.md#the-engines-events)) are
  `mission_started`, `mission_ended`, `object_added`, `object_removed`, `order_started`,
  `order_ended` and `trigger_fired`, the last for each of the mission's triggers that fires.

### Filters

A third argument limits a handler to the objects it's for. The engine checks it without calling the
handler, so the game doesn't slow down for the rest:

```lua
-- The Reliant and the Yamato take half the damage.
hooks.add("object_damage", function(e)
    e.value *= 0.5
end, { type = { "reliant", "yamato" } })
```

The filter takes `object` (a handle), `type`, `class` and `side`, each a name or a list of names;
every test given must hold. It tests the hook's main object, which the table above names: `object`
for most hooks. A filter can also be a function, which gets `e` and returns `true` for a call the
handler is for. `radio_say` and `vm_command` concern no object, so they only take a function.

### Order, removal and errors

- Handlers run newest mod first (the mod that loads last), and within a mod in the order they were
  added. So a later mod's handler that returns `false` stops an earlier mod's.
- `hooks.add` and `hooks.after` return a handle, and `handle:remove()` removes the handler.
- A handler that raises an error is logged with its file and line, and removed, and the changes it
  made to `e` are undone.

## Objects

Scripts see objects (ships, stations, nav points) as handles, such as `e.object`. Every script can
read their fields, such as `type`, `side`, `position` or `hull`. [Objects](reference.md#objects)
lists the fields and the methods.

```lua
-- In a global script: every hostile fighter turns on the player.
local world = require("openreliant.world")
for _, object in world.objects() do
    if object.class == "fighter" and object.side == "hostile" then
        object:give_order("fight", world.player)
    end
end
```

- The same object always gives the same handle, so `==` compares objects, and handles work as table
  keys.
- A handle is valid until its object leaves the mission or the mission ends. Reading a field of one
  that isn't valid is an error. `object:is_valid()` tells which.
- `openreliant.world` gives global scripts `world.objects()`, the missiles in flight as
  `world.missiles()`, the player's ship as `world.player`, and the mission as `world.mission`, with
  its `number` and its `file`'s name.
- `type` is a name such as `"predator"`, or the qualified name of a mod's type, such as
  `"teapot:teapot"`.
- `shields` and `armor` give each quadrant: `left`, `right`, `fore` and `aft`. `hull` is the share
  of armour left in the weakest quadrant, from 1 down to 0.

Global scripts can change many of an object's fields on any object, and an object script can change
them on its own object. The [reference](reference.md#objects) marks each with *Changes*:

- `throttle`: 1 is full, 2 the afterburner and -1 reverse thrust.
- `roll_input`, `pitch_input` and `yaw_input`: how hard it turns, from -1 to 1.
- `pilot`: the pilot who flies it, whose record sets how it flies and fights. A pilot of the game's
  by number, a mod's pilot by its qualified name, or `"none"`.
- `position`, `orientation` and `velocity`: setting the first two moves or turns it at once, and
  setting its velocity pushes it.
- `side`, `shields`, `armor`, `afterburner_fuel` and `countermeasures`. Shields and armour go from 0
  up to what a whole ship of the type has.
- What a mission's commands set: `invulnerable`, `cloaked`, `targetable`, `lights`, `disabled`,
  `guns_disabled`, `missiles_disabled`, `engines_disabled`, `eject_disabled`, `do_not_disturb` and
  `avoidance_disabled`.

An order usually sets the throttle and the turning each frame, so a change to those lasts until the
order sets them again. To change what a ship does, give it an order ([Orders](#orders)).

```lua
-- In a global script: a mod's pilot flies every enemy fighter.
local world = require("openreliant.world")
for _, object in world.objects() do
    if object.class == "fighter" and object.side == "hostile" then
        object.pilot = "bananas:trooper"
    end
end
```

[`examples/mods/bananas`](../../examples/mods/bananas) does this every half second in its game
mode, so that fighters that join the mission later get the pilot too.

### Where things are

`orientation` is where an object's axes point: `right`, `down` and `forward`, in the game's frame,
where Y points down. `openreliant.util` turns points between the world and an object's own frame,
and works with orientations and angles:

```lua
local util = require("openreliant.util")
local world = require("openreliant.world")

-- How far off the player's nose its last attacker is, in degrees, and whether it's above.
local player = world.player
local attacker = player.last_attacker
if attacker then
    local off = math.deg(util.angle_off(player.position, player.orientation, attacker.position))
    local above = util.to_local(player.position, player.orientation, attacker.position).y < 0
end

-- A point 100 units ahead of the player, and an orientation that looks at the attacker.
local ahead = util.to_world(player.position, player.orientation, vector.create(0, 0, 100))
local facing = util.look_at(attacker.position - player.position)
-- The same orientation turned 10 degrees to the right, about its own Y axis.
local right = util.turn(facing, "y", math.rad(10))
```

`util.angles` and `util.from_angles` turn an orientation into pitch, yaw and roll and back, and
`util.normalize_angle` brings an angle within half a turn either way.

## Object scripts

An object script runs on one object, from when the object is added to the mission until it
leaves, or the mission ends. The manifest starts it on every object of a class or a type, and a
global script starts it on one object with `object:add_script(name, data)`, which passes `data` to
its `on_init`. `object:remove_script(name)` stops it. `require("openreliant.self")` gives the
script its own object.

```lua
-- wingman.luau, listed as Fighter=wingman.luau: a badly damaged wingman runs from its attacker.
local self = require("openreliant.self")

return {
    engine_handlers = {
        on_update = function()
            if self.is_player or self.side ~= "friendly" or self.order == "run_away" then return end
            if self.hull < 0.3 and self.last_attacker then
                self:give_order("run_away", self.last_attacker)
            end
        end,
    },
}
```

- The script gets `on_init` and then `on_added` as it starts, and `on_removed` as its object leaves
  the mission. As a mission ends, its objects' scripts stop without `on_removed`.
- Each object's scripts have their own globals, so the same script on two ships keeps two sets of
  variables.
- `self:hook(name, handler)` adds a handler for the calls that concern the object only, like
  `hooks.add` with the object as the filter.
- `require("openreliant.nearby").objects(radius)` gives the objects within `radius` of the script's
  object, nearest first.

A global script can start an object script on any object it chooses, such as each ship of a type
a mod adds:

```lua
return {
    engine_handlers = {
        on_object_added = function(object)
            if object.type == "teapot:teapot" then
                object:add_script("teapot_ship.luau")
            end
        end,
    },
}
```

### Missile scripts

A missile script runs on one missile, from its launch until its flight ends, as it strikes
something, runs out of time or is set off, or until the mission ends. `Missile=` starts it on every
missile, and `require("openreliant.self")` gives it its missile, a handle
([Missiles](reference.md#missiles)) with the missile's `type`, `launcher`, `target`, `position` and
`velocity`.

```lua
-- Raptors fired at the player's ship turn to the nearest other ship of the player's side, if any.
local self = require("openreliant.self")
local nearby = require("openreliant.nearby")

return {
    engine_handlers = {
        on_added = function()
            local player = self.target.object
            if self.type ~= "raptor" or not (player and player.is_player) then return end
            for _, other in nearby.objects(20000) do
                if other.side == player.side and not other.is_player then
                    self.target = { object = other }
                    return
                end
            end
        end,
    },
}
```

- The script gets `on_init` and `on_added` as the missile is launched, its target set, and
  `on_removed` as its flight ends. As a mission ends, its missiles' scripts stop without
  `on_removed`.
- Each missile's scripts have their own globals, as each object's have.
- `self.target` can be set to aim the missile elsewhere, `position`, `orientation` and `velocity`
  to move, turn or push it, and `self:detonate()` ends its flight at once. Global scripts can do all
  of these to any missile.
- `nearby.objects(radius)` gives the objects around the missile, nearest first.
- Global scripts hear of each missile with the events `missile_added` and `missile_removed`.

### Turret scripts

A turret is one of a ship's guns that turns to aim (`"aimed"`), spins its barrels while the ship
fires (`"spinning"`), or launches missiles (`"launcher"`). A turret script runs on one turret while
its ship is in the mission: `Turret=` starts it on every turret of every ship as the ship is added,
after the ship's own scripts. `require("openreliant.self")` gives it its turret, a handle
([Turrets](reference.md#turrets)) with its `object`, its `kind`, its `gun_type`, its `position` and
its `target`.

```lua
-- Missile turrets on the Coalition's capital ships hold their fire for the player's ship.
local self = require("openreliant.self")

return {
    engine_handlers = {
        on_update = function()
            if self.kind ~= "launcher" or self.object.side ~= "hostile" then return end
            local aimed = self.target and self.target.object
            if aimed and aimed.is_player then self.target = nil end
        end,
    },
}
```

- The script gets `on_init` and `on_added` as its ship is added, and `on_removed` as the ship leaves
  the mission. A turret destroyed with its base stays: `self.destroyed` becomes true, and it turns
  and fires no more.
- Each turret's scripts have their own globals.
- Setting `self.target` aims an aimed turret or a missile turret; nil leaves it to look for a target
  of its own. A spinning gun fires where its ship points, so it has no target.
- `object:turrets()` gives global scripts the turrets of any object.

## Orders

A ship does what its orders say. `object:give_order(order, target)` gives it one, by the order's
name ([Order](reference.md#order)) or a mod's order by its qualified name, aimed at `target` or at
nothing. The new order goes on top of the ship's orders, as a mission's SetAI does, and the ones
below carry on as it ends. Global scripts can give any object orders, and an object script its own
object.

A third argument aims the order at one part of `target`, as a mission's orders can: for a Launch,
the carrier's launch gate, counting from 0, and for a Dock, its port. A ship given a Launch waits at
its gate until `object:start_launch()` starts it, as a mission's StartLaunch does:

```lua
local ship, carrier = world.objects()[2], world.objects()[1]
ship:give_order("launch", carrier, 1)  -- waits at the carrier's second gate
ship:start_launch()                     -- and goes, after a short random wait
```

`openreliant.orders` shows and ends them:

```lua
local orders = require("openreliant.orders")
local world = require("openreliant.world")

-- What a ship is doing, from the top order down.
local ship = world.objects()[2]
for _, entry in orders.stack(ship) do
    print(entry.order, entry.target)
end
orders.cancel(ship)  -- ends the top order; the one below carries on
orders.clear(ship)   -- drops all of them, as a mission's ClearAI does
print(orders.info("fight").priority)
```

### Custom AI orders

Global and mission scripts can register an order of their own with `orders.register(name,
definition)`. It returns the order's qualified name, which `give_order` takes. A mission script's
orders end with its mission.

```lua
-- pulse.luau, from examples/mods/custom-order: a short burst of throttle.
local orders = require("openreliant.orders")
local world = require("openreliant.world")
local elapsed = {}

local pulse = orders.register("pulse", {
    flags = { avoidance = true },
    init = function(ship)
        elapsed[ship] = 0
    end,
    update = function(ship, target, seconds)
        elapsed[ship] += seconds
        ship.throttle = 0.25
        return elapsed[ship] < 2
    end,
    exit = function(ship)
        elapsed[ship] = nil
        ship.throttle = 0
    end,
})

-- Elsewhere: world.objects()[2]:give_order(pulse)
```

- `update` is required. It runs each frame for each ship that follows the order, with the ship, its
  target (nil for none, or for a flight group), and the seconds of game time. Returning `false`
  ends the order; returning nothing or `true` carries on.
- `init` runs as the order starts or starts again, and `exit` as it ends or another order replaces
  it. A one-shot order runs only `update`.
- `priority` is 0 by default, for an order that any other order replaces. Once an order with a
  higher priority has started, only an order of higher priority, a one-shot order or `explode`
  replaces it, as with the game's orders.
- `flags` ([OrderFlags](reference.md#orderflags)) are each false by default: `players`, for an
  order the player's ship can be given; `one_shot`, for one that runs its update once and ends;
  `retaliate`, to let the ship turn on whoever hits it hard enough; `avoidance`, to watch for
  objects the ship could hit while it follows the order; and `send_flight`, to send the ship's
  steering and speed to the other players in a multiplayer game.
- The functions can steer the ship, but can't give or end orders or register another. To do
  something later, send an [event](#events).
- Keep each ship's state in a table keyed by the ship, as above, and clear it in `exit`.
- A function that fails turns its order off: the ships following it drop it, and their orders below
  carry on.
- The order goes away when the scripts that registered it stop or reload. A loaded saved game starts
  the global scripts again, and they register their orders again.

## Events

Scripts send each other events: `core.send_global_event(name, data)` to the global and mission
scripts, and `object:send_event(name, data)` to the scripts of one object. Global, mission and
object scripts handle them in the `event_handlers` they return, by the event's name:

```lua
-- The wingman's script tells the global scripts it has fled.
local core = require("openreliant.core")
local self = require("openreliant.self")
core.send_global_event("WingmanFled", { ship = self })

-- A global script hears it.
return {
    event_handlers = {
        WingmanFled = function(data)
            print(tostring(data.ship) .. " has fled")
        end,
    },
}
```

- An event arrives at the next update, before the scripts' `on_update`.
- Player and menu scripts send events to the global scripts too, which is how they change the
  game. They don't receive events: to show the game's state, a global script writes it to a
  [game section](#storage), and the player script reads it each frame, as
  [`examples/mods/arena`](../../examples/mods/arena) does.
- `data` must be plain data: nil, booleans, numbers, strings, vectors, objects, and tables of these.
  It's copied as it's sent, so changing the table afterwards changes nothing.
- Each script with a handler for the event gets it, newest mod first. A handler that returns `false`
  stops the rest.

## Interfaces

A script offers functions to other scripts by returning `interface_name` and `interface`.
Other scripts reach it through `require("openreliant.interfaces")`, as `I.<name>`:

```lua
-- In mod A's global script.
local fled = 0
return {
    interface_name = "Wingmen",
    interface = { fled = function() return fled end },
    event_handlers = { WingmanFled = function() fled += 1 end },
}

-- In another mod's global script.
local I = require("openreliant.interfaces")
if I.Wingmen and I.Wingmen.fled() > 2 then
    -- ...
end
```

- Global and mission scripts see each other's interfaces. The scripts on an object see the
  interfaces of the other scripts on that object, and player and menu scripts see each other's.
- An interface that nobody offers is nil.
- A later script that offers the same name takes its place, and gets the earlier interface in its
  `on_interface_override(base)` handler, so it can call through to it.

### Built-in interfaces

`I` also holds groups of the packages' functions, under names that suit what a mod does:

| Group | What it holds | Scripts |
|---|---|---|
| `Flight` | The orientation and frame functions of `util` | All |
| `AI` | `orders`, and `give_order(ship, order, target, component)` | Global, object |
| `Combat`, `Weapons` | `add_hook` and `after_hook`, which are `hooks.add` and `hooks.after` | Global, object |
| `Carriers` | `give_order`, `start_launch`, `add_hook` and `after_hook` | Global, object |
| `Camera`, `HUD` | The `camera` and `hud` packages | Player |
| `Controls`, `Audio` | The `input` and `audio` packages | Player, menu |
| `FrontEnd` | The `ui` package | Player, menu |
| `Missions` | The `world` package | Global |
| `Campaign` | `world.mission` and `core.send_global_event` | Global |

`Campaign` is about the mission that runs, not about a mod's [campaigns](#campaigns). A group a
script can't use is nil, and its functions keep the rules of their packages. A mod can offer an
interface under a group's name, such as `interface_name = "Flight"`, which then takes its place for
the scripts that see it, and gets the built-in group in `on_interface_override(base)`. When it
stops, the built-in group comes back. [Built-in interfaces](reference.md#built-in-interfaces) lists
each group's functions, and [`examples/mods/strafe-run`](../../examples/mods/strafe-run) uses
them.

## The records

`require("openreliant.records")` gives the game's records. Load scripts can change them; other
scripts can only read them.

| Table | Contents | First number | Names |
|---|---|---|---|
| `ships` | Ship stats, `shipstats.bin`, then the types the mods add | 0 | The ship types OpenReliant has names for, such as `predator`, and the qualified names of the types the mods add, such as `teapot:teapot` |
| `guns` | Gun stats, `gunstats.bin`, then the guns the mods add | 1 | `laser_cannon`, `pulse_cannon` and the rest, and the qualified names of the mods' guns |
| `missiles` | Missile stats, `missilestats.bin`, then the missiles the mods add | 0 | `screamer`, `raptor` and the rest, and the qualified names of the mods' missiles |
| `pilots` | Pilot stats, `pilotstats.bin`, then the pilots the mods add | 0 | The qualified names of the mods' pilots |
| `text` | The game's text, `language.dll`, by string id | 1 | |
| `itac_text` | The ITAC's text, `itaclang.dll`, by string id | 1 | |

Records are looked up by number or by name, with the field names of the [stat
tables](../formats/stats.md). The definitions file for editors ([Editors](#editors)) lists every
field of `Ship`, `Gun`, `Missile` and `Pilot`.

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
- Records can't be removed, because missions refer to them by number.
- A load script that fails has its changes undone, and the next one runs.
- `on_records_loaded` runs once every mod's load scripts have run, so a mod can adjust what the
  mods before and after it changed ([`examples/mods/balance`](../../examples/mods/balance)).

### Mods' records

A mod adds a record by adding a ship type, a gun, a missile or a pilot in its manifest ([New ships,
guns, missiles and pilots](modding.md#new-ships-guns-missiles-and-pilots)). The record starts as a
copy of its base's, and a load script tunes it by its qualified name:

```lua
-- records.luau, from examples/mods/bananas.
local records = require("openreliant.records")

-- The Banana Gun's shots fly faster and hit harder than the Pulse Cannon's.
local gun = records.guns["bananas:banana_gun"]
gun.speed *= 1.5
gun.damage.shield *= 1.5
gun.damage.hull *= 1.5

-- A Banana locks on in half the time of a Bandit.
local missile = records.missiles["bananas:banana"]
missile.lock_time = math.floor(missile.lock_time / 2)

-- The Trooper flies like a beginner.
local trooper = records.pilots["bananas:trooper"]
trooper.tier_b = "level_0"
trooper.skill = "low"
```

Wherever scripts see a ship type, a gun, a missile or a pilot, a built-in one is OpenReliant's name
for it, such as `"predator"`, or a number where it has none. One a mod adds is its qualified name,
such as `"teapot:teapot"`. A pilot is a number, `"none"`, or the qualified name of a mod's pilot.
[`examples/mods/interceptor`](../../examples/mods/interceptor) tunes a mod's ship type.

## Saved games

The game is saved between missions: in the Reliant's rooms, and by the autosave as the campaign
moves on. Global and player scripts save their state in a file next to the saved game
(`saves\<call sign>GAME<slot>.scripts`), so the saved game itself stays as the original writes it:

```lua
local missions = 0

return {
    engine_handlers = {
        on_mission_start = function()
            missions += 1
        end,
        on_save = function()
            return { missions = missions }
        end,
        on_load = function(saved)
            missions = saved and saved.missions or 0
        end,
    },
}
```

- `on_save` returns plain data ([Events](#events)), which is kept with the saved game.
- When a saved game is loaded, the scripts start again, and each gets `on_load` with what its
  `on_save` returned, in place of `on_init`. A script that didn't run when the game was saved, such
  as one of a mod added since, gets `on_init` instead.
- The same goes for the restart point. The scripts' state is kept as each mission of the campaign
  starts, and a replay or the pause menu's RESTART puts it back, so that the scripts start the
  mission again as they were.
- Mission and object scripts don't run between missions, so they aren't kept. Menu scripts run
  across games, so they aren't kept either.

[`examples/mods/tally`](../../examples/mods/tally) keeps a tally with each saved game.

## Storage

`openreliant.storage` gives each mod named sections of plain data, which you read and change like
tables:

```lua
local storage = require("openreliant.storage")
local tally = storage.game_section("tally")
local best = storage.global_section("best")

tally.kills = (tally.kills or 0) + 1
if tally.kills > (best.kills or 0) then
    best.kills = tally.kills
end
for name, value in tally do
    print(name, value)
end
```

- A game section goes with the saved game and the restart point, and starts empty with each new
  game. Global and object scripts change it; the other scripts can only read it.
- A global section is kept in the game folder, in `storage\<mod>.data`, across every game. Any
  script can change it. OpenReliant writes the sections that changed at most every 2 seconds, and
  as it quits.
- The global section called `settings` holds the mod's options ([Options](#options)), and
  `global_section` doesn't open it.
- Each mod has its own sections: two mods' sections of the same name are separate. All of a mod's
  scripts see the same sections.
- Values are plain data, copied as they're stored and as they're read, so changing a table read
  from a section changes nothing until it's stored again. Setting a field to nil removes it.

## Timers

`openreliant.async` runs one of the mod's functions after a delay:

```lua
local async = require("openreliant.async")

async.register_timer("reinforce", function(data)
    print("wave " .. data.wave)
end)

async.after(30, "reinforce", { wave = 2 })
```

- A timer names a function rather than holding it, so that it can be kept with the saved game.
  Register the function when the script runs, at its top level, so that it's there again after a
  load.
- A timer only runs a function registered by scripts of the same kind in the same mod, and for an
  object script, on the same object. A player script can't run a function the mod's global script
  registered.
- Global and object scripts' timers count game time, which stops while the game is paused. Player
  and menu scripts' timers count real time.
- A timer runs at the first update after its time is up, before `on_update`; for player and menu
  scripts, at the next frame, before `on_frame`. It gets its data, which must be plain data.
- Global and player scripts' timers are kept with the saved game and the restart point. An object
  script's timers stop as its object leaves the mission.

## Player and menu scripts

Player and menu scripts decide what the player sees, hears and does. They run separately from the
game's scripts: they can read objects, but change the game only by sending
[events](#events) to the global scripts.

```lua
-- clock.luau, listed as Player=clock.luau: the time spent flying, over the flight display.
local hud = require("openreliant.hud")
local flown = 0

return {
    engine_handlers = {
        on_frame = function(seconds)
            if not hud.shown then return end
            flown += seconds
            hud.text(vector.create(16, 16, 0), string.format("%.0f s", flown), {
                colour = vector.create(0.4, 1, 0.4),
            })
        end,
        on_key_press = function(key)
            if key == "f9" then flown = 0 end
        end,
    },
}
```

- `on_frame` runs each frame drawn, even while the game is paused, with the seconds of real time
  since the last.
- For a player script, `require("openreliant.self")` gives the player's ship (nil between games),
  and `openreliant.nearby` the objects around it.
- Player and menu scripts run, and draw with `ui` over the screen, in the briefing, the loadout,
  the ITAC and the other rooms, over the movies and over the loading screens too.

[`examples/mods/dvd`](../../examples/mods/dvd) draws over the menus, and
[`examples/mods/wingmen`](../../examples/mods/wingmen) over the flight display.

### Drawing

`openreliant.hud` draws over the flight display, and `openreliant.ui` over the menus: the front
end's screens and the pause menu. Both have `text`, `line`, `rectangle`, `picture` and `shape`, and
`measure` for the size of a text.

- Draw in `on_frame`, or in a registered display's or screen's `frame`: each frame starts with
  nothing drawn. Drawing at any other time is an error.
- `shown` says whether the display or the menu shows this frame. Check it before drawing.
- Places are in the window's pixels from its top left corner, and `width` and `height` give the
  window's size.
- Each function takes a style table, whose fields are all optional
  ([Tables](reference.md#tables)): `colour` (a vector of red, green and blue from 0 to 1) and
  `alpha` for all of them, `width` for a line, `scale`, `align` (`"left"`, `"centre"` or
  `"right"`), `font` and `base_font` for text.
- Text is drawn in the game's font, at the game's text size times the style's `scale`, unless the
  style picks another font ([Pictures, shapes and fonts](#pictures-shapes-and-fonts)).

### Pictures, shapes and fonts

`hud` and `ui` can draw the mod's PNG pictures and the game's shapes, and text in the mod's fonts:

```lua
local ui = require("openreliant.ui")

return {
    engine_handlers = {
        on_frame = function()
            if not ui.shown then return end
            ui.picture(vector.create(20, 30, 0), "badge.png", vector.create(64, 64, 0), { alpha = 0.8 })
            ui.shape(vector.create(100, 30, 0), 1, { scale = 1, colour = vector.create(1, 1, 1) })
            local style = { font = "menu_large", scale = 1.5 }
            local size = ui.measure("Flight status", style)
            ui.text(vector.create(20, 110, 0), "Flight status", style)
        end,
    },
}
```

- **Pictures** are PNG files in the mod, named without folders. `size` is in window pixels; without
  it, the picture is drawn at its own size. The style's `colour` and `alpha` tint it.
- **Shapes.** A shape number picks a shape from the game's current sprite set: the flight display's
  set for `hud`, or the current menu screen's set for `ui` ([Shapes](modding.md#shapes)). Each shape
  keeps its own anchor point, and is drawn at the game's scale times the style's `scale`. A set
  that isn't loaded, or a shape it doesn't have, is an error.
- **Fonts.** A text style's `font` is one of the game's, `"default"`, `"hud"`, `"menu_small"` or
  `"menu_large"`, or a font file in the mod. A `.fnt` file draws as the game's bitmap fonts do. A
  `.ttf` or `.otf` file needs OUTLINE FONTS on under VIDEO. Its letters are laid out with the
  spacing of the built-in font that `base_font` names, `"default"` unless given, which also draws the
  characters the file doesn't have.
- `measure` takes a text style, or just a number for its scale, and measures as `text` draws.
- A reload reads the files again. All the mods' pictures and fonts together can use up to 128 files
  and 64 MiB. A missing, broken or oversized file is an error in the script.

[`examples/mods/drawing-assets`](../../examples/mods/drawing-assets) draws each of them.

### HUD displays

A player script can register a display, which draws over the flight display each frame:

```lua
local hud = require("openreliant.hud")

local status = hud.register_display("status", {
    frame = function(seconds)
        hud.text(vector.create(20, 30, 0), "Shift F12: strafe run")
    end,
})
hud.set_display_enabled(status, false)  -- hides it until it's turned on again
```

While the flight display shows, each enabled display draws in the order it was registered, after
the scripts' `on_frame`. A display whose `frame` fails is turned off; the others carry on.

### Screens

A player or menu script can register a screen: a panel that draws with `ui` and gets the keys while
it's shown.

```lua
local ui = require("openreliant.ui")

local help = ui.register_screen("help", {
    frame = function(seconds)
        ui.rectangle(vector.create(20, 60, 0), vector.create(500, 160, 0), { alpha = 0.8 })
        ui.text(vector.create(30, 70, 0), "Escape closes this panel.")
    end,
    key = function(key, down)
        if key == "escape" and down then ui.show_screen(nil) end
    end,
})
ui.show_screen(help)
```

- `ui.show_screen(name)` shows a screen, and `ui.show_screen(nil)` closes it. One shows at a time.
- In flight, a shown screen draws over the flight display. The game's controls still get the keys.
- A screen whose `frame` or `key` fails closes, and so does a screen whose scripts stop.
- A menu script can also make a screen take the place of one of the front end's
  ([Replacing a screen](#replacing-a-screen)).

### Camera views

A player script can register a camera view, which places the camera each frame:

```lua
local camera = require("openreliant.camera")
local util = require("openreliant.util")

local chase = camera.register_view("chase", {
    frame = function(ship, seconds)
        return {
            position = util.to_world(ship.position, ship.orientation, vector.create(0, -200, -1000)),
            orientation = ship.orientation,
        }
    end,
    letterbox = false,
})
camera.set_view(chase)          -- looks at the player's ship
camera.set_view("cockpit")      -- back to the cockpit
```

- `frame` gets the object the view looks at and the seconds since the last frame, and returns the
  camera's `position` and `orientation`. The orientation's axes must be unit length, at right
  angles and right-handed.
- `set_view(view, object)` switches to a view of `object`, or of the player's ship. It takes the
  game's views by name, such as `"cockpit"`, `"chase"` or `"target"` ([View](reference.md#view)),
  and the mods' by their qualified names. `camera.view` is the view that shows.
- A mod's view is an outside view: it draws no cockpit, and `letterbox` adds bars above and below.
- The game's camera keys and a mission's cutaways override a script's view, and a script can't
  change the view while the mission holds the camera.
- If `frame` fails, or the object leaves the mission, the camera goes back to the cockpit.
- One run of OpenReliant has room for about 200 views, displays and screens together, counting
  the ones registered before a reload. Registering more is an error.

### Keys and actions

`on_key_press(key)` and `on_key_release(key)` hear the keys, by name, such as `"f9"` or `"escape"`
([Key](reference.md#key)). `input.key_down(key)` says whether a key is held.

In flight, `on_action(action)` hears the controls bound to the game's actions, by name, such as
`"fire_lasers"` ([Action](reference.md#action)), and `input.action_down(action)` says whether
they're held.

A menu script can register an action of its own, which the controls screen lists after the game's,
for the player to bind:

```lua
-- action.luau, from examples/mods/custom-order: Shift F12 starts the mod's order.
local input = require("openreliant.input")
local core = require("openreliant.core")

local pulse = input.register_action("pulse", {
    label = "Custom order: throttle pulse",
    key = "f12",
    modifier = "shift",
})

return {
    engine_handlers = {
        on_action = function(action)
            if action == pulse then
                core.send_global_event("CustomOrderPulse", {})
            end
        end,
    },
}
```

- `register_action` returns the action's qualified name, such as `custom-order:pulse`, which
  `on_action` and `action_down` use. Registering the same name twice is an error, even in another
  case.
- The definition needs a `label`, and can give a default `key` with a `modifier` (`"none"`,
  `"shift"` or `"control"`), a joystick `button` and a `gamepad_button`. A default that the game or
  another mod already uses stays unbound.
- The player rebinds, clears and resets the actions on the controls screen, as the game's.
  `starlancer.ini` keeps the bindings by the actions' qualified names.
- A control held when the action registers, or held outside flight, must be released before it
  counts as pressed again.

### Sound

`openreliant.audio` plays sounds, music and Betty's lines:

```lua
local audio = require("openreliant.audio")

audio.play_sound(3, 0.5)              -- the game's standard sound 3, at half volume
audio.play_music("New_Pensive.wav")   -- from the music folder, or a mod's file of that name
audio.say("countermeasures_low")      -- Betty's line
```

- `play_sound` takes the number of one of the game's standard sounds, the menus' and the
  display's. A mod replaces a sound by replacing its file ([Modding](modding.md)).
- `play_music` plays a piece from the game's `music` folder, looping, in place of the music that
  plays.
- `say` takes one of Betty's lines by name ([BettyLine](reference.md#bettyline)).

### Debug drawing

`openreliant.debug` draws lines and text at points of the world, over the flight display, where the
camera sees them. It's for working out what a script does:

```lua
local debug = require("openreliant.debug")
local self = require("openreliant.self")

return {
    engine_handlers = {
        on_frame = function()
            local target = self and self.last_attacker
            if target then
                debug.line(self.position, target.position, { colour = vector.create(1, 0, 0) })
                debug.text(target.position, "attacker")
            end
        end,
    },
}
```

## Menus, game modes and campaigns

A menu script can replace the front end's screens with its own, and a load or menu script can add
game modes, which the main menu's GAME MODES lists. A campaign is a game mode that flies its
missions in order and remembers how far the player got.

### Replacing a screen

`ui.replace_screen(screen, name)` replaces one of the front end's screens, given by its name
([FrontEndScreen](reference.md#frontendscreen)), such as `"main_menu"`, with the mod's registered
screen `name` ([Screens](#screens)). While the front end shows that screen, it runs the mod's screen
in its place: the front end draws the screen's background, the mod's screen draws over it and takes
the keys, and the pointer is drawn on top. `ui.pointer` gives the pointer's place and whether its
left button is down.

```lua
local ui = require("openreliant.ui")

local screen = ui.register_screen("main_menu", {
    frame = function()
        ui.text(vector.create(ui.width / 2, ui.height / 2, 0), "PRESS ENTER", { align = "centre" })
    end,
    key = function(key, down)
        if down and key == "enter" then ui.go_to("pilot_roster") end
        if down and key == "escape" then ui.quit() end
    end,
})
ui.replace_screen("main_menu", screen)
```

- To move on, the mod's screen asks the front end: `ui.go_to(screen)` goes to another of its
  screens (or to the mod's screen that replaces it), `ui.start_game_mode(name)` starts a game
  mode, and `ui.quit()` quits the game. If the front end can't show the screen asked for, nothing
  happens and the log says so.
- `ui.play_movie(name)` plays a Bink movie from the game folder or a mod, such as
  `"thread01.bik"`, on a cleared screen. Escape or the pointer's right button ends it.
- `ui.replace_screen(screen, nil)` gives the screen back to the front end. If the mod's script
  stops, or its screen's callback fails, the front end shows its own screen again.
- These functions are for menu scripts only.

[`examples/mods/main-menu`](../../examples/mods/main-menu) replaces the main menu.

### Game modes

`core.register_game_mode` adds a game mode. The main menu then shows a GAME MODES button, which
opens a list of every mod's modes ([Front end](../engine/front-end.md#the-game-modes-screen)).

```lua
local core = require("openreliant.core")

core.register_game_mode({
    name = "arena",
    label = "ARENA",
    description = "Wave after wave in a Phoenix.",
    missions = { 29 },
    ship = "phoenix",
    loop = true,
})
```

- `missions` are mission numbers, flown in order. Each is a standard `.DTE` file, the game's or a
  mod's, so a mode doesn't change the mission format. A mod brings a mission of its own as a file
  such as `mission90.dte` ([How files are replaced](modding.md#how-files-are-replaced)). A mode has
  up to 64 missions.
- `ship` is the ship the player flies, one of the game's or a mod's by its qualified name, such as
  `"teapot:teapot"`. Without it, each mission's own ship is used.
- Without `loop`, the mode goes back to the main menu after its last mission. With `loop`, it
  starts again from its first mission, until the player leaves a mission from the pause menu.
- Leaving a mission from the pause menu always ends the mode.
- Only load and menu scripts register modes, and only as OpenReliant starts. A mod that is off has
  no modes.
- `core.game_mode` gives the qualified name of the mode that runs, such as `"arena:arena"`, and
  nil otherwise. `core.game_mode_mission` gives the mission the mode is at: its `number`, its
  `place` in the mode from 1, and the `count` of the mode's missions.

Every script can read `core.game_mode`, so a mod's global and player scripts apply its rules only
while its mode runs:

```lua
-- rules.luau, a global script: in the arena, the player's hits count double.
local core = require("openreliant.core")
local hooks = require("openreliant.hooks")

hooks.add("object_damage", function(e)
    if core.game_mode == "arena:arena" and e.attacker.is_player then
        e.value *= 2
    end
end)
```

[`examples/mods/arena`](../../examples/mods/arena) adds a game mode with rules and a HUD of its
own, and [`examples/mods/interceptor`](../../examples/mods/interceptor),
[`teapot`](../../examples/mods/teapot) and [`bananas`](../../examples/mods/bananas) each fly a mode
in a mod's ship.

### Campaigns

A game mode with `campaign = true` is a campaign:

- It flies its missions in order. A lost mission is flown again: the player's ship destroyed, the
  pilot captured or sent home for shooting a friend, or the mission's script rating it a total
  failure.
- The mission the player has reached is kept in the mod's global storage, in the section
  `campaigns`, under the mode's name without the mod's prefix ([Storage](#storage)). GAME MODES
  shows it, and the campaign carries on from it the next time. After the last mission, the campaign
  starts from its first again. A script can set the value, from 0 for the first mission, to move
  the campaign on or back: `storage.global_section("campaigns").tour = 1`.
- A campaign can't loop.

Any game mode can name a `briefing`: the name of one of the mod's registered screens, which the
front end shows before each of the mode's missions. The briefing reads `core.game_mode_mission`
to know which mission is next, flies it with `ui.launch_mission()`, and ends the mode with
`ui.go_to("main_menu")`. Without a briefing, the next mission starts at once.

```lua
local core = require("openreliant.core")
local ui = require("openreliant.ui")

ui.register_screen("briefing", {
    frame = function()
        local mission = core.game_mode_mission
        ui.text(vector.create(ui.width / 2, 100, 0), `MISSION {mission.place} OF {mission.count}`, { align = "centre" })
    end,
    key = function(key, down)
        if down and key == "enter" then ui.launch_mission() end
        if down and key == "escape" then ui.go_to("main_menu") end
    end,
})

core.register_game_mode({
    name = "tour",
    label = "FIRST TOUR",
    missions = { 1, 2, 3 },
    campaign = true,
    briefing = "briefing",
})
```

The missions are flown as INSTANT ACTION flies its mission: without the game's rooms, ITAC,
medals or saved games ([#641](https://github.com/OpenReliant/openreliant/issues/641)).

[`examples/mods/campaign`](../../examples/mods/campaign) is a short campaign of the game's first
three missions, with a briefing and a movie.

## Options

A mod can offer the player options, which the player sets on the mods screen: GAME OPTIONS, then
MODS, then OPTIONS with the mod chosen. A load or menu script declares the mod's page as
OpenReliant starts, with `openreliant.settings`, and any script of the mod reads the values:

```lua
local settings = require("openreliant.settings")

settings.register_page({
    title = "WINGMEN",
    options = {
        { label = "THE PANEL", kind = "heading" },
        { key = "show_panel", label = "SHOW PANEL", kind = "toggle", default = true },
        { label = "IN A FIGHT", kind = "heading" },
        { key = "pull_out_below", label = "PULL OUT BELOW", kind = "choice", default = 0.3,
          choices = { { value = 0.2, label = "20%" }, { value = 0.3, label = "30%" } } },
        { key = "rejoin_after", label = "REJOIN AFTER", kind = "number",
          min = 5, max = 60, step = 5, default = 20,
          description = "The seconds a wingman stays out of the fight." },
        { key = "panel_reach", label = "PANEL REACH", kind = "slider",
          min = 5000, max = 100000, step = 5000, default = 50000 },
        { key = "panel_title", label = "PANEL TITLE", kind = "text", default = "WINGMEN" },
    },
})

local rejoin_after = settings.get("rejoin_after")
```

- A `"toggle"` is a check box, with a boolean default. A `"choice"` steps through its `choices`, each
  a number or a string `value` with the `label` the screen shows, and its default is one of the
  values. A `"number"` steps from `min` to `max` by `step`, and its default is in the range. A
  `"slider"` is a number set by dragging a knob, for a wide range: it takes the same fields, and
  the knob stops on the steps. A `"text"` is a line the player types in a box, of up to 24
  characters, with a string default: a click in the box starts typing, Enter or a click elsewhere
  keeps the line, and Escape puts it back. Each of these needs a `key`, which scripts read it by.
- A `"heading"` has only a `label`, which the list writes in white over the options after it, to
  split a long page.
- An option's `description` shows under the list while the pointer is on it.
- A page has up to 64 options, a choice up to 32 choices, and a mod one page. A mistake in the page
  is an error in the script that declares it.
- Only load and menu scripts declare a page, and only as OpenReliant starts: the pages are fixed
  before the front end shows. A mod that is off has no page until it's turned on and OpenReliant
  has restarted.
- `settings.get(key)` gives what the player set, or the default. A value that no longer suits the
  option, such as a choice the mod has since dropped, reads as the default.
- `settings.set(key, value)` sets one of the mod's own options, as the player does on the mods
  screen, such as from a key the mod binds. A number is held to its range, and a value that doesn't
  suit the option otherwise is an error.
- The player sets options in the front end, before a game starts. A script that runs in a game
  reads them as it starts. A menu script can also hear a change at once, with the engine handler
  `on_setting_changed(key, value)`.
- The values are kept in the mod's global storage, in a section of its own that
  `storage.global_section` doesn't open. A value that is the default isn't kept.
- A key the player sets is an action the mod registers, which the controls screen binds
  ([Keys and actions](#keys-and-actions)), rather than an option.

[`examples/mods/wingmen`](../../examples/mods/wingmen) offers five options under two headings.

## Post effects

A player script can draw a post effect over the whole frame: a GLSL fragment shader from its mod,
registered with `openreliant.postprocessing`.

```lua
local post = require("openreliant.postprocessing")

post.register({
    name = "crt",
    shader = "crt.frag",
    stage = "after_hud",
    order = 0,
    parameters = { 0.3, 0.08, 0.6 },
})
post.set_parameters("crt", { 0.5, 0.08, 0.6 })
post.set_enabled("crt", false)
```

- `stage` is `"before_hud"` (the default), which draws over the scene before the flight display
  and the menus are drawn, or `"after_hud"`, which draws over everything.
- Within a stage, effects draw by `order`, lowest first. Effects with the same order draw in the
  order they were registered. Each effect reads what the one before it drew.
- `parameters` holds up to four numbers, which the shader reads. Those left out are 0.
- `enabled = false` registers the effect turned off, for `set_enabled` to turn on later.
- `register` returns the effect's qualified name, such as `crt:crt`. `set_enabled` and
  `set_parameters` take the effect's own name or the qualified one.
- The shader compiles when the script registers it. A shader that doesn't compile is an error in
  the script, with the file and the line.
- An effect is removed when the script that registered it stops. If a script fails to load, the
  effects it registered are removed.
- The mods can register at most 64 effects at once.
- Effects draw on the GPU only. With `--software` they register and draw nothing.
- Compiled shaders are kept in the game folder's `cache/shaders`, so a shader compiles again only
  when it or OpenReliant's shader compiler changes. The folder can be deleted at any time.
- In the developer mode, saving a folder mod's shader reloads its scripts, which compiles the
  shader again ([Reloading](#reloading)).
- MOD EFFECTS on the VIDEO tab, `ModEffects` in `starlancer.ini` and `--no-mod-effects` turn all
  the mods' shaders off: their post effects, and their surface and lighting functions. Choosing a
  GRAPHICS preset doesn't change it.

The shader is GLSL 450, and reads:

```glsl
#version 450
// The frame as the effects before this one left it.
layout(set = 2, binding = 0) uniform sampler2D source;
// The frame before any effect.
layout(set = 2, binding = 1) uniform sampler2D frame_image;
layout(set = 3, binding = 0, std140) uniform Frame {
    vec4 size_time;   // x and y: the frame's size in pixels; z: the seconds passed
    vec4 parameters;  // the script's numbers
} frame;
layout(location = 0) in vec2 uv;      // 0 to 1 across and down the frame
layout(location = 0) out vec4 colour;

void main() {
    colour = texture(source, uv);
}
```

A shader file's name ends in `.frag` or `.glsl`. Like scripts, shader files belong to the mod and
don't replace game files. [`examples/mods/crt`](../../examples/mods/crt) draws an old curved
monitor over the game: Shift F8 turns it on and off, and Shift F7 changes the scanlines.

## Surface and lighting functions

A player script can change how surfaces are lit, with GLSL functions from its mod, registered with
`openreliant.shaders`. OpenReliant compiles each into a variant of its own surface shader.

- A **surface function** changes a pixel's colour, normal, roughness, metalness, glow and alpha
  before it is lit. It applies to the textures it lists, by the names the models use, such as
  `Pred_cp01`, in any case. With `everywhere = true`, it also applies to every lit surface in the
  scene that has no surface function of its own. `object:set_surface(name, parameters)` gives one
  object's whole model a surface function, which wins over the functions on its textures, and
  `object:set_surface(nil)` takes it away.
- A **lighting function** changes how much of each light reaches a pixel, on every surface lit for
  each pixel. One draws at a time: the enabled one registered last.

```lua
local shaders = require("openreliant.shaders")
local self = require("openreliant.self")

shaders.register_lighting({ name = "bands", shader = "bands.glsl", parameters = { 3 } })
shaders.register_surface({
    name = "ink",
    shader = "ink.glsl",
    textures = { "Pred_cp01" },
    everywhere = false,
    parameters = { 3, 8 },
})
shaders.set_enabled("bands", false)

return {
    engine_handlers = {
        on_mission_start = function()
            -- The player's ship, which is there once a mission has started.
            self:set_surface("ink", { 2, 8 })
        end,
    },
}
```

The file holds the function alone, without `#version`, and can define helpers before it. A
surface function is called `surface`, and a lighting function `lighting`:

```glsl
// The pixel, which the function reads and sets.
struct Surface {
    vec3 colour;     // the texture's colour, in its sRGB encoding
    float alpha;
    vec3 normal;     // in camera space, unit length; zero for an unlit pixel
    float roughness; // 1 and 0 where the texture has no material maps
    float metallic;
    vec3 glow;       // emitted light, added after lighting; starts as the emissive map's
    vec2 uv;         // read only: the texture coordinates
    vec3 position;   // read only: its position in camera space
    vec3 toEye;      // read only: the direction toward the eye
    vec2 frameSize;  // read only: the frame's width and height in pixels
};

void surface(inout Surface s, vec4 parameters, float time) {
    s.glow = vec3(0.0, 0.2, 0.0) * (0.5 + 0.5 * sin(time));
}

// cosine: from 0 to 1, between the pixel's normal and the light. Returns how much of the light
// reaches the pixel; `return cosine;` changes nothing.
float lighting(float cosine, vec4 parameters) {
    return ceil(cosine * parameters.x) / parameters.x;
}
```

- `time` is the seconds passed, and `parameters` the script's numbers. Those left out are 0.
- `s.frameSize` is the size of the frame the pixel is drawn into, which `gl_FragCoord` counts in.
  An effect in screen space, such as scan lines, divides by it to look the same at any resolution:
  `gl_FragCoord.y / s.frameSize.y` runs from 0 to 1 up the frame.
- The functions can call the shader's own helpers, such as `encoded` and `decoded`, which turn a
  colour into and out of linear light.
- If the function sets roughness or metalness on a surface without material maps, the surface is lit
  as a material ([Material maps](modding.md#material-maps)).
- Alpha shows on surfaces the game blends, such as glass and effects. A function registered with
  `see_through = true` also makes the solid surfaces it draws on objects and textures blend by the
  alpha it sets, sorted with the game's other blended draws. They still write depth, as a solid
  model does, so that of two models that cut into each other the nearer hides the other. Set
  `writes_depth = false` for something with no solid shape, such as a glow or a cloud. A function
  that applies `everywhere` leaves the surfaces solid.
- A lighting function only changes surfaces lit for each pixel, with PER-PIXEL LIGHTING. It changes
  the light falling on them, not their highlights.
- Give helper functions names unique to your mod. The lighting function and a surface function can
  come from different mods, and they are compiled into one shader. If they don't compile together,
  the log says so, and that surface function's surfaces draw without it.
- Each registration compiles the function on its own, and a mistake in it is an error in the
  script, with the file and the line. Compiled variants are kept in the shader cache.
- `enabled = false` registers a function turned off.
- The rules for names, removal, reloading and MOD EFFECTS are those of [post effects](#post-effects).
  The mods can register at most 64 functions at once.

[`examples/mods/cel-shading`](../../examples/mods/cel-shading) draws the ships as a cartoon: a
lighting function makes each light fall in flat bands, and a surface function on every lit surface
draws a dark line round the outlines. Shift F6 turns it on and off, and Shift F5 changes the
number of bands.

## Replacing OpenReliant's shaders

A mod can replace one of OpenReliant's shaders with its own, without a script: a file at the top
level of the mod with the same name as one of OpenReliant's shaders.

| File | What it draws |
|---|---|
| `device.glsl` | The scene, the flight display and the menus |
| `bloom.glsl` | The bloom, the frame's finish and the gamma ramp, and the vertex stage of post effects |
| `shadow.glsl` | The shadow maps |

Start from OpenReliant's own, in [`src/platform/shaders`](../../src/platform/shaders) of the
version you play. A replacement is at your mod's risk: OpenReliant's shaders change between
versions, and a replacement made for one can stop fitting the next.

- Each file holds a vertex stage and a fragment stage, which it picks with `#ifdef VERTEX` and
  `#ifdef FRAGMENT`, as OpenReliant's do. `#include "colour.glsl"` takes the mod's own
  `colour.glsl`, or OpenReliant's where it has none. Other includes are errors.
- The last mod in the load order that has the file replaces OpenReliant's.
- Both stages compile as OpenReliant starts, through the shader cache, and are checked against
  OpenReliant's own. A replacement may only use textures and uniform blocks that OpenReliant's
  shader binds, with the same types and no larger. It may only read inputs that OpenReliant's shader
  reads, and it must write every output that OpenReliant's shader writes. A fragment stage writes no
  others, and the fragment stage reads only what the vertex stage writes.
- A replacement that doesn't compile or doesn't fit is left out, and OpenReliant uses its own
  shader instead. The log says which file, which stage, and why, with the line of a compile error.
- A replaced `device.glsl` is also the shader the mods' surface and lighting functions are
  compiled into. Keep its hooks (`MOD_SURFACE`, `MOD_LIGHTING`) and the line `// mod_functions`
  for them; without that line the functions draw nothing, and the log says so.
- Replacements are chosen as OpenReliant starts, while MOD EFFECTS is on. Changing MOD EFFECTS
  takes effect for them at the next start.
- They draw on the GPU only. The software device ignores them.

## Files

`openreliant.vfs` reads files. A file comes as a string of its bytes.

- `vfs.read(name)` reads a file the way the game does. It looks in three places in turn: the latest
  mod's copy, the file in the game folder, and the game's `resource.hog`.
  - A mod's file is found by its name alone, so `missions\mission1.dte` finds a mod's
    `mission1.dte`.
  - The game folder's file is found by its path from the game folder, in any case, such as
    `missions\mission1.dte` or `music\theme.wav`. A name without a folder, such as `palette.tga`,
    is looked up in the game folder itself, then in the archive.
- `vfs.read_mod(name)` reads a file of the calling mod.
- Both return nil if there is no such file, or if the name is a folder. `vfs.exists(name)` says
  whether `vfs.read` would find it.
- A script can read a loose file of up to half its mod's memory limit (32 MiB). A bigger file is an
  error.

## The console

The developer mode turns on the tools for writing scripts: the console, and reloading. Turn it on
with `DeveloperMode=1` in the `[OpenReliant]` section of `starlancer.ini`, or with
`--developer-mode` ([Configuration](configuration.md)); it's off by default.

F11 then brings up the console, in the menus, the Reliant's rooms and the briefing, and in flight,
where any mod has scripts. It pauses the mission, and F11, Escape or CLOSE takes it away again. It shows what the scripts print and
their errors, and runs the lines typed into it:

| Command | What it does |
|---|---|
| `help` | Lists the commands |
| `help <name>` | What a package (`storage` or `openreliant.storage`), an engine handler (`on_update`) or a hook (`object_damage`) is |
| `mods` | Lists the mods, and their scripts that run |
| `reload` | Reads the folder mods' scripts again, and starts them again from where they were |
| `clear` | Empties the console |
| `global <mod>`, `player <mod>`, `menu <mod>` | Runs Luau with the mod's global, player or menu scripts, until `exit` |

```text
> global wingmen
wingmen global> player = require("openreliant.world").player
wingmen global> player.hull, player.speed
0.8    120
wingmen global> require("openreliant.interfaces").Wingmen.pulled_out()
2
wingmen global> exit
```

- In Luau, a line runs as an expression where it is one, and its values are shown; otherwise it
  runs as statements. Variables you set stay for the next line, but they are separate from the
  scripts' globals. `require` gives the mod's modules as its scripts have them, and the packages
  its scripts can use.
- Enter or RUN runs the line, Up and Down bring back the lines typed before, and Page Up, Page Down,
  the mouse wheel and the arrows scroll the output.
- Any other line goes to the player and menu scripts' `on_console_command(text)`, so that a mod
  can add commands of its own.

### Reloading

In the developer mode, a folder mod's scripts reload as soon as one of them or one of its shaders
is saved, as `reload` reloads them:

- Global and player scripts start again from their state, as a saved game would keep it
  ([Saved games](#saved-games)): `on_save` runs, and the new scripts get `on_load`.
- Partway through a mission, its mission scripts start again, and so do the scripts on each of its
  objects, with `on_init` and then `on_added`, but no `on_mission_start` or `on_object_added`.
- Menu scripts start again with `on_init`.
- What the scripts registered (views, displays, screens, actions, orders, effects) goes away and is
  registered again as they start, so a changed shader compiles and draws
  ([Post effects](#post-effects)).
- Load scripts and `mod.ini` are read only as OpenReliant starts, so they need a restart. So does
  a file added to a folder mod.

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

Scripts run in a sandbox: they can't use the network or run programs, and the only files they can
read are the game's and the mods' ([Files](#files)). An error in a script never stops the game: it's
logged with the file and the line, and the game carries on.

| What | Limit |
|---|---|
| A call into a script | 1 second in a load script, and 100 milliseconds in any other |
| A mod's scripts' memory | 64 MiB |
| A loose file a script reads | 32 MiB, half of that memory ([Files](#files)) |
| Drawing each frame | 4096 things and 64 KiB of text over the flight display (`hud` and `debug` together), and as much over the menus (`ui`). What's past that isn't drawn |
| The pictures and fonts scripts draw | 128 files and 64 MiB, all mods together ([Pictures, shapes and fonts](#pictures-shapes-and-fonts)) |
| Camera views, HUD displays and screens | About 200 together in one run of OpenReliant, counting the ones registered before a reload ([Camera views](#camera-views)) |
| Post effects | 64 at once, all mods together ([Post effects](#post-effects)) |
| Surface and lighting functions | 64 at once, all mods together ([Surface and lighting functions](#surface-and-lighting-functions)) |
| A mod's options | One page of up to 64 options, a choice of up to 32 choices, and a text of up to 24 characters ([Options](#options)) |
| A game mode's missions | 64 ([Game modes](#game-modes)) |

## When something goes wrong

| In the log | What to check |
|---|---|
| `skipping the mod ...: it needs OpenReliant 0.7.0` | OpenReliant is older than the mod's `OpenReliant=` |
| No `started` line for the script | `mod.ini` lists it under `[Scripts]`, with the file's exact name |
| `there's no hook named '...'` | The hook's name ([the reference](reference.md#the-games-functions)) |
| `... has no field '...'` or `expected a number, got string` | The field's name and type |
| `e can only be used while its handler runs` | Keep values from `e` in variables, not `e` itself |
| `... is an event, whose fields can't be changed` | Events can only be read |
| `... concerns no object to filter by` | That hook only takes a function as its filter |
| `the object is no longer in the mission` | `object:is_valid()` before using a handle kept from earlier |
| `script timed out` | A loop that doesn't end, or does too much at once |
| `... is not available to load scripts` | Load scripts can't use that package |
| `object scripts can't change this object's ...` | An object's scripts can only change their own object |
| `only plain data can be passed on` | An event's or a timer's data holds a function or something else that isn't plain data |
| `only global scripts can add scripts` | Start object scripts from a global script, or list them in `mod.ini` |
| `hud is only drawn while it's shown` | Check `hud.shown` or `ui.shown` before drawing or reading its size, and draw in `on_frame` |
| `only plain data can be kept` | What `on_save` returns, or a value stored in a section, holds a function or something else that isn't plain data |
| `a timer names ..., which no script registered` | `async.register_timer` runs as the script starts, before a timer can fire |
| `player scripts can only read a game section` | Change game sections from a global or object script |
| `orders.register requires a global script` | Register orders from a global or mission script |
