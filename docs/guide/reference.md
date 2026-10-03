# Scripting reference

This page lists everything mods' scripts can use: the engine handlers, the packages, the fields
and methods of objects, the hooks with the fields each handler sees in `e`, and the names of
values. [Scripting](scripting.md) explains how to use them. `openreliant hooks` prints the list of
hooks, and `openreliant hooks <name>` one hook.

This page is generated from OpenReliant's code by `make definitions`, so don't change it by hand.

- [Engine handlers](#engine-handlers)
- [Packages](#packages)
- [Objects](#objects)
- [The game's functions](#the-games-functions)
- [The order routines](#the-order-routines)
- [The mission's events](#the-missions-events)
- [The engine's events](#the-engines-events)
- [Tables](#tables)
- [Names of values](#names-of-values)

## Engine handlers

The functions a script returns in `engine_handlers`, which OpenReliant calls. Global scripts
include mission scripts.

| Handler | Scripts | When it's called |
|---|---|---|
| `on_init(data: any?)` | global, object, player and menu | When the script starts, with the data `add_script` gave it, or nil. |
| `on_save()`: plain data | global and player | When the game is saved, between missions, and as each mission of the campaign starts, for its restart point: what it returns, which must be plain data, is kept with it. Mission scripts aren't kept. |
| `on_load(saved: any?)` | global and player | In place of `on_init`, when a saved game is loaded or the game goes back to the restart point, with what the script's `on_save` returned then, or nil. A script that didn't run then, such as one of a mod added since, gets `on_init` instead. |
| `on_records_loaded()` | load | After every mod's load scripts have run. |
| `on_update(seconds: number)` | global and object | Each frame in which game time passes, after the ships' orders, with the seconds it covers. |
| `on_step()` | global and object | Each simulation step, 25 a second, after everything has moved. |
| `on_frame(seconds: number)` | player and menu | Each frame drawn, even while the game is paused, with the seconds of real time since the last. |
| `on_mission_start(mission: Mission)` | global, player and menu | When a mission has started and its first ships are there. |
| `on_mission_end(outcome: Outcome)` | global, player and menu | When the mission ends, for whatever reason. |
| `on_object_added(object: Object)` | global | When an object is added to the mission. |
| `on_object_removed(object: Object)` | global | When an object leaves the mission, such as once it has blown up. |
| `on_added()` | object | When the script's object is in the mission: as it's added, or at once if the script starts later. |
| `on_removed()` | object | When the script's object leaves the mission. |
| `on_key_press(key: Key)` | player and menu | When a key is pressed. A key held down is told once. |
| `on_key_release(key: Key)` | player and menu | When a key is released. |
| `on_action(action: Action)` | player and menu | When the player uses the controls bound to an action, in flight. |
| `on_console_command(text: string)` | player and menu | When a line typed in the console isn't one of its commands, with the line. |
| `on_viewport_resized(width: number, height: number)` | player and menu | When the window changes size, with its new size in pixels. |
| `on_interface_override(base: { [any]: any })` | global, object, player and menu | When the script's interface takes the place of one an earlier script offered under the same name, with that one. |

## Packages

What `require("openreliant.<name>")` gives.

### `openreliant.core`

OpenReliant's version, and events for the global scripts. For load, global, object, player and menu scripts.

| Name | Type | What it is |
|---|---|---|
| `version` | string | The version of OpenReliant, such as `0.7.0`. |
| `send_global_event(name: string, data: any)` | nothing | Sends the event `name` to the global and mission scripts, with `data`, which must be plain data. It arrives at the next update. |

### `openreliant.records`

The game's records: ships, guns, missiles, pilots and text. Only load scripts can change them. For load, global, object, player and menu scripts.

### `openreliant.hooks`

Handlers on the game's functions and events. For global and object scripts.

### `openreliant.world`

The mission's objects, the player's ship and the mission itself. For global scripts.

| Name | Type | What it is |
|---|---|---|
| `player` | [object](#objects), or nil | The player's ship, while a mission runs; nil between missions. |
| `mission` | [Mission](#mission), or nil | The mission that runs, with its `number` and its `file`'s name; nil between missions. |
| `objects()` | list of [objects](#objects) | Every object in the mission, in the order of their slots. |

### `openreliant.self`

The script's own object, as a handle: an object script's object, or the player's ship for a player script, nil between games. For object and player scripts.

### `openreliant.nearby`

The objects around the script's own. For object and player scripts.

| Name | Type | What it is |
|---|---|---|
| `objects(radius: number)` | list of [objects](#objects) | The objects within `radius` of the script's object, or of the player's ship for a player script, nearest first, without it. |

### `openreliant.orders`

What the order table says of each order, the orders each object has, and ending them. An object's give_order gives orders. For global and object scripts.

| Name | Type | What it is |
|---|---|---|
| `info(order: Order)` | [OrderInfo](#orderinfo), or nil | What the order table says of `order`: its developers' name, its priority and its flags. Nil for an order the table doesn't have. |
| `stack(object: Object)` | list of [OrderEntry](#orderentry) | The orders `object` has, the one it follows first, each with what it's aimed at. The ones below carry on as each ends. |
| `cancel(object: Object)` | boolean | Ends the order `object` follows, as an order ends itself: its exit runs, and the order below it carries on. Returns whether it had one. Global scripts can end any object's orders, and an object's scripts their own object's. |
| `clear(object: Object)` | boolean | Drops all of `object`'s orders, as a mission's ClearAI does, where the one it follows gives way. Returns whether they were dropped. Global scripts can drop any object's orders, and an object's scripts their own object's. |

### `openreliant.hud`

Drawing over the flight display, while it's shown: text, lines and rectangles, in the window's pixels. For player scripts.

| Name | Type | What it is |
|---|---|---|
| `shown` | boolean | Whether it's shown this frame, which is when what's drawn on it shows, and its other fields can be read. |
| `width` | number | The window's width, in pixels. |
| `height` | number | The window's height, in pixels. |
| `text(at: vector, text: string, style: TextStyle?)` | nothing | Draws `text` at `at`, in pixels from the window's top left corner, in the game's font, as `style` says. |
| `line(from: vector, to: vector, style: LineStyle?)` | nothing | Draws a line from `from` to `to`, in pixels, as `style` says. |
| `rectangle(from: vector, to: vector, style: FillStyle?)` | nothing | Fills the rectangle between the corners `from` and `to`, in pixels, as `style` says. |
| `measure(text: string, scale: number?)` | [Size](#size) | How wide and tall `text` is drawn, in pixels, at `scale` times the game's own size, or at its own size where `scale` is nil. |

### `openreliant.ui`

Drawing over the menus, the front end's screens and the pause menu, while they're shown: text, lines and rectangles, in the window's pixels. For player and menu scripts.

| Name | Type | What it is |
|---|---|---|
| `shown` | boolean | Whether it's shown this frame, which is when what's drawn on it shows, and its other fields can be read. |
| `width` | number | The window's width, in pixels. |
| `height` | number | The window's height, in pixels. |
| `text(at: vector, text: string, style: TextStyle?)` | nothing | Draws `text` at `at`, in pixels from the window's top left corner, in the game's font, as `style` says. |
| `line(from: vector, to: vector, style: LineStyle?)` | nothing | Draws a line from `from` to `to`, in pixels, as `style` says. |
| `rectangle(from: vector, to: vector, style: FillStyle?)` | nothing | Fills the rectangle between the corners `from` and `to`, in pixels, as `style` says. |
| `measure(text: string, scale: number?)` | [Size](#size) | How wide and tall `text` is drawn, in pixels, at `scale` times the game's own size, or at its own size where `scale` is nil. |

### `openreliant.input`

Whether keys are held, and the controls bound to actions. For player and menu scripts.

| Name | Type | What it is |
|---|---|---|
| `key_down(key: Key)` | boolean | Whether `key` is held down. |
| `action_down(action: Action)` | boolean | Whether the controls bound to `action` are held: its key, or its joystick button. |

### `openreliant.camera`

The camera's view, and switching between the game's views. For player scripts.

| Name | Type | What it is |
|---|---|---|
| `view` | [View](#view), or nil | The view the camera shows; nil while no mission is shown. |
| `set_view(view: View, object: Object?)` | boolean | Switches the camera to `view`, of `object`, or of the player's ship where it's nil, as the player's camera keys do. Returns whether it switched: a mission's own camera and the cutaways hold it. |

### `openreliant.audio`

Interface sounds, music and Betty's lines. For player and menu scripts.

| Name | Type | What it is |
|---|---|---|
| `play_sound(index: number, volume: number?)` | boolean | Plays sound `index` of the game's standard sounds, the menus' and the display's, at `volume` from 0 to 1, or at its loudest where it's nil. Returns whether it played. |
| `play_music(name: string)` | nothing | Plays the piece `name` from the game's music folder for ever, in place of the music playing. |
| `say(line: BettyLine)` | boolean | Betty says `line`. Returns whether she does. |

### `openreliant.storage`

Sections of plain data for each mod: kept with the saved game, or in the game folder across every game. For load, global, object, player and menu scripts.

| Name | Type | What it is |
|---|---|---|
| `game_section(name: string)` | Section | The section `name` of the calling mod's storage that's kept with the saved game, and starts empty with each new game. Global and object scripts change it; other scripts read it. |
| `global_section(name: string)` | Section | The section `name` of the calling mod's storage that's kept in the game folder, across every game. Any script changes it. |

### `openreliant.async`

Timers, kept with the saved game: game time for global and object scripts, real time for player and menu scripts. For global, object, player and menu scripts.

| Name | Type | What it is |
|---|---|---|
| `register_timer(name: string, handler: (data: any) -> ())` | nothing | Registers `handler` under `name` for the script's mod, for timers to run. Register it as the script runs, so that a timer kept with a saved game finds it again after the game is loaded. |
| `after(seconds: number, name: string, data: any?)` | nothing | Runs the function registered under `name` once `seconds` have passed, with `data`, which must be plain data: seconds of game time for global and object scripts, and of real time for player and menu scripts. |

### `openreliant.interfaces`

The interfaces other scripts offer, as `I.<name>`: those of the global scripts to global scripts, those of an object's scripts to the object's other scripts, and those of player and menu scripts to each other. Nil for one nobody offers. For global, object, player and menu scripts.

### `openreliant.util`

Orientations, turning points between the world and an object's own frame, and angles. Luau's vector library has the rest of the vector maths. For load, global, object, player and menu scripts.

| Name | Type | What it is |
|---|---|---|
| `to_world(position: vector, orientation: Orientation, point: vector)` | vector | The point of the world that `point` is in the frame of something at `position` turned as `orientation`: `point`'s x to its right, y down and z forward of it. |
| `to_local(position: vector, orientation: Orientation, point: vector)` | vector | Where the point of the world `point` is in the frame of something at `position` turned as `orientation`: x to its right, y down and z forward of it. |
| `angle_off(position: vector, orientation: Orientation, point: vector)` | number | The angle in radians between the forward axis of something at `position` turned as `orientation` and the direction to `point`: 0 dead ahead, pi straight behind. |
| `look_at(direction: vector)` | [Orientation](#orientation) | The orientation whose forward axis points along `direction`, turned about its Y axis, then its X axis, with no roll, as the game turns a ship to look at something. |
| `turn(orientation: Orientation, axis: Axis, angle: number)` | [Orientation](#orientation) | `orientation` turned by `angle` radians about its own `axis`: right-handed, so about its Y axis, which points down, a positive angle turns its nose to the right. |
| `angles(orientation: Orientation)` | vector | The angles in radians that `orientation` is turned by from looking along the world's Z axis, as the game reads them: x the pitch, y the yaw and z the roll. |
| `from_angles(angles: vector)` | [Orientation](#orientation) | The orientation turned by `angles` in radians from looking along the world's Z axis, as `angles` gives them: about X, then Y, then Z. |
| `normalize_angle(angle: number)` | number | `angle` in radians brought within half a turn either way, from -pi to pi. |

### `openreliant.vfs`

Reading the game's and the mods' files. For load, global, object, player and menu scripts.

| Name | Type | What it is |
|---|---|---|
| `read(name: string)` | string? | The file `name` as the game reads it: a mod's, the latest mod's first, or else the game's own, as a string of its bytes. Nil where there's none. |
| `read_mod(name: string)` | string? | The calling mod's own file `name`, as a string of its bytes. Nil where it has none. |
| `exists(name: string)` | boolean | Whether the game has the file `name`, in a mod or of its own. |

### `openreliant.debug`

Lines and text placed in the world, drawn over the flight display where the camera sees them, for debugging. For player scripts.

| Name | Type | What it is |
|---|---|---|
| `line(from: vector, to: vector, style: LineStyle?)` | nothing | Draws a line between the points `from` and `to` of the world, as `style` says, where the camera sees them. |
| `text(at: vector, text: string, style: TextStyle?)` | nothing | Draws `text` at the point `at` of the world, as `style` says, where the camera sees it. |

## Objects

Scripts see objects through handles. A handle stays valid until its object is removed or its
mission ends; reading a field of a handle that isn't valid is an error. Every script can read the
fields; global scripts can change those marked *changes* on any object, and an object's own
scripts on their object.

| Field | Type | What it is |
|---|---|---|
| `slot` | number | The slot it fills in the mission, from 0. |
| `type` | [ShipType](#shiptype) | Its type, such as `predator`. |
| `class` | [ShipClass](#shipclass), or nil | Its class, such as `fighter`; nil for an object without stats, such as a nav point. |
| `side` | [Side](#side) | The side it's on. |
| `position` | vector | Where it is. |
| `orientation` | [Orientation](#orientation) | Where its axes point: to its right, down and forward, out of its nose (`openreliant.util`). |
| `velocity` | vector | How far it moves in a simulation step, of which there are 25 a second. |
| `speed` | number | How fast it moves: the length of its velocity. |
| `is_player` | boolean | Whether it's the player's ship. |
| `order` | [Order](#order), or nil | The order it's following, such as `fight`; nil for none. |
| `last_attacker` | [object](#objects), or nil | The object that last hit it; nil for none, or once that one has left the mission. |
| `throttle` | number | *Changes.* Its throttle: 1 is full, 2 the afterburner's and -1 reverse thrust's. Its order or its pilot usually sets it each frame. |
| `roll_input` | number | *Changes.* How hard it rolls, from -1 to 1. Its order or its pilot usually sets it each frame. |
| `pitch_input` | number | *Changes.* How hard it pitches, from -1 to 1. Its order or its pilot usually sets it each frame. |
| `yaw_input` | number | *Changes.* How hard it yaws, from -1 to 1. Its order or its pilot usually sets it each frame. |
| `shields` | [Quadrants](#quadrants) | Its shields in each quadrant. |
| `armor` | [Quadrants](#quadrants) | Its armour in each quadrant. |
| `hull` | number, or nil | The share of its armour it has left, from about 1 as it's made down to 0: its weakest quadrant against a quadrant's full armour. Nil for an object without stats. |

| Method | Returns | What it does |
|---|---|---|
| `is_valid()` | boolean | Whether the object is still in the mission. A handle stops being valid once its object is removed or its mission ends. |
| `give_order(order: Order, target: Object?)` | boolean | Gives it `order`, aimed at `target` or at nothing, as a mission's SetAI does: the order goes on top of its orders if the one it follows gives way. Returns whether it took. Global scripts can give any object orders, and an object's scripts their own object. |
| `send_event(name: string, data: any)` | nothing | Sends the event `name` to the object's scripts, with `data`, which must be plain data. It arrives at the next update. |
| `add_script(name: string, data: any?)` | boolean | Starts the script `name` of the calling mod on the object, as an object script, and passes `data` to its `on_init`. Returns whether it started. Only global scripts can add scripts. |
| `hook(name: string, handler: (e: any) -> boolean?, filter: (Filter \| (e: any) -> boolean)?)` | HookHandle | `hooks.add`, for the calls that concern this object only: a handler for the hook `name`, with an optional `filter`. Returns the handler's handle. Global scripts can hook any object, and an object's scripts their own. |
| `remove_script(name: string)` | boolean | Stops the script `name` of the calling mod on the object. Returns whether it ran there. Only global scripts can remove scripts. |

## The game's functions

Each is a function of the original game, under its name. `hooks.add` runs a handler before the
function, and `hooks.after` runs one after it. Changing a field of `e` changes what the function
does, and a handler that returns `false` stops it.

### object_damage

Damage to `object` from `attacker`. Its shield in `quadrant` takes `value` first. What gets through, times `factor`, damages its armour (`object_armor_damage`). `kind` says what dealt the damage.

| Field | Type |
|---|---|
| `object` | [object](#objects) |
| `quadrant` | [Quadrant](#quadrant) |
| `value` | number |
| `factor` | number |
| `attacker` | [object](#objects) |
| `kind` | [DamageKind](#damagekind) |

### object_armor_damage

Damage to the armour of `object` in `quadrant`, once its shield there is down: `value` from `attacker`, of `kind`. Armour below zero destroys the object (`object_destroyed`).

| Field | Type |
|---|---|
| `object` | [object](#objects) |
| `quadrant` | [Quadrant](#quadrant) |
| `value` | number |
| `attacker` | [object](#objects) |
| `kind` | [DamageKind](#damagekind) |

### component_damage

Damage to one of the components of `object`, such as a capital ship's turret or engine: `value` from `attacker`, of `kind`.

| Field | Type |
|---|---|
| `object` | [object](#objects) |
| `value` | number |
| `attacker` | [object](#objects) |
| `kind` | [DamageKind](#damagekind) |

### damage_by_difficulty

How hard damage of `kind` lands on `object` at the game's difficulty: the result is what `value` becomes.

| Field | Type |
|---|---|
| `object` | [object](#objects) |
| `kind` | [DamageKind](#damagekind) |
| `value` | number |
| `result` | number |

### object_destroyed

The end of `object`: its pilot ejects, or it explodes. With `may_spin`, it may spin out as it goes; with `no_eject`, the player's pilot doesn't eject.

| Field | Type |
|---|---|
| `object` | [object](#objects) |
| `may_spin` | boolean |
| `no_eject` | boolean |

### bullet_fire

`owner` fires a shot of `gun_type` from one of its guns. `heard` says whether the shot makes a sound.

| Field | Type |
|---|---|
| `owner` | [object](#objects) |
| `gun_type` | [GunType](#guntype) |
| `heard` | boolean |

### missile_launch

`launcher` launches a missile from one of its racks.

| Field | Type |
|---|---|
| `launcher` | [object](#objects) |

### missile_launch_turret

One of the missile turrets of `object` launches a Screamer.

| Field | Type |
|---|---|
| `object` | [object](#objects) |

### object_orders

`object` runs its current order, as it does each frame. Each order's routines have hooks of their own, such as `order_fight`.

| Field | Type |
|---|---|
| `object` | [object](#objects) |

### order_retaliate

`object`, a fighter, turns on whoever last hit it, once it has taken enough damage lately and its order allows it.

| Field | Type |
|---|---|
| `object` | [object](#objects) |

## The order routines

Each order an object follows, such as Fight or Run Away, runs routines of the original game:
an `init` as the order starts, an `update` each frame, and for a few an `exit` as it ends. Each
routine is a hook under its name. Its handlers see the object that runs the order as `e.object`,
and `e.object.order` is the order. Where OpenReliant doesn't run a routine yet, its handlers
still run, and the function does nothing.

| Hook | What it is |
|---|---|
| `order_do_nothing` | The update of order 0, Do Nothing, which `object` runs. |
| `order_fly_aimlessly_init` | The init of order 1, Fly Aimlessly, which `object` runs. |
| `order_fly_aimlessly` | The update of order 1, Fly Aimlessly, which `object` runs. |
| `order_launch_missile` | The update of order 2, Launch Missile, which `object` runs. |
| `order_unnamed_3` | The update of order 3, which `object` runs. |
| `order_warp_in_init` | The init of order 4, Warp In, which `object` runs. |
| `order_warp_in` | The update of order 4, Warp In, which `object` runs. |
| `order_warp_out_init` | The init of order 5, Warp Out, which `object` runs. |
| `order_warp_out` | The update of order 5, Warp Out, which `object` runs. |
| `order_fly_init` | The init of order 6, Fly, which `object` runs. |
| `order_fly` | The update of order 6, Fly, which `object` runs. |
| `order_run_away` | The update of order 7, Run Away, which `object` runs. |
| `order_land_init` | The init of order 8, Land, which `object` runs. |
| `order_land` | The update of order 8, Land, which `object` runs. |
| `order_escort_init` | The init of order 9, Escort, which `object` runs. |
| `order_escort` | The update of order 9, Escort, which `object` runs. |
| `order_find_new_target` | The update of order 10, Find New Target, which `object` runs. |
| `order_explode_init` | The init of order 11, Explode, which `object` runs. |
| `order_explode` | The update of order 11, Explode, which `object` runs. |
| `order_ripper_grabs_target_object_init` | The init of order 12, Ripper grabs target object, which `object` runs. |
| `order_ripper_grabs_target_object` | The update of order 12, Ripper grabs target object, which `object` runs. |
| `order_ripper_grabs_target_object_exit` | The exit of order 12, Ripper grabs target object, which `object` runs. |
| `order_object_attach_init` | The init of order 13, Object Attach, which `object` runs. |
| `order_object_attach` | The update of order 13, Object Attach, which `object` runs. |
| `order_formation_regroup_init` | The init of order 14, Formation Regroup, which `object` runs. |
| `order_formation_regroup` | The update of order 14, Formation Regroup, which `object` runs. |
| `order_patrol_route_init` | The init of order 15, Patrol Route, which `object` runs. |
| `order_patrol_route` | The update of order 15, Patrol Route, which `object` runs. |
| `order_toggle_cloak` | The update of order 16, Toggle Cloak, which `object` runs. |
| `order_ship_follow_curve_init` | The init of order 17, Ship Follow Curve, which `object` runs. |
| `order_ship_follow_curve` | The update of order 17, Ship Follow Curve, which `object` runs. |
| `order_ship_follow_curve_exit` | The exit of order 17, Ship Follow Curve, which `object` runs. |
| `order_slow_rotate` | The update of order 18, Slow Rotate, which `object` runs. |
| `order_jump_in_init` | The init of order 19, Jump In, and of order 40, Jump In, which `object` runs. |
| `order_jump_in` | The update of order 19, Jump In, and of order 40, Jump In, which `object` runs. |
| `order_jump_out_init` | The init of order 20, Jump Out, and of order 41, Jump Out, which `object` runs. |
| `order_jump_out` | The update of order 20, Jump Out, and of order 41, Jump Out, which `object` runs. |
| `order_find_scoop_up` | The update of order 21, Find Scoop Up, which `object` runs. |
| `order_random_spin_slow_init` | The init of order 22, Random Spin Slow, which `object` runs. |
| `order_random_spin_medium_init` | The init of order 23, Random Spin Medium, which `object` runs. |
| `order_random_spin_fast_init` | The init of order 24, Random Spin Fast, which `object` runs. |
| `order_fixed_gate_jump_in_init` | The init of order 25, Fixed Gate Jump In, which `object` runs. |
| `order_fixed_gate_jump_in` | The update of order 25, Fixed Gate Jump In, which `object` runs. |
| `order_fixed_gate_jump_out_init` | The init of order 26, Fixed Gate Jump Out, which `object` runs. |
| `order_fixed_gate_jump_out` | The update of order 26, Fixed Gate Jump Out, which `object` runs. |
| `order_formation_init` | The init of order 27, Formation, which `object` runs. |
| `order_formation` | The update of order 27, Formation, which `object` runs. |
| `order_fixed_gate_open_init` | The init of order 28, Fixed Gate Open, which `object` runs. |
| `order_fixed_gate_open` | The update of order 28, Fixed Gate Open, which `object` runs. |
| `order_fixed_gate_close_init` | The init of order 29, Fixed Gate Close, which `object` runs. |
| `order_fixed_gate_close` | The update of order 29, Fixed Gate Close, which `object` runs. |
| `order_eject_init` | The init of order 30, Eject, which `object` runs. |
| `order_eject` | The update of order 30, Eject, which `object` runs. |
| `order_fixed_gate_collapse_init` | The init of order 31, Fixed Gate Collapse, which `object` runs. |
| `order_fixed_gate_collapse` | The update of order 31, Fixed Gate Collapse, which `object` runs. |
| `order_match_speed` | The update of order 32, Match Speed, which `object` runs. |
| `order_dark_reign_shoot` | The update of order 33, Dark Reign shoot, which `object` runs. |
| `order_move_to_spawn_pos` | The update of order 34, Move to spawn pos, which `object` runs. |
| `order_turns_object_lights_on_init` | The init of order 35, Turns object lights on, which `object` runs. |
| `order_turns_object_lights_on` | The update of order 35, Turns object lights on, which `object` runs. |
| `order_make_boridin_section_break_away_init` | The init of order 36, Make Boridin section break away, which `object` runs. |
| `order_rotate_boridin_breakaway_warp_projector_init` | The init of order 37, Rotate Boridin breakaway warp projector, which `object` runs. |
| `order_start_warp_projection_from_boridin_init` | The init of order 38, Start warp projection from Boridin, which `object` runs. |
| `order_start_warp_projection_from_boridin` | The update of order 38, Start warp projection from Boridin, which `object` runs. |
| `order_make_ripper_drop_what_its_carrying_init` | The init of order 39, Make ripper drop what it's carrying, which `object` runs. |
| `order_make_ripper_drop_what_its_carrying` | The update of order 39, Make ripper drop what it's carrying, which `object` runs. |
| `order_turns_object_lights_off` | The update of order 42, Turns object lights off, which `object` runs. |
| `order_huuuuuuuge_explosion` | The update of order 43, Huuuuuuuge explosion, which `object` runs. |
| `order_immediately_set_ship_to_zero_velocity_and_rotation` | The update of order 44, Immediately set ship to zero velocity and rotation, which `object` runs. |
| `order_fly_ship_backwards` | The update of order 45, Fly ship backwards, which `object` runs. |
| `player_controls` | The update of order 100, Player Control, which `object` runs. |
| `order_multiplayer_control` | The update of order 101, Multiplayer Control, which `object` runs. |
| `order_avoid_target_init` | The init of order 102, Avoid Target, which `object` runs. |
| `order_avoid_target` | The update of order 102, Avoid Target, which `object` runs. |
| `order_torpedo_init` | The init of order 103, Torpedo, which `object` runs. |
| `order_torpedo` | The update of order 103, Torpedo, which `object` runs. |
| `order_launch_init` | The init of order 104, Launch, which `object` runs. |
| `order_launch` | The update of order 104, Launch, which `object` runs. |
| `order_fight_init` | The init of order 105, Fight, which `object` runs. |
| `order_fight` | The update of order 105, Fight, which `object` runs. |
| `order_eject_106_init` | The init of order 106, Eject, which `object` runs. |
| `order_eject_106` | The update of order 106, Eject, which `object` runs. |
| `order_scoop_up_init` | The init of order 107, Scoop Up, which `object` runs. |
| `order_scoop_up` | The update of order 107, Scoop Up, which `object` runs. |
| `order_scoop_up_exit` | The exit of order 107, Scoop Up, which `object` runs. |
| `order_eject_spin_init` | The init of order 108, Eject Spin, which `object` runs. |
| `order_eject_spin` | The update of order 108, Eject Spin, which `object` runs. |
| `order_dock_init` | The init of order 109, Dock, which `object` runs. |
| `order_dock` | The update of order 109, Dock, which `object` runs. |
| `order_dock_exit` | The exit of order 109, Dock, which `object` runs. |
| `order_dark_reign_shoot_110_init` | The init of order 110, Dark reign shoot, which `object` runs. |
| `order_dark_reign_shoot_110` | The update of order 110, Dark reign shoot, which `object` runs. |
| `order_dark_reign_shoot_110_exit` | The exit of order 110, Dark reign shoot, which `object` runs. |
| `order_ripper_end_drop_object_init` | The init of order 111, Ripper end drop object, which `object` runs. |
| `order_ripper_end_drop_object` | The update of order 111, Ripper end drop object, which `object` runs. |
| `order_ripper_attach_cargo_pod_to_mammoth_init` | The init of order 112, Ripper attach cargo pod to Mammoth, which `object` runs. |
| `order_ripper_attach_cargo_pod_to_mammoth` | The update of order 112, Ripper attach cargo pod to Mammoth, which `object` runs. |
| `order_eject_fighter_attack` | The update of order 113, Eject fighter attack, which `object` runs. |
| `order_disrupted_init` | The init of order 114, Disrupted, which `object` runs. |
| `order_disrupted` | The update of order 114, Disrupted, which `object` runs. |
| `order_disrupted_exit` | The exit of order 114, Disrupted, which `object` runs. |
| `order_make_capship_list_left` | The update of order 115, Make capship list left, which `object` runs. |
| `order_make_capship_list_right` | The update of order 116, Make capship list right, which `object` runs. |
| `order_friendly_fire_init` | The init of order 117, Friendly Fire, which `object` runs. |
| `order_friendly_fire` | The update of order 117, Friendly Fire, which `object` runs. |
| `order_eject_player_init` | The init of order 118, Eject Player, which `object` runs. |
| `order_eject_player` | The update of order 118, Eject Player, which `object` runs. |
| `order_ship_follow_curve_backwards_init` | The init of order 119, Ship Follow Curve Backwards, which `object` runs. |
| `order_ship_follow_curve_backwards` | The update of order 119, Ship Follow Curve Backwards, which `object` runs. |
| `order_ship_follow_curve_backwards_exit` | The exit of order 119, Ship Follow Curve Backwards, which `object` runs. |
| `order_mill_init` | The init of order 120, Mill, which `object` runs. |
| `order_mill` | The update of order 120, Mill, which `object` runs. |
| `order_deathmatch_respawn_effect_init` | The init of order 121, Deathmatch Respawn Effect, which `object` runs. |
| `order_deathmatch_respawn_effect` | The update of order 121, Deathmatch Respawn Effect, which `object` runs. |
| `order_deathmatch_respawn_effect_exit` | The exit of order 121, Deathmatch Respawn Effect, which `object` runs. |
| `order_first_step_init` | The init of order 21, Find Scoop Up, and of order 115, Make capship list left, and of order 116, Make capship list right, which `object` runs. |

## The mission's events

The events a mission's triggers can wait for, under the names of their conditions. Each comes
for the mission's ships, those its file lists, whether or not a trigger waits for it. Their
fields can only be read, and a handler that returns `false` stops the handlers after it.

### shot_at

`attacker` hits `object`: its component number `component`, or the object as a whole when `component` is nil.

| Field | Type |
|---|---|
| `object` | [object](#objects) |
| `attacker` | [object](#objects) |
| `component` | number, or nil |

### destroyed

`object` is destroyed, or its component number `component`. `attacker` is what last hit it. Each ship is destroyed once, though its components can be destroyed before it.

| Field | Type |
|---|---|
| `object` | [object](#objects) |
| `component` | number, or nil |
| `attacker` | [object](#objects), or nil |

### launched

`object` has launched from its carrier.

| Field | Type |
|---|---|
| `object` | [object](#objects) |

### ship_reached

`reached_by` has reached the mission's ship `ship`, a point on a curve it follows or the curve's end.

| Field | Type |
|---|---|
| `ship` | number |
| `reached_by` | [object](#objects) |

### camera_reached

The director's camera has reached the mission's ship `ship`, a point on its curve or the curve's end.

| Field | Type |
|---|---|
| `ship` | number |

### object_scooped

`object` has taken `scooped` aboard with its tractor beam.

| Field | Type |
|---|---|
| `object` | [object](#objects) |
| `scooped` | [object](#objects) |

### player_ready_to_jump

JUMP DRIVE took the jump the mission had ready for `object`, the player's ship.

| Field | Type |
|---|---|
| `object` | [object](#objects) |

### jumped_in

`object` has jumped in.

| Field | Type |
|---|---|
| `object` | [object](#objects) |

### fixed_gate_jumped_in

`object` has come in through the fixed gate `gate`.

| Field | Type |
|---|---|
| `object` | [object](#objects) |
| `gate` | [object](#objects) |

### player_ready_to_warp

JUMP DRIVE took the warp the mission had ready for `object`, the player's ship.

| Field | Type |
|---|---|
| `object` | [object](#objects) |

### player_wants_backup

REQUEST BACKUP brought the mission's backup for `object`, the player's ship.

| Field | Type |
|---|---|
| `object` | [object](#objects) |

### ripper_grabbed_object

`object`, a Ripper, has `grabbed` aboard.

| Field | Type |
|---|---|
| `object` | [object](#objects) |
| `grabbed` | [object](#objects) |

### ripper_dropped_object

`object`, a Ripper, has let go of `dropped`, or fitted it to a ship.

| Field | Type |
|---|---|
| `object` | [object](#objects) |
| `dropped` | [object](#objects) |

### cloaked

`object` cloaks.

| Field | Type |
|---|---|
| `object` | [object](#objects) |

### decloaked

`object` uncloaks.

| Field | Type |
|---|---|
| `object` | [object](#objects) |

### docked

`object` has docked.

| Field | Type |
|---|---|
| `object` | [object](#objects) |

### explosion_ship

The explosion that `object` set off is over.

| Field | Type |
|---|---|
| `object` | [object](#objects) |

## The engine's events

Their fields can only be read, and a handler that returns `false` stops the handlers after it.

### mission_started

A mission has started: number `number`, from the file `file`. Its first ships are there.

| Field | Type |
|---|---|
| `number` | number |
| `file` | string |

### mission_ended

The mission ends: `ending` says how it ended for the player, and `rating` how its script rated it.

| Field | Type |
|---|---|
| `ending` | [Ending](#ending) |
| `rating` | [Rating](#rating) |

### object_added

`object` has been added to the mission.

| Field | Type |
|---|---|
| `object` | [object](#objects) |

### object_removed

`object` is leaving the mission: it has blown up, or its slot is being reset. Its handle stops being valid after this.

| Field | Type |
|---|---|
| `object` | [object](#objects) |

### order_started

`object` has started `order`, which has come to the top of its orders. One-shot orders, which run once and end straight away, don't start.

| Field | Type |
|---|---|
| `object` | [object](#objects) |
| `order` | [Order](#order) |

### order_ended

`object` has ended `order`, which it had started, as the order was popped or replaced.

| Field | Type |
|---|---|
| `object` | [object](#objects) |
| `order` | [Order](#order) |

### trigger_fired

The mission's trigger number `trigger` has fired on an event of `condition`. It's one of `object`'s triggers, or a flight group's or a squad's when `object` is nil.

| Field | Type |
|---|---|
| `trigger` | number |
| `condition` | [Condition](#condition) |
| `object` | [object](#objects), or nil |

## Tables

Values given as tables of fields. Scripts can only read the ones OpenReliant gives them.

### Orientation

| Field | Type |
|---|---|
| `right` | vector |
| `down` | vector |
| `forward` | vector |

### Quadrants

| Field | Type |
|---|---|
| `left` | number |
| `right` | number |
| `fore` | number |
| `aft` | number |

### Mission

| Field | Type |
|---|---|
| `number` | number |
| `file` | string |

### OrderInfo

| Field | Type |
|---|---|
| `name` | string |
| `priority` | number |
| `flags` | [OrderFlags](#orderflags) |

### OrderFlags

| Field | Type |
|---|---|
| `players` | boolean |
| `one_shot` | boolean |
| `retaliate` | boolean |
| `avoidance` | boolean |
| `send_flight` | boolean |

### OrderEntry

| Field | Type |
|---|---|
| `order` | [Order](#order) |
| `target` | [object](#objects), or nil |
| `component` | number, or nil |

### TextStyle

A table a script gives, which may leave out any field.

| Field | Type | Default |
|---|---|---|
| `colour` | vector | `vector.create(1, 1, 1)` |
| `alpha` | number | 1 |
| `scale` | number | 1 |
| `align` | [Align](#align) | `"left"` |

### LineStyle

A table a script gives, which may leave out any field.

| Field | Type | Default |
|---|---|---|
| `colour` | vector | `vector.create(1, 1, 1)` |
| `alpha` | number | 1 |
| `width` | number | 1 |

### FillStyle

A table a script gives, which may leave out any field.

| Field | Type | Default |
|---|---|---|
| `colour` | vector | `vector.create(1, 1, 1)` |
| `alpha` | number | 1 |

### Size

| Field | Type |
|---|---|
| `width` | number |
| `height` | number |

### Outcome

| Field | Type |
|---|---|
| `ending` | [Ending](#ending) |
| `rating` | [Rating](#rating) |

## Names of values

A value that has a name in OpenReliant is given as a string: its name. One without a name is a
number. A script can set a field to either.

### ShipType

`predator`, `grendel`, `wolverine`, `reaper`, `phoenix`, `reliant`, `yamato`, `victorious`, `endeavour`, `mitchell`, `bremen`, `ulysses`, `nanny`, `limpet_car`, `prowler`, `ripper`, `mammoth`, `stork`, `sabre`, `kamov`, `scimitar`, `ramases`, `badanov`, `pukov`, `kurgan`, `sharov`, `gurevich`, `saladin`, `darkreign`, `stalag`, `antanov`, `kronstadt`, `boridin`, `troop_car`, `torpedo`, `escape_pod`, `debris`, `crewman`, `russian_torpedo`, `neptune_hi`, `uranus_hi`, `jupiter_hi`, `venus_hi`, `proto_gate`, `advanced_gate`, `proximity_mine`, `black_box`, `satellite`, `mammoth_wreck_front`, `mammoth_wreck_back`, `badanov_wreck_back`, `badanov_wreck_front`, `kurgan_wreck`, `krasnaya`, `latov`, `czar_docked`, `dm_beacon`, `kafelnikof`, `krasny`, `varyag`, `other_ramases`, `other_mitchell`, `rogue_base`, `boridin_breakaway`, `other_escape_pod`, `cargo_pod`, `zakov`, `shell`, `rock_chunk`, `limpet_pod`, `kiev`, `neptune_lo`, `uranus_lo`, `jupiter_lo`, `venus_lo`, `reliant_hangar`, `comms_relay`, `late_escape_pod`, `other_late_escape_pod`, `fuel_pod`, `t_phoenix`, `sun_marker`, `nebula_marker`, `marker`, `stand_in`, or a number.

### ShipClass

`fighter`, `capital`, `support`, `other`, `torpedo`, `debris`, `mine`, `planet`, or a number.

### Side

`friendly`, `hostile`, `neutral`, or a number.

### Order

`do_nothing`, `fly_aimlessly`, `launch_missile`, `unnamed_3`, `warp_in`, `warp_out`, `fly`, `run_away`, `land`, `escort`, `find_new_target`, `explode`, `ripper_grabs_target_object`, `object_attach`, `formation_regroup`, `patrol_route`, `toggle_cloak`, `ship_follow_curve`, `slow_rotate`, `jump_in`, `jump_out`, `find_scoop_up`, `random_spin_slow`, `random_spin_medium`, `random_spin_fast`, `fixed_gate_jump_in`, `fixed_gate_jump_out`, `formation`, `fixed_gate_open`, `fixed_gate_close`, `eject`, `fixed_gate_collapse`, `match_speed`, `dark_reign_shoot`, `move_to_spawn_pos`, `turns_object_lights_on`, `make_boridin_section_break_away`, `rotate_boridin_breakaway_warp_projector`, `start_warp_projection_from_boridin`, `make_ripper_drop_what_its_carrying`, `jump_in_40`, `jump_out_41`, `turns_object_lights_off`, `huuuuuuuge_explosion`, `immediately_set_ship_to_zero_velocity_and_rotation`, `fly_ship_backwards`, `player_control`, `multiplayer_control`, `avoid_target`, `torpedo`, `launch`, `fight`, `eject_106`, `scoop_up`, `eject_spin`, `dock`, `dark_reign_shoot_110`, `ripper_end_drop_object`, `ripper_attach_cargo_pod_to_mammoth`, `eject_fighter_attack`, `disrupted`, `make_capship_list_left`, `make_capship_list_right`, `friendly_fire`, `eject_player`, `ship_follow_curve_backwards`, `mill`, `deathmatch_respawn_effect`, `deathmatch_dark_reign_target`, `unnamed_200`, or a number.

### Align

`left`, `centre`, `right`, or a number.

### Key

`escape`, `one`, `two`, `three`, `four`, `five`, `six`, `seven`, `eight`, `nine`, `zero`, `minus`, `equals`, `backspace`, `tab`, `q`, `w`, `e`, `r`, `t`, `y`, `u`, `i`, `o`, `p`, `left_bracket`, `right_bracket`, `enter`, `left_control`, `a`, `s`, `d`, `f`, `g`, `h`, `j`, `k`, `l`, `semicolon`, `apostrophe`, `grave`, `left_shift`, `backslash`, `z`, `x`, `c`, `v`, `b`, `n`, `m`, `comma`, `period`, `slash`, `right_shift`, `keypad_multiply`, `left_alt`, `space`, `caps_lock`, `f1`, `f2`, `f3`, `f4`, `f5`, `f6`, `f7`, `f8`, `f9`, `f10`, `num_lock`, `scroll_lock`, `keypad_7`, `keypad_8`, `keypad_9`, `keypad_minus`, `keypad_4`, `keypad_5`, `keypad_6`, `keypad_plus`, `keypad_1`, `keypad_2`, `keypad_3`, `keypad_0`, `keypad_period`, `non_us_backslash`, `f11`, `f12`, `keypad_enter`, `right_control`, `keypad_divide`, `print_screen`, `right_alt`, `pause`, `home`, `up`, `page_up`, `left`, `right`, `end`, `down`, `page_down`, `insert`, `delete`, `left_windows`, `right_windows`, `menu`, or a number.

### Action

`cockpit_camera`, `left_view_camera`, `right_view_camera`, `rear_view_camera`, `flyby_camera`, `target_camera`, `external_camera`, `missile_camera`, `next_enemy_target`, `previous_enemy_target`, `next_friendly_target`, `previous_friendly_target`, `next_subtarget`, `previous_subtarget`, `target_under_reticule`, `target_nearest_enemy`, `target_nearest_friendly`, `target_torpedo`, `smart_target`, `primary_target`, `afterburners`, `afterburner_toggle`, `reverse_thrust`, `jump_drive`, `match_speed`, `accelerate`, `decelerate`, `zero_throttle`, `full_throttle`, `roll_ship_clockwise`, `roll_ship_anti_clockwise`, `nose_up`, `nose_down`, `rotate_clockwise`, `rotate_anti_clockwise`, `strafe_left`, `strafe_right`, `joystick_roll`, `fire_lasers`, `full_guns`, `gunnery_window`, `gunnery_window_locked`, `synchronise_guns`, `toggle_blindfire`, `launch_missile`, `missile_window`, `rotate_missiles_clockwise`, `rotate_missiles_anticlockwise`, `comms_window`, `powerball_window`, `powerball_window_locked`, `full_power_to_gunnery`, `full_power_to_engines`, `full_power_to_shields`, `equalize_power`, `objectives_window`, `wing_status_window`, `wing_status_window_locked`, `damage_window`, `damage_window_locked`, `radar_ranges`, `shield_balancing`, `countermeasures`, `eject`, `cloak_ship`, `ecm`, `spectral_shields`, `attack_my_target`, `back_off`, `help_me`, `permission_to_land`, `display_kills`, `send_comms_message`, `key_config`.

### View

`cockpit`, `cockpit_left`, `cockpit_right`, `cockpit_rear`, `chase`, `chase_too`, `launch_bay`, `launch_below`, `launch_aside`, `landing_tube`, `landing_aside`, `jump_out`, `jump_in_close`, `jump_in_ahead`, `jump_in_aside`, `target`, `external`, `director`, `pull_back`, `missile`, `eject`, `pickup`, `pod_shot`, `watch`, `watch_marker`, `flyby`, or a number.

### BettyLine

`missiles_gone`, `armor_failing`, `screamer`, `havoc`, `jack_hammer`, `vagabond`, `imp`, `bandit`, `raptor`, `hawk`, `solomon`, `countermeasures_low`, `countermeasures_gone`, `cloak_on`, `cloak_off`, `blind_fire_on`, `blind_fire_off`, `spectral_shields_on`, `spectral_shields_off`, or a number.

### Axis

`x`, `y`, `z`.

### Ending

`playing`, `destroyed`, `rescued`, `captured`, `left`, `total_failure`, `friendly_fire`, `ejecting`, or a number.

### Rating

`total_failure`, `failure`, `partial_failure`, `partial_success`, `success`, `success_bonus`, or a number.

### Quadrant

`left`, `right`, `fore`, `aft`.

### DamageKind

`bullet`, `missile`, `collision`, `crash`, `screamer`, or a number.

### GunType

`laser_cannon`, `pulse_cannon`, `messon_blaster`, `proton_cannon`, `gattling_lasers`, `tachyon_cannon`, `neutron_particle_gun`, `collapser_guns`, `gattling_plasma_cannon`, `vulcan_battery`, `nova_cannon`, `turret_flak`, `turret_lasers`, `allied_huge_gun`, `coalition_huge_gun`.

### Condition

`shot_at`, `destroyed`, `launched`, `camera_reached`, `ship_reached`, `proximity_close`, `proximity_general`, `object_scooped`, `player_ready_to_jump`, `jumped_in`, `fixed_gate_jumped_in`, `player_ready_to_warp`, `jumped_through_hoop`, `player_wants_backup`, `ripper_grabbed_object`, `ripper_dropped_object`, `cloaked`, `decloaked`, `targetted`, `player_l1_doubletap`, `player_l2_doubletap`, `player_r1_doubletap`, `player_r2_doubletap`, `player_l1_l2_r1_r2_pressed`, `player_l1_r1_pressed`, `game_timer_expired`, `tractor_beam_locked`, `tractor_beam_broken`, `inside_object`, `outside_object`, `docked`, `undocked`, `being_chased`, `call_reinforcements`, `explosion_ship`, or a number.

### PilotTier

`level_0`, `level_1`, `level_2`, or a number.

### PilotSkill

`low`, `medium`, `high`, or a number.
