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

## Comparison with the original

| State or operation | Original | OpenReliant |
| --- | --- | --- |
| Player roles | `player_slots` (`0x0058832C`) counts slots from the first | `Objects.players` keeps this convention |
| Local player | `player_index` (`0x005883FA`) selects the local ship | `Objects.player` selects the displayed player |
| Shield balance | `shield_balance` (`0x00412D40`) uses the local ship and two globals, fore at `0x0051CF78` and aft at `0x0051CF34` | Separate reserves in each player's simulation state |
| Shield recharge | `object_recharge_shields` (`0x00476FC0`) runs for all objects, but applies the reserve globals only to the local ship | Each player's recharge uses their own reserves; ordinary ships recharge without reserves |
| Flight controls | `player_controls` (`0x00413410`) reads local devices and control globals | Local input produces flight commands; each participant has separate control state |
| Remote control order | `order_multiplayer_control` (`0x00414F70`) sets `disabled` when `sent_off` is set | Keeps that check, then applies the participant's commands without reading local devices |
| Kills and deaths | `kills_add` (`0x004B14F0`) and `deaths_add` (`0x004B1580`) update local globals and per-slot counters at `0x005DB684` and `0x005DB688`, with a `0x3C` stride | Participant mission state and lifecycle follow in [#1367](https://github.com/OpenReliant/openreliant/issues/1367) |

`simulation_step` (`0x004774D0`) reads devices every fourth tick and updates every object's nodes,
shields and guns. It runs an extra Player Control update for the local ship before movement.
The remote control order does not repeat the local control routine. Reading the local devices
once for each connected ship would give them all the same controls.

The original remains the comparison for gameplay rules and timing. Host authority requires
simulation state and commands for each participant, rather than treating remote reported ship
state as authoritative ([#954](https://github.com/OpenReliant/openreliant/issues/954)).

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

Leaving ends the admission, clears held controls and leaves ship disposition to the game mode.
A later occupant gets a different participant identity even if the game mode assigns the same
ship. Session authentication, ordering and disconnect detection belong to
[#954](https://github.com/OpenReliant/openreliant/issues/954).

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

## Remaining work

The overall split is [#955](https://github.com/OpenReliant/openreliant/issues/955).

- [#1367](https://github.com/OpenReliant/openreliant/issues/1367): scanner, mission ending,
  participant tallies and game mode rules for ship disposition and respawn.
- [#1368](https://github.com/OpenReliant/openreliant/issues/1368): effects addressed to the player
  they concern, including device beeps and warnings, local-player damage scaling, and local-only damage paths such as shockwaves.
  Shockwaves still strike only the displayed player, using that player's reserves with the
  existing damage arithmetic.

This state split does not add a network session or change mission files. Single player remains
one participant running the existing simulation and presentation paths.
