# The script VM at run time

How the payload runs mission scripts: threads, the interpreter loop, calls, commands, the clock, timers and events. The bytecode, and the triggers and parts that point into it, are described with the [mission format](../formats/dte.md#script). The structures below are defined in [`src/engine/vm.zig`](../../src/engine/vm.zig), and `make ghidra-annotate` applies them to the Ghidra project together with the names used here.

## Threads

Every block runs on a thread, a `0xB8`-byte context from the pool at `vm_thread_pool` (`0x537590`), which holds 32. `vm_thread_start` (`0x0045B8D0`) takes a block, points the thread's instruction pointer past the block's length halfword and its block end at `block + length`, and runs it at once unless told to defer it. It starts none while 31 are running.

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | Stack pointer, saved while the thread is suspended |
| `0x04` | 4 | Block end, where the block's constants start; saved likewise |
| `0x08` | 4 | Frame pointer: the running part's first argument |
| `0x0C` | 4 | Clock value to resume at; zero when not waiting |
| `0x10` | 4 | Instruction pointer; null marks a free slot |
| `0x14` | 4 | Block end at which the script debugger's step-over stops |
| `0x18` | 20 | The values of the event that started the thread, which `push_local` reads |
| `0x2C` | 128 | The stack |
| `0xAC` | 1 | **Unknown.** `0xFF` when the thread starts |
| `0xAD` | 1 | Call depth |
| `0xAE` | 1 | Set by `InterruptTriggerCode`: the thread waits for its trigger to fire again, which clears it |
| `0xAF` | 1 | The low byte of the index of the trigger that started the thread; `0xFF` for none |
| `0xB0` | 4 | The last command's result, or the last part's return value, for `push_result` |
| `0xB4` | 4 | **Unknown.** Zero when the thread starts |

`vm_thread_run` (`0x0045BA30`) leaves a thread alone until the clock passes its wake time. Otherwise
it loads the thread's stack pointer and block end into `vm_stack_top` and `vm_block_end`, makes it
`vm_thread`, and calls the interpreter. The thread then has either finished, and its slot is freed,
or yielded, and its stack pointer and block end are saved for the next run.

Once a frame, `process_mission` (`0x0045A570`), which `mission_frame` calls after `events_flush`,
runs the script: `vm_threads_run` (`0x0045B9B0`) runs on each thread that was running as the pass
began, from the pool's first slot, but those `InterruptTriggerCode` holds. A thread the pass starts
in a later slot runs in the same pass while the pass has threads still to count. `process_mission`
then copies the live objects' places into the mission's ships (`mission_ships_sync`), and once the
clock has ticked since, runs the timers and checks the proximity conditions (`0x0045AF60`).

`mission_bind_tables` (`0x00453050`) fills the part tables as the mission is bound: section 8's
parts, whose blocks lie in the script, then section 17's, whose blocks lie in `script_b`. A part
whose offset is `0xFFFF` has no block. `mission_script_start` (`0x0045CBC0`) runs each part flagged
to run at the start, at once, before any trigger is armed; then it arms every object's triggers, and
marks each ship not destroyed and all its components intact, making the ships of the first curve
that starts at it where the start part has not ([The director's camera](director.md#the-curves-ships)).

## The interpreter

`vm_run` (`0x0045C980`) fetches an opcode, advances the instruction pointer past it, and calls the
opcode's handler from `vm_dispatch_table` (`0x4F6350`):

```c
uint __fastcall handler(byte **ip, uint **frame, uint previous);
```

`ip` points at the thread's instruction pointer and `frame` at its frame pointer. `previous` is what
the last handler returned, 1 for the first. A handler returns `previous` to carry on, and the loop
ends when one returns zero. The thread has then finished if a `return` ran at call depth zero,
which sets `vm_finished`; otherwise it has yielded, and resumes at its instruction pointer on its
next run.

The opcodes take the stack's values as unsigned: the comparisons test with `CMP` and `SBB`, the
divisions are `DIV`, and the sums and products wrap. The float opcodes load a value with `FILD`, as
an exact whole number, so the float comparisons compare as the others do. The float arithmetic
takes the value lower on the stack unsigned and the top value signed for a difference or a
quotient, and the top value unsigned and the lower one signed for a sum or a product, then truncates
with `__ftol`. The float stores apply a value, loaded unsigned, to the float the store target holds.
While a mission runs, Direct3D leaves the FPU at single precision, so each of these results is the
exact one rounded to a float. `push_percent n` pushes the top value times `n` times 0.01
(`0x004DC730`), each product rounded.

`select_array`, `select_global` and `select_argument` make a place the store target
(`vm_store_target`) and push its value; `assign` and the compound stores write it and pop both. The
array is the game's variables ([The game's variables](#the-games-variables)).

The loop also serves a script debugger. With one attached, it can stop a thread at a byte that
section 10, one flag per script byte, marks, and report the position. **Unknown:** the debugger's
protocol. Not ported ([#539](https://github.com/vdmkenny/openreliant/issues/539)).

## The game's variables

The array `push_array` and `select_array` reach is a block of 64 of the game's variables, from
`jump_ready` (`0x0052A3F0`) up to the next global (`0x0052A4F0`), which scripts use by number. The
engine and the shipped missions use the first 38. A number past the block reaches the globals after
it in the game; OpenReliant gives every number a byte names a variable of its own
([`vm.Variables`](../../src/engine/vm.zig)).

| Number | Name | What it holds |
|---|---|---|
| 0, 1 | `jump_ready`, `warp_ready` | Whether the mission has a jump or a warp ready for JUMP DRIVE, which the display's prompt reads ([Jumps](jump.md)) |
| 3 | `backup_available` | Whether the carrier sends backup: the radio's REQUEST BACKUP (`0x004558D0`) raises the mission's PlayerWantsBackup event for the first request while it is set, and the carrier refuses otherwise. The scripts set it as backup can come and clear it as it can no longer |
| 4 | `player_missiles_left` | The missile display's counts together ([Missiles](missiles.md)) |
| 9 | `mission_over` | Set once the camera has watched the mission's end long enough, or once the player's ship has landed |
| 10 | `landing_cleared` | Whether PERMISSION TO LAND lands the player's ship ([Landing](orders.md#landing)) |
| 14 | `mission_success` | How the script rates the mission: -1 a total failure, then failure, partial failure, partial success, success, and 4 success with a bonus, as the game's debug line names them |
| 15 | `script_players` | How many players fly the mission, which WinMain sets before the mission loads (`script_set_players`, `0x004124D0`): 1 outside a multiplayer game. The scripts test it for the enemies a multiplayer game adds and for which ending of a part runs; mission 1's ambush ends only through it |
| 27 | `last_success` | The rating of the last mission the pilot came through, which `mission_end_record` (`0x00475A90`) keeps unless it is a total failure. Mission 25's second part weighs its own rating by it |
| 28 | `objectives_met` | Set by the script once the mission's objectives are met, as mission 1's is once the ambushers are destroyed. The debriefing of a mission the ejected pilot was picked up in tells the pilot the mission was a success by it, and a failure without it (`0x00424ECE`, `0x0042545B`) |
| 30 | `ghost_alive` | Whether Ghost, the ace mission 1 puts up against the player, lives: mission 1's script clears it as Ghost dies, and mission 4's has Petrov say a line by it |
| 33 | `countdown` | Seconds left, which mission 29's script sets. The game takes one off at every 100th tick of the mission (`0x00477889`), and in Instant Action's simulator and in mission 29 the display shows it as a clock in minutes and seconds, none below 0 (`0x004861FD`) |
| 37 | `ion_cannons_hold_lock` | While it is set, the Dark Reign's ion cannon (order 110) keeps its target rather than losing it as the target flies into its cone or out of its angle, or giving up a long search in a multiplayer game (`0x0040D40F`, `0x0040D7D9`) |

Some variables belong to an attempt at a mission, and the rest to the campaign.
`mission_reset_variables` (`0x00475620`) clears 0, 1, 3, 9, 10, 14, 28, 34 and 37 before each
attempt. A new campaign (`campaign_new`, `0x004751B0`), which WinMain starts as the game starts,
clears 0 to 31, then sets 5 to 8, 13, 14, 16 to 23, 29 to 32, 35 and 36 to 1: flags which the
scripts clear as the story's characters die, as mission 1's does `ghost_alive`, and which the flow
between missions reads to pick its films and messages. The pilot's saved game keeps 5 to 8, 11 to
13, 16 to 27, 29 to 32, 34 and 36 in its `VARS` chunk (`game_save`, `0x00475650`; `game_load`,
`0x00475430`). WinMain saves the game as a restart point before a mission's attempts and loads it
again for a replay or a restart (`restart_save`, `0x00475D20`; `restart_load`, `0x00475D30`), so
that every attempt starts from the variables the first had. OpenReliant keeps a campaign's
variables in `gameflow.Campaign`: each attempt at a mission starts from those the last mission the
pilot came through left, and a mission outside a campaign from a new campaign's
(`gameflow.restartPoint`). **Unknown:** what the campaign's other flags stand for
([#381](https://github.com/vdmkenny/openreliant/issues/381)).

## Calls

`call_part n` calls entry `n` of the part table. Above the arguments the caller pushed, it pushes a
call record, then points the frame at the first argument and enters the part's block:

| Offset | Field |
|---|---|
| `0x00` | Argument count |
| `0x04` | Return address |
| `0x08` | The caller's frame pointer |
| `0x0C` | The caller's block end |

`return` at a call depth above zero pops the part's return value into the thread's result, then the
record, then the arguments.

The part table and the command table share one `0x74`-byte record: the part's block or the command's
implementation at `0x00`, and the argument count in the byte at `0x04`. The command catalogue also
fills the name, parameters and description that follow; the loader fills only those two fields of a
part's entry.

## Commands

`command n` lowers the stack pointer by the command's argument count, so that it points at the
first argument, and calls the implementation:

```c
uint __fastcall command(byte **ip, uint *args);
```

The arguments are popped, and the result is written where the first was and stored as the thread's
result. It is also the handler's return value, so a zero result ends the loop: `Wait` sets the
thread's wake time to the clock plus its argument and returns zero, which suspends the thread until
then.

A command pops as many arguments as the catalogue gives it, whatever the script pushed. Mission
801's script calls `StartDirectorCam` with four where it takes five, so the command takes the
caller's block end for its first, and the part's `return` goes astray.

Before each call, `command` sets `vm_command_flag` (`0x00537584`) to bit 0 of the command's word in
section 24, inverted ([`.DTE` missions](../formats/dte.md)). It reads the low byte of the word
`number` places past section 24's offset, whatever its count (`0x0045BEDC`).

Many commands act on a ship, a flight group or a squad, which their first argument names by its
record's address. They hand `for_each_ship` (`0x0045D460`) a routine of their own for one ship, with
their arguments after the first, and it walks the entity (`0x0045D480`):

- A ship runs the routine once.
- A flight group runs it for each of its ships, in the mission's order (`flight_group_ships`),
  passing over the players' ships while `vm_command_flag` is set.
- A squad runs it for each of its members in turn, from its first in `squad_members`, until a record
  of another squad: a member that is a ship for the ship, with the component the member names
  tagged on the first argument (`vm_tag_component`) and untagged after (`vm_tag_pop`,
  `0x0045D8E0`); a flight group for each of its ships, as above; and a squad for each of its own, a
  squad down.

Before the routine runs for a ship, its object's `+0x698` becomes a reference (`dte.Reference`) to
the first ship the walk ran for, none for the first (`for_each_ship_note`, `0x0045D720`, through
`record_reference`, `0x004513A0`, whose reference has its top byte `0xFF`). **Unknown:** what
reads it.

`SetAI` and `SetupLaunch` number the orders they give from 0 as they walk (`0x0040CBC0`,
`0x0040CBE0`): each order pushed takes the next number (`0x005185A8`) while the byte at
`0x005185B1` is set, and 0 otherwise. The escort, the formations, the jumps, Launch and Warp Out
read the number, a ship's place among its group's.

A command that waits runs again when its thread runs next: it moves the thread's instruction pointer
back over itself and returns zero. `WaitForSpeech`, `WaitForMovie` and `WaitForDirectorCam` move it
back 2 bytes, over the command alone; `WaitForJumpOrLaunch` 4, over the push of its argument too,
which then pushes it afresh.

Every command, by the number `command` takes, with what it does and whether OpenReliant runs it.
One that OpenReliant does not run yet does nothing and lets the script go on
([#281](https://github.com/vdmkenny/openreliant/issues/281)); its description is the developers' own,
from the catalogue.

| Number | Command | What it does | Ported |
|---|---|---|---|
| `0x00` | `PrintShipName` | The developers' test command, with two test arguments | No |
| `0x01` | `CreateTimer` | Starts the part the second argument names after the seconds the third gives, as many times as the fourth says or, for 0, for ever, under the ID the first gives, in place of any timer of that ID ([The clock and timers](#the-clock-and-timers)) | Yes |
| `0x02` | `DestroyTimer` | Destroys the timers of the ID the argument gives | Yes |
| `0x03` | `CreateFlightGroup` | Makes each ship of the flight group the argument names, in the mission's order, and lists the flight groups in their wings ([Missions](missions.md)) | Yes |
| `0x04` | `DestroyFlightGroup` | Each ship of the flight group leaves the mission at once, a stand-in in its place (`object_retire`), a planet's atmosphere let go of with it ([Backdrop](backdrop.md#planet-atmospheres)) | Yes |
| `0x05` | `Wait` | The thread waits the seconds the argument gives | Yes |
| `0x06` | `PlaySpeech` | Plays the speech file the argument names at once, without the radio's window or a film ([Radio](radio.md#the-scripts-commands)) | Yes |
| `0x07` | `WaitForSpeech` | Waits while a line plays | Yes |
| `0x08` | `PlayCommsMovie` | Plays the film `pilots\<film>` the first argument names in the radio's window, with the speech file the second names, under the string the third numbers | Yes |
| `0x09` | `WaitForMovie` | Waits while a film of the radio's plays (`0x0057C3A8`) | Yes |
| `0x0A` | `PrintDebugMessage` | Writes the text the argument names on the screen, for debugging | No |
| `0x0B` | `SetAI` | Each ship the first argument names takes the order the second gives, aimed at what the fourth names, the orders numbered as they are given; the third, whether it starts at once, is not read ([Orders](orders.md)) | Yes |
| `0x0C` | `ClearAI` | Each ship the argument names, past the players' slots, drops its orders, where its current one gives way (`orders_clear`, [Orders](orders.md)) | Yes |
| `0x0D` | `SetPatrolRoute` | Each ship the first argument names follows the patrol route the second names | No |
| `0x0E` | `SetPilot` | The ship the first argument names is flown by the pilot the second names | No |
| `0x0F` | `SetTriggerState` | Arms or disarms the trigger of the condition the second argument gives on the entity the first names ([Events](#events)) | Yes |
| `0x10` | `StartDirectorCam` | The director's camera takes a shot along the mission's curves or at a ship, at once ([The director's camera](director.md#the-commands)) | Yes |
| `0x11` | `StartShipAnimation` | Each part of the ship the first argument names, but those taken out of its model, plays its track the second names from its start, in the track's own mode, at 4 a step (`node_play_named`) | Yes |
| `0x12` | `ShipFollowCurve` | Each ship the first argument names flies the path from the curve the second names over the seconds the third gives ([Following a path](orders.md#following-a-path)). **Fix:** where a ship refuses the order, the game writes the path into the order on top of its stack; OpenReliant writes none | Yes |
| `0x13` | `SetupLaunch` | Readies each ship the first argument names to launch from the ship the second names, through the gate the third gives ([Launches](launch.md)) | Yes |
| `0x14` | `StartLaunch` | Launches each ship the argument names ([Launches](launch.md)) | Yes |
| `0x15` | `DisplaySubTitle` | Writes the string the argument numbers as a subtitle | No |
| `0x16` | `ResetCodePriority` | Clears the priority of the orders of the entity the argument names | No |
| `0x17` | `InterruptTriggerCode` | The thread stops, and runs on when its trigger fires again | Yes |
| `0x18` | `CommsFromShip` | The ship the first argument names says the speech file the third names, at once, its face moving as the second says, the film looping while the line plays ([Radio](radio.md)) | Yes |
| `0x19` | `CommsFromPilot` | As `CommsFromShip`, for a pilot of the pilots' table, the first argument | Yes |
| `0x1A` | `SetInvulnerability` | Each ship the first argument names takes the invulnerability the second gives, or the component `push_component` named for it does. Only ships past the players' slots are reached, save in missions 30 to 35 and in the Reliant's simulator's training ([Objects](objects.md)) | Yes |
| `0x1B` | `MovingShipFollowCurve` | As `ShipFollowCurve`, the path carried by where the fourth argument's ship stands from where the mission placed it | Yes |
| `0x1C` | `DisableObject` | Each ship the first argument names is disabled while the second is set, which leaves it out of the mission's work, or enabled again; for a component, which `push_component` or a squad's member names, its assembly shows its damaged model instead, or its own again | Yes |
| `0x1D` | `PositionRelative` | Each ship the first argument names moves as far as the ship or point the second names stands from where the mission places it, its record's run-time place with it ([Missions](missions.md#the-missions-ships)) | Yes |
| `0x1E` | `WhenPlayerLastJumped` | How many seconds of the script's clock ago JUMP DRIVE last took a jump or a warp, at least 1 | Yes |
| `0x1F` | `StartMissileCam` | The director's camera follows a missile the ship the argument names fires | No |
| `0x20` | `StartChaseCam` | The camera follows the ship the argument names from behind | No |
| `0x21` | `SetPlayerTarget` | Where the first argument names the player's ship, the ship the second names, or its component, becomes the player's target, where the player can aim at it; the display follows, and MATCH SPEED stops ([Display](hud.md#the-target)) | Yes |
| `0x22` | `SetTargetable` | Each ship the first argument names can be targeted, where its type allows, or not; for the component `push_component` named, whether it can be picked as a subtarget | Yes |
| `0x23` | `PlayMusic` | Plays `music\` and the name the first argument points at, for ever at level 80, at once where the second is 1, or for any other value once the music playing has faded out ([Sound](sound.md#music)) | Yes |
| `0x24` | `StopDirectorCam` | The camera goes back to the player's cockpit, forced | Yes |
| `0x25` | `SetActionCentre` | The action sphere ([Maneuvers](maneuvers.md)) centres on the object the first argument names, its radius the second, or 220000 for none | Yes |
| `0x26` | `Dock` | The ship the first argument names docks at the port the third gives of the ship the second names, or at the first free port of a flight group's or a squad's ships ([Docking](orders.md#docking)) | Yes |
| `0x27` | `DisableTaunts` | Keeps the enemy's taunts on the radio (`0x00529CB4`) quiet while the argument is set; a mission's start clears it (`radio_reset`, [Radio](radio.md#remarks)) | Yes |
| `0x28` | `Fly` | Each ship the first argument names flies to the point the second names, at the speed the third gives, or at full throttle for 0 (Fly, [Orders](orders.md#the-orders)). **Fix:** where a ship refuses Fly, the game writes the speed into the order on top of its stack, such as Player Control's mouse stick, which then turns the player's ship; OpenReliant writes none | Yes |
| `0x29` | `CommsFromShipOnce` | As `CommsFromShip`, the film played once, then the dead channel's while the line goes on | Yes |
| `0x2A` | `CommsFromPilotOnce` | As `CommsFromPilot`, the film played once | Yes |
| `0x2B` | `DisableLights` | Puts out the lights of each ship the first argument names while the second is set, the static lights baked into its parts with them, and lights them again where it is not ([Static lights](rendering.md#static-lights)) | Yes |
| `0x2C` | `SetEnvironmentFX` | Turns the environment effect the first argument numbers on while the second is set, or off: the ice field, and effect 2, which does nothing ([Environment effects](backdrop.md#environment-effects)) | Yes |
| `0x2D` | `MultiPlayerSync` | **Unknown.** It takes no arguments, and its description names only its author | No |
| `0x2E` | `DisableGenericComms` | Keeps the remarks the radio makes by itself (`0x00529538`) quiet while the argument is set; a mission's start clears it ([Radio](radio.md#remarks)) | Yes |
| `0x2F` | `DisableGuns` | Each ship the first argument names fires no guns while the second is set, its turrets resting too | Yes |
| `0x30` | `SetNavPoint` | Sets the nav point of each ship the first argument names to the one the second names | No |
| `0x31` | `SetEscortPoint` | Each ship the first argument names takes the object the second names as its escort point (`+0x724`), whose marker the player's ship shows ([The escort point's marker](missions.md#the-escort-points-marker)) | Yes |
| `0x32` | `ResetAfterBurners` | Fills the player's afterburner fuel | No |
| `0x33` | `DisableMissiles` | Each ship the first argument names launches no missiles while the second is set | No |
| `0x34` | `DisableEngines` | Each ship the first argument names has its engines off while the second is set | No |
| `0x35` | `DisableEject` | The pilot of each ship the first argument names cannot eject while the second is set | Yes |
| `0x36` | `SetHostile` | Each ship the first argument names turns hostile while the second is set, or friendly, a neutral one too | Yes |
| `0x37` | `ResetToSpawnPositions` | In a deathmatch, puts the player at a spawn place at random | No |
| `0x38` | `UpdateEnvironmentFXState` | Applies what the script asks of its space at once rather than at the next jump (`environment_update`), and aims the sun, the lights and the nebula again from the markers (`backdrop_place`) ([Backdrop](backdrop.md)) | Yes |
| `0x39` | `SetPrimaryTarget` | The ship the argument names, or its component, becomes the mission's primary target, which PRIMARY TARGET makes the player's ([Display](hud.md#picking-a-target)) | Yes |
| `0x3A` | `WaitForJumpOrLaunch` | The thread waits while any ship the argument names is jumping, going through a gate or launching | Yes |
| `0x3B` | `DoNotDisturb` | Each ship the first argument names does not retaliate, come to another's help, rise to a taunt or take the wingmen's commands while the second is set (`do_not_disturb`, [Objects](objects.md#flags)) | Yes |
| `0x3C` | `SetEnvironmentFXNebula` | Asks for the nebula the argument numbers (`nebula_requested`, `0x0058A6B8`) | Yes |
| `0x3D` | `StartShipAnimationReverse` | As `StartShipAnimation`, backwards at -4 from where each part stands | Yes |
| `0x3E` | `SnapToPoint` | The ship the first argument names, unless it is exploding, ejected or out of a multiplayer game, is put where the object the second names will stand next, turned as it will be, and stopped | Yes |
| `0x3F` | `PlayFostersLastStand` | Plays the Foster's Last Stand film | No |
| `0x40` | `OpenInstrument` | Opens the display's window the argument numbers, held open ([Display](hud.md#the-windows)) | Yes |
| `0x41` | `CloseInstrument` | Closes the display's window the argument numbers | Yes |
| `0x42` | `DestroySubObject` | The component the first argument names (`push_component`) goes at once, with its assembly: an engine takes its share off the ship's engines, a shield generator leaves it without one, and its damaged model goes too unless the second argument is set, when it is shown in its place | Yes |
| `0x43` | `SetObjective` | Sets the state of one of the mission's objectives ([Display](hud.md#the-objectives)) | Yes |
| `0x44` | `SetRescueProbabilities` | The odds of the ejected pilot's pickup by a nanny ship, capture by the Antanov and death ([Ejection](ejection.md)) | Yes |
| `0x45` | `IsShipThisPlayer` | 1 where the argument names the player's ship, 2 otherwise | Yes |
| `0x46` | `SetFlybackMarker` | Sets the flyback markers afresh on each ship the first argument names, the second their reach ([Display](hud.md#the-flyback-markers)) | Yes |
| `0x47` | `ResetFlybackMarker` | Drops the flyback markers | Yes |
| `0x48` | `StopShipAnimation` | Stops the track the second argument names on the ship the first names | No |
| `0x49` | `SetShipAvoidance` | Each ship the first argument names, unless a stand-in, keeps clear of others no more while the second is set (`no_avoidance`, [Orders](orders.md#avoidance)) | Yes |
| `0x4A` | `MatchSpeed` | Where the first argument names the player's ship, MATCH SPEED turns on, matching at once where it already was, while the second is set, and off otherwise | Yes |
| `0x4B` | `MovingShipBackupCurve` | As `MovingShipFollowCurve`, the path flown backwards | Yes |
| `0x4C` | `WaitForKey` | The thread waits for the key the argument numbers | No |
| `0x4D` | `TerminateMission` | The mission ends once the frame is over, as one the player's ship is destroyed in where it is numbered below 28 (`0x00588338`, [The loop](loop.md)) | Yes |
| `0x4E` | `TurretSetTarget` | Each aimed turret on the component the first argument names, of each ship it names, aims at the ship the second names | Yes |
| `0x4F` | `SetAnyTriggerState` | As `SetTriggerState`, for the one of the triggers of a condition the fourth argument counts | Yes |
| `0x50` | `WaitForDirectorCam` | Waits while the camera shows the director's shots (view 13) | Yes |
| `0x51` | `KillAllScriptExecutionExecptMe` | Ends every other thread | Yes |
| `0x52` | `StackDirectorCam` | As `StartDirectorCam`, after the shots waiting ([The director's camera](director.md#the-commands)) | Yes |
| `0x53` | `Scanner` | The scanner looks for the object the argument names, or stops for none ([Head-up display](hud.md#the-jump-prompt-the-eject-marker-and-the-scanner)) | Yes |
| `0x54` | `ReplaceSubObject` | The ship the second argument names takes the place of the component the first names: it stands where the component's frame stands, turned as it is, a cargo pod turned on as the Mammoth's and the Stalag's pods hang, and the component is hidden | Yes |
| `0x55` | `Fire` | The ship the first argument names holds its guns' trigger for the ticks the second gives ([Guns](guns.md#the-trigger)) | Yes |
| `0x56` | `MultiplayerScriptSync` | In a multiplayer game, holds the players' scripts in step; in a game of one, runs on | Yes |
| `0x57` | `FriendlyFire` | The carrier sends the player's ship home as though it had destroyed a friend ([Friendly fire](orders.md#friendly-fire)) | Yes |
| `0x58` | `Cloak` | Cloaks each ship the first argument names while the second is set, or uncloaks it | No |
| `0x59` | `ReplenishWeapons` | The ship the argument names is armed again, a player's with the racks its loadout chose, or by loadout tier 0 in the simulator or where the briefing was skipped, and any other by its own tier; and made whole ([Missiles](missiles.md#the-loadout)) | Yes |
| `0x5A` | `WillsBlag` | The mission's record of the ship the argument names is no longer destroyed, and its pilot neither ejects nor has | No |
| `0x5B` | `ShowHudIcon` | Shows one of the display's icons, off, on or flashing | No |
| `0x5C` | `DisableListing` | The ship the first argument names, a ship alone, does not lurch as a torpedo strikes it while the second is set (`listing_disabled`, [Collisions](loop.md#collisions)) | Yes |
| `0x5D` | `DisableObjectAtNextJump` | Disables the object the first argument names, such as a planet, at the next jump or warp while the second is set, or enables it | No |
| `0x5E` | `DarrensNaughtyBlag` | **Unknown.** It takes two ships, and its description names only its author | No |

## The clock and timers

`vm_clock` (`0x538C9C`) counts the seconds of the mission: `vm_clock_start` (`0x00457C10`) zeroes it
and starts a periodic multimedia timer at one second, whose callback, `vm_clock_tick`
(`0x00458910`), increments it unless the script debugger holds it (`0x005373F8`) or the game is
[paused](loop.md).

`CreateTimer` fills one of the 16 timers at `vm_timer_table` (`0x537470`), first destroying any
timer with the same ID:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | The part to start; -1 for a free entry |
| `0x04` | 2 | Period, in seconds |
| `0x06` | 2 | Firings left; zero for no limit |
| `0x08` | 2 | Countdown to the next firing |
| `0x0A` | 2 | The timer's ID |
| `0x0C` | 4 | The clock value it last counted down at |

`vm_run_timers` (`0x0045D140`) counts each timer down once per clock value. At zero it starts the
part on a new thread for the scheduler, then reloads the countdown, or after the last firing
destroys the timer.

## Events

The game posts events as they happen to a queue of a thousand `0x30`-byte records at `event_queue`
(`0x52ABD8`), `event_queue_count` (`0x005373E4`) of them waiting, which `init_mission`
(`0x0045A4E0`) empties as a mission starts. Each names the ship it happened to, its condition, its
values, and its qualifier: the component of the ship it concerns, by its index among the components
of the ship's live object (`object_component_index`, `0x0045ADE0`), or `0xFF` for the ship itself.

- `event_post` (`0x0045B7C0`) takes an event for the ship's own triggers, where one of them would
  answer it.
- `event_post_group` (`0x0045B690`) takes one to be raised on the ship's flight group and on the
  squads that hold it too, where a trigger would answer it: the ship's own, its flight group's, or a
  squad's that holds the ship (`object_in_squad`, as the component the event concerns), in that
  order, each group only where its slice holds triggers.

Whether a trigger would answer is the matcher's test (`event_would_fire`, `0x0045B4E0`, below),
whatever the trigger's thread; like the matcher, the test has the object keep the event, and gives
the event's values to the first free thread's locals for each trigger that answers. With a thousand
events waiting, the game lists them and stops with the assertion "Trigger List exceeded"
(`0x0045B330`).

`events_flush` (`0x0045B840`), which `mission_frame` calls once a frame before `process_mission`,
raises each event in turn on its ship's object (`trigger_raise_event`, `0x0045CE70`) and, where it
was posted for them, on the ship's groups (`condition_raise`, below); then the queue is empty. An
event that a trigger's thread posts as it runs at once waits its turn in the same pass.

| Condition | Posted by | Values |
|---|---|---|
| ShotAt | `event_shot_at` (`0x0045A9E0`), with the groups: last in `object_damage` and in `object_armor_damage`, unless `0x00545860` holds it back; and in `component_damage`, for the ship but for damage of kind 4, and for the component struck | The attacker's ship, the ship's damage value twice, the ship, -1 |
| Destroyed | `event_destroyed` (`0x0045AA60`), with the groups: as a ship's Explode begins (`explode_ship_init`), and the limpet car's (`explode_limpet_car_init`); as a pilot ejects (`order_eject_init`, `order_eject_spin_init`); as a ship's hull is lost (`object_hull_lost`); and for each component `node_draw` takes out | The ship of what struck it last (`last_attacker`), the ship |
| Launched | `event_launched` (`0x0045A9B0`), with the groups, as each launch style ends ([Launches](launch.md)) | The ship |
| JumpedIn | `event_jumped_in` (`0x0045B300`), with the groups, as Jump In ends ([Jumps](jump.md#jump-in)) | The ship |
| ObjectScooped | `0x0045AAD0`, with the groups, as Scoop Up has the pod aboard ([Ejection](ejection.md)) | The pod's ship |
| RipperGrabbedObject | `event_ripper_grabbed` (`0x0045AB10`), with the groups, as a Ripper has what it grabbed aboard ([The Ripper](orders.md#the-ripper)) | What it grabbed's ship |
| RipperDroppedObject | `event_ripper_dropped` (`0x0045AB90`), with the groups, as a Ripper leaves what it let go, or has fitted a pod to a ship ([The Ripper](orders.md#the-ripper)) | The pod's ship |
| ExplosionShip | `event_post_explosion` (`0x0045AB50`), with the groups, as the Uber Explode ends ([Effects](effects.md)) | The ship |
| Cloaked, Decloaked | `object_cloak`, `object_uncloak` ([Cloak](cloak.md)) | None |
| PlayerReadyToJump, PlayerReadyToWarp | `player_jump` (`0x00412B20`), on the player's ship | None |
| Docked | Dock, as the ship is in its berth ([Docking](orders.md#docking)) | None |
| CameraReached | `event_camera_reached` (`0x00451180`), as the director's camera reaches the end of a curve, or a place a point marks on it ([The director's camera](director.md#a-shot)) | None |
| CloseProximity, Proximity, ShipReached | The watches (below) | The ship close by; for the first two, how far, in the subject's radii |
| ShipReached | `event_post_ship_reached` (`0x0045AC10`), as a ship following a path reaches the end of a curve, or a place a point marks on it ([Following a path](orders.md#following-a-path)) | The ship that reached it |

A hit by an object that stands for no mission's ship posts no ShotAt: an object stands for the
mission's ship of its slot's index (`object_ship`, `0x0045A970`). `0x00545860` is set while
`objects_collide` tests a ship against a hull again after a first hit, up to nine times, so that
those knocks post no ShotAt; a shot at an object listing components, whose armour takes nothing of
it, posts the ship's from `object_armor_damage` at once, whatever the flag. The component whose ShotAt a hit posts is
the one the part struck counts against: the first component among the parts of its model of the
part's group (SHP part `+0x108`, [SHP](../formats/shp.md)) where it has one, else of its assembly.

`event_destroyed` has the ship's record note the loss: the ship's Destroyed flag, after which its
own Destroyed is posted no more, or for a component, its bit of `intact_components` (bit `n & 31`)
cleared.

JUMP DRIVE (`player_jump`), while the mission goes on and the mission has a jump or a warp ready
(`jump_ready`, `warp_ready`), notes the script's clock at `0x005373F4`, which `WhenPlayerLastJumped`
counts from, and posts PlayerReadyToJump for each jump and PlayerReadyToWarp for each warp it takes,
clearing it. **Unverified:** it first closes the target display's large form, or else its small one,
where the words at `0x0057BEA8` and `0x0057BE44` hold 1 or 3; nothing writes them.

### Matching

`trigger_raise_event` raises an event on an object unless its ID is `0xFFFF`, then sets
`condition_verdict` (`0x00525F84`) to 1 again. `trigger_match` (`0x0045CEA0`) first has the object
keep the event, where the condition keeps its last one: the `0x28`-byte records at `event_values`,
one for each object, hold ShotAt's five values, then Destroyed's, which `push_event_value` reads.
Then it walks the triggers in the object's slice of the trigger list, and takes each that answers
the event: armed, of the event's condition and qualifier, with a block to run, and, while
`condition_verdict` is 0, of the repeat mode the condition exempts from a veto.

1. It copies the event's values into the first free thread's locals.
2. It checks the trigger's operands against the values: those the condition marks as checked, and
   of those, the ones whose low halfword is not `0xFFFF` (`trigger_check_operand`, below). A failed
   check passes over the trigger, which stays armed.
3. Unless a thread the trigger started is still running (`trigger_thread_running`, `0x0045D0D0`),
   it starts that thread on the trigger's block, at once where the trigger's `+0x16` is 0, otherwise
   for the scheduler, the thread keeping the trigger's index in a byte (`0x0045B929`). A thread of
   the trigger that waits for it (`InterruptTriggerCode`) runs on again instead. The test compares
   the whole index against that byte (`0x0045D106`), so trigger 255 takes every thread no trigger
   started for its own, and a trigger past 255 never finds its own threads.
4. It disarms the trigger as its repeat mode says: `once` at once, `counted` once its count at
   `+0x19` has run down, `always` never.

`condition_raise` (`0x00453210`) raises an event that happened to a ship on the ship's flight group,
then on each squad that holds the ship, as the component the event concerns, each only where its
slice holds triggers. A group's event concerns the group itself (qualifier `0xFF`). For each group,
the condition's handlers, where it has them, count its members: a flight group's ships, whole, or a
squad's members (`condition_squad_add`, `0x004533D0`), a ship as the component its membership
names, each ship of a flight group whole, and a squad's own members in turn. Their verdict becomes
`condition_verdict` for the group's triggers.

- **ShotAt** (`shot_at_group_begin`, `0x00452BB0`; `shot_at_group_add`, `0x00452BD0`;
  `shot_at_group_verdict`, `0x00452C00`): the handlers add up the members' damage values twice over
  (`shot_at_shield_total`, `0x005294E6`; `shot_at_hull_total`, `0x0052950A`), and the group's event
  carries their average, over the members counted, for both of its damage values; they never veto.
- **Destroyed** (`destroyed_group_begin`, `0x00452C40`; `destroyed_group_add`, `0x00452C50`;
  `destroyed_group_verdict`, `0x00452CA0`): the verdict holds only once every member is destroyed,
  or the component a squad names of it (`destroyed_group_all`, `0x00525F7C`). Until then the event
  fires only the group's triggers of repeat mode 1, which the condition exempts.
- **Cloaked**, **Decloaked**: Destroyed's first and last handlers, with `cloak_group_add`
  (`0x0045D800`), which does nothing, for each member, so every event goes ahead. Both are posted for
  the ship alone, so the handlers never run.

A ship's damage value (`ship_damage_value`, `0x00452CB0`) is how much of its armour it has lost, in
whole hundredths: its weakest quadrant's against the full armour of its type, six times its armour
class ([Objects](objects.md)), or a component's own against what it starts with; 100 once any of it
has run out, and for a component the ship lists no more. The full armour comes from the object's
current type (`ship_combat_stats`, `0x004FC670`). For a stand-in, type 1001, such as a ship not made
yet or one retired, the game reads past the table at `0x00508224`, in a 3D sound's name. That value
makes the full armour a large negative number, so a stand-in's value is 100 as well.

### Watches

As the mission's tables are made (`mission_bind_tables`), `0x0045AE10` lists a watch for each
trigger of CloseProximity (`0x00536DD8`), Proximity (`0x00536758`) and ShipReached (`0x0052A5D0`),
in the trigger list's order: the trigger, the object whose slice holds it (the first,
`0x00453530`), and a flag, set. A trigger of the player's ship, the mission's first, watches the
other players' ships too, with a watch on each. `SetTriggerState` sets and clears the flags of a
trigger's watches as it arms and disarms the trigger (`0x0045B2D0`).

Once the script's clock has ticked, after the timers (`process_mission`), `0x0045AF60` has the
watches look for ships close by, each on a mission's ship that is not destroyed and whose object is
no stand-in, while its flag is set:

- CloseProximity's, once a ship, within 20 of the ship's radii (`0x004DC72C`).
- Each of Proximity's within its trigger's second operand, a number of the ship's radii, where it is
  set.
- ShipReached's, once a ship, on a waypoint or a nav point (kinds `0x3E5` and 999), within 4000.

`0x0045B170` looks: each other mission's ship, not destroyed and no stand-in, within the distance of
the watching ship posts the watching ship's event for its own triggers (`event_post`), with the ship
and, for the proximity conditions, how far it stands, in the watching ship's radii, truncated. The
matcher never checks that distance (below), so a Proximity trigger answers the event of any of its
object's watches.

### The commands

- `SetTriggerState` (`0x0045D300`, command `0x0F`) arms each trigger of the condition its second
  argument names, in the slice of the object its first names, where the third is set, and disarms
  it otherwise. Only the triggers of a component `push_component` named for the command answer, or
  those of the object itself (`0x0045D910`); arming one gives it its count again, from `+0x1A`
  (`trigger_set_armed`, `0x0045D390`). Its watches follow it.
- `SetAnyTriggerState` (`0x0045D3A0`, command `0x4F`) does the same for the one trigger of that
  condition the fourth argument numbers among the slice's, from 0, its count left as it stands.
- `WhenPlayerLastJumped` (`0x00458580`, command `0x1E`) gives the seconds of the script's clock since
  JUMP DRIVE last took a jump or a warp, at least 1; `0xFFFF` before the first, as the script's start
  sets the time.

### Conditions

`condition_descriptors` (`0x4F6698`) describes each condition in `0x1C` bytes:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | Name, as in `ShotAt` |
| `0x04` | 2 | **Unknown.** Zero, but `0x400` for the internal `ExplosionShip` |
| `0x06` | 2 | The kinds of object whose triggers can have the condition: bit 0 ships, 1 flight groups, 2 squads |
| `0x08` | 4 | The values an event carries, a list ending with a null label; null for none |
| `0x0C` | 1 | Slot in each object's kept events; `0xFF` for none |
| `0x0D` | 1 | The repeat mode exempt from a veto; `0xFF` for none |
| `0x10` | 12 | Handlers: before the members, per member, and the verdict |

Every trigger in the shipped missions belongs to a kind of object its condition allows.

An event value is 12 bytes: a label pointer, a kind mask of the kind the commands' parameters use, a
byte that is `0xFF` except `0x09` for ShotAt's weapon, and a byte saying whether a trigger's operand
is checked against the value. ShotAt carries the attacker, the shield damage, the hull damage, the
victim and the weapon; Destroyed the killer and the victim. The damage values set kind bit `0x1000`,
which no command parameter uses.

Events pass ships as the addresses of their records, and the matcher turns a trigger's operands into
the same form (`trigger_operand_value`, `0x004530A0`): the [mission format](../formats/dte.md#operands)
gives the encoding. `trigger_check_operand` (`0x0045D810`) passes an operand for any ship on the
players' ships alone, the records of the first `player_slots` ships; it compares a number operand of
the proximity conditions as an upper bound rather than for equality, but their distance value is not
marked as checked, so the matcher never compares it; and anything else must equal the value. An
operand naming no ship, flight group or squad stops the game ("NULL entity referenced in script").
The catalogue is also generated into [`src/engine/vm/conditions.zig`](../../src/engine/vm/conditions.zig).

## In OpenReliant

[`vm/machine.zig`](../../src/engine/vm/machine.zig) runs the VM: the threads, the interpreter, the
clock, the timers, `for_each_ship`, and the commands that lie beside the interpreter (`CreateTimer`,
`DestroyTimer`, `Wait`, `InterruptTriggerCode`, `KillAllScriptExecutionExecptMe`, and the display's
`OpenInstrument` and `CloseInstrument`). The bound mission
([`mission/bind.zig`](../../src/engine/game/mission/bind.zig)) finds the record a script names by
its place (`ship_index`, `record_kind` and the rest) and reads the image where the script points
([Missions](missions.md#the-records-as-the-script-names-them)).
[`game/executor.zig`](../../src/engine/game/executor.zig) ticks the clock (`vm_clock_tick`) and
holds the commands that act on the game: every command [the table above](#commands) marks as
ported, other than those `vm/machine.zig` holds and `vm/triggers.zig`'s `SetTriggerState` and
`SetAnyTriggerState`. They act on it through the world the mission's start and its frame give the
machine, which the game reaches through its globals. A command not ported yet does nothing and gives
1, which lets the thread run on, and is logged the first time it runs
([#281](https://github.com/vdmkenny/openreliant/issues/281)).

[`vm/triggers.zig`](../../src/engine/vm/triggers.zig) matches the events to the triggers, raises
them on the groups with the conditions' handlers, and holds `SetTriggerState` and
`SetAnyTriggerState`; [`game/mission/events.zig`](../../src/engine/game/mission/events.zig) holds
the queue, what posts each event, and the watches. The game's code posts its events through the
world (`gameobj.World.events`).

Where the game holds an address on a thread's stack, OpenReliant holds where the place lies in the
mission image, which holds the script, its strings and every record a script names. The
instruction pointer and a block's end are such places, and a frame is a place on the thread's own
stack; an event names a ship, a flight group or a squad so too.

**Improvement:** the clock ticks from the game's own clock, once every 100 ticks the pause does not
hold, in the place of a timer of its own.

**Fix:** where the game faults or reads past a table, OpenReliant ends the thread and logs why: an
integer division by zero, a stack that runs past its 32 places or below its first, an opcode with no
handler, an instruction or a record past the image, an argument read with no frame, a store with no
target, a local past the fifth, and squads that hold one another round in a circle.
`in_flight_group` and `in_squad` end the thread on a place past the address space, such as
`push_null`'s, where the game faults. A command whose flags in section 24 lie past the image, as for
a section that starts at the file's end, takes none, where the game reads past its copy of the file.
The entries of a part table past the mission's parts have no block, where the game leaves them as
`malloc` gave them. `for_each_ship` stops at a squad that holds itself round, which the game walks
for ever, and passes over a member no record stands for, and a ship past the last object's slot.
A ninth component tag is dropped, where the game writes past its list of eight. No thread starts
where the pool has none free, and no timer is made where the table is full, where the game takes
one past them. A call through the second part table to a part with no block does nothing, where
the game runs from address zero. `in_squad` passes over a member squad no record stands for, where
the game reads from address zero, and a member past the object table, where it reads past it.

**Fix:** with a thousand events waiting, OpenReliant passes over the ones past them and logs it,
where the game stops. An operand naming no ship, flight group or squad passes nothing, logged once,
where the game stops. A thread keeps the whole index of the trigger that started it beside its
record, which the matcher compares, where the game compares the index against its low byte: trigger
255 finds none of the threads no trigger started, and a trigger past 255 finds its own. The matcher
takes an object's slice of the trigger list as far as the object table and the list reach, where the
game reads past them. The handlers' count of a squad passes over a member of a kind the game has no
name for, where the game stops ("unknown ai group member"), and one no record stands for, and stops
at a squad that holds itself round. Cloaking an object that stands for no mission's ship posts
nothing, where the game faults. The watches' lists are as long as the mission needs, where the game
writes them into tables of a fixed size without looking.

Not ported: the script debugger; and the events that code OpenReliant does not run yet posts, such
as FixedGateJumpedIn from the gates' jumps
([#307](https://github.com/vdmkenny/openreliant/issues/307)).
