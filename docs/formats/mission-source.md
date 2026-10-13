# Mission source

Mission source is a mission written as text. `sltool dte decompile` writes a mission's source from
its `.DTE` file, and `sltool dte build` compiles source into a standard `.DTE` that plays in the
original too ([#1126](https://github.com/OpenReliant/openreliant/issues/1126)). The syntax is a
subset of Luau, which Luau's own parser reads as the mission is built: nothing in the file runs, in
OpenReliant or anywhere else.

```luau
-- mission1.dte as source.

reliant_group = flight_group("(FG)Reliant", { wing = "player" })

player_ship = ship("Player_Ship", {
    type = "grendel",
    group = reliant_group,
    position = { -11608147, -3, 11596510 },
    yaw = 90,
})
convoy_nav_point = nav_point("Convoy Nav Point", { position = { 1234884, 0, 11312658 }, yaw = 175 })

convoykilled = global("(GV)convoykilled", 0)

on(player_ship, "player_ready_to_jump", { repeats = "always" }, function()
    jumping_to_convoy()
    InterruptTriggerCode()
    if convoykilled == 1 then
        go_home_total_loss()
    else
        jumping_to_sherman()
    end
    InterruptTriggerCode()
    return 1
end)

jumping_to_convoy = part("(F)Jumping to CONVOY", function()
    -- ...
    return 1
end)
```

## The file

A mission's source is one file, named `<mission>.mission.luau`, such as `mission1.mission.luau`.
At its top level it holds declarations and nothing else:

- `name = constructor(...)` declares a record, such as a ship or a part, under `name`.
- `on(...)` declares a trigger.
- `mission(...)` gives the mission's own details.

Comments go anywhere, and blank lines don't count. Every name is the file's: a declaration can use
any name the file declares, before or after it. A name is a Luau identifier,
`[A-Za-z_][A-Za-z0-9_]*`, that isn't a Luau keyword, a command's name or one of the names this page
gives the source itself.

The order of the declarations of a kind is the order of the mission's records of that kind, since
the script and the records refer to records by their place: the first ship declared is ship 0, the
first part part 0, and so on.

## The mission

```luau
mission({ name = "Patrol" })
```

`name` is OpenReliant's name for the mission ([OpenReliant's mission
name](dte.md#openreliants-mission-name)). A mission without the declaration has none.

## Records

Each record has its display name, the name the original's tools and the game show, and fields in a
table. A field left out takes its default.

A value the game names is written by the name the scripting API gives it
([Scripting reference](../guide/reference.md)): a ship type as `"grendel"`, a pilot as
`"bandit_tigers_leader"`, an order as `"find_new_target"`, a condition as `"shot_at"`. The names come
from the tables the game runs on, so mission source, mods' scripts and the editor share them. A
value the game doesn't name, such as a ship type or an order a mod adds, stays a number.

### Globals

```luau
convoykilled = global("(GV)convoykilled", 0)
```

The display name and the value the global starts with.

### Flight groups

```luau
reliant_group = flight_group("(FG)Reliant", { wing = "player" })
```

| Field | Value | Default |
|---|---|---|
| `wing` | The wing the group's ships are listed in: `"player"`, `"second"`, `"third"` or `"none"` | `"none"` |

### Ships

```luau
naginata = ship("(A1)Naginata", {
    type = "naginata",
    group = reliant_group,
    pilot = "bandit_tigers_leader",
    position = { -11616031, 187, 11597653 },
    yaw = 90,
})
```

`ship` places a ship, a capital ship or a station. `nav_point`, `waypoint`, `point` and `curve_point`
place the mission's markers ([Ships](dte.md#ships)), which take the same fields but `type`.

| Field | Value | Default |
|---|---|---|
| `type` | The ship's type | Required for `ship` |
| `group` | Its flight group | None |
| `pilot` | Its pilot, by its record of `pilotstats.bin` | None |
| `position` | `{ x, y, z }`, in the game's coordinates, Y down | `{ 0, 0, 0 }` |
| `yaw`, `pitch`, `roll` | Whole degrees; -1 where the mission leaves the angle unset | 0 |
| `launch` | `{ from = "reliant", gate = 2 }`: the type of ship it launches from, the first of that type in the mission, and the gate it launches through | It doesn't launch |
| `formation_point` | Its place in a formation: `sabres[2]` is the second point of the formation `sabres` | None |
| `tier` | The loadout tier its missile racks are fitted by; 255 asks for the campaign's | 255 |
| `marker` | For a `point` that marks a place on a curve: `{ curve = camera_curve, at = 0.5 }`, the share of the way along it | None |

### Squads

```luau
sabre_targets = squad("(AI)sabretargets", { sabre_1, sabre_2, component(kurgan, 3), escort_group })
```

The display name and the members in their order: ships, a ship's component as `component(ship,
index)`, flight groups and other squads.

### Formations

```luau
sabres = formation("sabres", { { 0, 0, 0 }, { -400, 0, 300 }, { 400, 0, 300 } })
```

The display name and the formation's points, each where it stands from the formation's origin. A
ship names a point as `sabres[1]` for the first.

### Curves

```luau
camera_curve = curve({
    start = convoy_nav_point, finish = escort_point,
    from = { 1234884, 0, 11312658 }, to = { 1240000, 0, 11300000 },
    leaving_handle = handle_1, arriving_handle = handle_2,
    leaving = { 10, 0, 0 }, arriving = { 0, 0, -10 },
})
```

A curve has no display name. `start` and `finish` are the ships it runs between, `from` and `to`
their places, `leaving_handle` and `arriving_handle` the ships its tangents are drawn to, and
`leaving` and `arriving` the tangents ([Curves](dte.md#curves)). A ship left out is none.

### Parts

```luau
launchfunction = part("(F)launchfunction", function()
    -- ...
    return 1
end, { start = true })

go_home = part("(F)GO HOME (Total Loss)", function()
    -- ...
    return 1
end)

unused = part("(F)Not written yet")
```

The display name and the part's code, a function whose parameters are the part's arguments. A part
without a function has no block. `start = true` runs it as the mission starts, before any trigger is
armed.

### Triggers

```luau
on(black_guard, "shot_at", { repeats = "always", attacker = any_ship },
    function(attacker, shield_damage, hull_damage, victim, weapon_fired)
        if hull_damage >= 50 then
            -- ...
        end
        return 1
    end)
```

`on` takes the trigger's subject, the ship, flight group or squad whose events it watches, its
condition, its fields, which can be left out, and the code its events run. The function's
parameters are the values the condition's events carry, named after their labels in the condition
catalogue ([Conditions](dte.md#conditions)).

| Field | Value | Default |
|---|---|---|
| `repeats` | `"once"`, which disarms the trigger as it fires; `"always"`; or `{ counted = 3 }`, which fires that many times each time the script arms it, with `left = 1` where fewer firings are left as the mission starts | `"once"` |
| `component` | The subject's component it watches, by its index | The subject itself |
| `deferred` | `true` leaves the thread to the scheduler rather than running it inside the event | `false` |
| A value's name | What the event's value must be, for the values the condition checks: a number, a ship, flight group or squad, or `any_ship` for any of the players' ships | Not checked |

The triggers are in the order of their declarations, and a subject's triggers must follow one
another. A trigger whose subject is `nil` belongs to no object, so it never fires. A trigger without
a function runs nothing.

Triggers that share their code name it once:

```luau
convoy_hit = handler(function(attacker, shield_damage, hull_damage, victim, weapon_fired)
    -- ...
    return 1
end)
on(convoy_1, "shot_at", { repeats = "always" }, convoy_hit)
on(convoy_2, "shot_at", { repeats = "always" }, convoy_hit)
```

## The script

The code of parts and triggers is the script's statements ([Statements](dte.md#statements)), in
Luau's syntax:

| Statement | Source |
|---|---|
| A command | `SetAI(sabre_targets, "find_new_target", 1, nil)`. A command the catalogue doesn't have is `command(250, ...)` |
| A part called | `go_home()`, with its arguments |
| A part started on a thread of its own | `spawn(go_home)`, with its arguments after the part |
| An assignment | `convoykilled = 1`, `convoykilled += 1`, and `-=`, `*=` and `/=`. Floating-point stores are `add_assign_f(target, value)` and the like |
| `if` | `if ... then ... elseif ... else ... end`. An `else` with nothing in it is kept |
| A random choice | `local roll = random()`, then `if roll < 50 then ... elseif roll < 100 then ... else ... end`: one roll below 100, and the first arm whose threshold is above it, the `else` being the default. The roll can have any name; `sltool dte decompile` names a function's later rolls `roll_2`, `roll_3` and so on |
| `return` | `return 1` |

| Expression | Source |
|---|---|
| A number | `50`. Where the parameter takes a named value, it is written by its name: `"find_new_target"` for an order, `"shot_at"` for a condition, `"coalition_fighter"` for a pilot, `"talking"` for a head movement, `"ice_field"` for an environment effect, and a part's name for a part. A value the game doesn't name stays a number |
| Text | `"new_sim02.wav"`, as a Luau string |
| A ship, flight group, squad, curve or global | Its name |
| A ship's component | `component(ship, 3)` |
| None | `nil` |
| One of the game's variables | `game.mission_over`, by its name ([The game's variables](../engine/script-vm.md#the-games-variables)), or `game[37]` for one without |
| A part's argument | Its parameter |
| An event's value | Its parameter, in a trigger's function; `thread_value(1)` in a part, for the value of the event that started the thread |
| A value an object keeps of its last event | `last_event(ship, "shot_at", "Hull Damage")` |
| The last command's result | `result()` |
| A comparison | `==`, `~=`, `<`, `<=`, `>`, `>=`; in floating point `greater_f(a, b)` and the like |
| `and`, `or` | `and`, `or` |
| Arithmetic | `+`, `-`, `*`, `/`; in floating point `add_f(a, b)` and the like |
| Membership | `in_flight_group(ship, group)`, `not_in_flight_group`, `in_squad(object, squad)`, `not_in_squad` |

The script has no loops, since a branch only goes forward. A thread waits with commands such as
`Wait`, and runs again on a timer or a trigger.

## What the source leaves out

The source holds what the game reads of a mission. It leaves out:

- what the game works out again as it binds the mission or starts its script: the ships' runtime
  places and angles, which equal the authored ones in every shipped mission, the objects' trigger
  slices, a flight group's ships, the parts' and triggers' places in the script, the string pool,
  and the directory;
- the objects' numbers. The shipped missions number their ships, flight groups and squads in the
  order their authors made them, with gaps. The compiler numbers them itself: first the objects
  that `last_event` names, in the order the source names them, since the script names those by a
  byte, then the ships, the flight groups and the squads, each in order;
- the script's flags, which the editor link sets ([The editor link](../engine/editor-link.md)).

The rest is parked as unknown and unused: fields and sections that nothing in the game reads. The
compiler writes the fields as most of the shipped missions' records hold them (`dte.Ship.blank` and
the other records'), or 0 where they hold no value most, and leaves the sections empty, as mission 0
does. OpenReliant could keep data
of its own there, as it keeps the mission's name in section 21, since the original ignores them.
**Unverified:** that the original reads none of them; OpenReliant's engine, which follows the
original's disassembly, reads none.

| Where | What |
|---|---|
| Sections 1, 22 and 26 | The operand tables. `mission_build_part_tables` (`0x00452F50`) hands an entry of one, by the part's `kind`, to `mission_fill_part` (`0x00452FD0`), which pops it unread |
| Sections 9, 11 and 23 | Unread ([Directory](dte.md#directory)) |
| A ship's bytes `0x06`, `0x16`, `0x1A`, `0x2A`, `0x37`, `0x3C`, `0x3E` and `0x42` | Unread |
| A trigger's bytes `0x04` to `0x13`, `0x17`, `0x18` and `0x1B`, and its armed flag | Unread; the game arms every trigger an object's slice holds as the mission starts |
| A trigger's firings left, but for `{ counted = n }` | Read only for a counted trigger |
| A part's bytes but its name, flags and argument count, and its `kind` | Unread, but for the operand tables above |
| A curve's last word, a squad member's last bytes, the globals' and the flight groups' unused words | Unread |
| The objects' tool flags | For the original's tools ([Objects](dte.md#objects)) |
| A random choice's arms' last byte | Unread |

## References past the records

A reference to a record that the mission doesn't have, such as a curve's ship in some of the
leftover missions, is written by its index: `ship_index(59031)`, and likewise `flight_group_index`,
`squad_index`, `curve_index`, `global_index`, `part_index`, `object_index`, `formation_index` and
`formation_point_index`. `object_index` names an object by its number in the built mission, and a
number past its records gets an entry of no record in the object table.

## Building a mission

```bash
sltool dte decompile mission1.dte > mission1.mission.luau
sltool dte build mission1.mission.luau mission1.dte
```

`sltool dte build` compiles the source with
[`compile.zig`](../../src/formats/dte/source/compile.zig). It stops at the first error, which it
gives with its line and column, such as ``patrol.mission.luau:12:5: `nobody` is not declared``. Each
kind's records are written in the order of their declarations. The script holds the blocks the
triggers run, in the order the triggers first run them, then the parts' blocks in order, each
written as the developers' compiler wrote its statements ([Statements](dte.md#statements)).

## Editors

[luau-lsp](https://github.com/JohnnyMorganz/luau-lsp), the Luau language server, gives editors such
as VS Code completion and descriptions for mission source, from the definitions file
[`mission.d.luau`](../guide/mission.d.luau). It declares the declarations and their fields, the
functions of the script, every command of the catalogue with its parameters and the developers'
descriptions, and the names of the game's values. It comes with each release, and
`sltool dte definitions` writes it.

1. Install luau-lsp's extension, version 1.56 or later.
2. In the settings of the folder that holds the missions, such as its `.vscode/settings.json` in VS
   Code, add the file under a name, and turn on Luau's new type solver:

   ```json
   {
       "luau-lsp.platform.type": "standard",
       "luau-lsp.types.definitionFiles": { "@mission": "path/to/mission.d.luau" },
       "luau-lsp.fflags.enableNewSolver": true
   }
   ```

Mission source needs Luau's new type solver: a declaration can use a name the file declares after
it, and the old solver takes that for an unknown global. In nonstrict mode, the default, the new
solver reports no type errors, so `sltool dte build` is still what finds them. The scripting API's
definitions don't load in the new solver yet
([#1139](https://github.com/OpenReliant/openreliant/issues/1139)), so mods' scripts are best kept in
a folder of their own.

The definitions take the declarations, the functions of the script and the tables of fields from
[`language.zig`](../../src/formats/dte/source/language.zig), whose tables the compiler checks fields
against, and the commands, the conditions and the names of values from the game's tables.

## Reading the text

Luau's own parser reads mission source, so the syntax is exactly Luau's, comments included.
[`src/source_parser.zig`](../../src/source_parser.zig) calls the parser through a C++ shim, since
it has no C API, and copies its syntax tree into the library's
([`syntax.zig`](../../src/formats/dte/source/syntax.zig)): each statement and expression with the
line and column it starts at, and each error the parser finds with its place. Only the tools that
read source link the parser. sltool does; the library the tools share doesn't.

Mission source uses a subset of Luau. The parser gives back the rest, such as a loop, a function
declared by name, a method call, an `if` expression or a string with values put into it, as an
unsupported node with its place, for the compiler to refuse. An expression in brackets, or with a
type assertion such as `x :: number`, is the expression itself, type annotations on locals and
parameters change nothing, and a string in backquotes without values is text like any other.

## The round trip

`sltool dte decompile` names each record after its display name: the name in lower case, a leading
tag such as `(F)` or `(GV)` left out, each run of other characters an underscore, and an underscore
where a small letter meets a capital, with a number after it where two would clash. The name is the
record's from then on, and renaming the display name doesn't change it. A squad's members are
written as the game walks them, from the squad's first member while they are its own, and a
formation's points as OpenReliant finds them, from the formation's first point on, those that name
it (`dte.FormationPoint.Walk`). A place or another floating-point value is written as the shortest
number that reads back as the same 32-bit float, with an exponent from 2^53 on, such as
`-1.701416e38`: Luau warns about a whole number that large written in digits, since a double can't
hold every one exactly.

Built again, a decompiled mission is the same mission
([`same.zig`](../../src/formats/dte/same.zig)): the same records and code, decoded, with names
compared as text, an object by the record the game takes it for, and a formation's point by its
place among the formation's. The string pool's layout, its stale strings, the objects' numbers, the
sections' layout and the parked bytes may differ. Every shipped mission comes back as the same
mission. To keep a shipped mission byte for byte, edit its `.DTE` in place instead.

`sltool dte check` runs the round trip: it writes the mission as source, parses it, fails on an
error or a construct mission source doesn't use, builds the source again, compares the two missions
and binds the new one as starting a mission does.
