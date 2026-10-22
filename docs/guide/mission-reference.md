# Mission source reference

This page lists everything mission source holds: its declarations and their fields, the
functions and values of its script, the game's commands and conditions, and the names of the
game's values. [Mission source](../formats/mission-source.md) explains the syntax, and editors
complete and describe the same names from [`mission.d.luau`](mission.d.luau).
`sltool dte reference` writes this page from the game's tables.

## Declarations

The file's top level holds declarations: `name = constructor(...)` declares a record under
`name`, `on(...)` a trigger, and `mission(...)` gives the mission's own details.

### `mission`

```luau
mission(fields: MissionFields): ()
```

Gives the mission's own details.

### `global`

```luau
global(name: string, value: number): number
```

Declares a global: its display name and the value it starts with.

### `flight_group`

```luau
flight_group(name: string, fields: FlightGroupFields?): FlightGroup
```

Declares a flight group, by its display name.

### `ship`

```luau
ship(name: string, fields: ShipFields): MissionShip
```

Places a ship, a capital ship or a station, by its display name.

### `nav_point`

```luau
nav_point(name: string, fields: MarkerFields?): MissionShip
```

Places a nav point, by its display name.

### `waypoint`

```luau
waypoint(name: string, fields: MarkerFields?): MissionShip
```

Places a waypoint, by its display name.

### `point`

```luau
point(name: string, fields: PointFields?): MissionShip
```

Places a point, by its display name, such as one a camera curve runs to.

### `curve_point`

```luau
curve_point(name: string, fields: MarkerFields?): MissionShip
```

Places a curve point, by its display name.

### `squad`

```luau
squad(name: string, members: { Entity }): Squad
```

Declares a squad: its display name and its members in their order, ships, ships' components, flight groups and other squads.

### `formation`

```luau
formation(name: string, points: { Vector }): Formation
```

Declares a formation: its display name and its points, each where it stands from the formation's origin. A ship names a point as `sabres[1]` for the first.

### `curve`

```luau
curve(fields: CurveFields): Curve
```

Declares a curve, which has no display name.

### `part`

```luau
part<A...>(name: string, code: ((A...) -> number)?, fields: PartFields?): (A...) -> number
```

Declares a part: its display name and its code, a function whose parameters are the part's arguments. A part without a function has no block.

### `handler`

```luau
handler<A...>(code: (A...) -> number): (A...) -> number
```

Declares code that more than one trigger runs.

### `on`

```luau
on(subject: Entity?, condition: Condition, fields: (TriggerFields | Code)?, code: Code?): ()
```

Declares a trigger: its subject, the ship, flight group or squad whose events it watches, or nil for none; its condition; its fields, which can be left out; and the code its events run, whose parameters are the values the condition's events carry.

## Tables of fields

A declaration's fields go in a table, `{ name = value }`. A field whose type ends in `?` can
be left out.

### MissionFields

| Field | Type | What it is |
|---|---|---|
| `name` | `string?` | OpenReliant's name for the mission, which the game doesn't read. |

### FlightGroupFields

| Field | Type | What it is |
|---|---|---|
| `wing` | `Wing?` | The wing the group's ships are listed in: "player", "second", "third" or "none", the default. |
| `formation` | `Formation?` | The formation the group flies in. |

### ShipFields

| Field | Type | What it is |
|---|---|---|
| `type` | `ShipType` | The ship's type. |
| `group` | `FlightGroup?` | Its flight group. |
| `pilot` | `PilotNumber?` | Its pilot, by its record of pilotstats.bin. |
| `position` | `Vector?` | Where it is, `{ x, y, z }`, in the game's coordinates, Y down; `{ 0, 0, 0 }` by default. |
| `yaw` | `number?` | Its yaw, in whole degrees; -1 where the mission leaves the angle unset. 0 by default. |
| `pitch` | `number?` | Its pitch, in whole degrees; -1 where the mission leaves the angle unset. 0 by default. |
| `roll` | `number?` | Its roll, in whole degrees; -1 where the mission leaves the angle unset. 0 by default. |
| `launch` | `Launch?` | Where it launches from: `{ from = "reliant", gate = 2 }`. By default it doesn't launch. |
| `formation_point` | `FormationPoint?` | Its place in a formation: `sabres[2]` is the second point of the formation `sabres`. |
| `tier` | `number?` | The loadout tier its missile racks are fitted by; 255, the default, asks for the campaign's. |

### MarkerFields

| Field | Type | What it is |
|---|---|---|
| `group` | `FlightGroup?` | Its flight group. |
| `pilot` | `PilotNumber?` | Its pilot, by its record of pilotstats.bin. |
| `position` | `Vector?` | Where it is, `{ x, y, z }`, in the game's coordinates, Y down; `{ 0, 0, 0 }` by default. |
| `yaw` | `number?` | Its yaw, in whole degrees; -1 where the mission leaves the angle unset. 0 by default. |
| `pitch` | `number?` | Its pitch, in whole degrees; -1 where the mission leaves the angle unset. 0 by default. |
| `roll` | `number?` | Its roll, in whole degrees; -1 where the mission leaves the angle unset. 0 by default. |
| `launch` | `Launch?` | Where it launches from: `{ from = "reliant", gate = 2 }`. By default it doesn't launch. |
| `formation_point` | `FormationPoint?` | Its place in a formation: `sabres[2]` is the second point of the formation `sabres`. |
| `tier` | `number?` | The loadout tier its missile racks are fitted by; 255, the default, asks for the campaign's. |

### PointFields

| Field | Type | What it is |
|---|---|---|
| `group` | `FlightGroup?` | Its flight group. |
| `pilot` | `PilotNumber?` | Its pilot, by its record of pilotstats.bin. |
| `position` | `Vector?` | Where it is, `{ x, y, z }`, in the game's coordinates, Y down; `{ 0, 0, 0 }` by default. |
| `yaw` | `number?` | Its yaw, in whole degrees; -1 where the mission leaves the angle unset. 0 by default. |
| `pitch` | `number?` | Its pitch, in whole degrees; -1 where the mission leaves the angle unset. 0 by default. |
| `roll` | `number?` | Its roll, in whole degrees; -1 where the mission leaves the angle unset. 0 by default. |
| `launch` | `Launch?` | Where it launches from: `{ from = "reliant", gate = 2 }`. By default it doesn't launch. |
| `formation_point` | `FormationPoint?` | Its place in a formation: `sabres[2]` is the second point of the formation `sabres`. |
| `tier` | `number?` | The loadout tier its missile racks are fitted by; 255, the default, asks for the campaign's. |
| `marker` | `Marker?` | For a point that marks a place on a curve: `{ curve = camera_curve, at = 0.5 }`. |

### Launch

| Field | Type | What it is |
|---|---|---|
| `from` | `ShipType` | The type of ship it launches from, the first of that type in the mission. |
| `gate` | `number` | The gate it launches through. |

### Marker

| Field | Type | What it is |
|---|---|---|
| `curve` | `Curve` | The curve it marks a place on. |
| `at` | `number?` | The share of the way along the curve. |

### CurveFields

| Field | Type | What it is |
|---|---|---|
| `start` | `MissionShip?` | The ship the curve starts at; none by default. |
| `finish` | `MissionShip?` | The ship the curve ends at; none by default. |
| `from` | `Vector?` | Where the curve starts. |
| `to` | `Vector?` | Where the curve ends. |
| `leaving_handle` | `MissionShip?` | The ship the curve's leaving tangent is drawn to. |
| `arriving_handle` | `MissionShip?` | The ship the curve's arriving tangent is drawn to. |
| `leaving` | `Vector?` | The curve's leaving tangent. |
| `arriving` | `Vector?` | The curve's arriving tangent. |

### PartFields

| Field | Type | What it is |
|---|---|---|
| `start` | `boolean?` | `true` runs the part as the mission starts, before any trigger is armed. |

### TriggerFields

| Field | Type | What it is |
|---|---|---|
| `repeats` | `Repeats?` | "once", the default, which disarms the trigger as it fires; "always"; or `{ counted = 3 }`, which fires that many times each time the script arms it. |
| `component` | `number?` | The subject's component it watches, by its index; by default the subject itself. |
| `deferred` | `boolean?` | `true` leaves the trigger's thread to the scheduler rather than running it inside the event. |
| A value's name | `(Entity \| number)?` or `number?` | For each value of the condition's events that a trigger can check, what it must be for the trigger to fire ([Conditions](#conditions)). |

### Counted

| Field | Type | What it is |
|---|---|---|
| `counted` | `number` | How many times the trigger fires each time the script arms it. |
| `left` | `number?` | How many firings are left as the mission starts; by default as many as it counts. |

## The script's functions and values

The code of parts and triggers uses these besides the commands, its parameters, the file's
names and Luau's operators.

### `component`

```luau
component<T>(object: T, index: number): T
```

A ship's component, by its index.

### `any_ship`

```luau
any_ship: MissionShip
```

Any of the players' ships, as a value a trigger checks.

### `command`

```luau
command(number: number, ...: any): ()
```

Runs a command the catalogue doesn't have, by its number.

### `spawn`

```luau
spawn<A...>(part: (A...) -> number, ...: A...): ()
```

Starts a part on a thread of its own, with its arguments after the part.

### `random`

```luau
random(): number
```

Rolls a random choice: `local roll = random()`, then an `if` over the arms' thresholds, `if roll < 50 then`, with the default as `else`.

### `result`

```luau
result(): number
```

The result of the last command.

### `game`

```luau
game: GameVariables
```

The game's variables, by their names, or by their numbers, as in `game[37]`, for those without.

### `thread_value`

```luau
thread_value(place: number): any
```

A value of the event that started the thread, by its place, in a part.

### `last_event`

```luau
last_event(object: Entity, condition: Condition, value: EventValue): any
```

A value an object keeps of its last event of a condition, by its label in the condition catalogue: `last_event(ship, "shot_at", "Hull Damage")`.

### `in_flight_group`

```luau
in_flight_group(object: Entity, group: FlightGroup): boolean
```

Whether a ship is in a flight group.

### `not_in_flight_group`

```luau
not_in_flight_group(object: Entity, group: FlightGroup): boolean
```

Whether a ship isn't in a flight group.

### `in_squad`

```luau
in_squad(object: Entity, squad: Squad): boolean
```

Whether an object is in a squad.

### `not_in_squad`

```luau
not_in_squad(object: Entity, squad: Squad): boolean
```

Whether an object isn't in a squad.

### `greater_f`

```luau
greater_f(a: number, b: number): boolean
```

`a > b`, comparing floating-point numbers.

### `greater_equal_f`

```luau
greater_equal_f(a: number, b: number): boolean
```

`a >= b`, comparing floating-point numbers.

### `less_f`

```luau
less_f(a: number, b: number): boolean
```

`a < b`, comparing floating-point numbers.

### `less_equal_f`

```luau
less_equal_f(a: number, b: number): boolean
```

`a <= b`, comparing floating-point numbers.

### `add_f`

```luau
add_f(a: number, b: number): number
```

`a + b`, in floating point.

### `sub_f`

```luau
sub_f(a: number, b: number): number
```

`a - b`, in floating point.

### `mul_f`

```luau
mul_f(a: number, b: number): number
```

`a * b`, in floating point.

### `div_f`

```luau
div_f(a: number, b: number): number
```

`a / b`, in floating point.

### `add_assign_f`

```luau
add_assign_f(target: number, value: number): ()
```

`target += value`, in floating point.

### `sub_assign_f`

```luau
sub_assign_f(target: number, value: number): ()
```

`target -= value`, in floating point.

### `mul_assign_f`

```luau
mul_assign_f(target: number, value: number): ()
```

`target *= value`, in floating point.

### `div_assign_f`

```luau
div_assign_f(target: number, value: number): ()
```

`target /= value`, in floating point.

## References past the records

A reference to a record that the mission doesn't have, such as a curve's ship in some of the
leftover missions, is written by its index.

### `ship_index`

```luau
ship_index(index: number): MissionShip
```

A ship past the mission's records, by its index.

### `flight_group_index`

```luau
flight_group_index(index: number): FlightGroup
```

A flight group past the mission's records, by its index.

### `squad_index`

```luau
squad_index(index: number): Squad
```

A squad past the mission's records, by its index.

### `curve_index`

```luau
curve_index(index: number): Curve
```

A curve past the mission's records, by its index.

### `global_index`

```luau
global_index(index: number): number
```

A global past the mission's records, by its index.

### `part_index`

```luau
part_index(index: number): Part
```

A part past the mission's records, by its index.

### `object_index`

```luau
object_index(id: number): Entity
```

An object by its number in the built mission. A number past its records gets an entry of no record in the object table.

### `formation_index`

```luau
formation_index(index: number): Formation
```

A formation past the mission's records, by its index.

### `formation_point_index`

```luau
formation_point_index(index: number): FormationPoint
```

A formation point by its index among all the mission's points.

## Types

The types the declarations, the functions and the commands take and give, besides the tables
of fields and the names of values.

| Type | Is | What it is |
|---|---|---|
| `MissionShip` | A type of its own | A ship, a capital ship, a station or a marker, such as a nav point. |
| `FlightGroup` | A type of its own | A flight group. |
| `Squad` | A type of its own | A squad. |
| `Curve` | A type of its own | A camera or flight curve. |
| `FormationPoint` | A type of its own | A point of a formation. |
| `Formation` | A type of its own, `[number]: FormationPoint` | A formation, whose points a ship names as `sabres[1]` for the first. |
| `Entity` | `MissionShip \| FlightGroup \| Squad` | A ship, a flight group or a squad: what a trigger watches, and what most commands act on. |
| `Vector` | `{ number }` | A place or a direction: `{ x, y, z }`. |
| `Code` | `(...any) -> number` | The code a trigger runs: a function whose parameters are the values its condition's events carry. |
| `Part` | `(...any) -> number` | A part, which runs as `go_home()`, and which commands such as `CreateTimer` take. |
| `Repeats` | `"once" \| "always" \| Counted \| number` | How a trigger repeats. |

## Commands

The game's commands, from its catalogue. Their names, their parameters' labels and their
descriptions are the developers' own, and the parameters' names are made from the labels. A
command the catalogue doesn't have runs as `command(number, ...)`.

### PrintShipName

Test Function. Command 0 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `test_param_1` | `MissionShip \| FlightGroup \| string` | Test Param 1 |
| `test_param_2` | `number` | Test Param 2 |

### CreateTimer

Creates a timer to invoke a function. Command 1 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `unique_id_to_identify_timer` | `number` | Unique ID to identify timer |
| `function_to_execute_when_timer_activates` | `Part` | Function to execute when timer activates |
| `number_of_seconds_before_timer_activates` | `number` | Number of seconds before timer activates |
| `number_of_activations` | `number` | Number of activations (0 == continuous) |

### DestroyTimer

Destroys all timers associated with a function. Command 2 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `unique_id_of_timer_to_be_destroyed` | `number` | Unique ID of timer to be destroyed |

### CreateFlightGroup

Initializes a flight group. Command 3 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `flight_group_name_to_initialize` | `FlightGroup` | Flight Group name to initialize |

### DestroyFlightGroup

Destroys a flight group. Command 4 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `flight_group_name_to_destroy` | `FlightGroup` | Flight Group name to destroy |

### Wait

Stop Executing for N Seconds. Command 5 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `number_of_seconds_to_wait` | `number` | Number of Seconds to wait |

### PlaySpeech

Play a speech file. Command 6 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `name_of_speech_file` | `string` | Name of speech file |

### WaitForSpeech

Pause script until speech is complete. Command 7 of the catalogue.

Takes nothing.

### PlayCommsMovie

Play a movie in the comms window. Command 8 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `name_of_movie_file` | `string` | Name of movie file |
| `name_of_speech_file` | `string` | Name of speech file |
| `gtext_thingy_hangover_err` | `number` | GText thingy hangover err.... |

### WaitForMovie

Pause script until comms movie is complete. Command 9 of the catalogue.

Takes nothing.

### PrintDebugMessage

Prints a debugging message on screen. Command 10 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `text_to_print` | `string` | Text to print |

### SetAI

Sets a Ship or Flight Group's AI pattern. Command 11 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_to_be_controlled` | `Entity` | Entity to be controlled |
| `ai_mode` | `Order` | AI Mode |
| `initialize_immediately` | `number` | Initialize Immediately (T/F) |
| `entity_to_target` | `Entity?` | Entity to target (can be NULL) |

### ClearAI

Resets all AI intructions for an entity. Command 12 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_to_be_cleared` | `Entity` | Entity to be cleared |

### SetPatrolRoute

Sends a Ship to follow a patrol route. Command 13 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_to_send_to_patrol_route` | `MissionShip \| FlightGroup` | Entity to send to patrol route |
| `patrol_route_to_follow` | `FlightGroup` | Patrol route to follow |

### SetPilot

Assigns a pilot to fly a ship. Command 14 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_to_host_pilot` | `MissionShip` | Ship to host pilot |
| `pilot_to_fly_ship` | `PilotNumber` | Pilot to fly ship |

### SetTriggerState

Enables or disables the state of a trigger. Command 15 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_owning_trigger` | `Entity` | Entity owning trigger |
| `trigger_type_to_enable_disable` | `Condition` | Trigger type to enable/disable |
| `true_for_enable` | `number` | TRUE for enable; FALSE for disable |

### StartDirectorCam

Sets the camera to start following a predefined path. Command 16 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `curve_for_camera_to_follow` | `MissionShip \| Curve` | Curve for camera to follow (or Ship for static cam) |
| `ship_for_camera_to_track` | `MissionShip?` | Ship for camera to track (can be NULL) |
| `duration_of_camera` | `number` | Duration of camera (seconds) |
| `tracks_curve_to_this_ship_s_speed` | `MissionShip?` | Tracks curve to this ship's speed (can be NULL) |
| `ships_to_disable_for_duration` | `Entity?` | Ships to disable for duration |

### StartShipAnimation

Starts a specific animation for a ship. Command 17 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_to_animate` | `MissionShip` | Ship to animate |
| `animation_name` | `string` | Animation Name |

### ShipFollowCurve

Sets an ship/flight group to follow a predefined path. Command 18 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_to_follow_curve` | `MissionShip \| FlightGroup` | Entity to follow curve |
| `the_curve_for_the_entity_to_follow` | `Curve` | The curve for the entity to follow |
| `duration_of_movement` | `number` | Duration of movement (seconds) |

### SetupLaunch

Sets up a ship ready to launch. Command 19 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_to_be_launched` | `Entity` | Entity to be launched |
| `ship_to_launch_from` | `Entity` | Ship to launch from |
| `launch_position` | `number` | Launch position |

### StartLaunch

Launches a ship. Command 20 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_to_be_launched` | `Entity` | Entity to be launched |

### DisplaySubTitle

Prints a subtitle so we can understand those foreign bods. Command 21 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `gtext_pilot_define` | `number` | GText pilot define |

### ResetCodePriority

Clears/removes any priortiy order of the entity. Command 22 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_to_have_priorities_reset` | `Entity` | Entity to have priorities reset |

### InterruptTriggerCode

Stops script execution, will resume when trigger re-enabled. Command 23 of the catalogue.

Takes nothing.

### CommsFromShip

Play a movie in the comms window. Command 24 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_sending_comm` | `MissionShip` | Ship sending comm |
| `head_movement` | `FaceFilm` | Head movement |
| `name_of_speech_file` | `string` | Name of speech file |

### CommsFromPilot

Play a movie in the comms window. Command 25 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_sending_comm` | `PilotNumber` | Ship sending comm |
| `head_movement` | `FaceFilm` | Head movement |
| `name_of_speech_file` | `string` | Name of speech file |

### SetInvulnerability

Makes or stops a ship being invulnerable. Command 26 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_concerned` | `Entity` | Ship concerned |
| `invulnerability` | `number` | Invulnerability (0 - non, 1 - player can hit, 2 - fully invulnerable, 3 - Eject before exploding) |

### MovingShipFollowCurve

Sets an ship/flight group to follow a predefined path. Command 27 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_to_follow_curve` | `MissionShip \| FlightGroup` | Entity to follow curve |
| `the_curve_for_the_entity_to_follow` | `Curve` | The curve for the entity to follow |
| `duration_of_movement` | `number` | Duration of movement (seconds) |
| `entity_for_curve_to_use_as_its_start_offset` | `MissionShip` | Entity for curve to use as its start offset |

### DisableObject

Stops entities from being processed. Command 28 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_concerned` | `Entity` | Entity concerned |
| `true_false` | `number` | True/False |

### PositionRelative

Positions an entity relative to a ship/point's movement. Command 29 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_to_position` | `Entity` | Entity to position |
| `ship_point_to_use_as_relative_marker` | `MissionShip` | Ship/Point to use as relative marker |

### WhenPlayerLastJumped

Returns the number of seconds ago when the player jumped. Command 30 of the catalogue.

Takes nothing.

### StartMissileCam

Starts director cam for a missile. Command 31 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_that_fired_missile` | `MissionShip` | Ship that fired missile |

### StartChaseCam

Starts chase cam. Command 32 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_to_follow` | `MissionShip?` | Ship to follow |

### SetPlayerTarget

Sets player's target. Command 33 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `player_ship` | `MissionShip` | Player Ship |
| `ship_to_target` | `MissionShip` | Ship to target |

### SetTargetable

Sets an entity to be targetable or not. Command 34 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity` | `Entity` | Entity |
| `true_object_targetable` | `number` | true - object targetable, false - not targetable |

### PlayMusic

Play a Music Track. Command 35 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `name_of_music_file` | `string` | Name of music file |
| `true_play_immediately` | `number` | True - Play Immediately, false - Fade old tune first |

### StopDirectorCam

Stops the Current Director Camera. Command 36 of the catalogue.

Takes nothing.

### SetActionCentre

Sets the sphere for the action to be contained in. Command 37 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `object_to_action_around` | `MissionShip` | Object to action around |
| `radius_of_sphere_0_for_default` | `number` | Radius of sphere - 0 for default |

### Dock

Dock Ship. Command 38 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_to_dock` | `MissionShip` | Ship to dock |
| `object_ship_is_to_dock_to` | `MissionShip` | Object ship is to dock to |
| `docking_port` | `number` | Docking port |

### DisableTaunts

Stops bad guys from taunting the player. Command 39 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `true_disable_bad_guy_taunts` | `number` | true - Disable bad guy taunts |

### Fly

Fly. Command 40 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_param` | `Entity` | Ship |
| `point_to_fly_to` | `MissionShip?` | Point to fly to |
| `speed` | `number` | Speed (0 - Default) |

### CommsFromShipOnce

Play a movie in the comms window (without looping). Command 41 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_sending_comm` | `MissionShip` | Ship sending comm |
| `head_movement` | `FaceFilm` | Head movement |
| `name_of_speech_file` | `string` | Name of speech file |

### CommsFromPilotOnce

Play a movie in the comms window (without looping). Command 42 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_sending_comm` | `PilotNumber` | Ship sending comm |
| `head_movement` | `FaceFilm` | Head movement |
| `name_of_speech_file` | `string` | Name of speech file |

### DisableLights

Disable Object lights. Command 43 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity` | `Entity` | Entity |
| `true_or_false` | `number` | True or False |

### SetEnvironmentFX

Sets an environment effect. Command 44 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `effect_type_to_set` | `EnvironmentEffect` | Effect type to set |
| `on_param` | `number` | On(TRUE) or Off(FALSE) |

### MultiPlayerSync

Jay's shit. Command 45 of the catalogue.

Takes nothing.

### DisableGenericComms

Stops hard coded comms events from triggering. Command 46 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `true_disable_all_hard_coded_comms_events` | `number` | True - Disable all hard coded comms events |

### DisableGuns

Disables guns. Command 47 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity` | `Entity` | Entity |
| `true_disable_guns` | `number` | TRUE - disable guns, FALSE enable guns |

### SetNavPoint

Set Nav Point. Command 48 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity` | `Entity` | Entity |
| `nav_point_param` | `MissionShip?` | Nav Point |

### SetEscortPoint

Set Escort Point. Command 49 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity` | `Entity` | Entity |
| `escort_point` | `MissionShip?` | Escort Point |

### ResetAfterBurners

Reset the player's afterburner fuel. Command 50 of the catalogue.

Takes nothing.

### DisableMissiles

Disables missiles. Command 51 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity` | `Entity` | Entity |
| `true_disable_missiles` | `number` | TRUE - disable missiles, FALSE enable missiles |

### DisableEngines

Disables engines. Command 52 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity` | `Entity` | Entity |
| `true_disable_engines` | `number` | TRUE - disable engines, FALSE enable engines |

### DisableEject

Disables eject. Command 53 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity` | `Entity` | Entity |
| `true_disable_eject` | `number` | TRUE - disable eject, FALSE enable eject |

### SetHostile

Sets entity(s) to be hostile or not. Command 54 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity` | `Entity` | Entity |
| `true_entity` | `number` | true - entity(s) hostile, false - friendly |

### ResetToSpawnPositions

Resets the player to a random spawn location (deathmatch only). Command 55 of the catalogue.

Takes nothing.

### UpdateEnvironmentFXState

Updates state of environment FX instead of waiting for next jump. Command 56 of the catalogue.

Takes nothing.

### SetPrimaryTarget

Set Primary Target. Command 57 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity` | `MissionShip?` | Entity |

### WaitForJumpOrLaunch

Wait for ships to finish jumping or launching. Command 58 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity` | `Entity` | Entity |

### DoNotDisturb

Sets entity(s) so comms can/cant disturb them. Command 59 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity` | `Entity` | Entity |
| `true_dont_disturb` | `number` | true - dont disturb, false - can disturb |

### SetEnvironmentFXNebula

Sets the nebula material and lighting. Command 60 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `index_of_nebula_material` | `number` | Index of nebula material (0..6) |

### StartShipAnimationReverse

Starts a specific animation for a ship in reverse. Command 61 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_to_animate` | `MissionShip` | Ship to animate |
| `animation_name` | `string` | Animation Name |

### SnapToPoint

Snaps a ship to a specific point. Command 62 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_to_move` | `MissionShip` | Ship to move |
| `point_to_move_to` | `MissionShip` | Point to move to |

### PlayFostersLastStand

Plays the Foster's Last Stand movie! Command 63 of the catalogue.

Takes nothing.

### OpenInstrument

Opens up a window on the HUD. Command 64 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `instrument_number_to_open` | `number` | Instrument number to open |

### CloseInstrument

Closes a window on the HUD. Command 65 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `instrument_number_to_close` | `number` | Instrument number to close |

### DestroySubObject

Destroys Subobject. Command 66 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `sub_object_to_destroy` | `MissionShip` | SubObject to destroy |
| `true_keep_damaged_model` | `number` | true - keep damaged model, false - no damaged model |

### SetObjective

Sets a Mission Objective's status. Command 67 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `objective_number` | `number` | Objective number |
| `state` | `number` | State(0=Inactive, 1=Active, 2=Current) |

### SetRescueProbabilities

Sets an Ejected pod's chances of survival. Command 68 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `probability_of_nanny_rescue` | `number` | Probability of Nanny Rescue    ( 1-100% ) |
| `probability_of_antanov_capture` | `number` | Probability of Antanov Capture ( 1-100% ) |
| `probability_of_being_destroyed` | `number` | Probability of being Destroyed ( 1-100% ) |

### IsShipThisPlayer

Returns TRUE if ship is the players ship. Command 69 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_to_test` | `MissionShip` | Ship to test |

### SetFlybackMarker

Sets a Flyback marker on a ship or a group of ships after a set range. Command 70 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_concerned` | `Entity` | Entity concerned |
| `range` | `number` | Range |

### ResetFlybackMarker

Resets all flyback markers. Command 71 of the catalogue.

Takes nothing.

### StopShipAnimation

Stops a specific animation for a ship. Command 72 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_to_stop_animation_for` | `MissionShip` | Ship to stop animation for |
| `animation_name` | `string` | Animation Name |

### SetShipAvoidance

Enables/Disables ship avoidance for the ship(s). Command 73 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_concerned` | `Entity` | Entity concerned |
| `true_disable_avoidance_code` | `number` | TRUE - Disable Avoidance code, FALSE - Enable avoidance code |

### MatchSpeed

Enables/Disables Match Speed with target. Command 74 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_concerned` | `MissionShip` | Entity concerned |
| `true_enable_match_speed` | `number` | TRUE - Enable Match Speed, FALSE - Disable Match Speed |

### MovingShipBackupCurve

Sets an ship/flight group to follow a predefined path. Command 75 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_to_follow_curve` | `MissionShip \| FlightGroup` | Entity to follow curve |
| `the_curve_for_the_entity_to_follow` | `Curve` | The curve for the entity to follow |
| `duration_of_movement` | `number` | Duration of movement (seconds) |
| `entity_for_curve_to_use_as_its_start_offset` | `MissionShip?` | Entity for curve to use as its start offset |

### WaitForKey

Stops script until key pressed. Command 76 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `key_number_to_wait_for` | `number` | Key number to wait for |

### TerminateMission

End the mission, and drop to death sequence. Command 77 of the catalogue.

Takes nothing.

### TurretSetTarget

Sets the target for a ships turret. Command 78 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `turret` | `MissionShip \| Squad` | Turret |
| `entity_to_target` | `MissionShip` | Entity to target |

### SetAnyTriggerState

Enables or disables the state of a trigger. Command 79 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_owning_trigger` | `Entity` | Entity owning trigger |
| `trigger_type_to_enable_disable` | `Condition` | Trigger type to enable/disable |
| `true_for_enable` | `number` | TRUE for enable; FALSE for disable |
| `trigger_type_number` | `number` | Trigger Type Number(for triggers of same type - Count from 0) |

### WaitForDirectorCam

Waits for director cam to finish. Command 80 of the catalogue.

Takes nothing.

### KillAllScriptExecutionExecptMe

DANGER DANGER:Cancels ALL current script execution except the caller. Command 81 of the catalogue.

Takes nothing.

### StackDirectorCam

Sets the camera to start following a predefined path. Command 82 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `curve_for_camera_to_follow` | `MissionShip \| Curve` | Curve for camera to follow (or Ship for static cam) |
| `ship_for_camera_to_track` | `MissionShip?` | Ship for camera to track (can be NULL) |
| `duration_of_camera` | `number` | Duration of camera (seconds) |
| `tracks_curve_to_this_ship_s_speed` | `MissionShip?` | Tracks curve to this ship's speed (can be NULL) |
| `ships_to_disable_for_duration` | `Entity?` | Ships to disable for duration |

### Scanner

Sets the scanner off. Command 83 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `object_to_scan_for_null_to_disable` | `MissionShip?` | Object to scan for - NULL to disable |

### ReplaceSubObject

Replaces subobject with another object. Command 84 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `sub_object_to_replace` | `MissionShip` | SubObject to replace |
| `object_to_replace_it_with` | `MissionShip` | Object to replace it with |

### Fire

Fires ships guns. Command 85 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_to_fire` | `MissionShip` | Ship to fire |
| `duration` | `number` | Duration |

### MultiplayerScriptSync

Syncs scripts. Command 86 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `sync_number` | `number` | Sync number |

### FriendlyFire

Friendly Fire. Command 87 of the catalogue.

Takes nothing.

### Cloak

Cloak. Command 88 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_to_cloak` | `Entity` | Entity to cloak |
| `true_cloak_on` | `number` | True - Cloak on, False - cloak off |

### ReplenishWeapons

Replenish Weapons. Command 89 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_to_cloak` | `MissionShip` | Entity to cloak |

### WillsBlag

Blag blag blag blag blag. Command 90 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `entity_to_cloak` | `MissionShip` | Entity to cloak |

### ShowHudIcon

Show Hud Icon. Command 91 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `icon` | `number` | Icon |
| `param_0_off` | `number` | 0 - off, 1 - on, 2 - flash |

### DisableListing

Disable Listing. Command 92 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_param` | `MissionShip` | Ship |
| `true_stop_listing` | `number` | true - stop listing, false - enable listing |

### DisableObjectAtNextJump

Disables/enables object (e.g. planet) when the next jump/warp is made. Command 93 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_param` | `MissionShip` | Ship |
| `true_disable` | `number` | true - disable, false - enable |

### DarrensNaughtyBlag

Darrens Naughty Blag. Command 94 of the catalogue.

| Parameter | Type | Label |
|---|---|---|
| `ship_param` | `MissionShip` | Ship |
| `ship_param_2` | `MissionShip` | Ship |

## Conditions

What a trigger watches for, by the names mission source gives the conditions of the game's
catalogue; the catalogue's own names are the developers'. A trigger's function gets the values
its condition's events carry as its parameters, named after their labels, and a trigger checks
a value it can check by the field of the same name ([TriggerFields](#triggerfields)).

### `shot_at`

The catalogue's `ShotAt`, condition 0. A trigger of it watches a ship, a flight group or a squad. An object keeps its last event of it, which `last_event` reads.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `attacker` | Attacker | `MissionShip` | Yes |
| `shield_damage` | Shield Damage | `number` | No |
| `hull_damage` | Hull Damage | `number` | No |
| `victim` | Victim | `MissionShip` | Yes |
| `weapon_fired` | Weapon Fired | `number` | Yes |

### `destroyed`

The catalogue's `Destroyed`, condition 1. A trigger of it watches a ship, a flight group or a squad. An object keeps its last event of it, which `last_event` reads.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `killer` | Killer | `MissionShip` | Yes |
| `victim` | Victim | `MissionShip` | Yes |

### `launched`

The catalogue's `Launched`, condition 2. A trigger of it watches a ship, a flight group or a squad.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `launched_ship` | LaunchedShip | `MissionShip` | Yes |

### `camera_reached`

The catalogue's `CameraReached`, condition 3. A trigger of it watches a ship.

Its events carry no values.

### `ship_reached`

The catalogue's `ShipReached`, condition 4. A trigger of it watches a ship.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `reached_ship` | ReachedShip | `MissionShip` | Yes |

### `proximity_close`

The catalogue's `CloseProximity`, condition 5. A trigger of it watches a ship.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `approaching_ship` | ApproachingShip | `MissionShip` | Yes |
| `proximity` | Proximity | `number` | No |

### `proximity_general`

The catalogue's `Proximity`, condition 6. A trigger of it watches a ship.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `approaching_ship` | ApproachingShip | `MissionShip` | Yes |
| `proximity` | Proximity | `number` | No: a trigger sets it, how far it looks, in radii of the ship it watches |

### `object_scooped`

The catalogue's `ObjectScooped`, condition 7. A trigger of it watches a ship.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `object_scooped` | ObjectScooped | `MissionShip` | Yes |

### `player_ready_to_jump`

The catalogue's `PlayerReadyToJump`, condition 8. A trigger of it watches a ship.

Its events carry no values.

### `jumped_in`

The catalogue's `JumpedIn`, condition 9. A trigger of it watches a ship, a flight group or a squad.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `jumped_in_ship` | JumpedInShip | `MissionShip` | Yes |

### `fixed_gate_jumped_in`

The catalogue's `FixedGateJumpedIn`, condition 10. A trigger of it watches a ship, a flight group or a squad.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `ship_jumped_in` | ShipJumpedIn | `MissionShip` | Yes |

### `player_ready_to_warp`

The catalogue's `PlayerReadyToWarp`, condition 11. A trigger of it watches a ship.

Its events carry no values.

### `jumped_through_hoop`

The catalogue's `JumpedThroughHoop`, condition 12. A trigger of it watches a ship.

Its events carry no values.

### `player_wants_backup`

The catalogue's `PlayerWantsBackup`, condition 13. A trigger of it watches a ship.

Its events carry no values.

### `ripper_grabbed_object`

The catalogue's `RipperGrabbedObject`, condition 14. A trigger of it watches a ship.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `object_grabbed` | ObjectGrabbed | `MissionShip` | Yes |

### `ripper_dropped_object`

The catalogue's `RipperDroppedObject`, condition 15. A trigger of it watches a ship.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `object_dropped` | ObjectDropped | `MissionShip` | Yes |

### `cloaked`

The catalogue's `Cloaked`, condition 16. A trigger of it watches a ship, a flight group or a squad.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `cloaking_ship` | CloakingShip | `MissionShip` | Yes |

### `decloaked`

The catalogue's `Decloaked`, condition 17. A trigger of it watches a ship, a flight group or a squad.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `cloaking_ship` | CloakingShip | `MissionShip` | Yes |

### `targetted`

The catalogue's `Targetted`, condition 18. A trigger of it watches a ship.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `aggressor` | Aggressor | `MissionShip` | Yes |

### `player_l1_doubletap`

The catalogue's `Player_L1_DoubleTap`, condition 19. A trigger of it watches a ship.

Its events carry no values.

### `player_l2_doubletap`

The catalogue's `Player_L2_DoubleTap`, condition 20. A trigger of it watches a ship.

Its events carry no values.

### `player_r1_doubletap`

The catalogue's `Player_R1_DoubleTap`, condition 21. A trigger of it watches a ship.

Its events carry no values.

### `player_r2_doubletap`

The catalogue's `Player_R2_DoubleTap`, condition 22. A trigger of it watches a ship.

Its events carry no values.

### `player_l1_l2_r1_r2_pressed`

The catalogue's `Player_L1_L2_R1_R2 Pressed`, condition 23. A trigger of it watches a ship.

Its events carry no values.

### `player_l1_r1_pressed`

The catalogue's `Player_L1_R1 Pressed`, condition 24. A trigger of it watches a ship.

Its events carry no values.

### `game_timer_expired`

The catalogue's `Game Timer Expired`, condition 25. A trigger of it watches a ship.

Its events carry no values.

### `tractor_beam_locked`

The catalogue's `Tractor Beam Locked`, condition 26. A trigger of it watches a ship, a flight group or a squad.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `tractored_ship` | TractoredShip | `MissionShip` | Yes |
| `tractoring_ship` | TractoringShip | `MissionShip` | Yes |

### `tractor_beam_broken`

The catalogue's `Tractor Beam Broken`, condition 27. A trigger of it watches a ship, a flight group or a squad.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `tractored_ship` | TractoredShip | `MissionShip` | Yes |
| `tractoring_ship` | TractoringShip | `MissionShip` | Yes |

### `inside_object`

The catalogue's `Inside Object`, condition 28. A trigger of it watches a ship.

Its events carry no values.

### `outside_object`

The catalogue's `Outside Object`, condition 29. A trigger of it watches a ship.

Its events carry no values.

### `docked`

The catalogue's `Docked`, condition 30. A trigger of it watches a ship.

Its events carry no values.

### `undocked`

The catalogue's `UnDocked`, condition 31. A trigger of it watches a ship.

Its events carry no values.

### `being_chased`

The catalogue's `I'm Being Chased`, condition 32. A trigger of it watches a ship, a flight group or a squad.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `chased_ship` | ChasedShip | `MissionShip` | Yes |
| `chaser` | Chaser | `MissionShip` | Yes |

### `call_reinforcements`

The catalogue's `Player_CallReinforcements`, condition 33. A trigger of it watches a ship.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `player_targetted` | PlayerTargetted | `MissionShip` | Yes |

### `explosion_ship`

The catalogue's `ExplosionShip`, condition 34.

| Parameter | Label | Type | A trigger checks it |
|---|---|---|---|
| `explosion_ship` | ExplosionShip | `MissionShip` | Yes |

## Names of values

A value the game names is written by its name, in quotes. One without a name, such as a
mod's ship type, is written as a number.

### ShipType

`predator`, `naginata`, `grendel`, `crusader`, `coyote`, `mirage`, `tempest`, `patriot`, `wolverine`, `reaper`, `shroud`, `phoenix`, `reliant`, `yamato`, `alsace`, `kestrel`, `falco`, `victorious`, `endeavour`, `mitchell`, `bremen`, `arc_ship`, `ulysses`, `sai`, `nanny`, `galahad`, `hades`, `mule`, `lonestar`, `limpet_car`, `prowler`, `ripper`, `lueneburg`, `mammoth`, `intruder`, `sentry`, `goodwill`, `stork`, `sky_hawk`, `haidar`, `karak`, `salin`, `azan`, `sabre`, `lagg`, `kamov`, `saracen`, `salamander`, `scimitar`, `basilisk`, `kossac`, `yao`, `ramases`, `kozlov`, `morzov`, `badanov`, `pukov`, `xia`, `riza`, `cyclops`, `kurgan`, `sharov`, `gurevich`, `berijev`, `kirov`, `loki`, `kalan_shuttle`, `saladin`, `darkreign`, `stalag`, `antanov`, `kronstadt`, `boridin`, `troop_car`, `torpedo`, `ulysses_back`, `ulysses_fin`, `escape_pod`, `debris`, `debris_1`, `debris_2`, `debris_3`, `debris_4`, `debris_5`, `debris_6`, `debris_7`, `debris_8`, `debris_9`, `crewman`, `crewman_1`, `crewman_2`, `crewman_3`, `russian_torpedo`, `mammoth_back`, `baxter`, `neptune_hi`, `triton_hi`, `uranus_hi`, `saturn_hi`, `titan_hi`, `jupiter_hi`, `europa_hi`, `ganymede_hi`, `io_hi`, `calisto_hi`, `venus_hi`, `earth`, `kronstadt_wreck`, `planet_placeholder_4`, `proto_gate`, `advanced_gate`, `proximity_mine`, `black_box`, `satellite`, `mammoth_wreck_front`, `mammoth_wreck_back`, `proto_gate_panel`, `badanov_wreck_back`, `badanov_wreck_front`, `kurgan_wreck`, `krasnaya`, `asteroid_1`, `asteroid_2`, `asteroid_3`, `asteroid_4`, `asteroid_5`, `asteroid_6`, `asteroid_7`, `research_station`, `latov`, `gurevich_wreck_back`, `training_hoop`, `czar_docked`, `turret_asteroid_1`, `turret_asteroid_2`, `turret_asteroid_3`, `turret_asteroid_4`, `turret_asteroid_5`, `turret_asteroid_6`, `turret_asteroid_7`, `powerup_random`, `dm_beacon_gate`, `dm_beacon`, `pukov_wreck_back`, `other_escape_pod`, `cargo_pod`, `other_cargo_pod`, `grazer_gun_sat`, `archer_missile_sat`, `kafelnikof`, `reliant_wreck_back`, `stalag_doors`, `stalag_duct_cover`, `yakob_shuttle`, `krasny`, `varyag`, `other_ramases`, `fort_carter`, `koenig`, `washington`, `other_mitchell`, `ufelsky`, `kresta`, `krasnaya_left_arm`, `krasnaya_right_arm`, `rogue_base`, `kronstadt_arm`, `boridin_gun_dome`, `boridin_breakaway`, `darkreign_wreck_hat`, `yamato_wreck_back`, `maintenance_droid`, `maintenance_astronaut`, `rogue_base_wreck_top`, `tank`, `training_target`, `zakov`, `shell`, `rock_chunk`, `rock_chunk_tiny_1`, `rock_chunk_tiny_2`, `rock_chunk_tiny_3`, `rock_chunk_tiny_4`, `latov_wreck_1`, `latov_wreck_2`, `czar`, `zakov_wreck_back`, `sharov_wreck_back`, `limpet_pod`, `stalag_wreck_1`, `stalag_wreck_2`, `saladin_wreck`, `gegarin`, `krelov`, `kiev`, `kiev_wreck_back`, `baxter_wreck_top`, `victorious_wreck_front`, `mitchell_wreck_back`, `fort_bear`, `fort_sherman`, `neptune_lo`, `triton_lo`, `uranus_lo`, `saturn_lo`, `titan_lo`, `jupiter_lo`, `europa_lo`, `ganymede_lo`, `io_lo`, `calisto_lo`, `venus_lo`, `yamato_hangar`, `yamato_landing_bay`, `reliant_hangar`, `comms_relay`, `saladin_link`, `varyag_wreck_front`, `churchill`, `bokov`, `bulatov`, `shinnik`, `kovtun`, `late_escape_pod`, `other_late_escape_pod`, `fuel_pod`, `yevstafiy`, `mammoth_gulliver`, `mammoth_santa_maria`, `mammoth_rosario`, `mammoth_larsons_pride`, `mammoth_brittania`, `mammoth_sierra_madre`, `mammoth_mayan_gold`, `mammoth_dawn_chorus`, `mammoth_calysto`, `mammoth_sundown`, `mammoth_krenna`, `mammoth_seabound`, `mammoth_crimson_sky`, `asteroid_with_hole_1`, `asteroid_with_hole_2`, `asteroid_with_hole_3`, `asteroid_with_hole_4`, `t_predator`, `t_naginata`, `t_grendel`, `t_crusader`, `t_coyote`, `t_mirage`, `t_tempest`, `t_patriot`, `t_wolverine`, `t_reaper`, `t_shroud`, `t_phoenix`, `sun_marker`, `nebula_marker`, `dm_sphere_centre`, `beacon_marker`, `spawn_player`, `spawn_powerup`, `marker`, `stand_in`, or a number.

### PilotNumber

`bandit_tigers_leader`, `diceman_tigers_leader`, `moose_tigers`, `tigers`, `moose_volunteers`, `volunteers`, `bandit_volunteers_leader`, `viper`, `fifty_first`, `black_guard`, `black_sun_leader`, `black_sun`, `blades`, `black_eagle_leader`, `black_eagle`, `ivan_petrov`, `nicolai_petrov`, `black_aces`, `bremen_bridge_officer`, `buccaneer`, `cat_foster`, `cobra`, `couger`, `coalition_comms_officer`, `coalition_fighter`, `coalition_scientist`, `endeavour_bridge_officer`, `enriquez_reliant_bridge`, `enriquez_yamato_bridge`, `enriquez_cockpit`, `foster_dead`, `fort_bear_comms`, `fort_baxter_comms`, `fort_carter_comms`, `fort_sherman_comms`, `gamma_dead`, `gamma_leader`, `golden_warrior`, `hellcat_leader`, `hellcat`, `hornet`, `jackel_leader`, `jackel`, `jaguar`, `kestrel_command`, `koenig_bridge_officer`, `kestrel_bridge_officer`, `kurgen`, `lonestar`, `mauler`, `mcgann`, `mitchell_bridge_officer`, `nanny_leader`, `pirate_leader`, `pirate`, `prowler`, `pukov_captain`, `puma_leader`, `puma`, `raven`, `reliant_bridge_officer`, `ripper`, `ronin_leader`, `ronin`, `russian_bomber`, `sabre_leader`, `sabre`, `saracen`, `scorpion_leader`, `scorpion`, `saladin_captain`, `stahl_bridge`, `stahl_marines`, `steiner_ejected`, `stinger`, `stork`, `ulysses_captain`, `ulysses_captain_panicking`, `steiner_vampires_leader`, `vampire`, `varyag_captain`, `victorious_bridge_officer`, `virtual_flight_instructor`, `washington_bridge_officer`, `yamato_bridge_officer`, `frenchy`, `silky`, `mayday`, `trigger`, `vixen`, `cutter`, `claymore`, `skippy`, `juice`, `face`, `hawkeye`, `arrow`, `nero`, `rhino`, `stalker`, `flash`, `stretch`, `talon`, `butcher`, `snapper`, `banshee`, `wolf`, `reaper`, `worm`, `wildcat`, `siron`, `ferret`, `poker`, `blade`, `scarlet`, `rico`, `slick`, `irish`, `spider`, `ego`, `diceman`, `captain_mukai`, `cat_foster_prowler`, `coalition_torpedo_leader`, `general_reese_pod`, `kulov_borodin`, `kulov_pod`, `mammoth_1`, `mammoth_2`, `mammoth_3`, `mammoth_4`, `saracen_leader`, `stahl_ripper`, `golden_warrior_leader`, `hornet_leader`, `mammoth_5`, `mammoth_6`, `mammoth_7`, `bandit`, `marauder_leader`, `marauder`, `marine_leader`, `marine`, `jaguar_leader`, `buccaneer_leader`, or a number.

### Order

`do_nothing`, `fly_aimlessly`, `launch_missile`, `launch_jack_hammer`, `warp_in`, `warp_out`, `fly`, `run_away`, `land`, `escort`, `find_new_target`, `explode`, `ripper_grabs_target_object`, `object_attach`, `formation_regroup`, `patrol_route`, `toggle_cloak`, `ship_follow_curve`, `slow_rotate`, `jump_in`, `jump_out`, `find_scoop_up`, `random_spin_slow`, `random_spin_medium`, `random_spin_fast`, `fixed_gate_jump_in`, `fixed_gate_jump_out`, `formation`, `fixed_gate_open`, `fixed_gate_close`, `eject`, `fixed_gate_collapse`, `match_speed`, `dark_reign_shoot`, `move_to_spawn_pos`, `turns_object_lights_on`, `make_boridin_section_break_away`, `rotate_boridin_breakaway_warp_projector`, `start_warp_projection_from_boridin`, `make_ripper_drop_what_its_carrying`, `jump_in_spread`, `jump_out_spread`, `turns_object_lights_off`, `huuuuuuuge_explosion`, `immediately_set_ship_to_zero_velocity_and_rotation`, `fly_ship_backwards`, `player_control`, `multiplayer_control`, `avoid_target`, `torpedo`, `launch`, `fight`, `abandoned`, `scoop_up`, `eject_spin`, `dock`, `fire_ion_cannon`, `ripper_end_drop_object`, `ripper_attach_cargo_pod_to_mammoth`, `eject_fighter_attack`, `disrupted`, `make_capship_list_left`, `make_capship_list_right`, `friendly_fire`, `eject_player`, `ship_follow_curve_backwards`, `mill`, `deathmatch_respawn_effect`, `deathmatch_dark_reign_target`, or a number.

### Condition

`shot_at`, `destroyed`, `launched`, `camera_reached`, `ship_reached`, `proximity_close`, `proximity_general`, `object_scooped`, `player_ready_to_jump`, `jumped_in`, `fixed_gate_jumped_in`, `player_ready_to_warp`, `jumped_through_hoop`, `player_wants_backup`, `ripper_grabbed_object`, `ripper_dropped_object`, `cloaked`, `decloaked`, `targetted`, `player_l1_doubletap`, `player_l2_doubletap`, `player_r1_doubletap`, `player_r2_doubletap`, `player_l1_l2_r1_r2_pressed`, `player_l1_r1_pressed`, `game_timer_expired`, `tractor_beam_locked`, `tractor_beam_broken`, `inside_object`, `outside_object`, `docked`, `undocked`, `being_chased`, `call_reinforcements`, `explosion_ship`, or a number.

### FaceFilm

`talking`, `laughing`, `squadron`, `dying`, or a number.

### EnvironmentEffect

`ice_field`, `planet_bombard`, `bombard_flashes`, or a number.

### Wing

`player`, `second`, `third`, `none`, or a number.

### GameVariables

The game's variables, which `game` holds: `jump_ready`, `warp_ready`, `backup_available`, `player_missiles_left`, `mcgann_alive`, `nicolai_petrov_alive`, `ivan_petrov_alive`, `kulov_alive`, `mission_over`, `landing_cleared`, `al_rahan_alive`, `sharif_alive`, `steiner_alive`, `mission_success`, `players`, `krasnaya_alive`, `rameses_alive`, `kozah_alive`, `fixed_gate_alive`, `warp_gate_alive`, `last_success`, `objectives_met`, `czar_alive`, `ghost_alive`, `reliant_alive`, `countdown`, `chapter2_thread3_shown`, `red_dragon_alive`, `yamato_alive`, `ion_cannons_hold_lock`, or a number, as in `game[37]`, for one without a name.
