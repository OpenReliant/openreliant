# Orders

**Improvement:** global mod scripts can register custom orders (#615). The runtime resolves their
qualified names and allocates internal IDs after the original catalogue. `aigeneric.infoOf`
combines original and registered metadata for stack priorities, player eligibility, retaliation,
avoidance and disruption. The original catalogue remains generated and immutable. Custom
callbacks use the scripting bridge in `hooks.Scripts`; the engine and tools do not link Luau.

What each object is doing: flying in formation, escorting, docking, exploding, or following the player's controls. An object keeps a stack of orders, the current one on top, which the AI, the mission scripts and the player's controls push and pop, and `object_orders` runs the current one.

[`aigeneric.zig`](../../src/engine/game/aigeneric.zig) holds the stack and runs the orders, [`ai.zig`](../../src/engine/game/ai.zig) the steering they turn by, [`aifuncs.zig`](../../src/engine/game/aifuncs.zig) the orders that fly a ship, a capital ship's lurch and orders 44 and 45, [`aieject.zig`](../../src/engine/game/aieject.zig) and [`tractor.zig`](../../src/engine/game/tractor.zig) those of the [ejection](ejection.md), [`launch.zig`](../../src/engine/game/launch.zig) the [launches](launch.md) and [`jump.zig`](../../src/engine/game/jump.zig) the [jumps](jump.md), and [`ai/orders.zig`](../../src/engine/game/ai/orders.zig) lists every order with its flags, priorities and routines; `make order-tables` transcribes that table from the executable. The names below are those `make ghidra-annotate` gives the Ghidra project, which names each order's routines `order_` and the order's name, with `_init` and `_exit` for those two.

Ported so far: the stack (`order_push`, `order_pop`, `orders_clear`, `orders_pop_all`), what runs it (`object_orders`, `orders_update`, `order_retaliate`), the steering (`ai_steer`, `ai_roll_upright`) with its avoidance, and the orders Do Nothing, Fly, Run Away, Slow Rotate, the Random Spins, Match Speed, 44 and 45, Explode, the ejection's (Eject, 106, Scoop Up, Eject Spin, Eject Fighter Attack and Eject Player), Launch, the jumps (Jump In and Jump Out, each under both its numbers), Escort, Find New Target, Torpedo, Object Attach, Toggle Cloak, Mill, Make capship list left and right, and Fight with its [combat maneuvers](maneuvers.md), with Player Control being the player's [controls](controls.md). An order OpenReliant does not run yet still holds its place on the stack, and pushing it still pops and starts what it should ([#30](https://github.com/OpenReliant/openreliant/issues/30)). Not ported: the orders other players' machines queue ([#55](https://github.com/OpenReliant/openreliant/issues/55)).

OpenReliant keeps each object's stack and order state in its slot rather than allocating them with its first order, and hands a fatal "Cannot set ai" back to its caller as an error. **Fix:** where the game stops with it, OpenReliant logs it in the game's words and the order is not taken (`aigeneric.give`).

## The order table

`order_groups` (`0x4E06E0`) points at the records of each hundred order numbers: order `n` is
record `n % 100` of group `n / 100`. Group 0 holds orders 0 to 45, group 1 orders 100 to 122, and
group 2 one empty record, order 200. Each record is an `OrderRecord`:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | `init`: runs before the order's first update; null for none |
| `0x04` | 4 | `update`: runs each time `object_orders` runs the order |
| `0x08` | 4 | `exit`: runs when the order is popped or replaced after it has started; null for none |
| `0x0C` | 4 | Flags |
| `0x10` | 4 | Name: the developers' name, which fatal errors show |
| `0x14` | 4 | Priority |

| Flag | Name | Meaning |
|---|---|---|
| `0x1` | `players` | The order may be given to a player's ship. A player's ship refuses the other orders numbered below 100. |
| `0x2` to `0x10` | | **Unknown.** Set on some orders; nothing in the payload tests them. |
| `0x20` | `one_shot` | The order runs its update once and pops itself, and the order below carries on without starting again. Its `init` never runs. |
| `0x40` | `retaliate` | While it runs, the ship can turn on its attacker (see [Retaliation](#retaliation)). |
| `0x80` | `avoidance` | While it runs, `avoidance_scan` (`0x00492190`) lists the objects the ship could hit, unless the object has `no_avoidance`, which `SetShipAvoidance` sets to disable "Avoidance code": up to ten objects with listed components whose collision spheres, widened by a constant, overlap its own, at `GameObject` offsets `0x6B4` (the count) and `0x6B8`, and up to ten others for which `0x00401980`, which projects the two objects' motion, answers yes for a time of 50 updates and a margin of 2000 units, at `0x6E0` and `0x6E4`. |
| `0x400` | `send_flight` | While it runs, a multiplayer game sends the ship's steering inputs, throttle, rates and velocity. |

Most orders have priority 0. Warp In, Warp Out, Land, Jump In, Jump Out, the fixed gate jumps,
Launch, Dock and Friendly Fire have 1; Eject Player 97, Eject and Eject Spin 98, and Explode 99.

## The stack

An object's stack, `orders` (`0x684`), holds up to 20 `OrderEntry` records, the current order
first, with `order_count` (`0x680`) saying how many. It is allocated with the object's first order,
together with 0x90 bytes at `order_state` (`0x68C`) where the current order keeps whatever it
needs between updates.

| Offset | Size | Field |
|---|---|---|
| `0x00` | 2 | The order's number |
| `0x02` | 2 | Target kind: 0 a ship, 1 a flight group, 2 a squad, as in the mission's [object table](../formats/dte.md) |
| `0x04` | 2 | Target: the ship's slot, or the flight group's or squad's index; -1 for none |
| `0x06` | 2 | Target component, or -1 for the whole ship |
| `0x08` | 2 | A running count from `0x5185A8` while the byte at `0x5185B1` is set, as `SetAI` and `SetupLaunch` number the orders they give, otherwise zero |
| `0x0A` | 16 | The order's own data, zero when the order is pushed |

`player_controls` keeps the mouse's stick position in the first two words of its data.

`order_push` (`0x0040CC10`) takes a slot, an order and its target, and:

1. fails if the ship refuses the order (`order_refused`, `0x0040CA00`): the ship is a player's,
   its slot being below `player_slots` (`0x58832C`), which is 1 in a single-player game and the
   player count or 8 in multiplayer, and the order is numbered below 100 without `players`;
2. succeeds at once if the current order is the same order with the same target;
3. fails unless the current order gives way (`order_give_way`, `0x0040CA50`);
4. removes any equal order, with the same target, from deeper in the stack;
5. fails if the stack holds 20 orders;
6. pushes the order with its data zeroed. Unless the order is one-shot, it marks the order as
   starting (`order_starting`, `0x688`), sets the word at `0x620` to -1 and zeroes the state.

An object that is exploding, whose pilot has ejected, or with object flag `0x10000000` takes no
order. Otherwise the current order gives way at once when there is none, when it has yet to
start, or when the new order is one-shot. A started order gives way to Explode, and to any order
when its own priority is zero or the new order's is higher, running its `exit` as it does. Pushing
any other order on it is a fatal error, "Cannot set ai %s on ship %s: Still %s".

`order_pop` (`0x0040CE70`) runs the current order's `exit` if it has started and removes it. Unless
the popped order was one-shot, the order below starts again: it is marked as starting and the state
is zeroed. `orders_pop_all` (`0x0040CF80`) pops every order, and `orders_clear` (`0x0040CF50`) drops
them all at once when the current order gives way to clearing, so only that order's `exit` runs.

The script command `SetAI` pushes an order aimed at the ship, flight group or squad it names, on
each ship it applies to, and `ClearAI` clears the orders of each ship that is not a player's.

### Targets that name several ships

`order_target_walk` (`0x00401CB0`) hands each ship an order's target names to a routine, until the
routine says to stop: the ship itself, as the target names it; each ship of a flight group, whole;
and each ship of a squad (`squad_walk`, `0x00401D80`): its members in turn from its first, while
they are its own, a ship as the member names its component, a flight group's ships whole, and a
squad's own walk. Dock, Escort, the search for a new target, the search for a pod to scoop up, the
Dark Reign's guns and [Launch](launch.md#the-order) walk their targets so. **Fix:** the game walks a
squad that holds itself round for ever, reads a member no record stands for from address zero, and
stops with a fatal error at a member of a kind it does not know; OpenReliant gives a squad no
members once the walk has gone down more squads than the mission has, and passes over such a member.

## Running orders

`object_orders` (`0x0040C5F0`) runs an object's current order:

1. It starts the queued orders from other players that are due (see [below](#orders-from-other-players)).
2. With a `retaliate` order, it runs `order_retaliate`.
3. It clears the object's `afterburner` and `reverse_thrust`, so an order that burns sets them
   again each time it runs.
4. A one-shot order runs its update and pops itself, and `object_orders` then runs the order below.
   Any other order runs its `init` first if it is starting, then its update.
5. Afterwards it clears the throttle and both burns while the object's engines are disabled
   (`DisableEngines`), both burns when it has no afterburner fuel, and reverse thrust unless the
   object has `can_reverse`.

It runs from two places:

- `orders_update` (`0x0040C8F0`) runs `object_orders` once a frame for every object that is not
  disabled (`DisableObject`), the player's ship included, and after it, where the object's guns
  are not disabled, its [turrets](guns.md#each-frame) (`object_step_turrets`).
  `mission_frame` (`0x004924B0`), `mission_run`'s work for each frame, calls it (see
  [the game loop](loop.md)).
- `simulation_step` runs it for the player's ship, before the objects move, while the ship's
  current order is `Player Control`.

So the orders of AI ships run once a frame, and the player's [controls](controls.md) once a frame
and once each simulation step.

## Retaliation

Damage of kinds 0, 1 and 5 adds to an object's `recent_damage` (`0x690`), which `orders_update`
zeroes every 500 ticks, and each hit records the attacker's slot in `last_attacker` (`0x694`).
While the current order has `retaliate`, `order_retaliate` (`0x0040C520`) pushes Fight (105),
aimed at the attacker, once `recent_damage` reaches 0.7 (`0x004DC484`) of the ship's full armor,
six times its armor class. It does so
only when the attacker is on the other side, is not already the current order's target, and both
ships' combat stats hold 1 at `+0x28`, and not while the ship has `do_not_disturb`
(`DoNotDisturb`).
**Unknown:** what the word at `+0x28` of the combat stats means.

## Orders from other players

In a multiplayer game, orders from the other machines wait in a queue of up to 20, `queued_orders`
(`0xB90`) with `queued_order_count` (`0xB8C`). A `QueuedOrder` is the order's entry, a value the
sender passes, and the tick it is due. `order_queue` (`0x00402660`) adds one due a given number of
ticks after `frame_start` (see [the game loop](loop.md#ticks)). An equal order already queued stays
if it is due no sooner, and is replaced otherwise; a full queue is a fatal error.

`object_orders` takes each queued order that is due by `mission_ticks` and has a priority no lower
than the current order's, pushes it with its data, and removes it from the queue. It removes a due
order without pushing it while the object has not been created.

## Steering

Most orders that fly a ship steer with `ai_steer` (`0x00401380`), which takes a point to aim at,
a limit, an ease and flags. It sets the pitch, yaw and roll inputs from the point's direction in
the ship's frame, through `ai_steer_angles` (`0x00401710`), or `ai_steer_axes` (`0x00401690`) when
the word at `+0x24` of the ship's flight stats is nonzero. It takes `(1 - ease) * 6` times each turn
rate off its input and multiplies the result by 11.46, the degrees in a radian over five, so an
input fills at five degrees off; then it holds each input within the limit, at most 1. While frames
take more than 10 ticks, turns of less than a sixteenth of a turn (22.5 degrees) are halved first,
along with the limit.

`ai_steer_angles` banks the ship round: within 18 degrees of the nose it simply yaws at the point,
further off it rolls to bring the point overhead, and it pitches only once the roll is within 0.8
radians of where it wants it. A ship flying backwards turns toward the other way about.

`ai_steer_axes` turns the ship flat: it pitches and yaws at the point together and never rolls, and
with the point behind it, it yaws hard to the side the point lies on. No file sets the word: the
executable's `ship_flight_stats` (`0x004F9E70`) holds it for each ship type, and `stats_load_ships`
leaves it. The capital ships and most other types turn flat; the fighters bank, as do some
support ships, the Nanny and the limpet car among them. The missiles' own flight stats
(`missile_flight_stats`) turn every missile flat but the fuel pod.
[`create/flight.zig`](../../src/engine/game/create/flight.zig) lists the types.

| Flag | Meaning |
|---|---|
| `0x1` | First `avoid_near` (`0x004028F0`) moves the point around the objects with components in the ship's first avoidance list. |
| `0x2` | First `avoid_ahead` (`0x00402DC0`) moves the point around the objects in the second list, projected along their motion. |
| `0x4` | Unless avoidance took over, the ship also rolls toward the world's Y axis (`ai_roll_upright`). |
| `0x8` | Pitch stays at 0.2 or more. |

When avoidance moves the point, `ai_steer` steers with a limit of 1, no ease and without flag
`0x8`, and returns true. The lists are what [`avoidance_scan`](#avoidance) builds, and a ship with
`no_avoidance` avoids nothing.

**Fix:** the game follows a null pointer for a ship with no flight stats, a stand-in, that steers,
arrives or avoids what lies ahead, and for a collision course with such a ship on either side;
OpenReliant leaves the ship's inputs as they are, counts it as not arrived, avoids nothing for it,
and takes it for no collision course.

### Arriving

`ai_arrive` (`0x00402140`), through `ai_arrive_steer` (`0x00402160`), brings a ship to a point,
turned as an orientation, at a least throttle: Follow Curve arrives so at a path's start, and Dock
and Formation use it too. It goes by where the ship stands next. Within 2000 of the point it has
arrived: its throttle is the least it was given and its turning inputs nothing. Otherwise:

- Behind the point along the way the orientation faces, within 18 degrees of that line, and itself
  facing that way within 11, it steers at the point with `ai_steer`, flags `0x3`, and rolls to
  stand as the orientation stands: its roll input is the roll between their up axes less 12 times
  its roll rate, in degrees over 40.
- Otherwise it steers with `ai_steer`, flags `0x3`, round the circle through it that meets the
  orientation's line at the point, in the plane of that line and the ship: aiming half a radian
  round the circle ahead of itself, or at the point once within the circle's last half radian.
  The circle's radius is at least twice `speed_per_pitch_rate` (flight stats `+0x20`); standing
  ahead of the point, the ship aims across the far side of the smallest.

Either way its throttle is the way left, straight or round the circle, over 4 times its cruise
speed through its inertia (`4 * cruise / (1 - inertia)`), less 0.1, and never less than the least
it was given.

### Avoidance

`avoidance_scan` (`0x00492190`) runs for each object in `mission_frame`'s pass that draws them, the
ones it draws, while the object's current order has the `avoidance` flag and it has no
`no_avoidance`. It empties the ship's two lists (`GameObject + 0x6B4` and `+0x6E0`, a count and ten
slots each) and fills them from the objects that are not standing in, disabled or jumping, not
planets, not the ship itself or what it fights, and where neither names the other in its first
pass-through slot:

- an object that lists components goes on the first list while its sphere, 10000 wider than the two
  radii, overlaps the ship's where the step takes them both;
- any other goes on the second, where the ship lists no components, while the ship is on course to
  hit it within 50 steps by 2000 (`ai_collision_course`, `0x00401980`).

`ai_collision_course` first asks that the two be within reach of each other over the steps, at
their cruise speeds, with both radii and the margin. Against a target without components, the
target must then lie ahead of the ship, and the ship close on it by its velocity less twice the
target's, to within both radii and the margin. Against a target with components, the ship's next
position must instead lie within the ship's cruise speed times the steps, and the margin, of a box
of one of the target's parts: of the parts in its root's child list, every part whatever it is
linked to, shown and with a collision tree, each whose sphere, that reach wider, holds the position
has each box of its tree tested, and the position is within reach of a box where it stands nearer
to the box's centre, squared, than the box's half size and the reach, each squared, together.

**Fix:** the game also hands back the part and the box through two pointers it does not test, which
every caller passes null. Avoid Target (`order_avoid_target`, `0x0040B330`) asks only that its
target's type is below 0x100, not that it lacks components, so the game writes to address zero once
the ship comes within reach of a box of a ship that lists components. OpenReliant hands back
neither.

`avoid_near` (`0x004028F0`) works the first list, from the line between where the ship goes next
and the point it steers at. For each object not standing in, exploding or disabled, not farther
behind along that line than both radii, closing along it, and to be met within 250 steps: it
takes the object's box where it will then be, widened by the ship's radius, in the object's frame
and scaled by its visibility. Where the line crosses it, the point moves onto the box widened again
by the ship's radius: onto the face nearest where the line enters, at whichever is nearest the point
of four spots of it, each at the entry along one of the face's two axes and at an edge of the box
along the other. The point is scaled by the visibility again on its way back to the world, rather
than unscaled. The heading stays the one to the first point, but each object after the first tests
the line to the point the one before moved.

`avoid_ahead` (`0x00402DC0`), for a ship that lists no components, works the second list: each
object is taken where it will be once the ship has flown to where it is now at the ship's cruise
speed. Where the line to the point passes within 1000 of it, or 500 for an object of another side,
the point moves as far ahead of the ship as the object will be, and above or below the ship, away
from the object along the ship's own up and down axis, by both radii and 2000, or 1000 for another
side's.

## The orders

Each order's routines are named after it: `order_fly_init` and `order_fly` for Fly, for example.
Many take their target's validity from `order_target_valid` (`0x00401870`): a targetable object
that is not cloaked, exploding, disabled or ejected, nor has object flag `0x10000000`, and, when the
target is a component, one that is there and neither hidden nor has node flag `0x10`. Random
choices come from `object_random` (`0x004ADD10`), each object's own generator: a seed at `+0x638`,
set from C's `rand()` when the object is created, that steps as `seed * 0x343FD + 0x269EC3`, bits
16 to 30 of it over 32767 giving a number from 0 to 1.

Every order, by its number, with what it does and whether OpenReliant runs it. An order
OpenReliant does not run yet holds its place on the stack and does nothing
([#30](https://github.com/OpenReliant/openreliant/issues/30)).

| Number | Order | What it does | Ported |
|---|---|---|---|
| 0 | Do Nothing | Zeroes the throttle and the turning inputs. | Yes |
| 1 | Fly Aimlessly | On starting, takes a figure from 1 to 3 from the ship's own random numbers, keeps where the ship will be next and how it will be turned, its X axis reversed where its next number is odd, and sets the throttle to 0.4 and up to 0.3 more by `rand()`. Each update it steers with flags `0x3` for point `n` of its figure, from 1, and for the next once within 1000 of it. Point `n` lies `t = n` twentieths of a turn round, `(cos t - 1)(figure + 1)` times 25000 along the kept X axis and `sin(figure t)` times 50000 along the kept Z axis from where the order began: figure 1 is a circle, and figures 2 and 3 are wider loops that swing ahead and back two and three times on the way round. It never ends. **Improvement:** OpenReliant computes the sine and cosine rather than reading the engine's tables (`sr_sin`, `sr_cos`). | Yes |
| 2 | Launch Missile | One-shot: launches a missile at the target from the first of the ship's racks with missiles left that is not a Jack Hammer's ([Missiles](missiles.md#the-ais-missiles)). | Yes |
| 3 | (nameless) | One-shot: as Launch Missile, from the first rack of Jack Hammers. | Yes |
| 4 | Warp In | A ship arrives through its own tunnel, emerges, then posts JumpedIn ([Gates](gates.md#warps)). | Yes |
| 5 | Warp Out | A ship aligns with its target, opens its tunnel and enters it, then queues Warp In with the same sequence number. | Yes |
| 6 | Fly | Flies at the speed in its data, or at full throttle for zero. With a target it flies to it and pops within 2000 units; otherwise it keeps the heading it had when it started, steering at a point 20000 units along it. It steers with flags `0x7` and halves the throttle while avoiding. An object without flight stats is moved along that heading instead; **Improvement:** OpenReliant draws it gliding on between the ticks ([The game loop](loop.md#porting)). | Yes |
| 7 | Run Away | Flies away from the target at half throttle, for a point on the far side of the ship from the target, 100000 times as far from the ship as the target is. It moves the point round what is near (`avoid_near`), then steers at it with flags `0x3` and an ease of 0.1, which go round what is near and ahead again. Pops when the target's slot holds a stand-in. | Yes |
| 8 | Land | The player's ship lands on its carrier, which ends the mission ([Landing](#landing)). | Partly: the Yamato's style is not ([#349](https://github.com/OpenReliant/openreliant/issues/349)) |
| 9 | Escort | On starting, takes the ship its target names, or the ship at the order's number among a flight group's or a squad's ships, counting round them again past the last (`escort_count_place`, `0x0040AA50`); OpenReliant takes none where the group has no ships, which the game walks for ever (**Fix**). Each update, it pops once that ship's slot holds a stand-in; otherwise it steers for a point 10000 ahead of the ship: within 5000 of it with half its turn and flags `0x4`, and farther off with its full turn and flags `0x3`. Its throttle is the escorted ship's speed over its own cruise speed, and 0.0001 more for each unit the escorted ship lies ahead along its own heading. | Yes |
| 10 | Find New Target | Walks the ships its target names, weighing each it can aim at, cloaked or not, by the square of its node's distance from where the ship will be next ([Picking a fight](#picking-a-fight)). It fights the lightest to fight, pushing Fight, or Torpedo (103) for a ship of the torpedo class; with none, it mills round the lightest to mill round, pushing Mill (120); with neither it pops. | Yes |
| 11 | Explode | A destroyed object's end, by what it is and in one of three styles ([Destruction](objects.md#destruction)). | Yes |
| 12 | Ripper grabs target object | A Ripper carries its target off ([The Ripper](#the-ripper)). | Yes |
| 13 | Object Attach | On starting, keeps where the ship will stand next in the frame its target will stand in next. Each update it puts the ship there in the target's next frame, turned as the target will be, and gives it the target's turn, velocity, speed and rates of turn, so that it rides the target. | Yes |
| 14 | Formation Regroup | Not read yet. | No |
| 15 | Patrol Route | Not read yet. | No |
| 16 | Toggle Cloak | One-shot: cloaks or uncloaks the ship if its model's header allows a cloak, and the ships being launched from it do the same. | Yes |
| 17 | Ship Follow Curve | Flies the path of the mission's curves from the curve in its data ([Following a path](#following-a-path)). | Yes |
| 18 | Slow Rotate | Zero throttle, yaw input 0.1. | Yes |
| 19, 40 | Jump In | The ship arrives beside its target, flying in from far behind it; 40 first holds its place in the formation a while ([Jumps](jump.md#jump-in)). | Yes |
| 20, 41 | Jump Out | The ship turns to where it goes, charges and jumps: to its target, where Jump In of the matching number brings it in, or out of the mission where it names none; a ship jumping with the player's goes in formation behind it ([Jumps](jump.md#jump-out)). | Yes |
| 21 | Find Scoop Up | Starts at its first step, as 115 and 116 do (`0x0040B1C0`). The first goes on to the second, where a multiplayer game waits for every player unless the target is a ship (`ai_sequence_sync`, `0x00401000`). The second walks the ships its target names for the nearest to where the ship will be next that it can aim at, ejected or not (`0x0040B140`), and pushes Scoop Up (107) at it; with none it pops. Once Scoop Up is done, the order starts again from its first step. | Yes |
| 22 to 24 | Random Spin Slow, Medium, Fast | On starting, zero throttle and each turning input 0.1 plus a random number times 0.3, 0.5 or 0.9. Its update does nothing. | Yes |
| 25 | Fixed Gate Jump In | The ship comes in through the tunnel at the object its target names, out beyond its mouth, cut by its portal ([Gates](gates.md#jump-in)). | Partly: the Krasny's split in missions 16 and 66 is not ([#407](https://github.com/OpenReliant/openreliant/issues/407)) |
| 26 | Fixed Gate Jump Out | The ship goes out through the nearest gate's tunnel, the player's riding the worm, then comes in through its target's (25) ([Gates](gates.md#jump-out)). | Yes |
| 27 | Formation | On starting, keeps its place abreast of the target, 3000 apart: the ship `SetAI` numbers `n` flies `n / 2 + 1` places out, to the target's left where `n` is even and to its right where it is odd. Each update it pops once it can aim at the target no more; otherwise it arrives at its place in the frame the target will stand in next, turned as the target will be, at a least throttle of 0 ([Arriving](#arriving)). | Yes |
| 28 | Fixed Gate Open | A tunnel grows open at the object ([Gates](gates.md#open-and-close)). | Yes |
| 29 | Fixed Gate Close | The object's tunnel shrinks away and goes. | Yes |
| 30 | Eject | The pilot leaves the ship in its cockpit, which becomes the pod, and the rest of the ship a new object; the pod clears the ship, and the player's waits to be picked up ([Ejection](ejection.md#the-pod)). | Yes |
| 31 | Fixed Gate Collapse | The gate comes down in fireballs, its tunnel burning out ([Gates](gates.md#collapse)). | Partly: the Krasny's split is not ([#407](https://github.com/OpenReliant/openreliant/issues/407)) |
| 32 | Match Speed | Sets the throttle to the target's speed over the ship's cruise speed. Pops when the target is no longer valid. | Yes |
| 33 | Dark Reign shoot | Not read yet. | No |
| 34 | Move to spawn pos | A deathmatch's (`deathmatch.cpp`). Not read yet. | No ([#55](https://github.com/OpenReliant/openreliant/issues/55)) |
| 35 | Turns object lights on | Switches on the lights of the parts with the lightmap flag, with a sound, and pops. Ship type 165 instead switches on the first part's four lights one by one, then those of every lightmap part, a step each 100 ticks with a sound at each, and pops after 500 ticks. While the setting at `0x5D5618` is not 1 it pops at once. | No |
| 36 | Make Boridin section break away | Not read yet. | No |
| 37 | Rotate Boridin breakaway warp projector | Not read yet. | No |
| 38 | Start warp projection from Boridin | The Boridin's warp projection, through a tunnel of its own ([Gates](gates.md)). Not read in full yet. | No ([#30](https://github.com/OpenReliant/openreliant/issues/30)) |
| 39 | Make ripper drop what it's carrying | A Ripper lets go of what it carries ([The Ripper](#the-ripper)). | Yes |
| 42 | Turns object lights off | Switches off the lights order 35 switches on. | No |
| 43 | Huuuuuuuge explosion | The Uber Explode at the object, of size 50000 over 1500 ticks ([Effects](effects.md#the-uber-explode)), then it pops. | Yes |
| 44 | Immediately set ship to zero velocity and rotation | `object_stop` (`0x00403000`), then it pops. | Yes |
| 45 | Fly ship backwards | Throttle -0.5, no turning. | Yes |
| 100 | Player Control | The player's controls fly the ship ([Controls](controls.md)). | Yes |
| 101 | Multiplayer Control | Disables the object once it has object flag `0x10000000`. | No ([#55](https://github.com/OpenReliant/openreliant/issues/55)) |
| 102 | Avoid Target | Not read yet. | No |
| 103 | Torpedo | Find New Target's for a ship of the torpedo class. On starting, full throttle. Each update it pops once it can aim at its target no more; otherwise it steers with a limit of 2 and no ease at the target's node, led along the target's nose by the target's speed times the ticks the torpedo takes to get there at its top speed, less its own velocity times half those ticks, 25 at most. It goes off against what it meets ([Collisions](loop.md#collisions)). | Yes |
| 104 | Launch | The ship leaves its carrier, in the style the carrier's type picks ([Launches](launch.md)). | Yes |
| 105 | Fight | Fights its target by running [combat maneuvers](maneuvers.md), one after another. | Yes |
| 106 | Eject | The ship a pilot has left: destroyed 200 ticks on. | Yes |
| 107 | Scoop Up | A nanny ship or the Antanov takes the player's pod aboard with its tractor beams ([Ejection](ejection.md#scoop-up)). | Yes |
| 108 | Eject Spin | An AI pilot's ship spins, unpowered, for 200 ticks; then the pilot ejects (Eject). | Yes |
| 109 | Dock | Docks at a port of its target ([Docking](#docking)). | Station, Nanny, limpet car and limpet pod styles; Czar-specific limpet docking remains ([#320](https://github.com/OpenReliant/openreliant/issues/320)) |
| 110 | Dark reign shoot | The Dark Reign's ion cannon; `ion_cannons_hold_lock` keeps its target ([Script VM](script-vm.md#the-games-variables)). Not read in full yet. | No |
| 111 | Ripper end drop object | A Ripper draws its forearms back once it has let go ([The Ripper](#the-ripper)). | Yes |
| 112 | Ripper attach cargo pod to Mammoth | A Ripper fits a cargo pod onto a Mammoth ([The Ripper](#the-ripper)). | Yes |
| 113 | Eject fighter attack | A Sabre flies at the player's pod and shoots it down ([Ejection](ejection.md#eject-fighter-attack)). | Yes |
| 114 | Disrupted | A Havoc's shockwave gives it ([Effects](effects.md#shockwaves)). On starting, sets object flag `0x8` (unpowered), keeps the tick to end at, the duration in its data (a word) after `frame_start`, takes the push in its data after that (three floats) as a knock in the ship's own frame, though the shockwave gives it in the world's, and knocks each turn rate by up to 0.05 either way at random, which the ship tumbles by. It also plays fifteen [electric rays](effects.md#electric-rays) over the ship, each from its centre out to its radius in a random direction, 90 either way, with a jitter of 0.6, flickering, dimming as they go dark, and lasting as long as the order, white (0.8, 0.8, 1) and blue (0.3, 0.5, 1) in turn. It pops past that tick, and its `exit` clears the flag. | Yes |
| 115, 116 | Make capship list left, right | A capital ship struck by a torpedo lurches ([Collisions](loop.md#collisions)): its update (`capship_list`, `0x0040C3A0`) sets the roll and yaw inputs to 0.01 and 0.006 over the ship's roll and yaw rates, to the left for 115 and the right for 116, then 200 ticks on to 0.006 and 0.0048 the other way, and 300 ticks after that clears the roll and pops. | Yes |
| 117 | Friendly Fire | The carrier recalls the player's ship for destroying a friend, and it lands ([Friendly fire](#friendly-fire)). | Yes |
| 118 | Eject Player | The player's ship drifts, unpowered, for 400 to 599 ticks, then explodes, unless the pilot ejects first ([Destruction](objects.md#destruction), [Ejection](ejection.md#ejecting)). | Yes |
| 119 | Ship Follow Curve Backwards | Flies the path of Ship Follow Curve (17) backwards, from its end to its start. | Yes |
| 120 | Mill | On starting, where it can aim at its target, cloaked or not, keeps the tick and a circle facing from the target's node to where the ship will be next. Each update it pops once it can aim at the target no more or 500 ticks have passed; otherwise it flies at full throttle, steering with flags `0x3` for a point on the circle 50000 from the node, which comes round from the ship's side by 0.000005 of its cruise speed a tick. **Improvement:** OpenReliant computes the sine and cosine rather than reading the engine's tables (`sr_sin`, `sr_cos`). | Yes |
| 121 | Deathmatch Respawn Effect | A deathmatch's (`deathmatch.cpp`). Not read yet. | No ([#55](https://github.com/OpenReliant/openreliant/issues/55)) |
| 122 | Deathmatch Dark Reign target | It has no routines: nothing to run. | Yes |
| 200 | (nameless) | It has no routines: nothing to run. | Yes |

### Following a path

Ship Follow Curve (17) and Ship Follow Curve Backwards (119) fly a ship along a path of the mission's
curves ([The director's camera](director.md#curves)): from the curve its data names, on through the
curve that carries the path on from each curve's end, over the seconds its data gives. The data holds
the curve (`+0x0A`), the seconds (`+0x0E`) and the ship that carries the path (`+0x12`), whose offset
from where the mission placed it, as the order starts, moves the whole path (`curve_ride`). Their
state:

| Offset | What it holds |
|---|---|
| `+0x00` | The routine `motion_follow` gets its point from: `0x00403200`, or `0x00403600` backwards |
| `+0x04` | The fastest the ship moves, as a share of its top speed: 1 |
| `+0x08` | The curve it flies now |
| `+0x0C` | The step |
| `+0x10` | The mission's tick (`mission_ticks`) the curve began |
| `+0x14` | The curve's share of the order's seconds, in ticks, as its length is to the path's |
| `+0x18` | The path's length |
| `+0x28` | Where the carrying ship stood as the order started |
| `+0x34` | The share of the way along the curve to the next place a point marks, 0 for none |

| Step | What it does |
|---|---|
| 0 | It arrives (`ai_arrive`) at the path's start, turned toward the path's point 4 ticks on and at the throttle the path keeps between them over its cruise speed; the curve's clock holds at its start. The order backwards arrives at the path's end instead, turned toward its point 4 ticks back, its motion `motion_forward` |
| 1 | In a multiplayer game it waits for the other players (`ai_sequence_sync`, `0x00401000`, not ported: [#55](https://github.com/OpenReliant/openreliant/issues/55)); in a game of one, it goes on |
| 2 | It flies `motion_follow` along the path, or `motion_follow_backwards` where its motion was astern; backwards, `motion_follow`. The path moves it on to step 3 |
| 3 | The order pops, in a multiplayer game once the other players are there too (not ported: [#55](https://github.com/OpenReliant/openreliant/issues/55)), and its `exit` gives the ship `motion_forward`, or `motion_backward` after `motion_follow_backwards` |

The path's routine, each update of the motion, gives the curve's point as far along as its ticks
have gone by `mission_ticks`, which runs on through a frame's simulation steps (`curve_point`),
carried with the carrying ship. Forward, past a place a point marks, the
point has ShipReached, with the ship (`event_post_ship_reached`, `0x0045AC10`), one place an update.
At the curve's end the ship it ends at has ShipReached too, and the next curve begins; with none, the
step moves on. Backwards, past the curve's start, the curve before it begins, found by walking the
path again from the order's curve, or at that curve the step moves on.

**Fix:** the game divides by nothing for a path of no length and for a curve given no ticks, and
follows a path that comes round on itself for ever as it walks it; OpenReliant gives a curve of a
path of no length all the order's ticks, takes a curve given no ticks to its end going forward and
past its start going backwards, as the game's endless share does, and stops measuring such a path,
and walking it for the curve before one, after as many curves as the mission has
([Curves](director.md#curves)). Flying forward, it still follows such a path for ever
([#535](https://github.com/OpenReliant/openreliant/issues/535)). Walking the path backwards, the game
takes a curve's end for a ship unless its whole reference, kind and all, is `0x0000FFFF`
(`0x0040359E`), and so walks on from a curve that ends at no ship to one that starts or ends at
none; OpenReliant stops at an end whose index is `0xFFFF`. It holds a curve's ticks at 65535, where
the game takes them round from nothing. The game moves the step on, and forward posts the end's
ShipReached, at every move past the path's end, so that a second move before the order's update, a
collision's or that of a second step in the same pass, leaves the order running, to fly the path
again once the step comes round; OpenReliant moves it on once.

### Docking

Dock (109) brings a ship into a berth at another's port. Its target names the ship and the port by
its component: the port is the ship's docking points (SHP attachment kind 9), counted part by part
over its root's children. Where the target names no port, or names a flight group or a squad, the
init (`order_dock_init`, `0x00406B80`) takes the first free port of the ships it names, in the order
it walks them: the first port at which no other object's current order is Dock
(`0x00406A90`). It then picks a style by what the ship is and what it docks at, from a table of an
init, an update and an exit each (`0x004E1618`): the limpet car's (2), or at the Czar docked its
own (3); the limpet pod's (4); at a Nanny, the Nanny's (1); and otherwise the station's (0). The
data's first byte holds the style.

The station's style finds the docking points (`0x00406C80`): the ship's own, its first, and the
port, whose part plays its `deploy` track at 4 from its start. The port is found by counting the
component down at each docking point, so a component past the station's docking points, or a
negative one other than -1, which the init's search leaves alone, names none. A ship without a
docking point stops the game with "Docking information not defined on %s". The check of the
station's port reads the ship's own node again (`0x00406E2A`, `+0x10` where the port's is
`+0x20`), so a station without the port goes on to the berth with the port's node null, as
`order_push` cleared the state, and faults there. The berth (`0x00406E70`) is where the ship's
origin stands docked: the port, less the ship's own docking point turned by the port's
orientation, in the frame the station's part is drawn at, and turned as the port is.

**Fix:** the game takes the ship's own docking point in its part's own frame alone (the node's
`+0x18` and `+0x3C`, `0x00406E97`), which berths a ship whose point is on a part hung from another
part off by that part's place; OpenReliant carries it up the parts it hangs from. Every shipped
model has its docking points on parts that hang from the root.

The station style's state:

| Offset | What it holds |
|---|---|
| `+0x00` | The routine `motion_follow` gets its point from as the ship slides in: `0x00406F20` |
| `+0x04` | The fastest the ship slides, a share of its top speed: 0.5 |
| `+0x08` | The step |
| `+0x0C` | The mission's tick (`mission_ticks`) the slide ends at |
| `+0x10`, `+0x14` | The ship's own docking point's node and place on it |
| `+0x20`, `+0x24`, `+0x30` | The port's node, its place on it and its orientation |
| `+0x54` | Whether the ship came from the port's right, which mirrors the way round |
| `+0x58` | Where the ship stood as it began to slide in |

The init (`0x00407010`) picks the first step by where the ship stands in the port's frame: more
than 100000 behind the port, step 3 where it stands within a fifth of that to the side, and step 2
further out; nearer, step 1 behind the port and step 0 ahead of it. Steps 0 to 4 steer for a point
in the port's frame, mirrored across it for a ship that came from its right, at full throttle
(`ai_steer`, no flags), rolling the ship to stand as the port stands (its roll input the roll
between them less twice its roll rate, in degrees over 40, within 1), each on to the next within
2000 of its point. Holding the roll leaves the ship its pitch and yaw to come round with: a ship
that turns flat, as capital ships do, flies the whole way round, while a banking one turns only
while the point lies within 18 degrees of its nose or its tail.

| Step | Point, in the port's frame |
|---|---|
| 0 | 100000 to the side |
| 1 | 100000 to the side and 100000 behind |
| 2 | Twice the ship's cruise speed over its yaw rate to the side, 100000 behind |
| 3 | 50000 behind, on the port's line |
| 4 | 10000 behind, on the port's line |
| 5 | The ship latches on: attached, flying `motion_follow`, the station stopped dead, for 1000 ticks |
| 6 | It slides in: the path's point stands on the port's line behind the berth, as far back as the ship stood as it latched on, times the square of the share of the 1000 ticks left, with the port's up as the way up. Past them, the ship's motion is `motion_backward`, and the step moves on |
| 7 | It is stopped dead, set in its berth, heard docking (sound `0x37`, `dock`), and has its Docked (`event_post`); the order pops |

Its exit, the Nanny's too (`0x00407D10`), leaves the ship's first pass-through slot empty. The
ship stays attached.

**Fix:** where the ship has no docking point the game stops, and where the station has no port
that the component names it faults. OpenReliant logs either, and the order ends.

**Fix:** the game goes on reading the frames of a station that has gone; OpenReliant ends the
order, and until then the slide in holds the ship where it is.

### Nanny docking

`dock_nanny_init` (`0x004073E0`) enables carrier pass-through and plain motion. It stores the
selected port's point, raised by the docking ship's height. `dock_nanny_run` (`0x00407510`)
opens entry door 0 or 1, approaches a point 1500 above and 20000 ahead of the port, then
steers into it. Within 500 units it stops and closes the door. After strictly more than
500 ticks, `create.rearm` refits missiles through the shared `create.arm` path and restores
countermeasures, afterburner fuel, gun charge and rounds. Player ships retain their chosen
loadout, including modded missile racks. Hull and shields are not repaired.

Exit door 4 or 3 opens. After 400 ticks, Docked is posted and forward motion resumes.
The ship uses its afterburner for another 150 ticks, then the exit door closes and the order
ends. The player's locked Nanny view (43) returns to the cockpit. **Fix:** each door closes
from its own animation time instead of using the first port's time. Invalid ports or missing
carriers end the order without dereferencing missing nodes.

### Limpet docking

`dock_limpet_init` (`0x00407D30`) shares station docking-point lookup and berth math.
`dock_limpet_run` (`0x00407D70`) approaches 10000 behind the berth, then uses the shared
slide callback for 1000 mission ticks at half speed. It stops the carrier during entry.
At the berth, clamp parts 2 and 3 play `rotate` at speed 4. A visible pod mesh (part 0)
is hidden and replaced by a separate limpet-pod object, attached to the carrier. If it was
already hidden, the mesh shows again and the first existing limpet pod is retired, as in
the original. Three 400-tick waits cover clamp rotation, departure and clamp return.

The order posts Docked if the pod mesh is hidden, Undocked otherwise. Its exit restores
forward motion, clears attachment and clears the first two pass-through entries. The
separate pod's update (`0x004084B0`) destroys it if its carrier explodes. Undocked is also
exposed to mod scripts through the event declarations.

Czar-specific limpet docking remains in [#320](https://github.com/OpenReliant/openreliant/issues/320).

### Landing

Land (8) brings the player's ship down on its carrier, and ends the mission. PERMISSION TO LAND
gives it (`permission_to_land`, `0x00453DE0`), which `frame_controls` calls outside a multiplayer
mission: heard at most once in 500 of the timer's ticks (`0x0052987C`), it aims Land at the ship
the player launched from (`player_carrier`). In a training mission (30 to 35), the flight instructor
clears the ship to land where the script's variable 10 (`landing_cleared`, `0x0052A418`) is set. In
any other, unless the ship is landing already, the carrier refuses it, or clears it where variable
10 is set. Mission 1's script sets it as the Reliant jumps in. The pilot asks on the radio, and the
answer comes as a report 300 ticks later ([Reports](radio.md#reports)); where the radio's reports
are all taken, nothing answers and nothing lands.

The init (`order_land_init`, `0x0040EAC0`) picks a style by the carrier's type, from a table of an
init and an update each (`land_styles`, `0x004E1FE8`): the Reliant's (1) and the Yamato's (0). Any
other stops the game with "Cannot land on %s". The state's first word holds the style. The
Reliant's init (`0x0040F5C0`) sets the first step, due in 700 ticks, or at once where the ship is
being sent home for its friendly fire (ending 6 or 7). Its update (`0x0040F940`) keeps its state
as:

| Offset | What it holds |
|---|---|
| `+0x00` | The style |
| `+0x04` | The frame's tick the step waits for |
| `+0x0C` | The step |
| `+0x10` | The middle of the tube the ship lands in |

| Step | What it does |
|---|---|
| 0 | Until the step is due, the player flies on (`player_controls`). Then the cutaway: the scene becomes the landing's (`0x00587CD4` = 3), every object but the ship and its carrier is disabled (flag `0x400`) and those two enabled, the ship flies by its nose (`motion_plain`) and passes through everything, and the upper door of the carrier's first launch tube, part 6, plays `opendoor2` at 1.23 with the door's sound (`0x35`, `dooropen`) where it stands |
| 1 | The ship steers at a point 3000 over the tube's middle (`ai_steer`, no flags), its throttle 0.0001 for each unit it has to go, at most 0.5. Within 200 of it, it stops, its turns nothing, for 50 ticks |
| 2 | It sinks along its own Y axis, which points below it (`motion_downward`) |
| 3 | Its throttle is its distance from the tube's middle over 15000. Once it is less than 100 over it, along the carrier's Y axis, it stops, with the landing's sound (`0x3E`, `shipland`), for 270 ticks |
| 4 | The mission is over (`mission_over`) |

The cutaway (`0x0040F600`) switches to one of the [landing's views](camera.md#the-landings-views)
at random, and moves the carrier to (0, -1000000, 0), turned as the world is. The ship lands in the
carrier's first launch tube, the one the launch drops ships out of through its lower door
([Launches](launch.md#the-reliants-launch)): its middle is halfway between the middles of the
tube's lower door, part 0, and its upper door, part 6, each the middle of the bounds of the level
its part drew last. The ship stands 20000 ahead of it and 5000 above in the carrier's frame,
looking at the point 3000 over it, stopped, its power shared evenly. The carrier's orders are all
popped, and it stops. The approach leaves the ship pitched about 6 degrees nose down, as it looked
at the point over the tube from where it started, and it sinks along its own Y axis, so that it
comes to rest ahead of the tube's middle, tilted as it came.

**Improvement:** the ship levels out as it approaches: the point it steers at rises from the
game's height to the ship's own as it nears the tube, eased in and out over the way it comes, so
that it arrives level. It stops dead over the tube, and sinks straight down it, coming to rest
level. Once its top is below the underside of the tube's upper door, the door closes over it, its
opening played back as fast as the launch opens the tube's doors, 2 a step, with the game's sound
of a door closing (`0x36`, `doorclos`).
`--original` lands it as the game does, and leaves the door open.

**Fix:** a landing on a ship that nothing lands on ends at once, where the game stops, and
PERMISSION TO LAND does nothing where the player's ship launched from no carrier, where the game
reads through a null pointer.

Not ported: the Yamato's style, whose landing OpenReliant lets go of at once
([#349](https://github.com/OpenReliant/openreliant/issues/349)).

### Friendly fire

The player's hits on friends ([`friendly_fire.zig`](../../src/engine/game/friendly_fire.zig)):
`object_damage` and `object_armor_damage` hand a blow of the player's ship on a friendly object, a
shot's, a Screamer's or a collision's, to `friendly_fire_warning` (`0x00474C80`), the armour's only
while the object is not exploding, as `component_damage` does a shot's or a Screamer's on a friend's
component. The damage after the difficulty's scaling mounts (`friendly_fire_damage`, `0x00562CEC`),
and once past 800 (`0x004DC5EC`) and 3000 game ticks after the last (`friendly_fire_quiet_until`,
`0x00562CE8`), Moose warns the player on the radio, one of `ff_001` to `ff_004`, and the damage
counts from nothing again. The count of warnings (`friendly_fire_count`, `0x00562CF0`) would pick
`ff_005` to `ff_008` for a second and `ff_009` to `ff_012` for a third, but the game takes a second
back to the first, so those are never said. `friendly_fire_reset` (`0x00474B20`) clears the three as
`mission_run` starts a mission.

Destroying a friend sends the player home: armour below zero from such a blow, but a collision with
a pilot's pod that anything could harm, or a friend's component destroyed by a shot or a Screamer,
calls `player_friend_destroyed` (`0x00474E00`), which marks the player's ship (`+0x678`, 1), as
the script's `FriendlyFire` (`0x57`) does. Each frame after the orders, `mission_frame`
(`0x0049298C`) runs `friendly_fire_send_home` (`0x00474B40`) for a player's ship in the action
and marked: while the mission goes on and the ship's current order has no priority, the mission's
ending becomes 6 (7 where the mark is 3), and the ship takes Friendly Fire (117), aimed as its
current order is, and is sent off (flag `0x10000000`).

Friendly Fire keeps its stage (`+0x00`) and the frame's tick it ends at (`+0x04`):

| Stage | What happens |
|---|---|
| 0 | Its init (`0x00474E60`) has Moose say one of `ff_013` to `ff_023`; the player flies on (`player_controls`) for 300 ticks |
| 1 | For 700 ticks the ship is steered toward the carrier the player launched from (`ai_steer`, limit 1, no ease, no flags), the player's controls keeping 0.7 of the throttle and of each turn, the steering 0.3 of the turns |
| 2 | The order ends and the ship, no longer sent off, takes Land on the carrier, which lands it at once ([Landing](#landing)), and Jump Out at itself before it where the carrier is farther than 1000000; it is sent off again. The game also clears the carrier's flag `0x20` |

**Fix:** the game reads the carrier through a null pointer where the player launched from none;
OpenReliant lets the ship fly on as the player has it, and then ends the order.

Not ported: a multiplayer game's side of it
([#55](https://github.com/OpenReliant/openreliant/issues/55)). There, destroying a pilot's pod only a
player could harm marks the ship 2 and tells the others, whose carrier then aborts the mission
(`abrt_001`, said by pilot 27 for the Reliant and 28 for any other); and another player's ship
sent off jumps out.

### The Ripper

The Ripper (type `0x1F`) carries cargo pods in the tractor beams of its four back pincers
(`airipper.cpp`). Mission 1 has one lift sixteen pods onto a Mammoth at Fort Sherman: its script
orders the first grab, and two triggers that resume where they stopped (`InterruptTriggerCode`)
answer each RipperGrabbedObject with the next drop and each RipperDroppedObject with the next grab.

Two tables of 150 entries serve every Ripper, set up as a mission loads (`0x0040FC90`) and let go as
it ends (`0x0040FCF0`). `rippercargo` (`0x00518648`) pairs a Ripper with what it carries, filled in
turn from `next_rippercargo` (`0x00518AFC`); what a Ripper carries is the first entry naming it
(`0x00412340`). A set of beams (`0x74` bytes each at `0x00518B00`, the next at `0x00518640`) is
four tractor beams (`tractor_beam_mesh`, over `laser2`), one from the first point of each pincer's
first point list, the first two reaching for the middle of the pod's first pair of points and the
last two for that of its second ([SHP](../formats/shp.md)). An order shows them as it runs
(`0x00412200`), aimed and faded as a tractor's beams are: each from its pincer's point in the
pincer's frame, to the middle of its pair of the pod's points taken in the frame the pod's
`Cargo pod` part hangs from (the frame's parent, `+0x10`), which for the shipped pods is the pod's
own place, so the beams stay on a pod that is disabled and not framed.

The Ripper's tracks play on every part of it that has them (`0x0049A400`): `ready to grab`, its
forearms reaching out; `grab pod`, its pincers closing; and `cabin turn`. A step that waits for
the forearms or the pincers played backwards waits for the root's first child's track to be back
at its start; one that waits for the cabin to turn back waits for the `Ripper Cabin` part's. Each
wait for the other players between the steps (`0x00401000`) passes at once in a single-player
game. A Ripper comes to rest where its turning inputs and its throttle are within 0.025, and its
rates of turn within 0.02; Ripper end drop object's last turn needs its inputs and rates below
those values.

Ripper grabs target object (12) lifts its target aboard. Its init (`0x0040FD10`) makes the target
invulnerable, takes the beams, flies the Ripper by `motion_plain`, held (`attached`), and has the two
pass through each other. The Ripper stops 2500 above the target's component, in its frame, where the
target names one; in mission 26, 1000 below the target, which it lifts from below; else at the
target. Its steps (`0x0040FF80`), each timed from its start:

| Step | What happens |
|---|---|
| 1 | The Ripper steers at the point (limit 0.3): at full throttle while more than 2000 beyond where it stops, at 0.2 nearer, and not at all within 2000 of the point, or 100 lifting from below; near it and not facing it within 0.7, it holds still. At rest, it plays `ready to grab` at 15 |
| 2 | From below, it turns to face the target until at rest |
| 3 | 150 ticks: the beams come on, as the square of the time; then the target is heard (sound `0x3D`) and no longer frozen |
| 4 | 300 ticks: the target is drawn halfway to 300 from the Ripper, toward it |
| 5 | 500 ticks: the target turns to match the Ripper, easing (`cosine_ease`) |
| 6 | 300 ticks: it is drawn the rest of the way; then heard (sound `0x3C`), and the Ripper plays `grab pod` at 10 |
| 7 | 150 ticks; then the Ripper plays `cabin turn` at 4.5 |
| 8 | 500 ticks |
| 9 | The target's part `Cargo pod` hides and the Ripper's shows; the target is disabled and as invulnerable as before; the Ripper carries it and flies astern (`motion_backward`); the order ends, with the Ripper's RipperGrabbedObject |

Should the target go first, the Ripper takes back its motion and the order ends. Its exit
(`0x00410B50`) lets the Ripper go and frees the beams.

Make ripper drop what it's carrying (39) (`0x00410B90`, `0x00410C00`) stops the Ripper, flies it by
`motion_plain`, held. Where the order names a ship, the Ripper fits what it carries to it instead
(order 112). Else, at rest (its speed and rates below 0.05, by their signs), it plays `grab pod` from
350 at -10, plays sound `0x3C` on no object (-1), and lets go: what it carries stands where its own
`Cargo pod` is, and shows in its place; the order ends, and Ripper end drop object (111) takes
over. What it drops stays disabled.

Ripper end drop object (111) (`0x00410E60`, `0x00410E90`) lets the Ripper go; it plays `ready to
grab` from 350 at -6, then backs away astern at 0.2 for 50 ticks, and plays `cabin turn` from 400 at
-4.5. Once its cabin is round, it turns, still flying astern, to put its tail to a point 10000 ahead
of it (limit 2) until at rest, and flies on (`motion_forward`): neither it nor what it dropped
passes through the other any more, it carries nothing, and it has its RipperDroppedObject.

Ripper attach cargo pod to Mammoth (112) (`0x00411200`, `0x00411420`) fits what the Ripper carries
to the component its target names. The Ripper flies astern to 2500 above the component, in its
frame, or below it on a Sharov or a Boridin: at full throttle beyond 2000, then by `motion_plain` at
0.2 until within 300. At rest, it faces the component (limit 2) and plays `grab pod` from 350 at
-10. Then the ship is no longer frozen, and the pod stands where the Ripper's own was; over 150
ticks the beams come on, and it is heard (sound `0x3D`), shown in place of the Ripper's and
enabled. Over 1000 ticks it eases onto the component, keeping its turn for the first 0.15 of the
time, then turning, easing, until half of it, to the component's orientation turned a quarter back
about its X on a Mammoth, a Sharov or a Boridin and about its Z on another. Heard as it arrives
(sound `0x3C`), the Ripper plays `ready to grab` from 350 at -6, then `cabin turn` from 400 at
-4.5, and once its cabin is round turns to put its tail to a point 10000 behind it. Then the pod
is gone into the ship: disabled, no longer targetable and hidden, and the component shows; the
Ripper flies on (`motion_forward`) and has its RipperDroppedObject, and it carries nothing from
then on.

A Mammoth's cargo slots stay hidden until the Ripper fills them because the mission's script
hides them: it disables the components as it makes the ship (`DisableObject`), which hides each
assembly. Mission 1 disables a squad that holds the Loadup Mammoth's components 3 to 24 as it
creates the ship's flight group.

**Fix:** where the next `rippercargo` entry is still taken, the game stops with "Ripper Grab AI
error: Too many rippers doing their stuff at once."; where a Ripper carries nothing, it stops with
"Can't find the object the ripper grabbed!"; and for a component of a type its table of the Mammoth
and the Stalag lacks, it reads the grab point's height past the table's end. OpenReliant logs the
first and takes the entry, ends the order for the second, and stands 2500 above the component for
the third.

**Fix:** Ripper attach cargo pod to Mammoth never clears the Ripper's `rippercargo` entry once the
pod is fitted, so what the Ripper carries stays that pod: each later drop or fit by the same Ripper
takes the pod it fitted first out of the ship again, while the pod last grabbed stays hidden where
it was lifted, and RipperDroppedObject names the wrong pod. OpenReliant clears the entry, as Ripper
end drop object does.

**Fix:** as its cabin turns back, Ripper attach cargo pod to Mammoth waits for the root's first
child, a forearm with no `cabin turn` track that the step before has already seen at rest, so the
Ripper turns away while its cabin is still turning. OpenReliant waits for the `Ripper Cabin` part,
as Ripper end drop object does.

**Fix:** Make ripper drop what it's carrying takes a negative index other than -1 for a ship's
slot, and its sound `0x3C`, which follows an object, plays on none; both read before the objects'
table. OpenReliant takes such an index for none, and plays nothing.

**Improvement:** the pod's turn as it fits divides the share past 0.15 by the span to 0.5, where
the game multiplies it by its rounded reciprocal (`0x004DC540`).

**Improvement:** the beams' orders place what they carry once a tick, and the game draws it there;
OpenReliant draws it on between the ticks, as far as a tick of the step would take it
(`create.Slot.glide`), as the target is drawn in (steps 4 and 6) and as the pod is carried onto the
component. `--no-smooth-motion` leaves it where each tick places it.

### Picking a fight

Find New Target's walk visits each ship with `0x0040AE90`, which passes over one the ship cannot aim
at, cloaked or not. It counts the objects with stats whose current order is aimed at that ship and
component: Fight, and Mill. The ship then weighs as one to fight the square of the distance times
one more than the ships that fight it, and as one to mill round, times one more than those and one
more than those that mill round it. The lightest of each is kept, but to fight only a ship that is
not cloaked, not the target set aside for the searcher (`+0x6AC`, which the radio's menu sets to the
player's target for 3000 ticks, `0x0045517F`), and for a fighter one that fewer than two others
fight. A set-aside target whose time is up (`+0x6B0` before `game_ticks`) is set aside no more, but
is passed over as one to fight this walk still.

**Quirk:** the game weighs the one to fight by 0.7 more (`0x004DC484`) where the count of objects it
has just walked through equals the player's slot, which never happens; it looks meant to favour the
player's ship ([#314](https://github.com/OpenReliant/openreliant/issues/314)). OpenReliant weighs as
the game does.
