# Guns

How a ship is fitted with guns, how they are grouped, what a simulation step does with them, and the shots they fire. Gun type statistics and sources are documented in [`formats/stats.md`](../formats/stats.md#guns).

## The guns a model holds

`object_fit_guns` (`0x00479800`) traverses an object's model when created, after its [components](objects.md#components) are listed: once to count its guns and once to allocate them. It allocates `gun_count` records of `0x60` bytes at `+0x134` and one word for each gun at `+0x138`. `object_collect_guns` (`0x00479640`) traverses the root parts in order:

- A part of a turret class (3, 9, 10 or 18, via `part_is_turret`, `0x00479610`) whose [turret kind](../formats/shp.md#part-tag-0x01) is 1, 2 or 3 fits that [turret](#turrets); parts attached to it are skipped.
- A part sharing its link id with a turret-class part is skipped along with its attachments, because its muzzles belong to the turret. A turret class with any other kind is likewise skipped (for example, the Boridin's Ion Cannon with class 18, kind 0, and its six mounted guns produce no fitted guns).
- Any other part produces a fixed gun for each [attachment point](../formats/shp.md#attachment-point-tag-0x09) of kind 3 (muzzle), matching the gun type named at `+0x64`, followed by the guns of any mounted models ([Objects](objects.md#what-an-attachment-point-holds)). A muzzle naming type 0 triggers a warning and fires type 1 instead.

**Unverified:** that a part node holds attachments in order, ordering mounted model guns among its own.

A gun record tracks:
- `+0x00`: turret kind (-1 once destroyed)
- `+0x04`: muzzle node pointer
- `+0x08`: gun stats record pointer
- `+0x0C`: tick until trigger is held
- `+0x14`: side of its group
- `+0x18`: next available refire tick

Turrets store additional data in remaining fields ([Turrets](#turrets)). The word at `+0x138` counts elapsed firing steps to time sound effects.

## Groups

`gun_groups_build` (`0x004667F0`) derives a ship type's gun groups from the first instance created, storing them in the type table at `0x00545900` (`0x78` bytes per type: 20 groups of 6 bytes, each containing two 16-bit gun indices and an unused 16-bit word). Each gun pairs with the nearest mirror-image gun of its type across the lateral axis, closest pair first; the left gun leads the group. A gun with no counterpart forms its own group. Turrets of kinds 1 and 3 are omitted, and types without models receive no groups.

`create_object` marks each gun with its side (0 for the group leader, 1 for the other) and initializes `gun_mode`: group 0, synchronized, firing all groups at once unless the type has only one group (0x20 for one group, 0x30 for more).

## The trigger

`object_fire_guns` (`0x0047B1F0`) holds the trigger for firing guns by setting each gun's `+0x0C` to `frame_start` plus the requested ticks. `FIRE LASERS` holds it for one tick, so player guns fire during the current frame and stop unless the key remains held into the next frame; the mission script's `Fire` command (`cmd_Fire`, `0x00459DD0`) holds it for the ticks it gives. With `FULL GUNS`, every gun fires except aimed turrets; otherwise the two guns of the selected group fire ([Head-up display](hud.md#the-gunnery-display)). A pair fires together, or with `synchronised` cleared (SYNCHRONISE GUNS) in turn, one gun a shot. A muzzle of gun type 11 (Nova Cannon) is skipped either way because it charges up instead ([The Nova Cannon](#the-nova-cannon)). A ship whose guns are disabled fires nothing.

## The step

`guns_step` (`0x004770E0`) runs for every object during each simulation step, after shields recharge. An object listing components steps no guns of its own.

Gun charge (`+0x140`) recharges by the type's `gun_energy` multiplied by its power allocation (`+0x734`) and condition (`+0x66C`), over `ShipCombat._unknown_14` seconds of simulation steps, capping at `gun_energy`. A ship charging a gun does not recharge while its charge is non-zero.

Each gun whose trigger is held fires once its refire interval has elapsed:

- Guns ready to fire are summed first and checked against available charge at the start of the step. If the ship cannot pay the energy cost for all ready guns, none fire. Firing energy weapons deducts `Gun.shot_energy` from charge; projectile weapons deduct one round from ammunition (`+0x13C`).
- When gun condition drops below 0.9, weapons misfire: shots occur only as frequently as condition plus 0.1 allows.
- In alternate fire mode (non-synchronized single group), the two paired guns fire in turn: a gun fires only when its side matches the ship's turn state (`+0x14C`), alternating sides afterwards.
- The refire interval resets regardless of whether the shot succeeded. A ship aiming blind takes 135 ticks for every 100 ticks of base interval.
- Player shots always produce sound. Other ships produce sound once every `gun_sound_periods` steps for that type. Heard shots trigger the gun type's 3D sound following the projectile ([Sound](sound.md#where-the-sounds-come-from)).

A ship executing a jump fires nothing, though its weapons continue recharging. Successful shots create active projectiles.

## Shots

`bullet_fire` (`0x0047C5F0`) allocates the first available of 200 projectile records at `0x00563148` (`0xC4` bytes each), and `bullet_place` (`0x0047BDB0`) populates it. The projectile spawns at the muzzle node and travels along that node's forward vector at the gun type's velocity for its defined lifetime in ticks, which determines range. A ship aiming blind (`blind_fire_aim`) fires a shot of the types 1 to 10, the fighters' guns but the Nova Cannon, at a point instead, turned to face it with no roll: the player's at the lead cursor's point (`hud_lead_point`, [Display](hud.md#the-targeting-cluster)); another player's ship in a multiplayer game, the only other ship aiming blind, at its order's target, led as the AI leads it (`ai_lead_aim`), or along the muzzle where that target can't be aimed at. OpenReliant aims the player's. Gun type 12 scatters. The player's shot plays its gun type's force-feedback effect ([Controls](controls.md#force-feedback)).

Special gun rules:
- Two in five Turret Flak shots spawn as Turret Lasers shots instead (`bullet_fire`). Turret Flak shots have randomized lifetimes between 20% and 100% of their base duration, scattering up to 0.06 radians on each axis.
- The two Huge Guns project reach 1200 and 3000 units past hit targets, and their shots penetrate shields even when shields are down.

Potential targets are assigned at spawn: up to 20 objects whose radius, expanded by movement during flight time, intersects the projectile trajectory. Objects listing components are checked part by part ([The hit tests](objects.md#the-hit-tests)): along the projectile ray, each part whose collision tree root box intersects the path, or that plays a track, registers as a candidate with its node index (`bullet_candidate_test`, `0x0047BC90`). The target velocity subtracted is per-step, while the shot velocity is per-tick. Entities that move into the path after firing are not tested.

`bullets_move` (`0x0047A4E0`) advances all active shots by their velocity each simulation step, after objects move. `bullets_frame` (`0x0047A510`) renders them, tests collisions, and frees expired projectiles once per frame.

`bullet_hit` (`0x00479B40`) tests the segment between the shot's previous and current positions against candidate objects, discarding any that have been passed. An object is struck where the segment intersects its bounding radius:

- If shields are active in that quadrant, the shot impacts the shield: `object_damage` applies the gun type's primary damage value, and the fraction penetrating to armour equals secondary damage over primary damage. For the player ship, [shield reserves](controls.md#the-shield-balance) absorb damage first.
- If shields are down, the shot strikes the hull (`bullet_hull_hit`, `0x00479940`): the last part node whose box is crossed records the hit, and quadrant armour takes secondary damage. Impact throws [sparks](effects.md#sparks).
- Ships with active spectral shields take no damage; the tuned gun type check is ignored, deflecting all shots.

Objects listing components resolve collisions part by part. Within the component bounding box, candidates are tested against the segment at their next positions (`node_hit_test` with `missile_hull_test`), striking the last face crossed. Huge Gun shots trigger a lit fireball 5000 units across for 150 ticks, 40 [sparks](effects.md#sparks) along the surface normal, and the `EXPLOSION01` sound, inflicting no component damage. Other weapons emit 10 sparks of kind 1 along the normal and apply secondary damage to the component (`component_damage`). Shots missing all parts continue flying. Before any of that, a force field glows whole, and a ship with a shield generator glows round the hit ([Capital shields](effects.md#capital-shields)).

What the hit leaves on the part (`node_add_effect`, `0x004992D0`) bursts into orange puffs, or glows on a shield generator's ship ([Effects](effects.md#sparks)).

A shot on a cloaked ship's shields or components shows its hull round the point struck ([The cloak](cloak.md#hits)).

Expired shots are freed on the next frame. A shot striking a shield triggers a shield [flare](effects.md#shields) at the impact point unless the ship is cloaked.

### How a shot is drawn

`guns_init` (`0x00478990`) builds projectile meshes at startup: one set for the player and one for other ships, differing only in Turret Lasers rings. Most projectiles are bolts formed by two crossed textured quads (one upright, one horizontal) along the trajectory, with distant shots using the upright quad alone, textured with additive `gunflarelasers`. Eight builders create them, differing in bolt dimensions, draw distance, and cross rings.

`bullet_build` (`0x0047D9A0`) attaches up to eight visual components per shot based on gun type: mesh objects, sprite sets, lights, and parent frames. Textures sample UV coordinates across 32 of 256 texels (`0x00500FB0`, `0x00500FEC`), using the top half for friendly/neutral ships and the bottom half for hostile ships to distinguish colors. Pulse Cannon and Collapser Guns flares use dedicated textures for player and non-player shots. `bullets_frame` updates and interpolates these components between simulation positions each frame.

| Gun type | Drawn with |
|---|---|
| Laser Cannon | A bolt 60 across and 1200 long |
| Pulse Cannon | A flare, and a smaller one that wheels round it from a random start |
| Messon Blaster | Three thin bolts of different lengths, each at a random turn about the flight |
| Proton Cannon | A bolt 100 across and 1400 long that fades, to blue for a friendly shot |
| Gattling Lasers | Three Laser Cannon bolts about the flight, spinning |
| Tachyon Cannon | A star of three blades and a square ahead of it, spinning and fading |
| Neutron Particle Gun | A bolt 160 across and 1500 long, dim, turned at random each frame |
| Collapser Guns | Two flares either side of the flight, spinning and fading |
| Gattling Plasma Cannon | Four bolts of different lengths at random about the flight |
| Vulcan Battery | Four short bolts in two pairs that wheel about the flight in opposite ways |
| Nova Cannon | A bolt 360 across and 10000 long |
| Turret Flak | The first part of the shell model, `shell.shp`, which `guns_load_shell` (`0x00479140`) takes as each mission starts, once the objects are reset, counting its ship type, `0xB1`, as used |
| Turret Lasers | A bolt 400 across and 2400 long, with two diamonds across it |
| Allied and Coalition Huge Guns | Three squares crossed in the three planes, tumbling and fading, a glow, a light of their own and a trail of particles |

The Nova Cannon bolt rotates 1/8 turn during construction and takes the muzzle orientation, rendering unrotated.

**Improvement:** the Gattling Lasers' three bolts stand an exact third of a turn apart, where the game
multiplies by its rounded third of a turn (`0x004DC8A4`).

On hardware renderers (`sr + 0x1AC`), shots cast dynamic point lights: blue `(0, 0.5, 1)` or orange `(1, 0.5, 0)` for hostile ships unless fired by the player, reaching 1000 units radius. In the original game, only the latest two shots from the player (`0x0056317C`) and latest two from other ships (`0x00563168`) cast lights, with new shots extinguishing older ones.

**Improvement:** OpenReliant allows all shots to cast light (`ShotLights.every_shot`) so sustained fire illuminates passing hulls; `--original` and `--few-shot-lights` restore the original two-shot limit ([Renderer](../port/renderer.md#improvements)).

### Muzzle flashes

Every gun muzzle a model carries has a flash, hung from the muzzle's part and standing and turned as its attachment does (`node_mount_muzzle`, `0x00499680`). It starts hidden. `bullet_fire` lights it for a shot, whether a fighter's or a turret's, to go out after the shot's type's ticks (`gun_flash_ticks`, `0x00500F64`). While it lasts, `node_draw` draws it into the world's layer (`muzzle_flash_draw`, `0x0047BA80`), as large as the share of its muzzle's gun type's ticks it has left. A flash goes out of sight with the part that carries it.

| Gun types | Flash lasts, in ticks |
|---|---|
| Laser Cannon, Pulse Cannon | 50 |
| Messon Blaster | 30 |
| Proton Cannon | 20 |
| Gattling Lasers to Vulcan Battery | 50 |
| Nova Cannon, Turret Flak, Turret Lasers, Huge Guns | None |

A type whose flash lasts no time shows none: the game divides by its ticks and takes what it gets for a share of 0.

`guns_init` builds a flash mesh for each gun type (`muzzle_flash_mesh_build`, `0x004786E0`), all the same shape: a plume, as an engine glow's ([Effects](effects.md)), twice as wide and as high as the Laser Cannon's bolt and half as long, 120 across and 600 long. The quad across the muzzle draws `matflarea3` and the three down the flare `matflareb3`, added and unlit, with the flash's own texture coordinates, a texel in from each edge (`muzzle_flash_create`, `0x0047B150`). The Gattling Plasma Cannon's draws `gunflare\sfxalpha1` for both, a sheet of three frames 32 texels apart, one a tick: the quad across the muzzle takes a frame 30 texels square from a quarter of the way down, the others 30 across and 62 high from the top. OpenReliant builds the two meshes that differ.

**Improvement:** a flash casts a point light while it lasts, reaching two and a half times the flare's length at its brightest and dimming and drawing in as the flare shrinks, so that each shot lights the hull round the gun (`flash.Lights.cast`). Its colour is its flares' own: what their textures add where the flash draws from them, brought up to full brightness.

**Improvement:** the turrets' guns flash too, the Turret Flak, the Turret Lasers and both Huge Guns (`flash.Guns.turrets_too`). A turret's flash lasts 50 ticks and is sized by the Turret Lasers' bolt as the others are by the Laser Cannon's: 800 across and 1200 long. It draws the white flares, `matflarea7` and `matflareb7`, in the colour of its shot's light, blue, or orange from a hostile ship unless the player fired it, paler across the muzzle; its light takes the same colour.

`--original` leaves the flashes unlit and the turrets' guns without them.

### Particles and bursts

`guns_init` (`0x00478990`) makes the guns' [particle](effects.md#particles) templates and two pools of their own: the flak's (`0x005636D0`), 1000 over `gunflare\partic7`, which darkens what is behind it by its alpha; and the spent cases' (`0x0056315C`), 100 over `gunflare\case1`, which shows the texture's own colours.

A Huge Gun's shot trails particles from the explosions' pool: `bullet_build` hangs an emitter from the shot's frame for 10000 ticks, and `bullets_frame` streams from it once a frame, then stands it afresh behind the shot and off it each way across by up to half its stray. It points back along the shot at a speed below nothing, so the particles leave forward, up to 20 slower than that speed, and fall behind the faster shot.

| Gun | Particles | Half-size | Colour | Speed | Spread | Behind, stray |
|---|---|---|---|---|---|---|
| Allied Huge Gun (`0x005635D0`) | 120 to 129 ticks, 12 a tick | 700, 500, 250 | Blue (0.3, 0.8, 0.8) to nothing | 200 to 220 | 0.15 | 700, 400 |
| Coalition Huge Gun (`0x0056318C`) | 120 to 129 ticks, 12 a tick | 500, 700, 1100 | Orange (1, 0.9, 0.7) to nothing | 230 to 250 | 0.1 | 850, 850 |

A Turret Flak shell that ends without striking anything sounds `FLAK01` and bursts where it stands. Within 10000 of the camera:

- two flashes of flak ([Fireballs](effects.md#fireballs)), 280 across with a light and 245 across 20 to 39 ticks late, each over 130 ticks;
- 30 of the flak's particles (`0x00563104`) every way at 1.4 to 1.75 a tick, 150 to 159 ticks long, dimming from half grey and growing from a half-size of 42 to 119, a spark one time in 200;
- ten fireballs of the bang or the sheet at random, then ten of flak, each drifting out a random way at 10.5 a tick, lit, 0 to 19 ticks late, 50 to 119 ticks long and 14 to 70 across.

Farther off it is one flash of flak 600 across with a light, over 40 ticks.

A spinning gun throws a spent case as it fires each round, and so does a model's `puff` event (`clip_event_particles`, `0x0047C800`): one from each of the part's attachments of kind 7, back along it at 10 a tick, strayed up to an eighth either way across, carrying a quarter of the ship's velocity, showing one of the eight cells of `gunflare\case1`, four across and two down, at random. A case lasts 100 to 109 ticks at a half-size of 15.

[`guns/effects.zig`](../../src/engine/game/guns/effects.zig) ports the pools, the trails, the burst and the cases.

## The Nova Cannon

The Phoenix's Nova Cannon charges while the trigger is held and strikes when it is let go. Holding the trigger with one group chosen whose first gun is a Nova Cannon (`object_fire_guns`) adds 0.0025 times the guns' share of the power to the ship's `nova_charge` (`+0x148`), up to 1. Past 0.5 the player's view shakes at 0.3, and full at 0.6. The guns' charge doesn't recharge while `nova_charge` holds any.

`player_controls` lets it go once the trigger is up, for a Phoenix that isn't jumping (`nova_release`, `0x0047B3D0`). It takes the first of eight beams free (`nova_beams`, `0x00563190`); with none free, nothing happens and the charge waits. Below 0.5 the charge is lost. Otherwise:

- the blast sounds from the ship, positional sound 13 as loud as 2000 times the ship's radius, and the controller plays `nc` ([Controls](controls.md#force-feedback));
- the beam strikes every object but the ship, the stand-ins and the disabled ones, whose bounding box it meets up to 40000 straight ahead. One listing no components takes the cannon's shield damage times the ship's gun condition and the charge, on the quadrant the beam enters, its hull damage over that passing through, and its shields flare there unless it is cloaked. One listing components is struck part by part (`nova_strike_parts`, `0x0047B840`): each part whose mesh's box the beam meets takes the cannon's hull damage times the charge against its component for each leaf of its collision tree the beam crosses, with a hit's burst there ([Effects](effects.md#sparks));
- the beam shows for 80 ticks, and the charge is spent.

Each frame `bullets_frame` places the beams (`nova_beams_frame`, `0x00480690`). The beam is four blades on `ionc`, 150 wide either side narrowed by the square of the charge and 40000 long, standing 50 above and 20680 ahead of the ship, turned with it. Each blade's texture runs along it at 0.01 a tick more than the blade before's, and the blades are lit at the ship's end, dark at the far one, fading out over the last fifth of the beam's time. After a full charge 30 strands follow a helix along it (`nova_helix`), each two blades on `laser2` from one point of the helix to the next, radius 100, six turns a unit and 15000 long a unit from 600 ahead, the points 0.03 apart from 0.3 behind how far through its time the beam is. The strands rise and fall in brightness over the beam's time (`ease_rise_fall`); the game lights their first blades alone.

**Fix:** the game takes where the beam enters an object's box, which is in the object's frame, for a point in the world's, so the quadrant struck and the flare land wherever that puts them; OpenReliant takes the point where it enters. The game also keeps drawing a beam from a ship that has gone.

**Improvement:** the helix turns six times a unit exactly, where the game rounds its angle.

Not ported: the multiplayer game's release for another player's ship, and its quarter damage.

## Turrets

A turret part of kind 1, 2 or 3 forms a turret assembly: visible parts of its model sharing its link id, placed in slots defined at `+0xF8`. Setup initializes the gun record, sets node flag `0x400` on slot 0 (the base), and stores the model pointer at `+0x34` (`+0x30` for kind 2). The muzzle is the last part of the assembly; slot indices reference model parts.

| Kind | Fit | What the record keeps |
|---|---|---|
| 1, aimed | `turret_fit_aimed` (`0x00479160`) | The parts in slots 0 to 4 at `+0x38` to `+0x48`, slot 1 the base's where no part names it; a target at `+0x18` (none, index -1, at `+0x1C`); the tick it next looks for one at `+0x4C`; the yaw and pitch still to turn at `+0x50` and `+0x54`; and, where a part of the assembly is one of the object's components and the object's model has [firing arcs](../formats/shp.md#firing-arc-tag-0x10), that component's arc at `+0x58`, the last found |
| 2, spinning | `turret_fit_spin` (`0x00479470`) | The parts in slots 0 to 4 at `+0x1C` to `+0x2C`: the barrels that spin, the gun, and two flaps |
| 3, missile | `turret_fit_missile` (`0x004793A0`) | The parts in slots 0 to 4 at `+0x38`: the base and the launcher; a target at `+0x18`; a timer at `+0x4C`; the missiles left at `+0x58`, none at first; its state at `+0x5C`. It has no muzzle and no gun type |

Aimed turrets fire according to their parts' `fire` tracks: event 0 fires from each part muzzle (`clip_event_muzzles`, `0x0047C7B0`, through `bullet_fire`) with sound, matching the muzzle's gun type. These shots bypass capacitor charge, ammunition counts, refire delays, condition penalties, jumps, and gun disabled flags.

### Each frame

`orders_update` runs `object_step_turrets` (`0x0047C950`) after orders for objects with enabled weapons. Unless an object is exploding or executing a Dock order, each gun evaluates its turret step from the table at `0x00500FA0` (fixed guns and destroyed turrets marked -1 do nothing).

**Aimed, `turret_aimed_step` (`0x0047D3D0`).** When a target is active, the turret tracks it and rotates: the base turns about X by remaining yaw, and slot 1/slot 2 parts pitch about Y, each clamped to 0.02 radians per tick within mechanical limits (`node_turn`, `node_place`). If a target is lost during tracking, the turret continues turning by the previous frame's delta. If idle, it searches for a new target every 100 to 199 ticks.

`turret_aimed_track` (`0x0047CFA0`): invalid targets (`order_target_valid`) are dropped. Otherwise, the turret computes lead aim from its base (`ai_lead_aim_with_gun`), scaling lead randomly between 0.5 to 0.8 when the target has active ECM, and calculates required yaw and pitch angles (`turret_aim_angles`). If aiming or leading fails, the target is dropped. Remaining yaw and pitch deltas are stored at `+0x50` and `+0x54` via the shortest rotational path. When the muzzle forward axis passes within twice the target radius of the aim point ahead (`turret_in_line`, `0x0047CF10`), it holds the trigger for one tick and plays the `fire` track at speed 2 on idle parts, firing the muzzles.

`turret_aim_angles` (`0x0047CB10`) computes aim angles relative to the base part: yaw is
`atan2(y, -z)` and pitch is `-atan2(x, -z')`, where `z'` is `z` rotated by yaw. Angles outside
mechanical limits fail; Huge Guns aimed up to 20 degrees past a pitch limit clamp to the limit. If
firing arcs are defined, the direction in root space indexes a 32-row by 16-column bitmask table
requiring four adjacent bits set. The original game calculated angle from Y by dividing X by
`sin(yaw)`, which divides by zero when pointing straight forward or backward. **Fix:** OpenReliant
calculates the transverse length directly. Not ported: Stalag turrets firing in all directions while
`0x005883F8` is set ([#220](https://github.com/OpenReliant/openreliant/issues/220)). **Improvement:**
OpenReliant converts angles using exact mathematical constants rather than approximations
(`57.2958`, `0.0174533`, `3.14159`, `6.28319`).

`turret_pick_target` (`0x0047D1F0`) acquires the first valid object in slot order that it can lead
and aim at: type under `0x100`, not itself, and hostile (neither friendly nor neutral). Huge Guns
only target entities with component lists. Entities without components (or any entity for Huge Guns)
are targeted as a whole; otherwise, turrets on ships with components target individual
sub-components (excluding Kurgan, Antanov, Nanny, and Prowler). The original game did not check
target validity during selection, causing cloaked, exploding, or untargetable entities to monopolize
targeting queues. **Fix:** OpenReliant skips entities that tracking would drop. In multiplayer, it
skips the player who last damaged the object (`+0x10`), which OpenReliant omits
([#55](https://github.com/OpenReliant/openreliant/issues/55)).

**Fix:** in the original game, rear fighter turrets (including the Predator tail gun) have rear-facing muzzles but base reference frames pointing forward with zero yaw and pitch, preventing them from aligning with targets or firing. OpenReliant rotates the reference frame 180 degrees around X for rear-facing muzzles, allowing them to aim and fire backwards properly ([#219](https://github.com/OpenReliant/openreliant/issues/219)).

**Spinning, `turret_spin_step` (`0x0047C9B0`).** Barrels loop their `fire` track. While the trigger is held, barrels accelerate by 0.1 per tick up to a speed of 4, the gun track loops at matching speed, and protective flaps open at speed 4. When released, barrels decelerate by 0.02 per tick, the gun track stops at start, and flaps close. Weapons fire during the step regardless of spin speed.

**Missile, `turret_missile_step` (`0x0047D560`).** State transitions:

| State | Action |
|---|---|
| 0, searching | When empty, transitions to state 2. When cooldown expires, selects the nearest target ahead within Screamer lock range and within 0.7 distance vertical bounds that is targetable, hostile/neutral, has no components, and is not a stand-in, exploding, or disabled, then transitions to state 1 |
| 1, tracking | When empty, transitions to state 2. If the target becomes invalid, exceeds half lock range, or leaves the vertical cone, it resets to state 0 (re-scanning in 20 ticks). Otherwise, turns its base 0.1 radians toward targets offset by more than 0.1 lateral distance; when within 0.7 ahead and cooldown expires, launches a Screamer with a 1-in-5 probability per check ([`missile_launch_turret`](missiles.md#a-missile-turrets)), deducting ammunition on launch, and waits 2000 ticks (1000 in mission 28) |
| 2 | After 100 ticks, plays the launcher `reload` track forward at speed 4, transitioning to state 3 |
| 3 | After 800 ticks, plays the track in reverse at speed -4, transitioning to state 4 |
| 4 | After 300 ticks, reloads six missiles and returns to state 0 |

Turrets start in state 0 with zero missiles, reloading immediately. Targets between 50% and 100% of lock range are acquired and dropped alternately.

Destroying a turret base disables the weapon permanently: `node_forget` (`0x00499BB0`) sets its kind to -1 ([Objects](objects.md#a-components-destruction)).

Not ported: script `TurretSetTarget` targeting commands ([#281](https://github.com/OpenReliant/openreliant/issues/281)), and multiplayer damage-induced re-targeting ([#55](https://github.com/OpenReliant/openreliant/issues/55)).

Gun groups exclude kinds 1 and 3, and `FULL GUNS` excludes kind 1 ([The trigger](#the-trigger)). The original game read into adjacent memory when assemblies lacked expected parts; OpenReliant checks for missing base, muzzle, or launcher parts, skipping invalid slots and trigger calls (**Fix**).

## OpenReliant

[`guns.zig`](../../src/engine/game/guns.zig) implements weapon fitting (`fit`), grouping (`buildGroups`), trigger evaluation (`fire`), simulation steps (`step`), projectile handling (`shoot`, `moveBullets`, `bulletsFrame`), and visual rendering (`Looks`, `dress`, `animate`, `drawBullets`). Procedural geometries use compile-time recipe tables replacing the original eleven shape builders. Shapes are built once, keeping Turret Lasers variations distinct. `simulationStep` updates steps and moves projectiles; `missionFrame` executes per-frame updates; `drawFrame` queues render objects; and `playerControls` maps `FIRE LASERS`. `gun_stats` and active projectiles reside in `create.Objects`, and static binary records are defined in [`guns/stats.zig`](../../src/engine/game/guns/stats.zig), generated via `make gun-tables`.

The muzzle flashes are [`guns/flash.zig`](../../src/engine/game/guns/flash.zig)'s, which every model's muzzles draw (`objects.Model.flashes`).

Choosing a group and FULL GUNS are the gunnery display's keys ([Head-up display](hud.md#the-gunnery-display)).
