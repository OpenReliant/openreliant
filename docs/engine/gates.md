# Gates

The gates' tunnels, which ships jump through (`wgate.cpp`, `0x0041DD70` to `0x00423228`). A
Coalition gate stands with a tunnel open in it from the start, and Fixed Gate Open grows one at
any object, a nav point among them. A ship goes out through a tunnel with Fixed Gate Jump Out, the
player's riding the worm, and comes in through another with Fixed Gate Jump In; Fixed Gate Close
shrinks a tunnel away, and Fixed Gate Collapse brings a gate down. The Boridin breakaway projects
a tunnel of its own with Start warp projection from Boridin.

## In OpenReliant

[`game/wgate.zig`](../../src/engine/game/wgate.zig) holds the gates' state, their records and
the five orders; [`game/wgate/tunnel.zig`](../../src/engine/game/wgate/tunnel.zig) builds, shapes
and colours the tunnels and the jumps' flashes, and
[`game/wgate/worm.zig`](../../src/engine/game/wgate/worm.zig) the worm. `create.gateMade` sets the
Coalition's gates up ([`game/create.zig`](../../src/engine/game/create.zig)). A mission's start
lets every tunnel go.

[`game/wgate/warp.zig`](../../src/engine/game/wgate/warp.zig) implements Warp In and Warp Out,
with their independent tunnels, projector beams and particles, and
[`game/wgate/projection.zig`](../../src/engine/game/wgate/projection.zig) the Boridin breakaway's
projection.

Not ported: the collapse's second passes on the parts of models a gate carries, which the game's
walk of its nodes reaches too ([#540](https://github.com/OpenReliant/openreliant/issues/540)). No
shipped gate carries a model.

**Improvements**, which `--original` turns off:

- A tunnel is built four times as finely round and along, its rings a quarter as far apart so that
  it keeps its length. Its radii and depths follow the game's curves between the game's rings, so
  that it is round and its rings' wave smooth; its sway and its colours run between the game's
  vertices', as the game's are drawn between them.
- The ride through the worm has its chance to rumble once for each of the simulation's steps, 25 a
  second, rather than each frame, so that it rumbles as often whatever the frame rate: as the game
  does at 25 frames a second.

**Fixes**, each marked so in the code:

- Where an order names an object with no tunnel, the game reads the record before the first as one,
  whatever it holds; OpenReliant logs it and ends the order.
- Jump Out cuts the ship by the portal of the tunnel it goes through. The game cuts it by the
  portal of the gate its order names, which Jump In goes through next.
- The game turns a ship being drawn down the tunnel toward the angles of a matrix it never fills,
  whatever the stack holds there; OpenReliant leaves it turned as it is.
- The game makes the worm anew for each of the player's jumps out and never lets the last go;
  OpenReliant lets it go.
- The collapse's fireballs go off at the points of the hull's cut list by number, and the game reads
  past the list's end where a number lies beyond it, as the advanced gate's `OuterRing` does for its
  55 fireballs; OpenReliant counts on from the list's start again.
- The collapse's burn and fade write each colour to the vertex before its own, lighting the last
  vertex of the mouth's black rim and blacking out one of the ring before the last; OpenReliant
  writes each vertex's own.

**Improvement:** the sines and cosines come from `std.math` rather than the engine's tables, and a
segment's turn round the axis from `std.math.tau` over the segments, where the game multiplies by
6.2831855 (`0x004DC3EC`) and by one over the segments (`0x0051D130`).

## Time

The gates count their time in thousandths of the timer's ticks (`0x004DC418`): a tick is a
hundredth of a second, so that a rate of 1 runs from 0 to 1 in 10 seconds. Open and Close count
from the tunnel's last frame (`+0x0C`), the jumps from the order's last update (`+0x08`). The
ticks since a record's tick are taken unsigned, those since an order's update signed.

## The records

`0x0051D1A4` holds 32 records, each flagged in use in `0x0051D224` and allocated `0x88` bytes by
`0x0041FE60`:

| Offset | Field |
|---|---|
| `0x00` | Kind: 0 a warp's tunnel, 1 a fixed gate's while no advanced gate is among the objects, 2 while one is, 3 the Boridin's (`Wboridin_Mesh`, with two beams), which nothing makes |
| `0x08` | The frame's tick it was made on |
| `0x0C` | The tick of the last frame that drew it |
| `0x10` | The tick its texture last scrolled on, 0 until it has |
| `0x14` | The object it stands at |
| `0x18`, `0x1C` | A warp's size, and how much deeper every vertex of the tunnel stands, by the object's type for any kind (`0x00423020`, table `0x004E3F38`): a Badanov's 10000 and 15000, a Yamato's 50000 and 100000, and 2000 and 0 for any other type |
| `0x2C` | Set where the object's type is in that table |
| `0x20` | How far Open or Close has grown or shrunk it |
| `0x30` | Each ring's radius |
| `0x34` | The tunnel, whose frame hangs from its object's |
| `0x70` | The portal, whose frame hangs from the tunnel's |
| `0x74`, `0x78` | The two flashes a ship jumping in shows (`Wprotogate_Mesh1`, `Wadvgate_Mesh1` and the rest) |
| `0x7C` | Each ring's depth, the third of three floats |
| `0x80` | A list of ships that dent the tunnel as they pass (`0x00422540`), which nothing fills |
| `0x84` | Set while a ship comes through it, until it is half way |

`0x00420920` finds the first record at an object; `0x00420830` lets a record go. The gates' start
with each attempt at a mission (`0x0041E280`, from `0x004AD0A0`) takes the grid by the options'
detail and the textures, and clears the records; their end (`0x0041E4A0`, from `0x004AD260`)
lets them go.

## The tunnel

A tunnel (`0x0041DD70`, `Wgate_Mesh`) is a funnel of rings round its Z axis, each a ring of
vertices after a centre vertex, two triangles for each segment between two rings:

| Detail | Segments | Rings |
|---|---|---|
| Low | 9 | 6 |
| Medium | 12 | 8 |
| High | 16 | 12 |

A gate's tunnel is 344 or so times its size across at the mouth, each ring a sixth narrower than
the last: `80 * 1.2^(8 - ring)` times the size, 70 for a proto gate's tunnel and 40 for an advanced
gate's, 70 again in mission 8. The game works it out as `10 * 8 * 1.2^8 / (1.2^rings * rings)`
times `1.2^(rings - ring) * rings * size`, in double precision.

It is drawn with `warp128` (`ddwarp128` without a hardware renderer), added, by coordinates of its
own: `u` a unit along for eight rings, and `v` the vertex's height across a warp's tunnel's radius
in thousandths. A hardware renderer draws all but its last band in two passes, the second a
highlight texture by its normals, 7 for a proto gate's and 0 for an advanced gate's. Its object
takes colours of its own (`0x0041D7D0`): its mouth's ring and its last are black and clear, and
the ring before the last its deep colour; between them a hardware renderer's run in a straight
line from the mouth's colour to the middle's over the first 0.3 of the rings, then to the end's by
the square root:

| Tunnel | Mouth | Middle | End | Before the last |
|---|---|---|---|---|
| Proto gate (blue) | (0.92, 0.92, 0.66) | (0.2, 0.43, 0.77) | (0.05, 0, 0.31) | (0.12, 0.06, 0.63) |
| Advanced gate (red) | (1, 1, 0.86) | (0.77, 0.43, 0.2) | (0.31, 0, 0.05) | (0.63, 0.06, 0.12) |

A software renderer's run from white to black, the ring before the last a mid grey.

Each frame the gates' frame (`0x00420A00`), which `shield_bubbles_draw` runs before the bubbles,
works on each record of a fixed gate:

1. Each ring stands `ring * 1500 + sin(ring + time) * 300` deep, its time since it was made.
2. Each vertex stands at its ring's radius and depth, the last ring at the depth of the one before,
   and the record's `0x1C` deeper (`0x0041FA50`). At the high detail each sways across and down by
   up to 41.7 times the segments, at its own pace by the frame's tick.
3. Its normals, its bounds and its radius follow.
4. Its portal goes into the world's layer, and the tunnel too, unless the player's ship rides the
   worm.

As it is drawn, its texture scrolls by its time, 3.5 across and 0.6 along (`0x00420950`, its
object's hook at `+0x170`).

OpenReliant places the tunnel and its portal from where the gate's object is drawn, where the
game hangs their frames from it.

## Warps

Warp Out (5) and Warp In (4) use an independent tunnel for each ship, rather than a fixed
gate's tunnel. Their shared order state stores the step at `0x04`, an orientation at `0x0C`
and the saved position at `0x3C`.

Warp Out (`0x0041E550`, `0x0041E710`) clears the steering controls and uncloaks player slots.
The ship aligns with its target. The player faces it immediately and marks objects in a
500000-unit corridor ahead as jumping; other ships steer until their inputs and turn rates
are within 0.05. The projection sound plays and the player's camera takes view 9.

The order creates a kind-0 record, saves the departure frame and freezes the ship. Four beams
connect its warp projectors to two counter-rotating endpoint frames. Each beam is red, clear at
the projector and as bright as the effect at the far end: it has colours of its own, and its
material uses them (it is lit) and adds by their alpha (`0x0041D41A` to `0x0041D448`). Point group
10 supplies the origins; the Yamato uses four points on `Yam_Warp_Proj_3`. Without projector
points, the origin is 300 units ahead of the ship. Each beam has a cap and three blades, 110 units
wide on either side. Its endpoints stream particles with a 120-tick life.

The opening depth follows square-root easing. Ring spacing is 900 units for ships without
components and 4000 for ships with them. Rings start updating once the depth exceeds 800.
Their radii grow from five percent of the ship type's warp size to its full size. The
extension then moves the rings along the tunnel. At entry, the portal clips the ship,
the departure sound plays and the player's camera holds view 10. The ship moves forward
while the tunnel fades. Fighters stretch along their drawn Z axis between progress 0.2 and
0.6, without changing their flight orientation. The order hides the ship and queues Warp In at its target, keeping
the sequence number. A self-targeted departure ends without an arrival.

Warp In (`0x0041E5C0`, `0x0041F260`) stops the ship and uses the target's orientation. The
sequence spreads arrivals along the target's X axis: 0, -3000, +3000, -6000, +6000. It
reuses the departure record where one exists, resets its colours and reverses the tunnel.
The player takes camera view 11, clears jumping flags and updates the environment. The
arrival sound plays. At high detail the ship starts 20000 units behind its arrival point,
hidden (15000 units at lower detail), and becomes visible at progress 0.4. Other ships accelerate at throttle 2; the
Yamato moves explicitly while frozen. After the emergence and final wait, the tunnel is
freed, collision and motion flags are restored, the player returns to the cockpit and
JumpedIn is posted.

The existing fine-tunnel setting applies to warps too. `--original` uses the original grid.
**Fix:** a missing record or allocation failure ends the order and releases its frozen flags
instead of leaving the ship stuck.

## The Boridin's projection

Start warp projection from Boridin (38), which mission 28 gives the Boridin breakaway, projects a
warp tunnel ahead of the ship from its projector, the part `Bor brkawy proj ` (its name ends in a
space). The order never ends.

Its init (`0x004230A0`) keeps the tick it began, makes the projection anew (`0x0051D140` to
`0x0051D190`, which the gates' end lets go), and lets go of the ship's controls. The projection
holds:

- Six beams (`WProject Mesh`), built and drawn as Warp Out's are ([Warps](#warps)) but 1400 wide
  on either side, never culled, and coloured by their own colours: red and opaque at the far end,
  clear at the near one.
- At each beam's end, an emitter of large warp particles (`warp_large_particles`, `0x0051D138`):
  Warp Out's particles, from 1000 across down to 500, sent back along the world's Z axis at 100 a
  tick and up to 20 more, straying up to 0.15 either way.
- A tunnel built as an advanced gate's ([The tunnel](#the-tunnel)), of size 240 where the gates'
  are 40 or 70.

Each update (`0x00423230`), a spread eases in from 0 to 2500 over the first 500 ticks. Then, from
where the projector stands:

1. Beam `n`, from 0 to 5, runs from point `n` of the projector's warp projector list
   ([point list](../formats/shp.md#point-list-tags-0x0d-0x0e) kind 10) to its end: `(n + 1) * 8571.429` out along the projector's X axis and
   `(5 - n)² * spread + 75000` along its Z axis, turned about Z by `n` sixths of a turn and by the
   sway, the odd beams the other way. The sway is `sin(tick * 0.005) * 0.7π`. The beam's emitter
   streams from its end.
2. Each beam shows nine frames in ten, each by a roll of its own.
3. The tunnel stands at the projector, its ring `r` at `r² * spread + 44000` along the projector's
   Z axis, coloured as an advanced gate's tunnel. Nine frames in ten, its first six rings are lit
   by the beams' ends, ring `r` by beam `r`'s, and the rings after them are dark: each vertex of
   ring `r` keeps all of its colour up to 33333 from the end, less of it further off, and none from
   50000 on. On those frames its texture scrolls by the time since the last update, as a gate's
   tunnel's does ([The tunnel](#the-tunnel)).
4. The tunnel shows nine frames in ten.

**Unverified:** that the update, just past the file's known code, is the file's, as its init is.

**Fixes:**

- The init stops the game with an assertion ("Error in Boridin Warp Project AI") where the ship is
  no Boridin breakaway; OpenReliant logs it and goes on.
- The game makes the projection anew for each Start warp projection from Boridin without letting
  the one before go; OpenReliant lets it go first.
- The update takes the projector and six of its points for granted: the game fails where the model
  has no projector or the projector lists no points, and reads past the list's end where it lists
  fewer than six. OpenReliant does nothing where the projector or its points are missing, and the
  beams past the list's end leave from its last point. The shipped model lists six.

**Improvement:** the sway's sine comes from `std.math` rather than the engine's table, and the
turns are π/3 and 0.7π, where the game multiplies by 1.0471976 and 2.1991148.

## The Coalition's gates

`create_object` sets the Coalition's gates up (`0x00467D2B`, `0x0046823A`). A prototype (type
`0x6D`) has a proto gate's tunnel at the middle of the first two points of the door list of its
part 1, where that part stands from the one it hangs from; its power core
(`Protogate Power core`) burns for good with steady rays alone, and each of its parts plays its
`Rotate End` track. An advanced gate (type `0x6E`) has an advanced gate's tunnel at its part 6's,
and each part plays `Rotate Inner` at four times the pace, then `Rotate End`.

## The portal

A jump sets the portal up (`0x0041FDF0`): it faces along the tunnel's axis, at ring `rings - 5`
as the tunnel stands then. A ship going through is cut by it (`node_tree_clip`, `0x004ADEE0`):
only what lies on the tunnel's mouth side of the portal shows.

## Open and close

Fixed Gate Open (28) makes a tunnel at the object (`0x004218A0`), an advanced gate's where one is
among the objects and a proto gate's otherwise, and it is heard (`gateopen`). It grows from 0.0001
of its size, easing in and out, over 1.1 seconds (`0x00421940`), then the order ends.

Fixed Gate Close (29) is heard (`gateclos`, `0x00421920`), shrinks the tunnel likewise, then lets
it go (`0x00421A00`).

## Jump in

Fixed Gate Jump In (25, `0x00420B80`) brings the ship in through the tunnel at the object its order
names. It comes from 18000 deep and 2000 above the axis for the player's ship, 26000 deep for the
rest, to 53000 out beyond the mouth for a friend, 25000 for the rest, turned about the axis by 0.3
for each step of the spread (`0x004E3F68`). The spread starts at -2 and runs on to 2, then back to
-2, passing over 0 but for the player's ship, which sets it to 0. The ship faces the way it goes,
its lights' sprites hidden (`0x00423050`), unpowered, frozen and untargetable, colliding with
nothing where it lists no components, and goes in a straight line.

Its update (`0x00420FD0`) waits while another ship comes through the tunnel, save for the player's
ship. Then it holds the tunnel, the flashes stand at the portal's ring, and the ship starts where
it comes from, heard (`warpin`); for the player's ship the mission's space takes on what its script
asked of it (`environment_update`). It goes to where it goes over 5 seconds, letting the tunnel go
half way. Over the first fifth of the way, while the player's ship does not ride the worm, the
flashes show (`warpin3`, 25000 across): the first shrinking from 12500 either way as it brightens,
the second growing to it as it dims, each by the square of how far through. Then the ship is
powered, collides and can be targeted again, its lights' sprites show, the portal lets it go, and
the order ends; its FixedGateJumpedIn is posted with the gate's ship (`event_fixed_gate_jumped_in`,
`0x0045ABD0`).

In missions 16 and 66 the Krasny (type `0x9A`) comes out straight ahead, leaving the spread as it
is, at 0.13 rather than 2, with no flashes.

### The Krasny's split

A Krasny a third of the way through a gate (`0x004DC614`) splits where a collapse has caught it
(`0x0051D13D`, set by the collapse's start below). It is logged ">>>>>>Splitting the Krasny at
%d", and the split (`krasny_split`, `0x00422CA0`) runs:

- The screen flashes.
- Its jump ends as above, its FixedGateJumpedIn posted, though its lights' sprites stay hidden.
- It is unpowered and exploding, turning slowly by `(-4e-05, 2e-05, -0.0013)` a step and drifting
  on at `(0.2, 0.14, 40)` a step in its own frame.
- Of its parts only `bad front slice` shows, and it loses its shield generator.
- Every advanced gate's collapse moves on to its third step, the fade, from the start.
- The slice burns for 5000 ticks, flickering, with its lights and smoke
  ([Burning wrecks](effects.md#burning-wrecks)).
- At each of the slice's cut points, three burning bits head back along the ship, turned at random
  by up to 0.3 about each axis, a body three times in ten, and a lit fireball 1500 across goes off,
  each 10 ticks after the last.
- The gate becomes its last attacker, and the ship is lost (`object_hull_lost`).

A Krasny a third of the way through that no collapse has caught is logged ">>>>>>Did not take out
gate in time to split Krasny at %d", once in OpenReliant where the game logs it every frame, and
from then on no collapse can catch one (`0x0051D134`). A mission's start sets both flags back.

## Jump out

Fixed Gate Jump Out (26, `0x00420DD0`) takes the ship out through the nearest gate's tunnel,
whatever its order names: its inputs, its rates and its speed at nothing, colliding with nothing,
frozen, unpowered and untargetable, going to 12000 down the tunnel for the player's ship and 26000
for the rest. The player's ship's worm is made.

Its update (`0x00421510`) waits while another ship goes out, then the ship is drawn toward where it
goes, a growing share of the rest of the way each frame, until it is within 400. Then it is gone to
its slot times a million along X and 25 million back along Z. The player's ship rides the worm
(`0x0051D13E`), which stands where it does, turned as it is, and the screen flashes. While it rides,
the worm sways, its texture scrolls, and each frame, one time in 40, the view shakes and flashes and
the ride rumbles (sound 10 of `bank_stdsmp`, as loud as 2000 times the ship's radius). The ride lasts
4 seconds. Then the player's ship leaves the worm, flashing and shaking, the tunnels are free, the
ship is powered and collides again, the portal lets it go, and its order gives way to Fixed Gate
Jump In through the gate it named.

The worm (`0x00422700`, `Worm_Mesh`) is a tube of 31 rings, 16 segments round, 10000 across and
200000 apart, drawn solid with the gates' texture, with a highlight added by its normals, coloured
as a proto gate's tunnel over its rings (`0x00422AD0`). As the ship rides it sways by up to 2000
(`0x004229B0`), and its texture scrolls 10.5 along it and 0.5 across.

## Collapse

Fixed Gate Collapse (31, `0x00421AC0`) is logged ">>>>>>Starting gate collapse at %d"; a proto
gate's hull (`Protogate`) burns with flickering rays alone, for a while, and the screen flashes. In
missions 16 and 66, where a Krasny is coming through a gate in time, the collapse catches it
([The Krasny's split](#the-krasnys-split)). Its update (`0x00421B80`), counting from the tunnel's
last frame:

1. Over 10 seconds, 55 fireballs go off at the points of the hull's cut list in turn (`Protogate`,
   or `OuterRing` for any other gate), each 5500 to 8500 across and lit, every seventh heard
   (`explosion02`). Past the end of the list, OpenReliant counts on from its start again. Each frame the second passes of the gate's type's meshes go off at random, 0.3
   of the frames (`0x00422680`). Then they go off for good, and the screen flashes.
2. Over the first fifth, its rings slow to a stop: a proto gate's `forcering` from 1, an advanced
   gate's `InnerRing` from 4 and `Tube11` from 1. One frame in 20 a fireball 3500 to 4500 across
   goes off at a random point among the first 56 of the cut list, counted on from its start again
   past its end. The tunnel burns out (`0x00422380`): a flickering
   share of its vertices take a dull red, the ring before the last blue, brightest where the share
   has just reached them. The gate shakes by 15 along each axis at random, unpowered. A proto
   gate's step lasts 20 seconds, any other's 40, its tunnel burning twice as fast. It lasts on
   while a Krasny the collapse caught is still coming through, until the Krasny splits.
3. The tunnel fades (`0x004221E0`) over 1.7 seconds: its vertices take a pale grey, the ring
   before the last green, by the same reach.
4. It is logged ">>>>>>Gate fully collapsed at %d"; any gate but a proto gate lets its tunnel go,
   an advanced gate losing its hull (`object_hull_lost`), and a gate's `forcefield` is hidden.

The wipes reach a share of the vertices counted from the tunnel's first ring. The game writes each
colour to the vertex before its own; OpenReliant writes each vertex's own.
