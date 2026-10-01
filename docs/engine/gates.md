# Gates

The gates' tunnels, which ships jump through (`wgate.cpp`, `0x0041DD70` to `0x00423228`). A
Coalition gate stands with a tunnel open in it from the start, and Fixed Gate Open grows one at
any object, a nav point among them. A ship goes out through a tunnel with Fixed Gate Jump Out, the
player's riding the worm, and comes in through another with Fixed Gate Jump In; Fixed Gate Close
shrinks a tunnel away, and Fixed Gate Collapse brings a gate down.

## In OpenReliant

[`game/wgate.zig`](../../src/engine/game/wgate.zig) holds the gates' state, their tunnels, the
worm and the five orders; `create.gateMade` sets the Coalition's gates up
([`game/create.zig`](../../src/engine/game/create.zig)). A mission's start lets every tunnel go.

Not ported: the warps' tunnels (kind 0, Warp In and Warp Out, orders 4 and 5), with their
particles and beams ([#481](https://github.com/vdmkenny/openreliant/issues/481)); the Boridin's
projection (kind 3, order 38) ([#30](https://github.com/vdmkenny/openreliant/issues/30)); and the
Krasny's split in missions 16 and 66 ([#407](https://github.com/vdmkenny/openreliant/issues/407)).

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

## Time

The gates count their time in thousandths of the timer's ticks (`0x004DC418`): a tick is a
hundredth of a second, so that a rate of 1 runs from 0 to 1 in 10 seconds. Open and Close count
from the tunnel's last frame (`+0x0C`), the jumps from the order's last update (`+0x08`).

## The records

`0x0051D1A4` holds 32 records, each flagged in use in `0x0051D224` and allocated `0x88` bytes by
`0x0041FE60`:

| Offset | Field |
|---|---|
| `0x00` | Kind: 0 a warp's tunnel, 1 a fixed gate's while no advanced gate is among the objects, 2 while one is, 3 the Boridin's |
| `0x08` | The frame's tick it was made on |
| `0x0C` | The tick of the last frame that drew it |
| `0x10` | The tick its texture last scrolled on, 0 until it has |
| `0x14` | The object it stands at |
| `0x18`, `0x1C` | A warp's sizes, by its ship's type (`0x004E3F38`): 2000 and 0 for a gate |
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
2. Each vertex stands at its ring's radius and depth, the last ring at the depth of the one before
   (`0x0041FA50`). At the high detail each sways across and down by up to 41.7 times the segments,
   at its own pace by the frame's tick.
3. Its normals, its bounds and its radius follow.
4. Its portal goes into the world's layer, and the tunnel too, unless the player's ship rides the
   worm.

As it is drawn, its texture scrolls by its time, 3.5 across and 0.6 along (`0x00420950`, its
object's hook at `+0x170`).

OpenReliant places the tunnel and its portal from where the gate's object is drawn, where the
game hangs their frames from it.

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
gate's hull (`Protogate`) burns with flickering rays alone, for a while, and the screen flashes.
Its update (`0x00421B80`), counting from the tunnel's last frame:

1. Over 10 seconds, 55 fireballs go off at the points of the hull's cut list in turn (`Protogate`,
   or `OuterRing` for any other gate), each 5500 to 8500 across and lit, every seventh heard
   (`explosion02`). Each frame the second passes of the gate's type's meshes go off at random, 0.3
   of the frames (`0x00422680`). Then they go off for good, and the screen flashes.
2. Over the first fifth, its rings slow to a stop: a proto gate's `forcering` from 1, an advanced
   gate's `InnerRing` from 4 and `Tube11` from 1. One frame in 20 a fireball 3500 to 4500 across
   goes off at a random point of the cut list. The tunnel burns out (`0x00422380`): a flickering
   share of its vertices take a dull red, the ring before the last blue, brightest where the share
   has just reached them. The gate shakes by 15 along each axis at random, unpowered. A proto
   gate's step lasts 20 seconds, any other's 40, its tunnel burning twice as fast.
3. The tunnel fades (`0x004221E0`) over 1.7 seconds: its vertices take a pale grey, the ring
   before the last green, by the same reach.
4. It is logged ">>>>>>Gate fully collapsed at %d"; any gate but a proto gate lets its tunnel go,
   an advanced gate losing its hull (`object_hull_lost`), and a gate's `forcefield` is hidden.

The wipes count a vertex from the tunnel's centre, a vertex short of its ring's own.
