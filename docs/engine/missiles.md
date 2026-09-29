# Missiles

`missiles.cpp` keeps the missiles in flight, their trails and their stats; the launchers, the lock and the loadout live in the files that call it. OpenReliant is [`game/missiles.zig`](../../src/engine/game/missiles.zig).

**Unverified:** the file's extent. The assertions name its path from `0x00494CB0` to `0x00496B0E`; the strings and the data its code uses (`missilestats.bin`, `MissileTrail BMO`, `Missilebursttrail mesh`) place `stats_load_missiles` (`0x00494BC0`) and everything to `0x00498443`, `order_torpedo` among it, in it too.

## Types

A missile's type is the id of the missile hardpoint (attachment kind 0) that holds it, the type of
its object, and its index into every missile table.

| Type | Name | Hardpoint holds | Missiles | Guidance |
|---|---|---|---|---|
| 0 | Screamer | `01_screamer_pod.shp`, of `01_screamer.shp` | 20 | Straight when a player fires it outside multiplayer; else homing |
| 1 | Raptor | `02_raptor_pod.shp`, of `02_raptor.shp` | 3 | Homing |
| 2 | Havoc | `03_havoc.shp` | 1 | Homing, ends within 10000 of its target; shockwave kind 5 |
| 3 | Jack Hammer | `04_jackhammer.shp` | 1 | Homing |
| 4 | Bandit | `05_bandit.shp` | 1 | Homing |
| 5 | Vagabond | `06_vagabond.shp` | 1 | Homing, on a cloaked target too |
| 6 | Solomon | `07_solomon_pod.shp`, of `07_solomon.shp` | 4 | Picks its own target |
| 7 | Imp | `08_imp.shp` | 1 | Homing, ends within 10000 of its target; shockwave kind 6 |
| 8 | Hawk | `09_hawk_pod.shp`, of `09_hawk.shp` | 4 | Homing |
| 9 | Torpedo | | | None: only the torpedoes' trail and sound |
| 10 | Fuel pod | `fuel_pod.shp` | 1 | Let fall: 5000 more afterburner fuel while it hangs |

## Stats

`missile_stats` (`0x005037A0`) holds `0x28` bytes a type, and `missile_flight_stats`
(`0x005035E8`) a flight model a type. The executable holds its own words for each, and
`stats_load_missiles` (`0x00494BC0`) reads up to 11 records of `missilestats.bin`
([Stats](../formats/stats.md#missiles)) over them, keeping in whole numbers what `__ftol` cuts
down:

| Offset | Field | From |
|---|---|---|
| `0x00` | 30 for every type; nothing reads it | Executable |
| `0x04` | The launch's 3D sound: 15 (`MISSILE01`) to 23 for types 0 to 8, 24 for 9, none for 10 | Executable |
| `0x08` | Flight time, in ticks | `0x48 * 100` |
| `0x0C` | Shield damage | `0x4C` |
| `0x10` | Hull damage | `0x50` |
| `0x14` | Component damage | `0x60` |
| `0x18` | The guidance order once the launch is over: type + 2 for 0 to 8, 0 for 9, 11 for 10 | Executable |
| `0x1C` | Lock time, in ticks | `0x54` |
| `0x20` | Decoy chance, in percent | `0x58` |
| `0x24` | Lock range | `0x5C` |

Before loading, a record holds a flight time of 1000 ticks (12000 for 9 and 10), damages of 290,
180 and 180, a lock of 200 ticks, a decoy chance of 50 and a lock range of 50000. The flight model
takes the speed, and the turn rate for all three rates; the rest is the executable's: an inertia of
0.84 and rate inertias of 0.71, for a speed of 300 and turn rates of 0.14 before loading (50 and
0.05 for type 9, and all zero for type 10).

## The loadout

A ship carries its missiles in racks, one for each of its missile hardpoints: 20 records of `0x0C`
bytes at `GameObject + 0x158`, `rack_count` of them (`+0x150`).

| Offset | Field |
|---|---|
| `0x00` | Missile type, i16; below 0 for none |
| `0x04` | Where the node of the part that carries the hardpoint lists the hung pod or missile |
| `0x08` | Missiles left |

`create_object` fits them after the guns:

1. The tier: 5 is 4, and outside 0 to 4 is 0. A fighter (types 0 to 11) asked for 0 takes
   `campaign_tier` (`0x00562DF0`), and then any 4 is 0. A mission's ship record asks with its byte
   `0x3D`: 0 and 255 for the campaign's tier, 4 and 5 for tier 0. The campaign's tier is 0 for a
   new pilot and rises to 1, 2 and 3 after the 11th, 19th and 21st missions
   (`mission_end_record`).
2. The types (`object_loadout_by_tier`, `0x0045E500`): each missile hardpoint of the parts in the
   root's child list, every part in order whatever it is linked to, in turn, takes the missile its
   attachment names for the tier: its id for tier 0, and the low half of the four words after it
   for tiers 1 to 4. A player's ship takes the racks the player chose on the loadout screen instead
   (`0x00588400`, `0x54` bytes a player), unless the briefing is skipped.
3. The fitting (`object_fit_missiles`, `0x0045E1A0`): on each hardpoint, in turn, hangs what its
   rack holds, the pod or the missile (`attachment_models`), and fills the rack with the pod's
   capacity, or 1. A rack of no missile ends the loadout (`0x0045E24F`): its count is 0 and every
   hardpoint after it reads the same rack. In every shipped model each tier names a missile for
   each missile hardpoint, so only a rack left empty on the loadout screen ends it.
4. 5000 more of the afterburner's fuel for each fuel pod, and 29 countermeasures.

A re-arm (`order_dock`, `cmd_ReplenishWeapons`) lets go of what hangs and fits the racks again: a
player's ship with the racks its loadout chose, but the player's own by tier 0 where the briefing
was skipped or in the simulator; any other ship by the tier at `GameObject + 0x648`, which nothing
writes.

OpenReliant fits a player's ship with the racks the loadout screen chose where it ran
([Loadout](loadout.md#what-it-leaves-the-mission)), and by the tier otherwise, as the game does when
the briefing is skipped. The root lists each part at its number (`object_link_part`), so the
hardpoints of a part linked to another, as in `Jap_Sai.SHP` and `Chin_Han.SHP`, are fitted too.

**Fix:** a rack of no missile leaves its hardpoint bare and is taken out, the racks after it moving
down, so that each hardpoint after it takes the rack the loadout fitted on it
([#451](https://github.com/vdmkenny/openreliant/issues/451)). The game flies without the missiles
of every rack after an empty one, and without any where the first is empty.

Not ported: the Nanny's re-arm (`order_dock`, `0x00407A5F`,
[#320](https://github.com/vdmkenny/openreliant/issues/320)).

## Flight

`missiles` (`0x005887F0`) holds 200 records of `0x28` bytes, and `0x005887F4` the newest live one;
each links to the one launched before it and after it.

| Offset | Field |
|---|---|
| `0x00` | The tick its launch or jettison began, which its flight time counts from; -1 while free |
| `0x04` | Its object, from `object_alloc`, which no slot of `game_objects` holds: nothing else collides with it, targets it or shows it on the radar. Its type is the missile's |
| `0x08` | Its launcher's slot |
| `0x0C` | The countermeasure it chases, or -1 |
| `0x10` | Its trail |
| `0x14` | Its type's stats |
| `0x18`, `0x1C` | In a network game, the player who launched it and the id it goes by there |
| `0x20`, `0x24` | The missiles launched before it and after it |

Its object keeps a stack of one order (`0x684`), whose target (`+0x04`) and component (`+0x06`) it
flies at, and whose order is one of the table at `0x00503D20`, each with an `init` and an `update`.

### The launch

`missile_launch` (`0x00496290`) takes a rack, a target and its component. It does nothing for a
ship whose missiles are disabled, or with no record free. The player's launch plays the `Missile`
force-feedback effect ([Controls](controls.md#force-feedback)).

- A pod with missiles left builds a missile of its own from the pod's second model, where the pod
  hangs; anything else, a rail's missile, a fuel pod or an empty pod, is itself let go of.
- The missile takes three places from where that hung: the launcher's place, its next place and
  its drawn frame, so it is drawn on from where it was. Its root is marked committed and unframed.
  It takes the launcher's velocity and side.
- Its launch sound (`stats + 0x04`) plays at its next place, facing the way it moves, on a sure
  voice for the player's missile. The voice follows it no further, and ends with its length.
  **Improvement:** OpenReliant's follows the missile and ends with it
  ([Sound](sound.md#playing)).
- One fewer is left in the rack. A pod's missile flies the pod launch and a rail's the rail launch,
  each with its trail; a fuel pod and an empty pod are jettisoned. Then it takes its target.
- A pod whose last missile this was is launched too, at nothing, and so jettisoned.

`missile_order_set` (`0x00496AA0`) runs the new order's `init`, sets it, then runs its `update`.

### Orders

| Order | Update | What it does |
|---|---|---|
| 0 | `0x00496B20` pod launch | Throttle 2, no steering; after 50 ticks, the type's order |
| 1 | `0x00496B60` rail launch | No steering. For 25 ticks, throttle 0 and a drop along its Y axis of 0.005 of its top speed a tick; for 25 more the same back up; then throttle 1; after 100 ticks, the type's order |
| 2 | `0x00497F10` Screamer | Flies straight (`0x00496C60`: throttle 1, no steering) when a player launched it outside a multiplayer game; otherwise homes |
| 3, 5 to 7, 10 | `0x004983B0` | Homes (`missile_home`) |
| 4, 9 | `0x00497F30` proximity | Havoc and Imp: ends within 10000 of the target's root, else homes |
| 8 | `0x00497F80` Solomon | Picks a target while it has none to aim at, then homes |
| 11 | `0x00498410` jettison | Throttle 0, no steering; ends 100 ticks on. Its `init` (`0x004983C0`) adds 50 along its Y axis to its velocity |

The launches' `init` (`0x00496B10`) and the jettison's keep the tick they began at.

### Homing

`missile_home` (`0x00496C90`) steers at the target while it is one to aim at
(`order_target_valid`), a cloaked one too for a Vagabond:

1. The aim is the target's node (`ai_target_node`), led along the target's nose by the distance to
   it times the target's speed over the missile's top speed. A decoyed missile aims at the
   countermeasure instead, and ends with it within 1000.
2. Beyond 1,000,000, the target is lost.
3. The throttle is the cosine of the angle off the aim, at least 0.
4. With the aim ahead, pitch and yaw take the angles off it, in radians less four times the rates,
   times 5.72958, within 1 either way: fully over ten degrees off. With the aim behind, no pitch
   and full yaw toward its side. No roll.
5. With the target lost, a missile whose trail has the Solomon's look flies straight; any other
   ends.

**Improvement:** OpenReliant works the gain out as 18 over pi.

The Solomon's choice (`0x00497F80`) is among the objects of other sides to the missile's that are
ones to aim at: of those that list no components, the nearest whose direction lies within 0.7 of
the missile's nose, else the nearest at all, by their drawn places; with none, likewise among the
components of those that list them, by where their nodes are drawn, or the object itself where
none of its components is one to aim at. With nothing, it flies straight.

### Each step and each frame

`missiles_move` (`0x00495720`), after `objects_update` each step: each missile takes its next
place, eases its pitch and yaw rates toward its inputs times its turn rates by its rate inertias,
turns by them, and moves. Its velocity is damped by its inertia, save in its launches and its
jettison, and pushed along its nose by the rest of it times its throttle and top speed. It never
rolls, and nothing knocks it.

`missiles_update` (`0x004960F0`), once a frame after the objects are framed, runs each missile's
order. Within its flight time, it tests the missile for contact, and with none, frames it and draws
it, its engine glows by its throttle. A missile with a target and no decoy lights that target's
missile warning (`missile_homing`), but not a player's Screamer outside a multiplayer game. Past
its flight time, it ends. In a multiplayer game it also drops the target of a player's missile
whose lock is broken, and ends one whose launcher is gone.

### Contact

`missile_collide` (`0x00495CF0`) tests the segment from the missile's drawn place to its next place
against every object of type below 256 that collides, but its launcher, of any side:

- An object that lists components: its parts, and those of the models mounted on it
  (`missile_hit_components`, `0x00495AC0`), by their collision trees at their next places
  ([`object_hit_test`](objects.md#the-hit-tests) with `missile_hull_test`, `0x004959A0`):
  within the boxes the segment meets, each face the segment starts in front of, no further off
  than it is long, is tested, and the last face crossed counts. But for a Havoc or an Imp, the part
  struck glows where its ship has a shield generator
  ([Capital shields](effects.md#capital-shields)), and takes the type's component damage.
- Any other: whether the segment passes within its radius. A Havoc or an Imp just ends there.
  Otherwise, where it first meets the sphere, the quadrant (`0x00463CA0`):
  - With the quadrant's shield below 0, or `invulnerable` at 4: `missile_hit_hull` (`0x00495BB0`).
    Every part in the root's child list, hidden or not, is tested by the box of its mesh; where the
    segment meets one, the quadrant's armour takes the type's hull damage and the hit sounds.
  - Otherwise, with a shield damage above 0: the shield takes it, with the hull damage over the
    shield damage as the share that passes through (`object_damage`), five times over in a
    multiplayer mission. The player's ship takes it only on the fore quadrant, and only as the hit
    empties a [shield reserve](controls.md#the-shield-balance): the fore's while it holds anything,
    else the aft's. With neither holding anything, or on any other quadrant, the player's shields
    take nothing.

    **Fix:** every other hit on the player's shields, a shot's, a knock's and a shockwave's, draws
    the reserve of the side struck and then reaches the shield, so OpenReliant takes a missile's the
    same way: off the fore or aft reserve while it holds, then on the shield.
  - The shield flares at the point unless the object is cloaked.

The missile's velocity is zeroed and it ends. A Screamer's damage counts as kind 5, any other's as
kind 1.

`missile_hit_hull` walks on past the first part met with the segment cut short to where it entered
that part, but in the part's own frame, so no part after it is truly tested.

**Fix:** where the segment meets no part's box, `missile_hit_hull` still reports contact without
ending the missile, so it is not drawn that frame and flies on. OpenReliant reports none, and draws
it.

### The end

`missile_end` (`0x00495870`) ends the voice its object holds, where it holds one; sets off a
Havoc's shockwave (kind 5) or an Imp's (kind 6) where it is drawn, 50000 across over 500 ticks,
sparing its launcher's side ([Effects](effects.md#shockwaves)); and its blast
(`missile_explode`, `0x0046E370`): 50 sparkles, living one to three seconds, and a lit fireball
from the sheet, three times its radius across over a second, both drifting at a quarter of its
velocity, and `EXPLOSION01` among the explosions. Its trail fades out from there, and its object and
record are freed.

`missiles_reset` (`0x00494D80`) frees every missile as a mission ends.

OpenReliant keeps the missiles with the objects (`create.Objects.missiles`).

## Trails

A missile leaves a trail, and so does a torpedo as it leaves its carrier (the Launch order's stage
at `0x0041A390`). `missile_trails` (`0x005887EC`) holds 200 records of `0x48` bytes, and
`missile_trail_list` (`0x005887F8`) the newest live one. A trail follows a missile's record (kind
1) or an object's slot (kind 2); `missile_end` detaches a missile's, which then fades out.
[`missiles/trail.zig`](../../src/engine/game/missiles/trail.zig) ports them.

| Offset | Field |
|---|---|
| `0x00` | Its type, whose look it takes |
| `0x04` | Its kind: 0 free, 1 a missile, 2 an object |
| `0x08`, `0x0C` | The missile, and the object's slot (-1 for a missile's) |
| `0x10`, `0x14` | The ring its ribbon lays next, and the ring its side ribbons do, from 1 |
| `0x18`, `0x1C` | Its ribbon, and its four side ribbons |
| `0x2C`, `0x30` | Its plume, and its glow |
| `0x34` | When its plume's texture last turned |
| `0x38`, `0x3C` | `frame_start + 50` as the side ribbons are made, and a byte the side ribbons set without a ribbon; nothing reads either |
| `0x40`, `0x44` | The trails made before it and after it |

### Looks

`missile_looks` (`0x00503958`) holds `0x58` bytes a type:

| Offset | Field |
|---|---|
| `0x00` | Its pieces: `0x1` a ribbon, `0x2` a plume, `0x4` side ribbons, `0x8` a glow; `0x10` the ribbon twists with the missile's turning, `0x20` it jitters |
| `0x04`, `0x08` | The ribbon's rings, and its colour, which the glow's first sprite takes too |
| `0x14`, `0x20` | A second colour and a fade: nothing reads them |
| `0x24`, `0x28` | The side ribbons' rings, and their colour |
| `0x34`, `0x40` | Likewise unread |
| `0x44` | How many side ribbons, up to four |
| `0x48` | The plume's colour |

| Type | Pieces | Ribbon | Side ribbons | Plume |
|---|---|---|---|---|
| 0 Screamer | ribbon, glow, jitter | 25, (0.3, 0.3, 0.6) | | |
| 1 Raptor | ribbon, side | 5, (0.7, 0.9, 1) | 3 of 5, (0.3, 0.7, 0.8) | |
| 2 Havoc | ribbon, plume | 35, (0.8, 0.6, 1) | | (0.5, 0.5, 0.5) |
| 3 Jack Hammer | ribbon, glow | 60, (0.5, 0.5, 0.5) | | |
| 4 Bandit | ribbon, side, jitter | 35, (0.2, 0.1, 0.5) | 3 of 10, (0.5, 0.5, 0.5) | |
| 5 Vagabond | ribbon, twist, jitter | 40, (1, 1, 1) | | |
| 6 Solomon | ribbon, glow, jitter | 45, (0, 0, 1) | | |
| 7 Imp | ribbon, plume | 30, (0.2, 0, 0.5) | | (0, 0, 1) |
| 8 Hawk | ribbon, plume, jitter | 40, (0.5, 0.5, 0.5) | | (0.5, 0.5, 0.5) |
| 9 Torpedo | ribbon, glow, jitter | 70, (1, 1, 1); a hostile torpedo's (227, 199, 139) / 255 | | |
| 10 Fuel pod | none | | | |

### Ribbons

A ribbon (`missile_trail_mesh_create`, `0x004970A0`) is a ring buffer of rings of four corners,
the corners of the tail's cross-section: the bounds' far face behind the object. Each ring is
joined to the next by two quads along the ring's diagonals, crossed, and one across the next
ring. The quads along take the top half of `missiletrail\mtrail2`, from one ring to the next,
and those across its bottom half. It is lit by the object's own colours and added to what is
behind. A new ribbon has every corner at the tail's first; a side ribbon's corners start black at
full strength, the ribbon's at nothing.

Once a frame (`missile_trail_update`, `0x00495280`):

1. Each corner fades by the frame's ticks times 0.015 over the rings times 0.04: a ring fades out
   over the ribbon's rings over 0.375 ticks. Its colour is the look's times what is left.
2. While the trail follows something, the cursor's ring is laid at its tail again, at full strength,
   the look's colour times the throttle, at least 0.5. A twisting ribbon's ring is widened by half
   the missile's turning (the sum of its three rates) plus 1, flattened to a fifth, and turned
   about the nose by the turning times the tick times 0.01; a jittering one's is stretched across
   and up by 0.5 to 2 at random.
3. The quads from the cursor's ring to the next, the oldest, are hidden (the face flags' cap bit),
   and those from the ring before to it shown. Once the ring stands more than three tail widths
   from the one before, the cursor moves on.
4. With nothing to follow and every corner faded out, the trail is freed.

The side ribbons (`missile_side_trails_update`, `0x004974B0`) fade and are laid likewise, in their
own colour, but their rings are a fifth of the tail and up to as much again, pushed out by 0.5 to
0.8 of the tail's half-width, and turned about the nose by their share of a whole turn, and by the
turning as the ribbon twists: a helix. They share one cursor, which only the first moves, so the
rest lay their rings at the one it has just moved to. Once the last has faded out, they are let
go, or, without a ribbon, the trail is freed.

### Plume and glow

The plume (`missile_plume_create`, `0x00497AA0`) is six rings of nine corners, joined by
triangles, widening from nothing at the mouth to 210 at 630 behind, over `shield128` scaled by the
alpha and added. Each frame while its missile lives (`missile_plume_update`, `0x00497DE0`), it
stands at the missile's tail, its axis tilted by up to 0.05 either way at random, and its texture
turns round it by 0.091 a tick. Its corners take the look's colour
(`missile_plume_colour`, `0x00497D60`) by nines from the first, half of it at the mouth and a
tenth less each nine; the corners go by nines from the centre of the mouth, not from its ring, so
each ring's last corner takes the next ring's colour. The first triangle keeps no texture
coordinates.

**Fix:** the game works the mouth's corners' texture coordinates round the plume out as a nought
over a nought, which is not a number; OpenReliant gives them 0.

The glow (`missile_glow_create`, `0x00497450`) is two sprites over `gunflare\partic6`, lit and
added: one in the look's colour, one white. Each frame while its missile lives, or the Russian
torpedo it follows (`missile_glow_update`, `0x00497980`), it stands 50 behind the tail, the first
as wide as the tail and up to a sixth more at random, the second half as wide.

**Fix:** with every trail taken, `missile_trail_create` takes the record past the last and writes
past its pool. OpenReliant leaves the missile without a trail.

## Countermeasures

A ship drops countermeasures to draw away the missiles homing on it. `countermeasures`
(`0x00540610`) holds 100 records of `0x24` bytes: whether it flies, the tick it ends at, the ship
that dropped it, its velocity, its scene object over `ships\decoy.shp` (`decoy_model`,
`0x00541420`), and its two streams of smoke. **Unverified:** that the code is `cloak.cpp`'s: it lies
after `cbox.cpp`'s and before `cloak.cpp`'s asserting code, and its model's name lies just before
`cloak.cpp`'s path among the strings. OpenReliant's is
[`cloak.zig`](../../src/engine/game/cloak.zig).

`decoys_init` (`0x00462390`), as a mission runs, clears them, loads the model and makes their smoke
(`decoy_particles`, `0x00541424`): a puff a tick at even odds, from 50 to 100 across, grey from 0.25
to nothing, living 100 ticks and up to 10 more, from the particles' first pool.

`object_spend_countermeasure` (`0x00462550`) spends one of the ship's countermeasures (`+0x5EC`;
29 as it is made). With none left, the player's display beeps its refusal (`hud_beep` 3) and
nothing more happens; otherwise the player's beeps (`hud_beep` 0) and:

1. The first free record takes it; with none free, it is spent for nothing.
2. It stands at the ship's tail, `(0, 0, bounds_min.z)`, at the ship's next place, turned as the
   ship will be, and drifts at a quarter of the ship's velocity, 5 along the ship's Y axis and 5
   back, for 1000 ticks. Its smoke streams from its nose and its tail, along its own Z axis either
   way, at 5 to 6 a tick, straying a quarter either way across.
3. Outside a network game, or on its host: each missile, in the order of its records, homing on the
   ship without a countermeasure, rolls `rand() % 100` against its type's decoy chance (`stats +
   0x20`), 30 more against a player's ship, else 50 more where the ship's pilot holds its
   countermeasures for 50 ticks at least (level 2 of `tier_c`). The first under it chases the
   countermeasure: one countermeasure draws away one missile at most. A network client takes the
   host's choice instead.

A missile drawn away keeps its target, which must stay one to aim at, stops lighting its
`missile_homing`, and homes on the countermeasure with no lead; within 1000 of it, both end
([Homing](#homing)).

`decoys_update` (`0x00462900`), once a frame after the explosions: each countermeasure past its
time ends; the rest turn about their Y axis by 0.01 for each of the frame's ticks and one more,
drift by their velocity times the frame's ticks, and trail their smoke.
`countermeasure_end` (`0x00462460`) turns every missile it drew away back to its target, and ends
it in a fireball from the sheet, 200 across over 50 ticks, drifting as it did.

OpenReliant reads the model once for the whole run.

## Who launches

Only these launch the missiles of `missiles.cpp`: the player (`player_launch_missile`), the Fight
order (`fight_fire`), orders 2 and 3, and a missile turret ([A missile
turret's](#a-missile-turrets)). A turret named a missile turret in the models' tables is a gun.

### The ring

The missile display (window 2) shows the player's missiles in a ring (`hud_missile_ring`,
`0x00501CC8`), ten entries of five halfwords, and the armed entry (`hud_missile_armed`,
`0x005656B0`):

| Halfword | Field |
|---|---|
| 0 | Missiles left, -1 for no entry |
| 1 | Where it stands round the ring, 0 the armed one at six o'clock |
| 2 | The first of its type's ten shapes in the display's set; the shape drawn is this and its place |
| 3 | Its name's text |
| 4 | Its type |

`hud_missile_ring_build` (`0x00484060`) builds it as a mission starts and after each re-arm: an
entry for each type the player's racks hold, but the fuel pod, in the order the racks first come,
with the missiles of all its racks. The middle entry is armed; each entry's place is the armed
entry's index less its own, and ten more below 0. `player_missiles_left` (`0x0052A400`) sums the
counts, and nothing reads it.

| Type | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|---|
| First shape | `0x56` | `0x4C` | `0x24` | `0x42` | `0x1A` | `0x6A` | `0x60` | `0x38` | `0x2E` |
| Name | `0x124` | `0x123` | `0x121` | `0x11E` | `0x127` | `0x126` | `0x125` | `0x120` | `0x122` |

The table's own words, overwritten before anything reads them, hold a test ring of four halfwords
an entry.

Outside a multiplayer game, ROTATE MISSILES CLOCKWISE and ANTICLOCKWISE (`hud_target_keys`,
`0x0048B6B0`, once a press) open the missile display held and turn the ring:

- clockwise, where the entry after the armed one is live, every live entry moves one place on, 9
  coming round to 0, and the one reaching 0 is armed;
- anticlockwise, where the armed entry is not the first, every live entry moves one place back, 0
  going round to 9, and the one reaching 0 is armed.

The ring doesn't wrap: the keys walk from the first entry to the last. Where it turned,
`MISSILESELECT` (3D sound `0x4B`) sounds at the player's ship and the display beeps (`hud_beep` 0);
where it could not, the display refuses (`hud_beep` 3). Then, where the armed entry is live, Betty
says its name, ending the name she said last (`missile_name_voice`, `0x00566660`):

| Type | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|---|
| `betty.fat` sound | 2 | 8 | 3 | 4 | 7 | 5 | 10 | 6 | 9 |

`0x0057BF3C` counts 150 ticks from each name, and nothing reads it. A turn loses the lock, which
began on the type armed before ([The lock](#the-lock)).

In the view ahead, `hud_window_draw` draws the window (`0x00486E8F`): for each live entry in the
ring's order, the armed one's count at `(-1, 0x43)` and its name at `(0, 1)` from the window's
place, both centred in the display's font; and each one's shape, its first shape and its place, at
`(0, 0x47)`, the shapes standing round the ring by their own offsets.

### The player's

LAUNCH MISSILE (`player_controls`, `0x00413BE7`, once a press) runs `player_launch_missile`
(`0x00412820`). Nothing happens while the ship's missiles are disabled or it jumps. Then, by the
armed type:

1. A Raptor, Havoc, Jack Hammer, Bandit, Vagabond, Imp or Hawk needs the lock to hold. Without it
   the display refuses (`stdsmp` 1), and where the armed entry has none left, Betty says so (sound 0
   of `betty.fat`), no more than once in 500 ticks; nothing more. A Screamer and a Solomon need no
   lock.
2. A cloaked ship outside a multiplayer game drops its cloak instead.
3. The missile display opens, held. With none of the armed type left, Betty says so.
4. The first rack of the armed type with a missile left launches one, at the ship's target while the
   lock holds, else at nothing, and the armed entry counts one off.

In a multiplayer game a missile is a power-up; and the Kamov of mission 25 lets the craft it
carries go instead. The right mouse button launches too, in the mouse's mode.

COUNTERMEASURES (`0x00413E80`, once a press), outside a mission's ending: with none left Betty says
so (sound `0xF`), and with 6, 4 or 2 left she warns they run low (`0xD`); then
`object_spend_countermeasure` ([Countermeasures](#countermeasures)).

A cloaked ship uncloaks in place of the launch ([The cloak](cloak.md#who-cloaks)).

OpenReliant reads both in `input.playerWeapons`, after the throttle's keys, and the right mouse
button after LAUNCH MISSILE. Not ported: the Kamov, and the multiplayer game's power-up.

### The lock

The player's lock is `main.cpp`'s, by where its code lies: `hud_missile_lock` (`0x00491520`), once
a frame from `mission_frame` while the view is one of the cockpit's or the chase view, and while the
player's ship has its Player Control order. `lock_rings_init` (`0x004911D0`) clears it as a mission
runs.

A lock is possible (`missile_lock_possible`, `0x00491350`) while:

1. the armed entry has missiles left, or a missile the player launched still flies at a target
   (`player_missile_guiding`, `0x004AF190`);
2. it is not a Solomon's;
3. the target is one to aim at, and the player's missiles are not disabled;
4. outside a multiplayer game, the target is hostile and the missile not a Screamer;
5. the target's node lies within the type's lock range of where the ship goes next, and within 0.7
   of the ship's nose.

`missile_lock_same` (`0x004914D0`) asks that the target, its component and the armed type are those
the lock began on, so turning the ring loses it.

| State (`0x0057DFF0`) | Each frame |
|---|---|
| 0 idle | The count (`missile_lock_count`, `0x0057DFBC`) at 100. Where a lock is possible, it begins: the target and the type kept, the ticks (`0x0057DFEC`) at minus the type's lock time, the rings' turn (`0x0057E000`) at 0 |
| 1 closing | While possible and the same, the count down and the ticks up by the frame's ticks; at 0, to 2. Otherwise lost |
| 2 waiting | Likewise the ticks up; at 0, to 3 |
| 3 locked | Likewise the ticks up |
| 4 | Nothing sets it; taken as lost |
| 5 lost | The count up and the ticks down; past 99, to 0 |

As a lock is lost, ticks it had counted past the lock go to the rings' turn. So a lock takes 100
ticks for the rings to close, and holds the type's lock time after it began, whichever is longer.
`0x0057DFE8` counts too, but nothing reads it.

The rings (`lock_rings`, `0x0057DFF4`) are three scene objects on one square 256 across
(`lock_ring_mesh_create`, `0x00491080`), each over a quarter of `tarring`, lit by their own colours
and added over the overlay's layer. In every state but 0, outside view 13:

- They stand on the line from the camera to the target's node (kept while the lock holds, and
  left as it was once lost), as far out as the screen's scale across over its width, times 2560,
  times what the count is short of 100 in hundredths: so they close in from the camera onto the
  target as the count runs down.
- They face the camera, turned about its axis by the turn kept in degrees, and before the lock the
  first by up to a radian to and fro at one and a half times the ticks in degrees, the second by up
  to 0.6 at two and a half times, the third a degree a tick; once locked, all three a degree a tick.
- They are drawn at 0.7 of their size times 1.33, 1.11 and 1, drawing together over the last 50
  ticks before the lock, and as one once locked.
- Their colour is 0.65 of dark red `(0.5, 0, 0)`, whitening over the last 50 ticks before the lock.

**Improvement:** the game turns the degrees into radians by 0.0174533 (`0x004DC71C`); OpenReliant
converts them exactly. It also divides by the 50 ticks where the game multiplies by 0.02
(`0x004DC940`) and -0.02 (`0x004DC944`).

Once locked, in the view ahead from the cockpit, `hud_draw` plays the locked tone (`stdsmp`
`0x15`, twice over) and holds its voice (`missile_lock_tone`, `0x00566644`); out of that view, or
once the lock is lost, it ends the voice, whatever plays on it by then. The pause menu ends it too.

**Fix:** `hud_missile_lock` means to play `stdsmp` 2 while the rings close and end it after, keeping
the voice at `0x0057DFC0`; but nothing sets that to none first, so the sound never plays, and the
game ends the first voice every frame instead, cutting what plays there. OpenReliant leaves that
voice alone, and the sound unplayed.

The target's brackets are drawn at the count's hundredths of their brightness
([The target](hud.md#the-target)).

### The AI's missiles

`fight_fire` (`0x004096B0`), after the guns, each update of the Fight order, unless the ship is
cloaked:

1. The missile ready flag (`FightState + 0x2F`) is cleared.
2. The first rack with missiles left, but a Jack Hammer's, is the only one looked at. Where the
   target's node lies beyond the type's lock range, or outside 0.7 of the ship's nose, the lock
   starts again: `locked_at` is the type's lock time from now. Once `locked_at` has passed, the
   missile is ready. Ready, once the pilot's wait for the next missile (`missile_at`) has passed,
   one time in five it launches one at the target; either way the wait is drawn again (from the
   pilot's `missiles` range), the lock starts again and the missile is no longer ready.
3. Not ready, the wait is drawn again: so it runs down only while the lock holds, which is
   seldom, for four to sixteen seconds by the pilot.
4. With no missile homing on the ship, the wait for a countermeasure is held at the pilot's least;
   with one, once the wait has passed, it is drawn again and a countermeasure dropped.

`order_fight_init` leaves `locked_at` as the order's state starts it, at 0, so a fresh Fight
order's lock is ready as soon as its target is in reach. The AI locks Screamers and Solomons, and a
ship with its missiles disabled still locks, lighting the player's enemy lock, though
`missile_launch` refuses it.

Orders 2, Launch Missile (`order_launch_missile`, `0x0040B940`), and 3 (`0x0040B990`, which the
game names nothing), both run once over the ship's orders, launch a missile at their target from
the first rack with missiles left: of any type but the Jack Hammer, and a Jack Hammer.

### A missile turret's

A missile [turret](guns.md#each-frame) (`turret_missile_step`) tracks what it finds ahead and
launches one time in five each time its wait is over, six before it reloads. `missile_launch_turret`
(`0x004967F0`) launches a Screamer from its launcher, where the turret's object may launch missiles
and a record is free. The Screamer is built as a Screamer pod's missile (attachment kind 0, id 0's
second model), of the object's side, and starts where the launcher stands: at its committed place,
its next, and its frame, at the object's velocity. It lays its trail, flies the pod launch and then
its guidance, at the turret's target. No sound is played.

### The missile camera

MISSILE CAMERA switches to view `0x12` on the player's ship. `camera_set_view` steps
`camera_missile` (`0x00539A94`) round the records from the one it last followed to the next live
missile that ship launched, refusing the view with none. `camera_frame` then keeps behind that
missile, as the chase view does but 800 back and 400 more at full throttle, 300 above, easing
toward its swings a two hundredth of the way each frame, and rolling with a twentieth of its yaw
too. Once the missile ends (`0x00539A7C`), the camera holds still for 150 ticks and goes back to the
cockpit. A mission's script starts it too (`StartMissileCam`).

