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
| `on_init(data: any?)` | global and object | When the script starts, with the data `add_script` gave it, or nil. |
| `on_records_loaded()` | load | After every mod's load scripts have run. |
| `on_update(seconds: number)` | global and object | Each frame in which game time passes, after the ships' orders, with the seconds it covers. |
| `on_step()` | global and object | Each simulation step, 25 a second, after everything has moved. |
| `on_mission_start(mission: Mission)` | global | When a mission has started and its first ships are there. |
| `on_mission_end(outcome: Outcome)` | global | When the mission ends, for whatever reason. |
| `on_object_added(object: Object)` | global | When an object is added to the mission. |
| `on_object_removed(object: Object)` | global | When an object leaves the mission, such as once it has blown up. |
| `on_added()` | object | When the script's object is in the mission: as it's added, or at once if the script starts later. |
| `on_removed()` | object | When the script's object leaves the mission. |
| `on_interface_override(base: { [any]: any })` | global and object | When the script's interface takes the place of one an earlier script offered under the same name, with that one. |

## Packages

What `require("openreliant.<name>")` gives.

### `openreliant.core`

OpenReliant's version, and events for the global scripts. For load, global and object scripts.

| Name | Type | What it is |
|---|---|---|
| `version` | string | The version of OpenReliant, such as `0.7.0`. |
| `send_global_event(name: string, data: any)` | nothing | Sends the event `name` to the global and mission scripts, with `data`, which must be plain data. It arrives at the next update. |

### `openreliant.records`

The game's records: ships, guns, missiles, pilots and text. Only load scripts can change them. For load, global and object scripts.

### `openreliant.hooks`

Handlers on the game's functions and events. For global and object scripts.

### `openreliant.world`

The mission's objects, the player's ship and the mission itself. For global scripts.

| Name | Type | What it is |
|---|---|---|
| `player` | [object](#objects), or nil | The player's ship, while a mission runs; nil between missions. |
| `mission` | [Mission](#mission), or nil | The mission that runs, with its `number` and its `file`'s name; nil between missions. |
| `objects()` | { Object } | Every object in the mission, in the order of their slots. |

### `openreliant.self`

The script's own object, as a handle. For object scripts.

### `openreliant.nearby`

The objects around the script's own. For object scripts.

| Name | Type | What it is |
|---|---|---|
| `objects(radius: number)` | { Object } | The objects within `radius` of the script's object, nearest first, without it. |

### `openreliant.interfaces`

The interfaces other scripts offer, as `I.<name>`: those of the global scripts to global scripts, and those of an object's scripts to the object's other scripts. Nil for one nobody offers. For global and object scripts.

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

Values given as tables of fields, which scripts can only read.

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
