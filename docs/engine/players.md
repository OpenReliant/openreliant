# Players

OpenReliant keeps simulation-owned player state in `players.State`, alongside the objects in
`create.Objects.player_states`. Player roles use the first `Objects.players` slots, independently
of which player this machine displays (`Objects.player`). An ordinary object has no player state.

**Improvement:** each player has separate shield reserves. The simulation uses the struck player's
reserves for shots, missiles and knocks, and that player's reserves when recharging shields.
Balancing still moves the same amount in the same order. The drawing snapshot includes these
records, so the HUD and the scripts' ship status read the displayed player's reserves from the
same snapshot as the shields. The public script API is unchanged.

Only the first `Objects.players` slots can hold participants. Local single-player control state
and reserves survive ship replacement. Starting a mission clears local reserves and preserves
throttle, speed matching and the afterburner toggle, following the original's local globals.
Host-managed participants use the lifecycle below.

The host stores each admitted pilot's session name in the game's code page. The original
name-change handler (0x004B6A80) copies up to 32 bytes into the player row at 0x005DB654.
A rename applies to the same admission across ship changes. A pilot taking over a vacant
slot starts with a fresh name. The target HUD reads the name from the bound ship's admission.
Session delivery is tracked in [#954](https://github.com/OpenReliant/openreliant/issues/954).

## Comparison with the original

| State or operation | Original | OpenReliant |
| --- | --- | --- |
| Player roles | `player_slots` (`0x0058832C`) counts slots from the first | `Objects.players` keeps this convention |
| Local player | `player_index` (`0x005883FA`) selects the local ship | `Objects.player` selects the displayed player |
| Shield balance | `shield_balance` (`0x00412D40`) uses the local ship and two globals, fore at `0x0051CF78` and aft at `0x0051CF34` | Separate reserves in each player's simulation state |
| Shield recharge | `object_recharge_shields` (`0x00476FC0`) runs for all objects, but applies the reserve globals only to the local ship | Each player's recharge uses their own reserves; ordinary ships recharge without reserves |
| Flight controls | `player_controls` (`0x00413410`) reads local devices and control globals | Local input produces flight commands; each participant has separate control state |
| Remote control order | `order_multiplayer_control` (`0x00414F70`) sets `disabled` when `sent_off` is set | Keeps that check, then applies the participant's commands without reading local devices |
| Kills and deaths | `kills_add` (`0x004B14F0`) and `deaths_add` (`0x004B1580`) update local globals and per-slot counters at `0x005DB684` and `0x005DB688`, with a `0x3C` stride | The host credits the pilot who owned the damage source. In an arena it also counts each pilot's deaths and keeps separate totals for team games. |

`simulation_step` (`0x004774D0`) reads devices every fourth tick and updates every object's nodes,
shields and guns. It runs an extra Player Control update for the local ship before movement.
The remote control order does not repeat the local control routine. Reading the local devices
once for each connected ship would give them all the same controls.

The original remains the comparison for gameplay rules and timing. Host authority requires
the host to simulate each ship from its pilot's commands. See
[#954](https://github.com/OpenReliant/openreliant/issues/954).

## Flight commands and targets

**Improvement:** `input.sampleFlight` resolves local bindings, axis inversion, view-dependent
camera keys and accumulated mouse movement into an `input.flight.Command`. `input.flight.apply`
uses the original steering, throttle, power and shield calculations. The native command contains
requests, never a position, velocity or shield value. It does not change the public script API.

`players.State.controls` owns the throttle setting, speed matching and afterburner toggle. Mouse
button latches, the held local power window and the local shield-balancing key stay in
`input.Player`. They affect which command the input side produces, not how a remote command runs.
The HUD and script instruments read matching state from the displayed participant's drawing copy.

A host input source submits a `players.Command` through the current participant and ship binding.
The host rejects invalid axes without replacing the previous input. The record retains held flight inputs while
consuming throttle presets, afterburner toggles, speed-match toggles and target requests once.
A target request names one object and an optional component. The host checks the object's
identity on receipt and again when applying the command, then checks whether it can be targeted.
Smart targeting starts off for each new pilot. A host command can turn it on or off. The
setting belongs to the admission and survives a ship change. When a shot lands, the host
checks that its firing ship still belongs to the same pilot. A shield hit selects the whole
ship, an armour hit changes the ship but keeps the component index, and a hit on a listed
hostile component selects that component. Collisions leave the selection alone. These rules
also run on a headless host. A cockpit shows its own pilot's selection and smart targeting light.
The host applies that input even for slot zero on a headless host. A host-managed slot reads
commands exclusively, including while the slot is vacant or the participant has no ship. Existing non-player Player
Control orders retain their local input behaviour.

This is an internal simulation input record. Packet ordering, buffering and timeouts belong to
[#954](https://github.com/OpenReliant/openreliant/issues/954); it is not a network packet format.
Each participant's control order receives the extra update before every physical step, in player
slot order. The local single-player path still reads devices at the same points, uses the same
press latches and gathers each mouse read once.

The control order remains the single owner of the selected target. `ai.controlEntry` finds Player
Control or Multiplayer Control for a specified participant. A submitted target retains its
`aigeneric.Aim`, so a ship removed before the request runs cannot be replaced by another ship in
the same slot. The host checks target validity before selecting it. Clearing a target also stops
speed matching.

Target search, subtarget cycling, range checks and speed matching use the participant's ship.
The display follows target changes only for the displayed participant. Automatic target upkeep
runs for every participant, without adding a second selected-target field to `players.State`.

## Participant and ship lifecycle

**Improvement:** `joinParticipant` issues a fresh `ParticipantRef` for a reserved player slot.
`bindParticipant` pairs it with the current ship's `ObjectRef`. The host passes that pair to
`submitPlayerCommand`, using the participant identity from the session. A command can replace
the previous input only while both parts of the pair still match. The host reads held input only
while the same ship remains bound.

Removal, replacement and mission reset end the ship binding and clear held commands, controls,
shield reserves, missile selection and lock state. The participant keeps their admission and can
bind the replacement when the game mode creates it. Repeating the same live binding preserves
input already received for that ship.

**Improvement:** the host can assign, change or clear an arena team with `setParticipantTeam`.
A pilot starts without a team. Their team belongs to their admission, so it survives a ship
replacement or mission reset. Leaving clears it. The host can read or change the assignment
while the pilot has no ship. Both operations check the admission, so a reference to a pilot
who left cannot read or change a new occupant's team.

Leaving ends the admission, clears held controls and leaves ship disposition to the game mode.
A later occupant gets a different participant identity even if the game mode assigns the same
ship. Session authentication, ordering and disconnect detection belong to
[#954](https://github.com/OpenReliant/openreliant/issues/954).

Joining the lobby updates the roster. In flight, an arriving pilot adds the original HUD line
(`net_receive_game_message`, 0x004B6F80, case 6). `mp_player_departed` (0x004B6890) uses
installed string 0x562 in the lobby and 0x328 on the flight HUD. OpenReliant sends the name and
admission from the host, so a departure still identifies the right pilot if the slot fills again.
The lobby shows system lines in its chat log. The [multiplayer pause screen](pause-menu.md#multiplayer-9)
keeps recent flight chat and pilot notices, including messages sent during a shared pause.

### Text chat

**Improvement:** the host relays lobby and flight chat for admitted pilots. Requests carry text
and a destination. The host takes the sender's callsign from the admission, reserves SYSTEM,
and uses the pilot's slot as a fallback if the callsign is blank or already in use. A direct
message goes to the sender and the selected admission. If that pilot leaves, a later occupant
of the slot cannot receive the message.

The host accepts at most 63 bytes of printable Windows-1252 text. It trims outer spaces and
rejects blank lines and control bytes. Each pilot can send a burst of two lines and earns
one more line every two seconds. The session can relay a burst of four and earns one more line
every 750 ms. Its limit persists when pilots reconnect. Excess lines are dropped. Chat does
not extend the connection timeout or write messages to the server log.

## Weapon commands

**Improvement:** each participant's simulation state owns missile selection and lock progress.
The HUD and the scripting instruments read the displayed player's selection from the drawing
snapshot. The HUD keeps the lock tone, missile name and warning sounds.

The host receives a held gun trigger and presses to rotate missiles, launch a missile or drop
a countermeasure. The host applies the ship's existing weapon rules. It takes ammunition from
the ship's racks and checks the selected weapon, lock and current target before a guided launch.
Changing the selected missile or target in the same command as a launch cannot reuse the old
lock. A replacement ship starts with its own loadout and a fresh lock.

Submitted commands advance locks on the game frame, including on a headless host. Local
single-player controls keep the existing camera and wormhole checks, button latches and input
order.

## Ship devices

**Improvement:** the host owns cloak, ECM and spectral shield charges for each participant.
The host fits them from the ship definition and model, then checks fitting and charge before
accepting an activation. It consumes each device press once. The game frame advances the
charges even on a headless host. Empty devices switch off and recharge. An empty cloak starts
decloaking, including when its charge runs out during activation.

The HUD and scripting instruments read the displayed participant's charges from the snapshot.
Local input keeps its existing device timing and presentation. The rules and original addresses
are in [The devices](hud.md#the-devices).

## Combat hit feedback

**Improvement:** hits address HUD interference, camera shake, controller feedback and armour
quadrant markers to the struck pilot. A headless host emits these effects in simulation order,
labelled with the participant's admission, ship reference and game tick. A presentation consumer
checks its current binding before applying an effect. A respawn or slot reuse invalidates
delayed feedback for the previous ship or participant.

The local game applies the same effects at their existing points in the damage routine. The
host's feedback sink only receives presentation events. Damage calculations and mission
notifications still run on the simulation side.

Hull impacts use the same recipient checks. The host keeps the struck pilot's sound cooldown and
sends the positional impact to other bound ships within the sound's range. The recipient places
the sound using their camera. Network delivery is tracked in [#954](https://github.com/OpenReliant/openreliant/issues/954).

Co-op taunts, missile warnings, kill remarks and friendly-fire warnings follow the affected
pilot's binding. The host keeps each warning's state and runs the `radio_say` hook. The receiving
radio applies the checks and deadlines for each type of line. See [Radio remarks](radio.md#remarks)
and [Friendly fire](orders.md#friendly-fire).

In co-op the host records each pilot's mission ending. A friendly-fire recall waits for the
bound ship's priority order to finish. Replacing the ship or leaving the session cancels a
pending recall. Once the ship is sent off, its pilot keeps the outcome until the next mission.
The other pilots can keep flying. See [Friendly fire](orders.md#friendly-fire).

## Kill credit

`explode_kill_credit` (0x00408500) calls `kills_add` (0x004B14F0) before the radio remark.
The original adds the award to the pilot's row. It also increments the local mission tally
once per destruction in campaign missions 0 to 27. OpenReliant reads this rule from the
installed mission record (`counts_kills`).

**Improvement:** the host credits the admission and ship that owned the last damage source.
Co-op pilots get credit even when their channels are closed or the host has no radio.
The cockpit skull and the existing `hud.kills` script field show the displayed pilot's total.
A replacement ship keeps both counts. At the start of a co-op mission, the pilot's own profile
supplies the starting rank, campaign tier, kills, awards and mission records (`WinMain`, 0x004A99CC).
The cockpit adds the host's kill credit for this attempt to the local career tally. The
debrief writes the pilot's new record to the profile. Replaying restores the starting record
for that attempt.

### Arena scores

The original compares the pilots' teams at 0x0040858E. When a player's ship starts exploding,
it records the death at 0x00408866 before checking who gets the kill. Each machine reports
its local pilot's totals in message 0x3B (0x004B9F20).

**Improvement:** the host scores the destruction for every bound pilot. A hostile ship or a
pilot's ship qualifies if it is a fighter, Kamov, Kurgan or Gurevich. The component hull path
also credits a Kurgan, Antanov or Gurevich. Free-for-all ignores team assignments. In a team
game the attacker needs a team, and a bound victim must belong to a different team. The victim
still records a death after friendly fire, an environmental loss or a hit from a departed pilot.
Only an assigned pilot contributes to a team's totals.

Starting an arena round clears individual and team scores and keeps the pilots' assignments
(`mp_arena_init`, 0x004AE860). Respawning preserves scores. A team keeps its score while any
member remains, including a pilot waiting for a ship. When its last pilot leaves or changes
teams, both team totals return to zero (`mp_reset_team_tallies`, 0x004B15E0).
The [Uber blast](effects.md#the-uber-explode) can also award a kill for a teammate. Its host
notice carries the owner and victim admissions and the scoring tick. Session delivery and pilot name lookup
are tracked in [#954](https://github.com/OpenReliant/openreliant/issues/954).

Hold **Display Kills** to see the flight standings. The rows follow `mp_draw_scoreboard`
(0x004AF650), which sorts by kills and then by fewest deaths. Exact ties stay in pilot slot
order. The panel uses the installed arena sprites and shows rank, pilot, kills, deaths and
ping. OpenReliant reports each pilot's measured round trip to the host. The client checks
that each name belongs to the same admission as the score. The table fits complete rows to the
HUD scale and the available screen height. When more rows are available, use the mouse wheel or
Page Up and Page Down while holding Display Kills.

The original sizes the arena wall around the map's scenery and spawn markers
(`arena_frame`, 0x004AEB50). The host applies the inward push and damping to ships that
cross the wall. It places ships that stray beyond 1.2 times the radius at 1.01 times the
radius, where the push can bring them back in. Gun bolts end at the wall except for turret
flak, which has its own burst. Clients show the wall ripple, blue sparks and the impact sound.

Order 121 protects a spawning fighter for 300 ticks. The fighter remains targetable, but
collisions, damage, flight controls and pickups are blocked during the spawn. The pilot sees
the original camera swing and the ship appears through the moving clipping plane. Other
pilots see the same sweep at the same age, including when they join while a ship is appearing.

Stock arena fighters use the original spin-out style (`explode_ship_init`, 0x004086F0).
When the order reaches its last frame, the host sends the dying fighter's place and velocity
before making its replacement (`explode_ship`, 0x00408A60). Clients use the shared blast,
mesh cutting and debris effects, which can continue playing after the new ship appears.
The original debris uses a scene mesh and its own flight record (`debris_add`, 0x00472700).
The fragments are visual and have no collision or damage rules.

### Stock arena rules

The six stock arena records pair each mission in `dm_scenarios` (0x0050C790) with its rules
and English lobby text. The lobby prefers the installed language strings. The records also
hold the Dark Reign targeting delay, the Tag Bomb fuse and the three role bonuses. Both host
paths use these defaults. The original lobby reads the name, description and team help IDs at
offsets 0, 2 and 4 of each record. It clears the team option when byte 0x0C is zero
(0x0044CB30), as it is for Nuclear Threat and Vampires. The host keeps the live state of the match,
including who carries the bomb.

### Asteroid Field

Asteroid Field is the first entry in `dm_scenarios` (0x0050C790). Mission 85 creates thirty
rocks, eight spawn markers and nine random pickups. Its startup script gives two groups of
rocks their slow and medium spins, then calls `ResetToSpawnPositions`. The scenario table
provides no special scoring or round-end callback. OpenReliant uses the common arena score
and spawn rules, with a host snapshot of the rocks' orientation and visibility.

The pickup pass checks contact in pilot and object order and requires at least two pilots.
`mp_arena_prepare_pickups` (0x004B1760) builds cumulative odds from the ten weighted records
in `mp_powerup_rules` (0x0050C508). Each pilot holds one effect. Fuel, repair and
countermeasures take effect on contact, then show for two seconds. The cloak, temporary
invulnerability and the three control and shield penalties also take effect on contact.
Mines and Screamers wait for Launch Missile. The pickup reappears when the effect expires,
the pilot uses it, or the ship is destroyed or leaves.

The host applies those rules to its simulated ships. The client gets the map's pickup mask,
the active mine slots and its own power-up. Mine ownership follows the admission and ship
that placed it. Team play uses four colours and the scenario's stock team flag. The host copies
the lobby teams at launch (`mp_arena_init`, `0x004AE860`). A team kill counts as a death and awards
no ordinary frag. A team keeps its tally until its last pilot leaves (`mp_player_departed`,
`0x004B6890`). A pilot who joins an arena in progress gets the least populated team.

The Dark Reign tower skips the relay carrier's whole team on its next target choice
(`0x004B3ED3`). Picking up the relay also cancels an active shot at its new carrier
(`0x004B3F70`). The team panel orders occupied teams by most kills, then fewest deaths.
The target brackets and both panels use the same badge table at `0x0050C31C`.

### Six Beacons

Nuclear Threat is the second stock arena in `dm_scenarios` (0x0050C790). Its map has six
beacon pickups, six placement markers and a gate. The host selects the rules after loading
a map. Selection uses the object types, so another map can use the same rules.

Two admitted pilots are enough to start collecting. A ship picks up a beacon when the distance
between their centres is less than their combined radii (`pickup_frame`, 0x004B24A0).
If two ships reach it in the same tick, the first pilot in slot order gets it. An exploding
or respawning ship cannot collect. The pickup delay expires 100 ticks after the explosion ends.
A lone pilot who touches a beacon sees the waiting message (0x5B9).

The sixth pickup announces the carrier (0x2EB). The blast fires when that pilot comes within
2,500 units of a gate, including the boundary (0x004B19D2, 0x004B32C0). It starts at the
first gate's position and orientation, lasts 1,000 ticks and uses 22 percent of the arena
radius. The launch announces the pilot (0x300) and puts all six beacons back into play.
Clients draw the native Uber blast and shockwaves from the blast's start tick, centre and
size. Pilots joining during the blast see it at its current age. The host applies its
damage and awards the kills.

A pilot who dies or leaves drops their cargo beside their ship. The host keeps running the
round when the pilot's death camera finishes. Drops cycle through the six
world axes at 0.8 times the ship's radius. At reset, each beacon takes the first marker clear
of the other beacons. If every marker is occupied, it stays where it is. Every 50 ticks the
host checks for loose beacons less than 500 units inside the arena boundary or beyond it and places
them again. Every 25 ticks it checks that six objectives are accounted for.
Both checks run before collection and gate contact. The host keeps one record per beacon
for loose and carried states, so it can repair the map without reconciling separate clients'
carried counts.

**Improvement:** the host determines pickup, loss and gate contact from its simulated ships.
Each drawn arena frame captures the six pickups and their carriers. A viewer joining mid-round
can read each pilot's count from its first snapshot. The count belongs to the original ship
and admission, so a replacement in the same slot starts with its own count. See
[Six Beacons target count](hud.md#six-beacons-target-count).

Both host paths bind mission 82 from the installed game and run its script on the host. Its
`ResetToSpawnPositions` command (`0x004591B0`) selects the arena rules. The host builds each
admitted pilot's fighter and chooses a free spawn marker (`0x004AF1D0`). The first host pilot
starts at the first marker. Later spawns use the original collision margin of 1.2 times the
sum of the radii. The ship starts with half its afterburner fuel and empty missile racks.

The client loads the arena scenery and reads beacon positions and carriers from the host.
The shared HUD uses installed strings for collections, launches and blast kills, with English
fallbacks. Only the scorer sees the bonus on the kill line. A pilot joining during a pause
gets the frozen objective state, cockpit readings and last sampled pings. The cockpit clock
uses the same 101 ticks per displayed second as the host (`tick_timer`, 0x004827C0).

**Improvement:** a returning pilot uses a free marker if another ship occupies the preferred
one. When every marker is occupied, a destroyed pilot waits for space while the other pilots
continue flying. An unsuccessful new admission leaves the round's roles alone.

### Random arena power-ups

Random power-ups (type 0x8C) have three rotating rings. Six Beacons pickups (0x8E) and the
gate (0x8D) have none. Each ring is a 1400 by 1400 square with the additive texture
`dmpowerup128-2` (0x004B1D10). The rings share a centre halfway between the first two points
in the first model part's first point list. A replacement model can move the rings by moving
those points. A model without both points shows no rings. The three squares start in different
planes and turn 0.052 radians per mission tick. They follow the pickup when it moves and
disappear while it is disabled (0x004B18E0).

## Co-op recalls

The host runs the normal flight controls for 300 ticks while the recall line plays, then mixes
steering toward each affected pilot's launch carrier for 700 ticks (`order_friendly_fire`,
`0x00474F20`). The rest of the wing sees the ship leave. Carrier recall and crew abort show the
affected pilot the stock Reliant or Yamato landing on their own copy of the scene. Ordinary
friendly fire, including the script's `FriendlyFire` command, ends with the ship jumping away.
The host keeps running the shared mission without moving the carrier into the cutaway.

## Remaining work

The overall split is [#955](https://github.com/OpenReliant/openreliant/issues/955).

- [#1367](https://github.com/OpenReliant/openreliant/issues/1367): scanner, mission ending,
  participant outcomes and game mode rules for ship disposition and respawn.
- [#1368](https://github.com/OpenReliant/openreliant/issues/1368): wingman loss, target feedback,
  device notifications and the remaining local combat rules.
- [#55](https://github.com/OpenReliant/openreliant/issues/55) tracks the remaining stock multiplayer rules.

This state split does not add a network session or change mission files. Single player remains
one participant running the existing simulation and presentation paths.
