# Battlestar Galactica

Battlestar Galactica (2003) is an Xbox and PlayStation 2 game by Warthog, who developed
StarLancer. Its game logic is StarLancer's, carried forward: its missions keep StarLancer's records
and script bytecode, its command catalogue and trigger conditions extend StarLancer's, and its
stats, combat maneuvers and comms films come from StarLancer's. Its archives, models and executable
are new. [#1017](https://github.com/OpenReliant/openreliant/issues/1017) tracks what it shares
with StarLancer.

```bash
sltool cd extract <image> <dir>                 # the disc's files
sltool bsg sections <mission.dte>               # a mission's directory
sltool bsg parts <mission.dte>                  # its script's routines
sltool bsg triggers <mission.dte>               # its triggers
sltool bsg script <mission.dte> <default.xbe>   # its script, with the commands' names
sltool bsg commands <default.xbe>               # the command catalogue
sltool bsg films <video.idx> <videodata.dat>    # the comms films
sltool bsg film <video.idx> <videodata.dat> <number|all> <dir>   # their frames, as PNG files
sltool bsg ls <archive.hxb>                     # an archive's files
sltool bsg extract <archive.hxb> <dir>          # every file of it, unpacked and checked
```

The code is in [`src/formats/games/bsg/`](../../src/formats/games/bsg), and the Xbox's own formats
are in [`src/formats/xbox/`](../../src/formats/xbox). This page describes the European Xbox
disc.

## The disc

The disc holds an Xbox volume ([Xbox formats](../formats/xbox.md#discs)):

| Path | Contents |
|---|---|
| `default.xbe` | The executable. |
| `Missions\*.dte` | The missions ([Missions](#missions)). |
| `Missions\<language>\*.loc` | The missions' text in each language: the subtitles, one line each. |
| `ship.txt`, `bullet.txt`, `missile.txt`, `pilot.txt` | The stats ([Stats](#stats)). |
| `evade.txt` | The combat maneuvers' weights ([Combat maneuvers](#combat-maneuvers)). |
| `vqmdata.txt`, `movies.txt` | Lists of the comms films ([Comms films](#comms-films)). |
| `comms\video.idx`, `comms\videodata.dat` | The comms films. |
| `comms\audio.idx`, `comms\audiodata.dat` | The comms' sound, going by the names. **Unknown:** its format. |
| `bigwad.hxb`, `gui.hxb`, `sfx.hxb`, `extra.hxb`, `wads\*.hxb` | The archives ([Archives](#archives)). |
| `Movies\` | The movies, as Xbox XMV files. |
| `fonts\` | Fonts, as TGA pictures with `.tnf` files. |

The executable ([Xbox formats](../formats/xbox.md#executables)) is stripped: it holds no source
paths or assertions, but holds the command catalogue with the developers' descriptions, the trigger
conditions' names, and `$Revision: N $` strings of their version control. It draws with the Xbox's
Direct3D.

## Missions

A mission keeps StarLancer's `.DTE` extension and its records, behind a new directory:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `0xDEADDEAD` |
| 4 | 120 | 15 entries of 8 bytes |
| `0x7C` | 4 | Zero |

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | The section's offset in the file |
| 4 | 2 | Its count of records |
| 6 | 1 | Zero |
| 7 | 1 | The size of a record |

StarLancer's directory has 27 fixed entries of a count, a zero byte, flags and an offset
([`.DTE` missions](../formats/dte.md#directory)). In every mission, the first section starts at
`0x80`, a section fills its count times its record size, and 16 bytes of `0xCD`, the debug fill of
Microsoft's C runtime, follow each section.

| Entry | Record size | Contents | StarLancer's section |
|---|---|---|---|
| 0 | `0x50` | The ships: StarLancer's `0x4C`-byte records and 4 bytes more. Every field up to `formation_point` at `0x34` matches StarLancer's. **Unverified:** the rest. | `ships` (3) |
| 1 | `0x14` | The flight groups: each starts with a flight group's object ID. | `flight_groups` (4) |
| 2 | `0x10` | The squads: each starts with a squad's object ID, in 16 bytes where StarLancer's take 12. | `squads` (12) |
| 3 | `0x0C` | The squad members: an object ID at `+0` and a squad's index at `+4`. | `squad_members` (13) |
| 4 | 8 | The objects. | `objects` (7) |
| 5 | 4 | A record for each object. **Unknown:** what it holds. | |
| 6 | `0x44` | The curves, in StarLancer's layout. | `curves` (16) |
| 7 | `0x0C` | **Unverified:** the globals. No script uses a global past their count. | `globals` (2) |
| 8 | `0x1C` | The parts. | `parts` (8) |
| 9 | `0x30` | The triggers. | `triggers` (5) |
| 10 | 2 | The script, counted in halfwords. | `script` (6) |
| 11 | 2 | The command flags, one for each of the 161 commands. | `command_flags` (24) |
| 12 | 2 | Empty in every mission. **Unknown.** | |
| 13 | 4 | **Unknown:** floats, such as 1.0. | |
| 14 | | Unused in every mission. | |

The missions carry no string pool. The ships, flight groups and parts keep their names' offsets,
but the names aren't in the file. **Unknown:** where they went. The executable names `BIGDTE.HXB`
and `MISSION1_1.DTE`, which the disc doesn't hold.

The script has StarLancer's bytecode ([Script VM](../engine/script-vm.md)), with the subtitles
and the comms films' names inline, as `push_string` runs. Given a directory in StarLancer's layout
that points at these sections, StarLancer's mission reader reads the missions' parts, triggers and
routines. One trigger, for example, plays the comms film `AD_01_06.wmv` with its line, waits three
seconds and ends the mission. `sltool bsg` reads them that way, and names the commands from the
catalogue in the game's executable. **Unknown:** two routines reach a `0x55` followed by a byte
that isn't a StarLancer opcode, so the game may have changed `0x55` or added an instruction.

## Commands

The executable holds the Executor's command catalogue at the address `0x0015D968`, in
StarLancer's layout:
`0x74`-byte entries of the implementation, the parameter count, the name, eight parameters of
kinds, a second word and a label, then the description and a flag
([Script VM](../engine/script-vm.md)). It has 161 commands where StarLancer has 95.

68 of StarLancer's commands keep their numbers, such as `CreateTimer` (`0x01`), `SetAI`
(`0x0B`), `StartDirectorCam` (`0x10`), `ShipFollowCurve` (`0x12`), `Dock` (`0x26`), `Fly` (`0x28`)
and `TerminateMission` (`0x4D`). Some take other arguments: `TerminateMission` takes whether the
mission succeeded, and `StartShipAnimation` whether the animation plays once, looped or backward.
These numbers hold other commands:

| Number | StarLancer's | Battlestar Galactica's |
|---|---|---|
| `0x0D` | `SetPatrolRoute` | `DestroyAllTimers` |
| `0x0E` | `SetPilot` | `StartDeathCam` |
| `0x15` | `DisplaySubTitle` | `HugeExplosion` |
| `0x1D` | `PositionRelative` | `FullStop` |
| `0x1F` | `StartMissileCam` | `FlashTurretGraphic` |
| `0x20` | `StartChaseCam` | `SetShipNameID` |
| `0x27` | `DisableTaunts` | `BreakDCam` |
| `0x2B` | `DisableLights` | `EnableFXLightning` |
| `0x2C` | `SetEnvironmentFX` | `DebugBreak` |
| `0x2D` | `MultiPlayerSync` | `FireNeutronCannon` |
| `0x32` | `ResetAfterBurners` | `SetRadarVisibility` |
| `0x35` | `DisableEject` | `ReduceHealth` |
| `0x36` | `SetHostile` | `SetMatchTarget` |
| `0x37` | `ResetToSpawnPositions` | `RandomWithExclude` |
| `0x38` | `UpdateEnvironmentFXState` | `SetAmbientLighting` |
| `0x3C` | `SetEnvironmentFXNebula` | `SetEnvironmentFXSkybox` |
| `0x3D` | `StartShipAnimationReverse` | `SetSpaceRocks` |
| `0x3F` | `PlayFostersLastStand` | `SetHealth` |
| `0x43` | `SetObjective` | `SetObjectiveState` |
| `0x44` | `SetRescueProbabilities` | `SetNebulaGas` |
| `0x45` | `IsShipThisPlayer` | `EjectSubobjectUltra` |
| `0x51` | `KillAllScriptExecutionExecptMe` | `KillAllScriptExecutionExceptMe`, the same command with its name corrected |
| `0x53` | `Scanner` | `DisableEngineTrails` |
| `0x56` | `MultiplayerScriptSync` | `TumbleUnderGravity` |
| `0x59` | `ReplenishWeapons` | `DisableAllTriggers` |
| `0x5A` | `WillsBlag` | `CreateAsteroidField` |
| `0x5E` | `DarrensNaughtyBlag` | `SetFlameTrail` |

The commands after StarLancer's run from `0x5F` to `0xA0`, in this order: `SetPlayerBombs`,
`IgnoreForCollision`, the tutorial's waits from `WaitForDecreaseVelocity` to `WaitForStrafeRight`
(`0x61` to `0x6B`), `PointAt`, `WaitForFirePrimaryMissiles`, `WaitForFireSecondaryMissiles`,
`WaitForPlayerSelectPrevTarget`, `WaitForPlayerSelectNextTarget`, `RememberThisCodeFrame`,
`KillRememberedCodeFrame`, the controls' switches from `DisableAfterburners` to `DisableTargeting`
(`0x73` to `0x78`), `FireMissileFromPort`, `ShowTip`, `DisableSpecialMoves`, `WaitMS` (`0x7C`),
`SetCameraZoom`, `ClearCameraZoom`, `SetDirectionalLighting`, `SetPlayCentre`, `AddObjective`,
`DeleteObjective`, `ShowObjectives`, `SetDataTag`, `SetShipName`, `StartVisibleCountdown`,
`DriftToTarget`, `CreateFomation`, `DestroyFormation`, `RemoveDataTag`, `PopAI`, `EjectSubobject`,
`TriggerExplosion`, `ShakeCamera`, `FireMissile`, `Magnetise`, `AddObjectiveTextID`,
`MarauderBombingRun`, `AlignFomation`, `RemoveShip`, `CreateIceAsteroidField`, `SetSafePerimeter`,
`EjectSubobjectUnderGravity`, `AttackMassiveObject`, `ShowObjectiveNum`,
`ShipFollowCurveAggressive`, `SetFormationTarget`, `SetSingleShipAvoidance`, `Random`,
`PrintDebugMessageNumeric`, `Set Formation Break` and `is SubObjectDead` (`0xA0`).

## Trigger conditions

The executable names StarLancer's 35 conditions, with the Ripper's two renamed
`TroopshipGrabbedObject` and `TroopshipDroppedObject`, and the console's buttons still among them,
such as `Player_L1_DoubleTap`. It names new ones too: `JumpedOut`, `ShotAtMissile`,
`Troopship Repelled`, `Collision`, `Docked With (Amasser)`, `Launched From (Amasser)`,
`Roll Match Lost` and `Roll Match Lost Inner`. The missions' triggers use StarLancer's numbers for
StarLancer's conditions, and numbers from 35 for new ones. **Unverified:** which new name has which
number. `sltool bsg triggers` shows the conditions by StarLancer's names, so the Troopship's show as
the Ripper's, and new ones by number.

## Stats

The stats are text files rather than StarLancer's binary tables
([Stat tables](../formats/stats.md)). A record starts with a line that names it, then has a line
for each field: a name and a colon, then its values.

| File | A record starts with | Fields |
|---|---|---|
| `ship.txt` | `SHIP: <type> INDEX: <n>`, such as `SHIP: SHV1VI00 INDEX: 0` | StarLancer's flight model, `MAXSPEED`, `MAXROLL`, `MAXPITCH`, `MAXYAW` and the four inertias from `SPEEDINERTIA` to `YAWINERTIA`, then `AFTERBURNERMULTIPLIER`, `REVERSETHRUSTMULTIPLIER`, `ACCELERATION`, `DECELERATION`, `TURNACCELERATION`, `TURNDECELERATION`, `ARMOURSTRENGTH`, `BLASTRADIUS`, `BLASTLIFE` and `BLASTDAMAGE`. Each has two values. **Unknown:** what the second is. |
| `bullet.txt` | The gun's name, such as `COL_LASERMK1` | `LIFE`, `SPEED`, `DAMAGE` and `FIRERATE`, as StarLancer's range, speed, damage and fire rate, then `BLASTRADIUS` and `BLASTLIFE`. |
| `missile.txt` | The missile's name, such as `COL_DUMBMK1` | A ship's flight model, inertias included, then `LIFE`, `DAMAGE`, `BLASTRADIUS` and `BLASTLIFE`. StarLancer's missiles share the ships' flight model at run time, but its file gives them a speed and a turn rate alone. |
| `pilot.txt` | `PILOT_<name>` | `FLYINGSKILL`, `FLYINGACCURACY`, `FLYINGREACTIONTIME`, `GUNNERYSKILL`, `GUNNERYFIREAMOUNT`, `GUNNERYFIREDELAY`, the least and most delays between missiles and between chaff, `COURAGE`, `VERBOSITY` and `AGGRESSION`. |

## Combat maneuvers

`evade.txt` weighs the combat maneuvers ([Maneuvers](../engine/maneuvers.md)) for each of a set of
ships, starting `SHIP: <type>`, at three ranges, `NEAR:`, `MEDIUM:` and `FAR:`. Each line names a
maneuver and gives four weights. **Unknown:** what each of the four is for.

The first ten maneuvers are StarLancer's ten, in StarLancer's order: `AIDEFEND_DODGE1` to
`AIDEFEND_DODGE3`, `AIDEFEND_OUTOFACTIONSPHERE`, `AIDEFEND_RUNAWAY`, `AIATTACK_PURSUE`,
`AIATTACK_MASSIVEOBJECT`, `AIATTACK_MEDIUMFIGHTER`, `AIDEFEND_LOOPTHELOOP` and `AIDEFEND_RUNTOSHIP`.
Nine are new: `AIDEFEND_MAINTAINFORWARDVECTOR`, `AIDEFEND_PEELAWAYLEFTRIGHT`,
`AIDEFEND_PEELAWAYUPDOWN`, `AIDEFEND_JINK`, `AIDEFEND_REVERSEANDFLIP`, `AIDEFEND_STRAFE`,
`AIDEFEND_ROLL_ATTACK`, `AIDEFEND_VIPER_BRAKE` and `AIDEFEND_SLIDER`.

## Comms films

The faces in the comms are StarLancer's face films ([Face films](../formats/fm8.md)).
`comms\videodata.dat` holds the films back to back, and `comms\video.idx` gives their count, a word
of 256 (**Unknown**), then each film's offset. A film is a 12-byte header, then chunks:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `VQ03` |
| 4 | 4 | The frames' size: two 16-bit values, 128 and 128 |
| 8 | 4 | One more than the film's frames, in every film |

The chunks are StarLancer's `fYEK` key frames and `fLED` delta frames, with the same key frame
header, but without StarLancer's XOR scrambling. No `fDNE` chunk ends a film. `sltool bsg film`
decodes them with StarLancer's face film decoder.

`vqmdata.txt` and `movies.txt` list comms films by name, such as `AD_01_01`, each with a `-` and a
number from 0 to 2, separated by tabs. **Unknown:** what the number is.

## Archives

The `.hxb` files are Warthog's own archive, `WART3.00`: a header, a table of entries, the members
back to back, and the members' names at the end. All numbers are little-endian.

| Offset | Size | Field |
|---|---|---|
| 0 | 8 | `WART3.00` |
| 8 | 4 | The count of entries |
| 12 | 4 | Where the names start, which is also where the members end |
| 16 | 4 | The names' length |
| 20 | | The entries, 20 bytes each |

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | Where the member starts in the archive |
| 4 | 4 | The bytes it takes, or 0 for a member stored as it is |
| 8 | 4 | Its size once unpacked |
| 12 | 4 | Its checksum |
| 16 | 4 | Where its name starts in the names |

The members start right after the entries, in the entries' order, with nothing between them. A
member stored as it is takes its unpacked size. More than half the sounds are stored that way,
and a few textures. Every other member is compressed with RefPack ([RefPack compression](../formats/refpack.md)),
in chunks of 128 KiB of unpacked data, the last chunk holding what is left. Each chunk is a 4-byte
length, then a stream of RefPack commands of that length, without the header that StarLancer's
streams start with. Each chunk's stream unpacks on its own.

The checksum is the CRC-32 of the unpacked member, without the final inversion that the usual
CRC-32 (zlib's) applies: zlib's CRC-32 of the member XOR `0xFFFFFFFF`.

The names are relative paths with forward slashes, such as `models/shv1vi00/shv1vi00.mdl`, each
ending in a zero byte. An archive can hold the same file more than once, each copy with its own
entry but sharing one name. `bigwad.hxb` holds some of the Galactica's textures up to twelve times, each
copy near a model that uses it, which suggests the archive is laid out for reading a model's files
in one pass from the disc.

`sltool bsg ls` lists an archive, and `sltool bsg extract` unpacks every file of it, checking each
checksum and writing a repeated file once. The code is in
[`src/formats/games/bsg/wart.zig`](../../src/formats/games/bsg/wart.zig).

| Archive | Holds |
|---|---|
| `bigwad.hxb` | The models (`models/<model>/`), their textures (`models/textures/`) and the objects' definitions (`levels/`). |
| `wads\<mission>.hxb` | What a mission loads: its models, textures and definitions, its music (`music/`), its sounds (`audio/`) and the in-game menus' pictures (`gui/backend/`). |
| `gui.hxb` | The menus' pictures (`gui/frontend/`, `gui/backend/`) and their text in each language (`gui/lang/<language>.loc`). |
| `sfx.hxb` | The sound effects (`sfx/`) and short pieces of music (`music/`). |
| `extra.hxb` | The fonts, the effects' sprites and pictures, and the particle effects' definitions (`levels/`). |

### The files

| Kind | Format | Holds |
|---|---|---|
| `.lvl` | Text | An object's definition ([Object definitions](#object-definitions)), or a particle effect's. |
| `.mdl` | Text | A model's parts ([Models](#models)). |
| `.bmsh` | Binary | A part's mesh. |
| `.banr` | Binary | **Unknown.** It comes with some meshes, under the same name. |
| `.btga` | Binary | A texture. |
| `.bwav` | Binary | A sound. |
| `.bxm` | Binary | A piece of music. |
| `.set` | Text | Lists of numbers, beside each mission's music and in `sfx/coll.set`. **Unknown:** what they set. |
| `.tnf` | Binary | A font's table, 2050 bytes, with its picture as a `.btga` of the same name. **Unknown:** its layout. |
| `.loc` | Text | The menus' text in one language. |

The binary kinds but the fonts start with a Unix time, from 2002 to 2004, which looks like when
the file was written. **Unknown:** the rest of their header. A mesh holds a texture's name, such as
`sh_v1_viper01.tga`, its vertices' positions and normals as floats, and its triangles as 16-bit
indices, among what look like addresses in the Xbox's memory.

### Object definitions

A `.lvl` file in `levels/` defines an object that a mission can place: a ship, a station or a
piece of scenery, by the name its model has, such as `levels/shv1vi00.lvl` for the Viper
(`SHV1VI00`, the name `ship.txt` uses too). It is a block of attributes:

```text
level
{
    name({SHV1VI00})
    acount(99)
    pcount(0)
    scount(0)
    tcount(0)
    ocount(0)
    attribute({ObjectType}, const, number,1)
    attribute({MeshName}, const, string,{SHV1VI00})
    attribute({MaxSpeed}, const, number,300)
    attribute({Gun1}, const, vector,-163,-107.000008,116.999992,0)
    ...
}
```

`acount` is the count of attributes. Each attribute has a name, `const` or `amend`, a type
(`number`, `string` or `vector`) and its value; strings are in braces. **Unknown:** what `amend`
changes, and what `pcount`, `scount` and `tcount` count: they are 0 in every file. A particle
effect's file has `ocount` blocks after its attributes, such as an `EmitterClass` block of the
emitter's directions, colours and sizes.

A ship's attributes give:

- its flight model, as `ship.txt` does (`MaxSpeed` to `YawInertia`, `Acceleration`, `TurnAccel`),
  and a second set for the player (`PlayerMaxSpeed` and so on);
- what it is: `ShipType` (`FIGHTER`, `STATIC`), `FlightModel`, `FriendOrFoe` and `Targetable`;
- its weapons by name, as `bullet.txt` and `missile.txt` name them: `PrimaryWeaponType`
  (`COL_LASERMK1`), `SubPrimaryWeaponType`, `SecondaryWeaponType` and `SubSecondaryWeaponType`;
- where its guns' muzzles are (`Gun1`, `Gun2`) and its engines' glows (`Jet1` to `Jet3`, with
  `Jet1Size` and so on), as positions in the model's space;
- its hardpoints, each a type, an ID and a matrix as four vectors, such as `Secondary00_type`,
  `Secondary00_ID` and `Secondary00_xform0` to `Secondary00_xform3`, the last being the position.
  The types are `SECONDARY` and `SUBSECONDARY` (the missiles' rails), `TURRET` and
  `PLAYERTURRET`, `LAUNCHTUBE`, `SUBOBJECT`, `LEECHPOINT` and `LEECHBEAM`;
- where the cockpit and the chase camera are (`CockpitOffset`, `CameraOffset`);
- the distances at which it changes to a coarser model (`LODDist1` to `LODDist5`);
- its engine's sounds (`EngineSound`, `EngineAfterburnSound`), and its blast when it explodes.

They hold what StarLancer splits between a model's attachment points
([`.SHP` models](../formats/shp.md)) and its ship stats ([Stat tables](../formats/stats.md)).

### Models

A `.mdl` file is a model's parts as Maya exported them. Each part is a `model` block inside the
model's own, which starts with a comment naming the Maya scene, such as
`Z:/BattleStar/SHIPS/sh_v1_viper01/models/sh_v1_viper01.mb`:

```text
    model
    {
// Maya scene Z:/BattleStar/SHIPS/sh_v1_viper01/models/sh_v1_viper01.mb
        name({c1_viper01})
        parent({})
        matrix(1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1)
        meshname({SHV1VI00c1_viper01Shape.msh})
    }
```

A part has a name, its parent's name (empty for none), a 4 by 4 matrix, a `pivot` point, and the
mesh it draws. The mesh is the `.bmsh` file of that name in the model's folder,
lowercase. A part's name starts with `c1` to `c5`, one set of parts for each level of detail: the
Viper has one part at each level, and the Galactica 84 parts at the first and none at the others.
