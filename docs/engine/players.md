# Players

OpenReliant keeps simulation-owned player state in `players.State`, alongside the objects in
`create.Objects.player_states`. Player roles use the first `Objects.players` slots, independently
of which player this machine displays (`Objects.player`). An ordinary object has no player state.

**Improvement:** each player has separate shield reserves. The simulation uses the struck player's
reserves for shots, missiles and knocks, and that player's reserves when recharging shields.
Balancing still moves the same amount in the same order. The drawing snapshot includes these
records, so the HUD and the scripts' ship status read the displayed player's reserves from the
same snapshot as the shields. The public script API is unchanged.

A player's state belongs to the participant slot, not to the physical ship's `ObjectRef`.
Replacing that ship leaves its reserves and control state intact. Starting a mission clears
reserves and pending commands, but preserves throttle, matching state and the afterburner toggle,
as the original leaves those local globals. Only the first `Objects.players` entries are active;
unused entries do not grant reserves to ordinary objects.

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

A host input source can submit a `players.Command` at the simulation boundary. Invalid axes are
rejected without replacing the previous input. The record retains held flight inputs while
consuming throttle presets, afterburner toggles, speed-match toggles and target requests once.
It takes precedence over local devices, including for slot zero on a headless host. Remote
participants without commands never read this machine's devices. Existing non-player Player
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

## Remaining work

The overall split is [#955](https://github.com/OpenReliant/openreliant/issues/955).

- [#1370](https://github.com/OpenReliant/openreliant/issues/1370): weapon commands and per-player
  missile selection and lock state. The existing local weapon path still uses the local display.
- [#1367](https://github.com/OpenReliant/openreliant/issues/1367): scanner, mission ending and
  participant lifecycle, including joining and leaving.
- [#1368](https://github.com/OpenReliant/openreliant/issues/1368): effects addressed to the player
  they concern, local-player damage scaling, and local-only damage paths such as shockwaves.
  Shockwaves still strike only the displayed player, using that player's reserves with the
  existing damage arithmetic.

This state split does not add a network session or change mission files. Single player remains
one participant running the existing simulation and presentation paths.
