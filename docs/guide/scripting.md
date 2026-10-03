# Scripting

Mods can include scripts, written in [Luau](https://luau.org), a version of Lua 5.1. Load scripts
change the game's records, such as a gun's damage, at startup. Global and mission scripts run as the
game plays: they react to what happens and change it through hooks on the game's functions and
events. Object scripts run on the ships and other objects of a mission, each on its own object.
Player and menu scripts decide what the player sees, hears and does: they draw over the flight
display and the menus, and react to the keys. This page explains how to write them; the
[scripting reference](reference.md) lists everything they can use, and
[`examples/mods`](../../examples/mods) holds complete example mods.

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

What a script prints with `print`, and its errors, go to the log after the mod's name. In the
developer mode, they go to the console too, and a folder mod's scripts reload as soon as one is
saved, carrying on from where they were ([The console](#the-console)); otherwise, go back to the
main menu and start a game again. After changing `mod.ini`, adding a file or changing a load
script, start OpenReliant again.

## Custom AI orders

Global scripts can register an order with `require("openreliant.orders").register(name, definition)`
([#615](https://github.com/OpenReliant/openreliant/issues/615)). The result is a qualified name,
such as `custom-order:pulse`, using the mod's folder or archive identity. Different mods can use
the same local name. Registering it twice in one mod is an error. Pass the qualified name to
`object:give_order` or `orders.info`; another mod can use the same full name. Internal numbers are
session-local and must not be saved. Original order names and numbers still work.

The definition takes the existing `OrderFlags`, a nonnegative `priority` (default 0), optional
`init` and `exit` functions, and a required `update`. Each callback receives the ship, its live
object target or nil, and the frame's seconds of game time. Group targets have no object handle.
Returning false from `update` ends the order; nil or true continues it. Callbacks may steer the
ship, but cannot change order stacks or register another order. Finish through the return value
and use events for changes that must happen later.

The existing stack rules apply: `init` runs when the order starts or restarts, and `exit` runs
when a started order ends or gives way. One-shot orders run only `update`. A callback failure
disables that registration; affected orders end and the underlying stack can continue. The
registration belongs to its script context. Its orders are removed before that context closes,
scripts reload or the mission ends. Global registrations can last across missions, but their
active orders cannot. Keep per-ship state in a closure keyed by object handles and clear it in
`exit`. Between-mission saves restart global registrations from their scripts.

[`examples/mods/custom-order`](../../examples/mods/custom-order) demonstrates a short throttle
pulse. Camera, HUD and input registries follow separately under #558.

## Kinds of scripts

| Kind | In `mod.ini` | When it runs | What it's for |
|---|---|---|---|
| Load | `Load=` under `[Scripts]` | Once, when OpenReliant starts, before the main menu | Changing [the records](#the-records) |
| Global | `Global=` under `[Scripts]` | For the whole game | [Hooks](#hooks) on the game's functions and events |
| Mission | The mission's file name under `[Missions]` | While that mission runs | Hooks for one mission |
| Object | A class, such as `Fighter=`, or a type, such as `Type.predator=`, under `[Scripts]` | On each object of that class or type, while it's in the mission | [Object scripts](#object-scripts) |
| Player | `Player=` under `[Scripts]` | For the whole game, even while it's paused | [What the player sees and does](#player-and-menu-scripts) |
| Menu | `Menu=` under `[Scripts]` | From OpenReliant's start until it quits, in the menus and over the missions | [Drawing over the menus](#player-and-menu-scripts) |

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
  ACTION, the simulator or `--mission`), and ends at the main menu. Global scripts start afresh
  with each game, and for a loaded game from the state they saved with it
  ([Saved games](#saved-games)).
- `[Missions]` matches the mission's file name in any case: `mission2.dte` is mission 2, and
  `mission251.dte` the second part of mission 25. A mission script starts as its mission begins,
  before its ships appear, and stops as it ends. Each attempt starts it afresh.
- The classes are `Fighter`, `Capital`, `Support`, `Torpedo`, `Mine`, `Planet`, `Debris` and
  `Other`. A type is `Type.` and its name ([ShipType](reference.md#shiptype)) or its number, such as
  `Type.12`.
- Each script has its own global variables, and each object's scripts their own.
- Later versions add scripts on missiles and turrets
  ([#587](https://github.com/OpenReliant/openreliant/issues/587)); this version skips them, and
  says so in the log.

## Engine handlers

A script returns a table, whose `engine_handlers` holds the functions OpenReliant calls, such as
`on_update`, each frame, or `on_mission_start`. Each one is optional:

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

[Engine handlers](reference.md#engine-handlers) lists them, with the kinds of script that can use
each and what each gets. They're called in the order the scripts started: the global and mission
scripts' first, in load order, then each object's. A handler that raises an error is logged and
isn't called again.

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

The [scripting reference](reference.md#the-games-functions), or `openreliant hooks` in a terminal,
lists them with the fields each handler sees. Later versions add hooks on more of the game
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
`bullet_fire` and `launcher` for `missile_launch`
([the reference](reference.md#the-games-functions)). A filter can also be a function, which gets
`e` and returns `true` for a call the handler is for.

### Order, removal and errors

- Handlers run newest mod first (the mod that loads last), and within a mod in the order they were
  added. So a later mod's handler that returns `false` stops an earlier mod's.
- `hooks.add` and `hooks.after` return a handle, and `handle:remove()` removes the handler.
- A handler that raises an error is logged with its file and line, and removed, and the changes it
  made to `e` are undone.

## Objects

Scripts see objects (ships, stations, nav points) as handles, such as `e.object`. Every script can
read their fields, such as `type`, `side`, `position` or `hull`. Global scripts can change some,
such as `throttle`, on any object, and an object's own scripts on their object. Their methods give
orders, send events and attach scripts. [Objects](reference.md#objects) lists the fields and the
methods.

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
- A handle is valid until its object leaves the mission or the mission ends; reading a field of one
  that isn't is an error. `object:is_valid()` tells which.
- `openreliant.world` gives global scripts the mission's objects, the player's ship and the mission
  itself.
- An order an object follows usually sets its throttle and steering each frame, so a change to
  those lasts until its order sets them again. To change what a ship does, give it an order.
  `openreliant.orders` lists the orders an object has, says what each order is, and ends them.
- `orientation` is where an object's axes point: to its right, down and forward, in the game's
  frame, where Y points down. `openreliant.util` turns points between the world and an object's
  own frame, and works with orientations and angles:

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
  ```

## Object scripts

An object script runs on one object, from when the object is added to the mission until it
leaves, or the mission ends. The manifest starts it on every object of a class or a type, and a
global script starts it on one object with `object:add_script(name, data)`, which passes `data` to
its `on_init`. `require("openreliant.self")` gives the script its own object.

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
- `openreliant.nearby` gives the objects around the script's object.

## Player and menu scripts

Player and menu scripts decide what the player sees, hears and does. They run in a state of their
own, apart from the game's scripts: they can read objects, but change the game only by sending
events to the global scripts.

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
  since the last. `on_key_press` and `on_key_release` hear the keys, by name, such as `"f9"` or
  `"escape"` ([Key](reference.md#key)). In flight, `on_action` hears the controls bound to the
  game's actions, such as `"fire_lasers"` ([Action](reference.md#action)).
- `openreliant.hud` draws over the flight display, and `openreliant.ui` over the menus: the front
  end's screens and the pause menu. Draw in `on_frame`: each frame starts with nothing drawn. Places
  are in the window's pixels from its top left corner, `width` and `height` give the window's size,
  and `shown` says whether the display or the menu shows this frame. Text is drawn in the game's
  font, at the size the game draws its own times the style's `scale`.
- For a player script, `require("openreliant.self")` gives the player's ship, and
  `openreliant.nearby` the objects around it.
- `openreliant.input`, `openreliant.camera`, `openreliant.audio` and `openreliant.debug` read the
  keys, switch the camera's view, play sounds, and draw lines and text placed in the world
  ([Packages](reference.md#packages)).
- Menu scripts don't run yet while the briefing, the loadout, the ITAC and the other rooms are
  shown ([#589](https://github.com/OpenReliant/openreliant/issues/589)).

## Events

Scripts send each other events: `core.send_global_event(name, data)` to the global and mission
scripts, and `object:send_event(name, data)` to the scripts of one object. A script handles them in
the `event_handlers` it returns, by the event's name:

```lua
-- The wingman's script tells the global scripts it has fled.
local core = require("openreliant.core")
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
  game.
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

- Global and mission scripts see each other's interfaces, an object's scripts those of the other
  scripts on the same object, and player and menu scripts each other's.
- An interface that nobody offers is nil.
- A later script that offers the same name takes its place, and gets the earlier interface in its
  `on_interface_override(base)` handler, so it can call through to it.

## Saved games

The game is saved between missions: in the Reliant's rooms, and by the autosave as the campaign
moves on. Global and player scripts keep what they need to carry on in a loaded game in a file beside
the saved game (`saves\<call sign>GAME<slot>.scripts`), so the saved game itself stays as the
original writes it:

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

## Storage

`openreliant.storage` gives each mod sections of plain data, by name, which read and change like
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
- The global section called `settings` is the mod's options ([Options](#options)), which
  `global_section` doesn't open.
- Each mod has its own sections: two mods' sections of the same name are separate. Every script of
  the mod sees the same sections, on either side.
- Values are plain data, copied as they're stored and as they're read, so changing a table read
  from a section changes nothing until it's stored again. Setting a field to nil removes it.

## Options

A mod can offer the player options, which the player sets on the mods screen: GAME OPTIONS, then
MODS, then OPTIONS with the mod chosen. A load or menu script declares the mod's page as
OpenReliant starts, with `openreliant.settings`, and any script of the mod reads the values:

```lua
local settings = require("openreliant.settings")

settings.register_page({
    title = "WINGMEN",
    options = {
        { key = "show_panel", label = "SHOW PANEL", kind = "toggle", default = true },
        { key = "pull_out_below", label = "PULL OUT BELOW", kind = "choice", default = 0.3,
          choices = { { value = 0.2, label = "20%" }, { value = 0.3, label = "30%" } } },
        { key = "rejoin_after", label = "REJOIN AFTER", kind = "number",
          min = 5, max = 60, step = 5, default = 20,
          description = "The seconds a wingman stays out of the fight." },
    },
})

local rejoin_after = settings.get("rejoin_after")
```

- A `"toggle"` is a check box, with a boolean default. A `"choice"` steps through its `choices`, each
  a number or a string `value` with the `label` the screen shows, and its default is one of the
  values. A `"number"` steps from `min` to `max` by `step`, and its default is in the range.
- A page has up to 64 options, a choice up to 32 choices, and a mod one page. A mistake in the page
  is an error in the script that declares it.
- Only load and menu scripts declare a page, and only as OpenReliant starts: the pages are fixed
  before the front end shows. A mod that is off has no page until it's turned on and OpenReliant
  has restarted.
- `settings.get(key)` gives what the player set, or the default. A value that no longer suits the
  option, such as a choice the mod has since dropped, reads as the default.
- The player sets options in the front end, before a game starts. A script that runs in a game
  reads them as it starts. A menu script can also hear a change at once, with the engine handler
  `on_setting_changed(key, value)`.
- The values are kept in the mod's global storage, in a section of its own that
  `storage.global_section` doesn't open. A value that is the default isn't kept.
- Changing the options in a game, and more kinds of option, are planned
  ([#600](https://github.com/OpenReliant/openreliant/issues/600),
  [#601](https://github.com/OpenReliant/openreliant/issues/601)).

[`examples/mods/wingmen`](../../examples/mods/wingmen) offers three options.

## Timers

`openreliant.async` runs a function of the mod's after a while:

```lua
local async = require("openreliant.async")

async.register_timer("reinforce", function(data)
    print("wave " .. data.wave)
end)

async.after(30, "reinforce", { wave = 2 })
```

- A timer names a function the mod registered, rather than holding the function itself, so that it
  can be kept with the saved game. Register the function when the script runs, at its top level, so
  that it's there again after a load.
- Global and object scripts' timers count game time, which stops while the game is paused. Player
  and menu scripts' timers count real time.
- A timer runs at the first update after its time is up, before `on_update`; on the presentation
  side, at the first frame, before `on_frame`. It gets its data, which must be plain data.
- Global and player scripts' timers are kept with the saved game and the restart point. A timer
  stops with its script's mod, so an object script's timers stop as its object leaves the mission.

## Files

`openreliant.vfs` reads files. A file comes as a string of its bytes.

- `vfs.read(name)` reads a file the way the game does. It looks in three places in turn: the latest
  mod's copy, the game folder's own file, and the game's `resource.hog`.
  - A mod's file is found by its name alone, so `missions\mission1.dte` finds a mod's
    `mission1.dte`.
  - The game folder's file is found by its path from the game folder, in any case, such as
    `missions\mission1.dte` or `music\theme.wav`. A name without a folder, such as `palette.tga`,
    is looked up in the game folder itself, then in the archive.
- `vfs.read_mod(name)` reads a file of the calling mod.
- Both return nil if there is no such file, or if the name is a folder. `vfs.exists(name)` says
  whether `vfs.read` would find it.
- A script can read a loose file of up to half its mod's memory limit (32 MB). A bigger file is an
  error.

## The console

The developer mode turns on the tools for writing scripts: the console, and reloading. Turn it on
with `DeveloperMode=1` in the `[OpenReliant]` section of `starlancer.ini`, or with
`--developer-mode` ([Configuration](configuration.md)); it's off by default.

F11 then brings up the console, in the menus and in flight, where any mod has scripts. It pauses
the mission, and F11, Escape or CLOSE takes it away again. It shows what the scripts print and
their errors, and runs the lines typed into it:

| Command | What it does |
|---|---|
| `help` | Lists the commands |
| `help <name>` | What a package (`storage` or `openreliant.storage`), an engine handler (`on_update`) or a hook (`object_damage`) is |
| `mods` | Lists the mods, and their scripts that run |
| `reload` | Reads the folder mods' scripts again, and starts them again from where they were |
| `clear` | Empties the console |
| `global <mod>`, `player <mod>`, `menu <mod>` | Runs Luau in the context of the mod's global, player or menu scripts, until `exit` |

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
  runs as statements. Its variables are kept for the next line, apart from the scripts' own.
  `require` gives the mod's modules as its scripts have them, and the packages its scripts can use.
- Enter or RUN runs the line, Up and Down bring back the lines typed before, and Page Up, Page Down,
  the mouse wheel and the arrows scroll the output.
- Any other line goes to the player and menu scripts' `on_console_command(text)`, so that a mod
  can add commands of its own.
- The console isn't there yet in the Reliant's rooms and the briefing
  ([#589](https://github.com/OpenReliant/openreliant/issues/589)).

### Reloading

In the developer mode, a folder mod's scripts reload as soon as one of them is saved, as `reload`
reloads them:

- Global and player scripts start again from their state, as a saved game would keep it
  ([Saved games](#saved-games)): `on_save` runs, and the new scripts get `on_load`.
- Partway through a mission, its mission scripts start again, and so do the scripts on each of its
  objects, with `on_init` and then `on_added`, but no `on_mission_start` or `on_object_added`.
- Menu scripts start again with `on_init`.
- Load scripts and `mod.ini` are read only as OpenReliant starts, so they need a restart.

## Values

- Numbers use the game's units ([developer documentation](../README.md)). Positions and velocities
  are Luau vectors, a velocity being the distance moved in a simulation step.
- Values OpenReliant has names for are strings, such as `"fighter"` or `"laser_cannon"`; one without
  a name is a number ([Names of values](reference.md#names-of-values)).
- `math.random` gives the same numbers on every computer for the same game: it starts again as each
  mission starts, from the game's own random numbers. `math.randomseed` and `os` aren't there.

## Packages

`require("name")` runs another script of the same mod once and returns what it returns; the name is
the file name, with or without `.luau`, in any case. `require("openreliant.<name>")` gives one of
OpenReliant's packages, such as `openreliant.hooks` or `openreliant.world`.
[Packages](reference.md#packages) lists them, with what each holds and the kinds of script that can
use it. Later versions add more, and requiring one of those now gives an error that says so.

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
read are the game's and the mods' ([Files](#files)). A call into a
script may run for at most 1 second in a load script and 100 milliseconds in any other, and each
mod's scripts may use at most 64 MiB of memory. An error in a script never
stops the game: it's logged with the file and the line, and the game carries on.

## When something goes wrong

| In the log | What to check |
|---|---|
| `skipping the mod ...: it needs OpenReliant 0.7.0` | OpenReliant is older than the mod's `OpenReliant=` |
| No `started` line for the script | `mod.ini` lists it under `[Scripts]`, with the file's exact name |
| `there's no hook named '...'` | The hook's name ([the reference](reference.md#the-games-functions)) |
| `... has no field '...'` or `expected a number, got string` | The field's name and type |
| `e can only be used while its handler runs` | Keep values from `e` in variables, not `e` itself |
| `... is an event, whose fields can't be changed` | Events can only be read |
| `the object is no longer in the mission` | `object:is_valid()` before using a handle kept from earlier |
| `script timed out` | A loop that doesn't end, or does too much at once |
| `... is not available to load scripts` | Load scripts can't use that package |
| `object scripts can't change this object's ...` | An object's scripts can only change their own object |
| `only plain data can be passed on` | An event's or a timer's data holds a function or something else that isn't plain data |
| `only global scripts can add scripts` | Start object scripts from a global script, or list them in `mod.ini` |
| `hud is only drawn while it's shown` | Check `hud.shown` or `ui.shown` before drawing or reading its size |
| `only plain data can be kept` | What `on_save` returns, or a value stored in a section, holds a function or something else that isn't plain data |
| `a timer names ..., which no script registered` | `async.register_timer` runs as the script starts, before a timer can fire |
| `player scripts can only read a game section` | Change game sections from a global or object script |
