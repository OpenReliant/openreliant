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
Replacing that ship leaves the reserves intact, as the original leaves its local globals. Starting
a mission clears the records. Only the first `Objects.players` entries are active; unused entries
do not grant reserves to ordinary objects.

## Comparison with the original

| State or operation | Original | OpenReliant |
| --- | --- | --- |
| Player roles | `player_slots` (`0x0058832C`) counts slots from the first | `Objects.players` keeps this convention |
| Local player | `player_index` (`0x005883FA`) selects the local ship | `Objects.player` selects the displayed player |
| Shield balance | `shield_balance` (`0x00412D40`) uses the local ship and two globals, fore at `0x0051CF78` and aft at `0x0051CF34` | Separate reserves in each player's simulation state |
| Shield recharge | `object_recharge_shields` (`0x00476FC0`) runs for all objects, but applies the reserve globals only to the local ship | Each player's recharge uses their own reserves; ordinary ships recharge without reserves |
| Flight controls | `player_controls` (`0x00413410`) reads local devices and control globals | The local input path remains until [#1366](https://github.com/OpenReliant/openreliant/issues/1366) |
| Remote control order | `order_multiplayer_control` (`0x00414F70`) sets `disabled` when `sent_off` is set | This does not supply an authoritative remote control path |
| Kills and deaths | `kills_add` (`0x004B14F0`) and `deaths_add` (`0x004B1580`) update local globals and per-slot counters at `0x005DB684` and `0x005DB688`, with a `0x3C` stride | Participant mission state and lifecycle follow in [#1367](https://github.com/OpenReliant/openreliant/issues/1367) |

`simulation_step` (`0x004774D0`) reads devices every fourth tick and updates every object's nodes,
shields and guns. It runs an extra Player Control update for the local ship before movement.
The remote control order does not repeat the local control routine. Reading the local devices
once for each connected ship would give them all the same controls.

The original remains the comparison for gameplay rules and timing. Host authority requires
simulation state and commands for each participant, rather than treating remote reported ship
state as authoritative ([#954](https://github.com/OpenReliant/openreliant/issues/954)).

## Remaining work

The overall split is [#955](https://github.com/OpenReliant/openreliant/issues/955).

- [#1366](https://github.com/OpenReliant/openreliant/issues/1366): per-player control state and
  targets, fed by normalised commands rather than local devices for remote ships.
- [#1367](https://github.com/OpenReliant/openreliant/issues/1367): scanner, mission ending and
  participant lifecycle, including joining and leaving.
- [#1368](https://github.com/OpenReliant/openreliant/issues/1368): effects addressed to the player
  they concern, local-player damage scaling, and local-only damage paths such as shockwaves. Shockwaves still strike only the
  displayed player, using that player's reserves with the existing damage arithmetic.

This state split does not add a network session or change mission files. Single player remains
one participant running the existing simulation and presentation paths.
