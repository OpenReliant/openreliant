# Writing missions

A mission is a `.DTE` file, and a mod can add one or replace one of the game's
([Missions](modding.md#missions)). OpenReliant lets you write a mission as text, called mission
source, which `sltool dte build` turns into a mission file. The file plays in OpenReliant and in the
original.

This guide writes a first mission step by step, builds it, plays it, and steps through its script
with the debugger while it plays. Then it changes one of the game's own missions, and explains what
a mission holds. The
[reference](mission-reference.md) lists every declaration, command and condition, and
[Mission source](../formats/mission-source.md) gives the exact rules of the text.

## What you need

- `openreliant` and `sltool`, which come together in each release, and the game installed as the
  [installation guide](installation.md) describes. The commands below run in a terminal, in the
  folder that holds `openreliant` and `sltool`, with the game in its `StarLancer` folder.
- A text editor. With luau-lsp, editors such as VS Code complete and describe the names of mission
  source as you type ([Editors](#editors)).

Mission source uses a small part of Luau, the language of mods' scripts. Nothing in it runs as a
program, though: `sltool` reads it and builds the mission from it. A few things to know about the
text:

- A line that starts with `--` is a comment, which `sltool` skips.
- Text goes in quotes: `"Sabre 1"`.
- A table, a list of values or of `name = value` fields, goes in braces: `{ 0, 0, 40000 }` or
  `{ type = "sabre", yaw = 180 }`.
- A name, such as `player` or `sabre_1`, is made of letters, digits and `_`, and doesn't start with
  a digit. Upper and lower case are different, and the words of the source itself, such as `ship`
  and `Wait`, can't be used as names.

## A first mission

In the game folder, next to `resource.hog`, make a folder called `mods` if there isn't one, and in
it a folder for the mission's mod, `first-mission`. In that folder, write the mod's manifest,
`mod.ini`:

```ini
[Mod]
Name=First Mission
Version=1.0
```

Then write the mission in `mission90.mission.luau`, next to it. A mission's number comes from its
file's name, and the game's missions don't use 90, so this mission adds a mission rather than
replacing one of the game's.

```luau
-- mission90.mission.luau: a first mission. The player's ship starts in space, with a nav point
-- ahead, where two Sabres wait. Once the player reaches the nav point, the Sabres attack, and once
-- both are destroyed, the mission ends as a success.

mission({ name = "First Mission" })

-- Flight groups. The player's own is listed in the player's wing.

alpha = flight_group("(FG)Alpha", { wing = "player" })
navs = flight_group("(FG)Nav points")
enemies = flight_group("(FG)Enemies")

-- Ships. The first ship is always the player's.

player = ship("Player", { type = "predator", group = alpha })
nav = nav_point("Nav 1", { group = navs, position = { 0, 0, 40000 } })
sabre_1 = ship("Sabre 1", {
    type = "sabre",
    group = enemies,
    position = { -2000, 0, 42000 },
    yaw = 180,
})
sabre_2 = ship("Sabre 2", {
    type = "sabre",
    group = enemies,
    position = { 2000, 0, 42000 },
    yaw = 180,
})

-- The script. This part runs as the mission starts.

start = part("(F)Start", function()
    -- A mission's ships appear as their flight groups are made.
    CreateFlightGroup(alpha)
    CreateFlightGroup(navs)
    CreateFlightGroup(enemies)
    -- The display points the player to the nav point, until the player is within 5000 of it.
    SetFlybackMarker(nav, 5000)
    PlayMusic("New_Mission01.wav", 0)
    return 1
end, { start = true })

-- Once the player's ship comes within 4000 of the nav point, the Sabres attack it.

on(nav, "ship_reached", { reached_ship = player }, function(reached_ship)
    SetAI(enemies, "fight", 1, player)
    return 1
end)

-- Once both Sabres are destroyed, the mission ends as a success.

on(enemies, "destroyed", function(killer, victim)
    game.mission_success = 3
    Wait(5)
    game.mission_over = 1
    return 1
end)
```

What each part does:

- `mission(...)` gives the mission a name, which `openreliant missions` shows. The original never
  reads it.
- `flight_group(...)` declares a flight group, by its name. A mission's ships appear only once their
  flight group is made, so every ship needs one. The player's group is listed in the player's wing
  ([Flight groups and wings](#flight-groups-and-wings)).
- `ship(...)` places a ship: its name, then its fields. The first ship is the player's. `type` is
  the ship's type ([ShipType](mission-reference.md#shiptype)).
- `nav_point(...)` places a nav point, a marker that the display can point the player to.
- `position = { x, y, z }` says where a ship is. A ship that isn't turned faces along Z, with X to
  its right and Y down, so the nav point, 40000 along Z, is straight ahead of the player's ship,
  which stands at `{ 0, 0, 0 }`, the default. The display shows a target's range in thousands of
  these units: a ship 40000 away shows as `40k`.
- `yaw = 180` turns the Sabres round to face the player. Angles are in whole degrees.
- `part(...)` declares a part, a piece of the script: its name, its code, and its fields, where
  `start = true` runs it as the mission starts. The code calls the game's commands, such as
  `CreateFlightGroup` and `PlayMusic` ([Commands](mission-reference.md#commands)), and must end with
  a `return`, here `return 1`.
- `on(...)` declares a trigger, code that runs when something happens to a ship or a group. The
  first runs once a ship comes within 4000 of the nav point, and `{ reached_ship = player }` keeps
  it to the player's ship: without it, the trigger would fire within a second, since the Sabres
  stand within 4000 of the nav point too. The second runs once every ship of `enemies` is
  destroyed.
- `game.mission_success` and `game.mission_over` are two of the game's variables. The first rates
  the mission, 3 for a success, and setting the second to 1 ends it.

### Building it

```bash
./sltool dte build StarLancer/mods/first-mission/mission90.mission.luau StarLancer/mods/first-mission/mission90.dte
```

`sltool` reads the source, checks it, and writes `mission90.dte` next to it. Build it again after
each change.

Where the source has a mistake, `sltool` gives its line and column and says what is wrong, and
writes no mission. With `enemy` in place of `enemies` on line 52:

```text
StarLancer/mods/first-mission/mission90.mission.luau:52:4: `enemy` is not declared
```

### Playing it

```bash
./openreliant StarLancer --mission 90
```

The mission starts at once, with the player's ship in space. `--mission` flies the mission's ship
type, the Predator here, unless `--ship` names another ([The mission](configuration.md#the-mission)).
Fly to the nav point the display points to, and destroy the two Sabres. Five seconds after the
second Sabre is destroyed, the mission ends and the pause menu opens: RESTART flies it again, and
LEAVE MISSION quits.

OpenReliant reads the mods as it starts, so start it again after you build the mission again.

### Stepping through it

`openreliant debug` stops the script at breakpoints while the mission plays, runs it a statement at
a time, and shows what it holds ([Debugging mission scripts](debugging.md)). Start it in one
terminal, and give it a breakpoint at the start part:

```bash
./openreliant debug
```

```text
(debug) break start
Breakpoint 1, start:1: for the next mission
```

Then start the mission in another terminal, with `--editor-link`:

```bash
./openreliant StarLancer --editor-link --mission 90
```

The script stops before the start part's first statement, `CreateFlightGroup(alpha)`, and `step`
runs it:

```text
Connected to StarLancer, OpenReliant x.y.z.
Mission 90 starts (mission90.dte).
1 of 1 breakpoints are in its script.
Stopped at 64, statement 1 of part 0, (F)Start:
      64  21 03       command   CreateFlightGroup
(debug) step
Stopped at 68, statement 2 of part 0, (F)Start:
      68  21 03       command   CreateFlightGroup
(debug) continue
```

- `list` shows the part's instructions, with its statements numbered.
- `state` shows the script's threads, the globals and the game's variables, such as
  `mission_success` once the Sabres are destroyed.
- `continue` lets the script run on to the next breakpoint, and `quit` lets it go.
- A trigger's code has no name to stop at, so give its place in the script instead.
  `./sltool dte script StarLancer/mods/first-mission/mission90.dte` lists the script with the
  offset of each instruction, and `break @10` stops before the first trigger's `SetAI`, once the
  player reaches the nav point.

While the script is stopped, the ships fly on as they were, but their orders, the controls and the
script wait. Stopped in the start part, the game shows its loading screen until the script runs on.

## Changing one of the game's missions

Any of the game's missions can be changed the same way: decompile it into source, change the source,
and build it into a mod under the mission's own name. The mod's mission replaces the game's, in the
campaign too, and the game's files stay as they are. Built without a change, the source makes the
same mission as the game's ([The round trip](../formats/mission-source.md#the-round-trip)), so the
mod changes only what you change. Here, Viper, one of the player's wingmen in mission 1, flies a
Phoenix in place of the Coyote.

In the `mods` folder, make a folder for the mod, `viper-phoenix`, with its manifest, `mod.ini`:

```ini
[Mod]
Name=Viper's Phoenix
Version=1.0
```

Extract mission 1 from the game's `resource.hog`, and decompile it into the mod's folder.
`sltool hog extract` unpacks every file of the archive into `game-files`, which you can delete once
you have the mission's source:

```bash
./sltool hog extract StarLancer/resource.hog game-files
./sltool dte decompile game-files/mission1.dte > StarLancer/mods/viper-phoenix/mission1.mission.luau
```

Open `mission1.mission.luau` in a text editor, find Viper's ship, `viper_s_coyote`, and change its
type. The mission comes from your own copy of the game, so this guide shows only the change, as a
diff: the line that starts with `-` comes out, the line that starts with `+` goes in its place, and
the lines that start with a space show where, and stay as they are.

```diff
 viper_s_coyote = ship("(WL)Viper's Coyote", {
-    type = "coyote",
+    type = "phoenix",
     group = flight_group_45th,
     pilot = "viper",
```

The ship keeps its names: the script finds it by `viper_s_coyote`, and `--watch` by
`(WL)Viper's Coyote`. Build the source into the mod, under the game's name for mission 1,
`mission1.dte`:

```bash
./sltool dte build StarLancer/mods/viper-phoenix/mission1.mission.luau StarLancer/mods/viper-phoenix/mission1.dte
```

Then play it:

```bash
./openreliant StarLancer --mission 1
```

Viper launches in a Phoenix with the rest of the wing, and the campaign's first mission has the
change too. To check it without flying, `--skip-launch` passes over the launch, and
`--watch "viper's"` shows Viper's ship:

```bash
./openreliant StarLancer --mission 1 --skip-launch --watch "viper's" --screenshot viper.png --screenshot-ticks 300
```

To play the game's own mission 1 again, start OpenReliant with `--no-mods`, or take the mod's folder
out of `mods`.

## Ships and markers

`ship(name, fields)` places a ship: a fighter, a capital ship or a station. Its fields are all
optional but `type` ([ShipFields](mission-reference.md#shipfields)):

- `type`, the ship's type. In the campaign, the player flies the ship picked on the loadout screen,
  whatever the first ship's `type` says.
- `group`, its flight group.
- `position`, and `yaw`, `pitch` and `roll` in whole degrees. The game turns a ship by its yaw about
  Y, then its pitch about X, then its roll about Z.
- `pilot`, the pilot who flies it, by name ([Pilot](mission-reference.md#pilot)), which sets how
  well it flies and fights. Mission 0's Sabres fly with `"jackel"`, one of the weakest.
- `launch`, for a ship that launches from a carrier: `{ from = "reliant", gate = 0 }` launches it
  through the first launch tube of the mission's first Reliant. Make the carrier's flight group
  before the ship's, so that the carrier is there, then start the launch with `StartLaunch` and wait
  for it to end with `WaitForJumpOrLaunch`. Mission 0 launches the player's wing this way
  ([Learning from other missions](#learning-from-other-missions)).

`nav_point`, `waypoint`, `point` and `curve_point` place markers: places that the script points the
player to, sends ships to, or films from. They take the same fields as a ship but `type`
([MarkerFields](mission-reference.md#markerfields)), and need a flight group too.

A value the game doesn't name, such as a ship type that a mod adds, is written as a number.

## Flight groups and wings

A ship appears once its flight group is made with `CreateFlightGroup`, so every ship and marker
needs a flight group. The start part usually makes them, and a part can make one later, to bring
its ships in during the mission.

`wing = "player"` lists a group's ships in the player's wing: they show in the wing status window,
and take the player's commands over the radio ([FlightGroupFields](mission-reference.md#flightgroupfields)).

Where a command takes an `Entity` ([Types](mission-reference.md#types)), it takes a ship, a flight
group or a squad. `SetAI(enemies, "fight", 1, player)` orders both Sabres to fight the player.

## The script

The script is the code of the parts and the triggers. It runs on threads, which take turns: each
start part, each trigger that fires, each part a timer runs and each `spawn` runs on a thread of its
own.

- **Parts.** `go_home()` runs the part `go_home` on the same thread, and comes back.
  `spawn(go_home)` starts it on a thread of its own and goes on at once. A part takes arguments as
  its function's parameters: with `function(seconds, ship)`, `go_home(5, player)` passes two.
  `CreateTimer(1, go_home, 30, 1)` sets timer 1 to run `go_home` once, 30 seconds later.
- **Commands.** The reference lists each command's parameters
  ([Commands](mission-reference.md#commands)). A ship, a flight group or a squad is given by its
  name, a value the game names in quotes, such as `"fight"` for an order, and nothing as `nil`.
- **Waiting.** `Wait(5)` waits five seconds. `WaitForSpeech()`, `WaitForMovie()` and
  `WaitForJumpOrLaunch(alpha)` wait for a line, a film or a launch to end. The other threads run on
  meanwhile.
- **Globals.** `convoy_hits = global("(GV)convoy hits", 0)`, outside any function, with the other
  declarations, declares a number that the code reads and changes: `convoy_hits += 1`.
- **The game's variables.** `game.landing_cleared = 1` lets the player land, and
  `game.mission_success` and `game.mission_over` end the mission
  ([Ending a mission](#ending-a-mission)). The reference lists them all
  ([GameVariables](mission-reference.md#gamevariables)).
- **Choices.** `if convoy_hits >= 3 then ... elseif ... else ... end`, with `==`, `~=`, `<`, `<=`,
  `>` and `>=`, and `and` and `or`. After a command that gives a result, such as
  `IsShipThisPlayer(ship)`, `result()` reads it.
- **Chance.** `local roll = random()` rolls a number from 0 to 99, and the `if` right after it picks
  an arm by it: `if roll < 50 then ... else ... end`.

The script has no loops: its code only goes forward. To do something again, run a part again, from
a timer or a trigger. A `return` can end the code of a part or a trigger early, and one must end
it.

Some commands leave the player's ship alone, as in the original: `SetInvulnerability`, for one,
reaches the player's ship only in the training missions.

## Triggers

`on(subject, condition, fields, code)` runs `code` when `condition` happens to `subject`: a ship, a
flight group or a squad ([Conditions](mission-reference.md#conditions)). The fields can be left
out.

```luau
on(convoy, "shot_at", { repeats = "always" }, function(attacker, shield_damage, hull_damage, victim, weapon_fired)
    convoy_hits += 1
    return 1
end)
```

- The code's parameters are the values that the condition's events carry, in the order the
  reference lists them. Their names are up to you.
- A trigger fires once, unless its fields say `repeats = "always"`, for every time, or
  `repeats = { counted = 3 }`, for three times.
- A field named after one of the values says what that value must be for the trigger to fire:
  `{ reached_ship = player }` keeps a `"ship_reached"` trigger to the player's ship, and
  `{ attacker = any_ship }` keeps a `"shot_at"` trigger to shots from the players' ships.
- On a flight group or a squad, a trigger answers its ships' events. `"destroyed"` waits until every
  one of them is destroyed, unless the trigger repeats `"always"`, which answers each one.
- The triggers of one subject must come one after another in the file.
- `SetTriggerState(convoy, "shot_at", 0)` turns the subject's `"shot_at"` triggers off, and `1`
  turns them on again.
- Triggers that run the same code declare it once, with `handler(...)`
  ([Triggers](../formats/mission-source.md#triggers)).

## Squads, formations and curves

- A **squad** is a list of ships, ships' components, flight groups and other squads, which commands
  and triggers take as one: `targets = squad("(AI)Targets", { sabre_1, sabre_2, convoy })`.
- A **formation** is a list of points, each where it stands from the formation's origin:
  `vee = formation("vee", { { 0, 0, 0 }, { -400, 0, 300 }, { 400, 0, 300 } })`. A flight group
  flies in it with `formation = vee` in its fields, and a ship takes its second point with
  `formation_point = vee[2]`.
- A **curve** is a path from one ship or marker to another, which the camera follows with
  `StartDirectorCam`, and ships fly with `ShipFollowCurve`
  ([CurveFields](mission-reference.md#curvefields)).

## Objectives

The objectives window lists a mission's objectives, numbered from 0 to 9. As the mission starts,
the first is the current one. `SetObjective(1, 2)` makes the second the current one, `1` in place of
`2` lists it, and `0` hides it.

The objectives' names come from the game's table, which has a row for each of the missions 1 to
35. A mission with a number of its own has objectives only where a game mode names them
([Game modes](scripting.md#game-modes)), and a mod can name a campaign mission's
([Each mission of the campaign](scripting.md#each-mission-of-the-campaign)).

## Ending a mission

- `game.mission_success` rates the mission: -1 a total failure, 0 a failure, 1 a partial failure, 2
  a partial success, 3 a success and 4 a success with a bonus.
- `game.mission_over = 1` ends the mission.
- `TerminateMission()` ends it too. In the missions numbered below 28, the game then counts the
  player's ship as destroyed.
- `game.landing_cleared = 1` lets the player land on the carrier with PERMISSION TO LAND, which ends
  the mission.
- The mission also ends once the player's ship is destroyed.

## Checking a mission

`openreliant missions` lists the missions, the mods' among them, and checks that each loads:

```bash
./openreliant missions StarLancer
```

Options of `--mission` check a moment of a mission without flying up to it: `--skip-launch` plays
the player's launch through without showing it, `--watch` points the camera at a ship, `--part`
runs a part, and `--screenshot` saves a picture and quits
([Checking a mission](modding.md#checking-a-mission)). In a mission whose player doesn't launch,
such as this one, `--watch` and `--part` start 600 ticks, six seconds, into the mission
([The mission](configuration.md#the-mission)):

```bash
./openreliant StarLancer --mission 90 --watch "sabre 1" --screenshot sabres.png --screenshot-ticks 900
```

`openreliant debug` steps through the script while the mission plays
([Stepping through it](#stepping-through-it), [Debugging mission scripts](debugging.md)).

## Editors

[luau-lsp](https://github.com/JohnnyMorganz/luau-lsp), the Luau language server, gives editors
such as VS Code completion and descriptions for mission source. It reads them from the definitions
file [`mission.d.luau`](mission.d.luau), which comes with each release: the declarations and their
fields, the script's functions, every command with its parameters and the developers' descriptions,
and the names of the game's values.

1. Install luau-lsp's extension, version 1.56 or later.
2. In the settings of the folder that holds your missions, such as its `.vscode/settings.json` in VS
   Code, add the file under a name, and turn on Luau's new type solver:

   ```json
   {
       "luau-lsp.platform.type": "standard",
       "luau-lsp.types.definitionFiles": { "@mission": "path/to/mission.d.luau" },
       "luau-lsp.fflags.enableNewSolver": true
   }
   ```

Mission source needs the new type solver, since a declaration can use a name that the file declares
after it, which the old solver takes for a mistake. The new solver doesn't report mistakes in the
types, though, so `sltool dte build` is still what finds them. The scripting API's definitions
don't load in the new solver yet ([#1139](https://github.com/OpenReliant/openreliant/issues/1139)),
so keep mods' scripts in a folder of their own.

## Learning from other missions

Reading the game's missions as source shows how they work: `sltool dte decompile` writes any of
them, as in [Changing one of the game's missions](#changing-one-of-the-games-missions). Their source
has no comments, and its names are made from the records' names, such as `jumping_to_convoy` from
`(F)Jumping to CONVOY`.

OpenReliant's Mission 0, the sandbox, is written as source with comments:
[`mission0.mission.luau`](../../src/openreliant/mission0.mission.luau). It launches the player's
wing from the Reliant, sets Sabres on them once they're out, and lets the player land.
