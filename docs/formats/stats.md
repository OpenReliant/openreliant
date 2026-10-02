# Stat tables

`shipstats.bin`, `gunstats.bin`, `missilestats.bin` and `pilotstats.bin` define every ship, gun,
missile and pilot. The game ships two identical copies of each: one in `LANCER.CAB` and one in
`resource.hog`.

```
sltool stats list <file>
```

lists a table's records with their field names, and marks the records the engine never loads.

## Frame

Each file is an array of **352-byte (`0x160`) records** with no header. All four use the same
frame: a 64-byte name padded with NULs, followed by the table's fields.

Mod scripts can read and change these records ([Scripts](../guide/modding.md#scripts)). The tables
below list each field's name in scripts; the record name is `name`.

| File | Records | Fields end at |
|---|---|---|
| `shipstats.bin` | 256 | `0x7C` |
| `gunstats.bin` | 15 | `0x58` |
| `missilestats.bin` | 16 | `0x64` |
| `pilotstats.bin` | 124 | `0x5C` |

Each table has its own loader in the payload executable. It reads one record at a time into a
buffer on the stack and copies the fields it needs into a runtime table. **No loader reads the name,
or anything after the table's last field**, and in the shipped files those bytes are zero in every
record.

| Table | Loader | Records read | Runtime tables |
|---|---|---|---|
| Ships | `stats_load_ships` (`0x00466500`) | Exactly 256 | `ship_flight_stats` (`0x4F9E70`) and `ship_combat_stats` (`0x4FC670`), `0x28` and `0x30` bytes per ship |
| Guns | `stats_load_guns` (`0x004788F0`) | Until the end of the file | `gun_stats` (`0x500CA4`), 16 entries of `0x2C` bytes |
| Missiles | `stats_load_missiles` (`0x00494BC0`) | **At most 11** | `missile_flight_stats` (`0x5035E8`) and `missile_stats` (`0x5037A8`), `0x28` bytes per missile in each |
| Pilots | `stats_load_pilots` (`0x0049CAE0`) | Until the end of the file | `pilot_stats` (`0x58A968`), 194 entries of `0x24` bytes |

Ships and missiles use the same runtime layout for their flight model: an object points to its
flight model at `+0x14`, whether it's a ship or a missile. The flight model holds the max speed, the
roll, pitch and yaw rates, the four inertias, and the max speed divided by the pitch rate, which the
ship loader computes after reading the file. A missile's flight model only has its speed and rates.
The word at `+0x24` doesn't come from any file: the executable has a value for each ship type and
missile, which sets how the AI turns the ship ([Steering](../engine/orders.md#steering)). The
runtime layouts, with the source of every field, are in the modules of the files that load them:
[`create.zig`](../../src/engine/game/create.zig), [`guns.zig`](../../src/engine/game/guns.zig),
[`missiles.zig`](../../src/engine/game/missiles.zig) and
[`pilots.zig`](../../src/engine/game/pilots.zig).

The gun and pilot loaders have no limit: a file with more records than the runtime table has
entries writes past its end. The missile loader stops after 11, so the last five of the 16
missiles, Blazer, Iron Tooth, Death Claw, Brute and Hell Fire, are never read. They are all zero,
and so is the eleventh, Stalker.

## Where the names come from

The loadout screen labels ship and missile stats with strings from `LANGUAGE.DLL`. For ships, a
layout table of eight 8-byte rows at `0x4EC020` gives each row on the screen a string ID and a
display kind (a ten-segment bar or a number), and row `r` shows the ship's `r`th loadout value. The
code that fills in those values shows which field is behind each label. Names marked **Screen** come
from there.

Names marked **Mods** come from
[Starlancer-OSS `stats-format.md`](https://github.com/LordBlacksun/Starlancer-OSS/blob/main/docs/stats-format.md),
which found the fields by comparing known mods with the original files.

## Ships

| Offset | Field | Script name | Loaded as | Evidence |
|---|---|---|---|---|
| `0x40` | Max speed | `max_speed` | float | Screen: **Max Speed** bar |
| `0x44` | Inertia | `inertia` | float | Screen: **Acceleration** bar. Mods: Inertia |
| `0x48` | Yaw rate | `yaw_rate` | float | Screen: **Agility** bar. Mods: YawMax |
| `0x4C` | Yaw inertia | `yaw_inertia` | float | Mods |
| `0x50` | Pitch rate | `pitch_rate` | float | Mods |
| `0x54` | Pitch inertia | `pitch_inertia` | float | Mods |
| `0x58` | Roll rate | `roll_rate` | float | Mods |
| `0x5C` | Roll inertia | `roll_inertia` | float | Mods |
| `0x60` | Shield power | `shield_power` | truncated | Screen: **Shield Power** bar |
| `0x64` | Armor class | `armor_class` | truncated | Screen: **Armor Class** bar |
| `0x68` | Afterburner fuel | `afterburner_fuel` | truncated | Screen: **Afterburner Fuel**, a number labelled ` SECS` |
| `0x6C` | Shield recharge | `shield_recharge` | float; 0 becomes 10 | Screen: **Shield Recharge** bar |
| `0x70` | Gun energy | `gun_energy` | float | The guns' maximum charge: `create_object` gives a new ship this much (`GameObject.gun_charge`), the guns recharge up to it, and the display's right arc shows the charge against it. Mods: GunEnergy |
| `0x74` | Gun recharge | `gun_recharge` | float | The seconds the guns take to charge fully (`guns_step`). Mods: GunRecharge |
| `0x78` | Rounds | `rounds` | truncated | The rounds a new ship's guns have. Each shot from a gun that fires rounds uses one (`guns_step`). Mods: Ammo |

"Truncated" means the loader converts the float to an integer with `_ftol`.

The loader copies `0x40` to `0x5C` into the ship's flight model in the order speed, `0x58`, `0x50`,
`0x48`, `0x44`, `0x5C`, `0x54`, `0x4C`: the three rates, then the four inertias, matching the pairs
the mod comparisons found. It also computes `0x40 / 0x50` for each ship.

The loadout screen shows each stat as a bar scaled between the minimum and maximum of that stat
across the ships it lists: the Alliance fighters the player can fly, and in a second list Coalition
fighters ([Loadout](../engine/loadout.md#the-figures)).

## Guns

| Offset | Field | Script name | Loaded as | Into | Evidence |
|---|---|---|---|---|---|
| `0x40` | Range | `range` | truncated | `+0x14` | How many ticks a shot lasts, which sets the gun's range. Mods |
| `0x44` | Speed | `speed` | float | `+0x18` | How fast a shot flies (`bullet_place`) |
| `0x48` | Shield damage | `damage.shield` | float | `+0x1C` | The damage a hit does to a shield (`object_damage`). Also used by the threat check below. Mods: DamageMin |
| `0x4C` | Hull damage | `damage.hull` | float | `+0x20` | The damage a hit does to a hull or a component. Damage that gets through a shield is scaled by this over the shield damage. Mods: DamageMax |
| `0x50` | Fire rate | `fire_rate` | `100 / x`, truncated | `+0x24` | The ticks between shots. Mods: CyclicRate |
| `0x54` | Shot energy | `shot_energy` | truncated | `+0x28` | The energy a shot takes from the guns' charge (`guns_step`). Zero for every gun that fires rounds. Mods: energy or heat per shot |

The loader stores `100 / fire_rate`, the interval between shots.

`gun_stats` is indexed by the gun type in a model's muzzle, from 1 to 15, so the file's first record
is type 1, and type 0 means no gun. The loader only fills `+0x14` to `+0x28` of each record. The
first five words come from the executable, and say what a shot costs the ship (energy for types 1
to 7, a round for the rest) and which sound it makes. OpenReliant's copy of those words is in
[`guns/stats.zig`](../../src/engine/game/guns/stats.zig), which `make gun-tables` generates from the
executable.

The two damage values are **not a minimum and a maximum**: in several guns the shield damage is
larger. `player_spectral_shields_set` (`0x00415430`) only uses the shield damage: when the spectral
shields are turned on, it counts each gun type among the nearby hostile ships, weights each count
by that damage, and tunes the shields to the most dangerous type, ignoring the two capital ship
guns.

## Missiles

| Offset | Field | Script name | Loaded as | Evidence |
|---|---|---|---|---|
| `0x40` | Speed | `speed` | float | Screen: **Speed** bar. Mods: MaxVelocity |
| `0x44` | Turn rate | `turn_rate` | float | Copied into all three rates of the missile's flight model |
| `0x48` | Flight time | `flight_time` | `x * 100`, truncated | Screen: **Range** is `speed * flight_time`. Mods: Range |
| `0x4C` | Shield damage | `damage.shield` | float | Screen: **Damage** is `0x4C + 0x50`. The damage a hit does to a shield (`missile_collide`) |
| `0x50` | Hull damage | `damage.hull` | float | Screen. The damage a hit does to a hull |
| `0x54` | Lock time | `lock_time` | truncated | Screen: **Locking Time** is `0x54 * 0.01`, labelled ` SECS` |
| `0x58` | Decoy chance | `decoy_chance` | truncated | In percent: the chance that a countermeasure decoys the missile (`object_spend_countermeasure`) |
| `0x5C` | Lock range | `lock_range` | float | The distance at which the missile can lock on to a target, for the player, the AI and missile turrets |
| `0x60` | Component damage | `component_damage` | float | The damage a hit does to a component, on ships that have components |

`0x48` is the flight time, not the range: the loadout screen computes the range as speed times
flight time. `0x54` is in hundredths of a second.

The screen hides the locking time for Screamer and Solomon, always shows Jack Hammer's damage bar as
full, and hides Stalker's speed, range and damage.

## Pilots

The record index is the pilot ID that missions use. The loader fills all 194 runtime slots with
defaults, then applies each record it reads. Three fields are **tier selectors**: 0, 1 or 2 selects
one of three presets for a group of runtime values, and any other value keeps the default. The four
32-bit words after them are copied with 16-bit moves, so only their low halves are used, and the
high halves are never read. The shipped data uses tiers 1 and 2.

| Offset | Field | Script name | Effect |
|---|---|---|---|
| `0x40` | Tier A | `tier_a` | Six 16-bit values |
| `0x44` | Tier B | `tier_b` | One float |
| `0x48` | Tier C | `tier_c` | Two floats and a 16-bit value |
| `0x4C` | Skill | `skill` | 0 low, 1 medium, 2 high, used by the Fight order's maneuvers ([Maneuvers](../engine/maneuvers.md)). Other values match none of the three |
| `0x50` | Copied | Not available | The pilot answers the radio's What's your status? only if this is above 0. **Unknown:** what else it does |
| `0x54` | Copied | Not available | **Unknown:** what it does |
| `0x58` | Copied | Not available | The radio checks it without any effect. **Unknown:** what it does |

In scripts, the tiers are `"level_0"`, `"level_1"` or `"level_2"` (or a number), and the skill is
`"low"`, `"medium"` or `"high"` (or a number).

| Tier | A | B | C |
|---|---|---|---|
| 0 | 10, 40, 800, 1600, 400, 800 | 5.0 | 0.6, 0.4, 100 |
| 1 | 30, 50, 400, 800, 300, 600 | 3.0 | 0.8, 0.2, 50 |
| 2 | 100, 100, 200, 400, 200, 400 | 1.5 | 1.0, 0.0, 25 |
| Default | 30, 50, 400, 800, 200, 400 | 3.0 | 0.8, 0.2, 50 |

The loader applies B, then A, then C; tier 2 of C also sets the last two values of A, to 50 and 100.

**Unknown:** what the runtime values do. Each group changes monotonically from tier 0 to tier 2.

## Prior art

The record frame, the counts and the names marked **Mods** are from
[Starlancer-OSS `stats-format.md`](https://github.com/LordBlacksun/Starlancer-OSS/blob/main/docs/stats-format.md),
which builds on Userunfriendly's hexcheat mod pack. It treats the bytes after each table's fields as
an undecoded tail; they are never read and always zero.
