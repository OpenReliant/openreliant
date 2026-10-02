# Jumps

Ships come and go by jumps (`jump.cpp`). Jump Out, orders 20 and 41, takes a ship away:
`order_jump_out_init` (`0x00416D50`) readies it, and `order_jump_out` (`0x00416E00`) runs it an
update at a time. Jump In, orders 19 and 40, brings a ship in beside an object: `order_jump_in_init`
(`0x00416540`) and `order_jump_in` (`0x00416570`). [`jump.zig`](../../src/engine/game/jump.zig)
holds the four. They are `jump.cpp`'s by the assertion `order_jump_in` makes with its path
(`0x004165EC`), which [the source map](../binary/sources.md) misses, as it lies in a case of a switch
([#310](https://github.com/OpenReliant/openreliant/issues/310)).

A mission's script gives the jumps with `SetAI`, most often to a flight group or a squad, each ship
numbered in turn among them ([Orders](orders.md#the-stack)): that number places it among the ships
that jump with it. JUMP DRIVE, once the mission has a jump ready, posts PlayerReadyToJump
([Script VM](script-vm.md#events)), whose trigger has the script give the player's wing its Jump
Out. Outside training, where the pilot waits, Moose calls four times on the radio, and then the
ship jumps as though the key were pressed ([Remarks](radio.md#remarks)). `WaitForJumpOrLaunch` holds a script's thread while a ship it names is on a jump
([Launches](launch.md#how-a-launch-is-given)).

The two orders share a state (`JumpState`):

| Offset | What it holds |
|---|---|
| `+0x04` | The step |
| `+0x08` | The frame's tick the step began, from which the motions count |
| `+0x0C` | Where the ship goes: Jump Out's destination, Jump In's arrival |
| `+0x18` | How it is turned: Jump Out's as it begins to charge, Jump In's its target's |
| `+0x3C` | Where it stood then |
| `+0x50` | The frame's tick of the last update |
| `+0x54` | How far through its step it is, from 0 to past 1 |
| `+0x58` | How many lights its effect has (`jump_effect_start`), which the lights' sweep along the hull reads |
| `+0x5C`, `+0x68` | Where Jump Out's motion takes it from and to |
| `+0x74` | The motion it puts aside while it flies a jump's own |
| `+0x78` | Its effect record ([What a jump shows](#what-a-jump-shows)) |
| `+0x7C` | Whether it jumps out with the player's ship |

Each update adds to the progress at `+0x54` the ticks since the last update times 0.001 times the
step's rate, and holds the ship's Nova Cannon's charge at nothing.

## Jump Out

`order_jump_out_init` lets the ship's throttle go, places it for its jump (below), and sounds
`jumponline` (sound `0x1D`) from it, among the player's own sounds for the player's ship. For the
player's ship the camera switches to view `0x27`, held ([Camera](camera.md#the-jumps-views)). The
ship of a player uncloaks ([Cloak](cloak.md)).

`jump_out_place` (`0x004184F0`) places it. Where the player's ship's current order is Jump Out and
names the same target by its index, the ship goes with it, in formation: it collides with nothing,
and the target, or 100000 ahead of the player's ship where the order names nothing or the player's
ship, is where it goes. It is turned to face it from the player's ship, and stands in row `r` of the
formation, `r` times 3000 behind the player's ship, which holds `r` ships abreast, 6000 apart and
centred on the player's line; the order's number counts through the rows from the first, which holds
one ship, up to nine rows. It is stopped, and set flying 150 ahead, its throttle what that is of its
cruise speed. The player's ship takes its place so too, by its own number: the first, 3000 back from
where it was. Each object the ship's way crosses within 500000 ahead of it (`segment_meets_box`),
but those on the same jump, stand-ins and disabled and jumping ones, is marked jumping (`jump_mark`,
`0x00418470`): so is every fuel pod (type `0xE1`), and every ship launching from the object or
docking with it, and those in turn. A jumping object stays where it is, and the frame passes it over
until the player's jump ends.

A ship that does not go with the player's goes to its target, where it stood last update, or 1e7
ahead of itself where the order names nothing or the ship itself.

`order_jump_out` runs a step at a time. Every update of the player's ship clears the jump the
mission has ready (`jump_ready`, `0x0052A3F0`).

| Step | What it does |
|---|---|
| 0 | It steers to face where it goes (`ai_steer`, at most 0.8 of each turn, with no ease), until its rates of turn are within 0.05 and its steering inputs within 0.02; a ship of the player's wing goes on after 1000 ticks whatever. A ship in the player's formation holds its place 100 ticks instead. Then it sounds `jumpout` (sound `0x19`) |
| 1 | It is held still: its steering inputs, its rates of turn, its turn and its speed nothing (the speed's figure alone: its velocity carries it on, slowing as its throttle has gone). The frame after, its effect begins, which keeps how it is turned and where it stands, and aims its motion 500000 along the way to where it goes |
| 2 | It charges at 6 |
| 3 | At full charge it goes: its motion is put aside for Jump Out's, it collides with nothing and draws at its finest (`model_show_finest`, `0x00417DC0`), and its motion starts from where it stands. It fades at 4 for 250 ticks |
| 4 | It flies ahead again, jumping, while its flare fades at 10; then it collides again |
| 5 | It is turned back as it was, powered and free to move, and flies its own motion again at its usual detail. The player's jump ends every object's jumping. An order that names another object gives way to Jump In at it, 19 for 20 and 40 for 41, at the same number; one that names nothing leaves the mission: the ship stops jumping, is disabled, but for a player's ship in a multiplayer game's way (object flag `0x10000000`), and is put 9.9e6 below where it went, its order done |

In step 1 the Boridin's breakaway (`boridin_breakaway`) lets go of the sprite of its core
(`Bor brk away CORE`). Not ported: OpenReliant's Jump Out leaves the sprite be
([#238](https://github.com/OpenReliant/openreliant/issues/238)).

While the player's ship jumps out (`jump_player_going`, `0x0051D0B0`), `order_jump_out` counts
`jump_countdown` (`0x0051D0B4`) down from 15 every 10 game ticks (`jump_countdown_next`,
`0x0051CFA0`), which nothing reads; `order_jump_out_init` sets it, with 1/15 at
`jump_countdown_step` (`0x0051D0A4`). OpenReliant leaves the countdown out.

## Jump In

`order_jump_in_init` has the ship collide with nothing and jump, and places it (`jump_in_place`,
`0x00418850`): abreast of its target, turned as the target is, where the target is drawn, the
order's number `n` putting it `(n + 1) / 2` times 3000 to the target's right for even `n` and to its
left for odd: the first at the target, the second to its left, the third to its right, and so on.

| Step | What it does |
|---|---|
| 0 | It is turned as its target is, set where it arrives, stopped, and moved back from there along its nose by 25000, or 100000 for a ship that lists components, to fly in from. It sounds `jumpin` (sound `0x1A`). For the player's ship, the camera switches to one of three views, held, picked from the C runtime's `rand`: twice its share of 32767, rounded, 0 for view `0x17`, 1 for `0x18` and 2 for `0x19` ([Camera](camera.md#the-jumps-views)); the mission's space takes on what its script asked of it (`environment_update`); and `jump_arriving` (`0x005E82F0`) is set, which cuts the space dust's streaks shorter ([Backdrop](backdrop.md#dust)) |
| 1 | It flashes in at 50. Then its motion is put aside for Jump In's, and it no longer jumps |
| 2 | It flies in at 3, the player's camera shaking by 1 less the progress (`hit_shake`). Then it flies its own motion again at full throttle, colliding, powered and free to move, and `jump_arriving` is cleared |
| 3 | Its order ends: for the player's ship the camera goes back to view 0, free, the display's brightness to 1, its effect record is let go, and JumpedIn is posted (`event_jumped_in`, `0x0045B300`), with the groups ([Script VM](script-vm.md#events)). Order 40 first holds 200 ticks, its roll input `s * (n + 1) / 2` times 0.5 and its pitch input `(n + 1) / 2` times 0.5, with `s` 1 for even `n` and -1 for odd |

In a multiplayer game, as the ship of the first player still flying jumps in, JumpedIn is posted
for the first player's ship too, before its own.

## The motions

Each takes the order's state ([Objects](objects.md#the-orders-motion-functions)):

- Jump Out's (`motion_jump_out`, `0x00474640`) moves the ship to the point between where its motion
  starts and where it goes, `+0x5C` and `+0x68`, by the square of the share of 250 ticks since it
  went: 0.004 for each of the mission's ticks. It does not turn, and its last throttle is nothing.
- Jump In's (`motion_jump_in`, `0x004746D0`) flies the ship along its nose at 600, or 2400 for one
  that lists components, less 0.003 of that for each tick since it was placed, and at its cruise
  speed at least. It does not turn, and its last throttle is nothing.

## What a jump shows

Each jump keeps a record (`jump_effects`, `0x0051CFA4`, 64 of them, `0x94` bytes each), which Jump
Out takes as it is held still and Jump In as it is placed (`jump_effect_alloc`, `0x00418900`), and
which each lets go as it ends (`jump_effect_free`, `0x004189A0`); the game stops with "Jump has
overrun array." when all are taken. It holds up to five trails at `+0x00`, up to twenty lights at
`+0x14`, Jump Out's burst at `+0x64`, Jump In's at `+0x68`, the flare at `+0x6C`, and how Jump In's
flare is turned at `+0x70`. The updates add them to the world's layer each frame, as each step says
below; all but the flare hang from the ship's root frame.

`jump_init` (`0x00416490`), as a mission loads, makes the flare's mesh (`jump_flare_mesh`,
`0x0051D0A8`): a square 4 by 2 facing along Z (`mesh_build_square`, `0x0044F000`) over the whole of
`jflare`, white and added. It loads the trails' texture, `trail3` (`0x0051D0AC`), and clears
`jump_arriving` and `jump_player_going`. `jump_free` (`0x00416510`) frees the mesh and the records as it ends.

`jump_effect_start` (`0x00417670`), as Jump Out's ship has been held still for a frame:

- A burst behind the ship, at `(0, 0, -200)` in its frame, which Jump Out fades as it goes but
  never adds to the scene.
- A trail at each point of kind 7 of each part hanging from the model's root, in the ship's frame,
  five at most ("Too many jumpt trail meshes assigned to this ship.  Check the pointlists!"), or one
  at the ship's own place where it has none (`jump_trail_mesh`, `0x00417AF0`, "JumpTrail Mesh"): a
  square 200 across at its start, then three blades a third of a turn apart through its axis, each
  200 wide and 20000 long, or 2000 wide and 40000 long for a ship that lists components, over
  `trail3` from 0.04 to 0.99, coloured by its own colours and added. It is turned half round so
  that it streams back, but for a Ripper whose `Cargo pod` shows, which flies astern.
- A light at each point of kind 8 of those parts, twenty at most ("Too many jump lights assigned to
  this ship.  Check the pointlists!"), and their count at `+0x58`: a sprite set of one sprite ("Jump
  BMO") 150 across either way, sorted as if 150 nearer, over `lights\flare-b`, coloured and added.

`jump_trail_shade` (`0x00418390`) shades a trail by a share `s`: every vertex opaque, each
blade's two near corners `(0.5, 0.7, 1)` times `0.3 s`, its far ones black. The square at its start
keeps its colours, nothing, and does not show.

`jump_burst_mesh` (`0x00417E30`, "JumpBurst Mesh") makes a burst: a point at its centre, which
nothing uses, then six rings `k` of twelve points, each `k` times 180 behind the centre and
`sin(0.1 pi k)` times 300 plus 30 across for Jump In, `k` times 1620 and 1080 plus 30 for Jump Out,
Jump In's first ring closing to its centre. Triangles band each ring to the next, over
`shield128` by where each corner stands, `u` its Z over 108000 and `v` its Y over 10800, all but
the first, which the game leaves at the texture's corner; coloured by their colours and added by
their alpha. `jump_burst_fade` (`0x00418150`) greys the colours from the first twelve on, a ring's
worth at a time, by 0.5 of the share down to nothing in steps of 0.1 of it, opaque, which puts them a
place ahead of the rings. `jump_burst_glow` (`0x004181C0`) colours them so too, the first twelve
`(0.5, 0.21, 0)` times the share squared and as opaque as the share, each twelve after them a step
of 0.04 of the share less from four steps, red; under the software renderer (`sr + 0x1AC` clear)
grey instead.

`jump_flare_object` (`0x00418120`, "Jump flare mesh") makes the flare, scaled to a width: the
ship's model's width across (`+0x5AC` less `+0x5A0`).

| Step | What shows |
|---|---|
| Jump Out 2 | The trails, shaded by the charge. The lights come on grey with it, 1.25 times the charge, until 0.8; from there light `round((c - 0.8) 5 (n - 1))`, `n` the lights, turns to `lights\flare-lb`, and the one two before it goes out. At full charge the lights go out |
| Jump Out 3 | The trails, shaded by 1 less the progress, and the lights. As it ends, the flare stands where the ship's root frame is |
| Jump Out 4 | The flare, `1 - p` of its width, and the trails and the lights |
| Jump In 0 | The flare where the ship starts to fly in from, turned as it is, and a copy of that turn at `+0x70`; the burst, hanging at `(0, 0, 800)`, `ddheat` in place of `shield128` under the software renderer, glowing at 1 and made twice as wide; and the trails. The update runs on into step 1 as if no time had passed |
| Jump In 1 | The flare, `p` of its width, the trails and the burst |
| Jump In 2 | The trails shaded and the burst glowing by 1 less the progress, and the trails and the burst. Until 0.3 of the flight the flare, full width, turned as it arrived times a scaling of `1 + 3 p` across and `1 - p / 0.3` up, which stretches and flattens it in the world's own X and Y |
| Jump In 3 | Order 40's hold: the trails and the burst |

`jump_idle` (`0x00417E20`), which Jump Out calls with the ship's root as it goes and as it ends,
does nothing.

**Improvement:** the flare casts a point light while it shows, in `jflare`'s own colour, as bright
as the share of it that shows, reaching ten times the ship's width, two and a half times the
flare's length as a muzzle flash's light does ([Guns](guns.md)); a ship lights up as it flashes in,
and so does whatever stands by. `--original` leaves it out.

In OpenReliant ([`jump/effect.zig`](../../src/engine/game/jump/effect.zig)), the meshes the records
share are built once. Jump Out's burst, which the game never draws, is left out. A ship with more
trails or lights than the records hold keeps the first, and a jump for which no record is free goes
on without one, where the game stops.

