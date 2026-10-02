# The game loop

How the payload paces a mission: a timer ticks 100 times a second, the loop runs one game tick for each tick of the timer, and objects move on every fourth tick. Function and variable names follow annotations in the Ghidra project (`make ghidra-annotate`).

## Ticks

`tick_timer` (`0x004827C0`) runs 100 times a second on a periodic multimedia timer created by `timer_start` (`0x004A70F0`), which `sound_init` sets up as the game starts, so that it runs in the front end as well as in a mission.

- Unless the game is paused (indicated by `paused`, `0x57E04C`), it advances `game_ticks` (`0x565064`), which counts from `sound_init` on, and the play time counters: ticks, seconds, minutes and hours at `0x565070` to `0x565076`. The play time rolls a second over after 101 ticks.
- `game_tick` also counts active ticks in `mission_ticks` (`0x587CC4`), which stops while the game is paused.
- The [script clock](script-vm.md#the-clock-and-timers) runs on its own timer once a second and also stops while paused.

## The loop

`mission_run` (`0x00494040`) sets the mission's clocks to zero, `mission_ticks`, `frame_start`, `frame_duration` and the play time counters, then loops:

- Each pass runs `game_tick` (`0x00477850`) once for each tick of `game_ticks` accumulated since the previous pass.
- Unless the game is paused, it then executes the frame work, `mission_frame` (`0x004924B0`). The simulation advances at a fixed rate regardless of display frame rate.
- The frame work runs every object's [orders](orders.md) via `orders_update`, and flushes script events once per frame.
- It begins with `frame_begin` (`0x00491E00`), which sets `frame_duration` (`0x588330`) to the ticks elapsed since `frame_start` (`0x5883B0`) and sets `frame_start` to `mission_ticks`; per-frame code measures elapsed time with these values.
- The loop ends once `mission_frame` says the mission is over, once the script has ended it (`TerminateMission` counts at `0x00588338`, which `mission_run` zeroes as it starts), or once the pause menu leaves it. A mission numbered below 28 that its script ended then ends as one the player's ship is destroyed in (`mission_ending` 1, `0x004941FC`).

`game_tick` counts `mission_ticks` on, and at every hundredth tick takes a second off the script's `countdown` ([Script VM](script-vm.md#the-games-variables)). It runs `simulation_step` (`0x004774D0`) unless the game is paused. `simulation_step` executes on every fourth call (25 times a second):

- Each object's individual updates.
- `objects_update` (`0x00468FA0`), which moves every object with `object_move` and handles collisions.
- Missile updates (`missiles_move`, `0x00495720`) and gun projectiles (`0x0047A4E0`).

The rates and speeds of the [flight model](objects.md#motion) are therefore measured per 1/25 of a second. Afterburner fuel burns 4 units per update from the ship's 100 per second stat, lasting that many seconds. Each frame draws moving objects interpolated between their last two positions based on elapsed ticks since the step ([Drawing between steps](objects.md#drawing-between-steps)), so visual motion advances 100 times a second.

## Porting

[`game/main.zig`](../../src/engine/game/main.zig) holds the clocks as `Clock`, with `frameBegin`, `frameReset`, `nextTick`, and `runTicks` for `mission_run` pacing (one game tick per timer tick). The ticking functions live in their respective files: `hog_snd.tickTimer` for `tick_timer` logic, and `gameobj.gameTick` and `gameobj.simulationStep`. OpenReliant runs the timer in a mission, and through the second before the hangar's movie ([Movies](movies.md#the-hangar)), and `Clock.start` sets `timer_ticks` and `game_ticks` to zero as well for each; the game's run on from `sound_init`.

**Improvement:** OpenReliant has no periodic timer. `advanceTo` takes the platform's monotonic count of hundredths of a second, and ticks come from the difference between counts rather than frame durations, so clocks keep to that count and nothing accumulates. The frame rate is decoupled from the tick rate in both directions: a frame shorter than 1/100 second runs no tick, a frame spanning several runs all of them in catchup, and a second of play is always 100 ticks and 25 simulation steps regardless of display refresh rate.

**Improvement:** `objects.stepFraction` counts elapsed time past the last tick, which `advanceToFine` maintains from a higher-precision timer, so moving entities update smoothly on every frame rather than stepping on ticks. Visual effects, which move by a velocity per tick, are drawn that far past the tick as well (`objects.pastTick`, and [Effects](effects.md#drawn-between-the-ticks)), and so is an object the orders place from tick to tick rather than move, by how far they place it a tick (`create.Slot.glide`): the pilot's pod drawn in by a tractor ([Ejection](ejection.md#scoop-up)), and an object with no flight stats under Fly. `--no-smooth-motion` and `--original` move objects on ticks, as the original does.

The simulation step processes objects in sequence ([The object array](objects.md#the-object-array)):

1. Each object's orientation is orthonormalized in turn.
2. Node updates, shield recharge, and the [guns' step](guns.md#the-step).
3. Player controls fly the player's ship while its active order is Player Control.
4. `objects_update` moves all objects, and [shots in flight](guns.md#shots) advance.
5. Each frame, `mission_frame` interpolates each object between its last two steps, checks shots against potential targets, and draws the scene after the camera frame.

Ported so far: the clocks, pacing, keyboard, joystick and mouse inputs (polled 25 times a second as `read_keyboard`, `read_joystick` and `read_mouse` do, rather than once per frame), simulation step work on objects and [missiles](missiles.md#flight), and per-frame orders and interpolation (`main.missionFrame`), which every mission runs with its script's frame's work.

Not yet: the countdown that `game_tick` steps once a second, and sound streaming that shares `tick_timer`.

## Collisions

After moving objects, `objects_update` gathers colliding candidates: slot index, collision radius (`0x59C`) times `visibility` (`0x12C`), and bounding sphere reach along X. It sorts the list by that reach (farthest first) and checks each object against subsequent ones whose spheres reach back to it. Pairs where either object lists the other in `passes_through` (`0x618`) or whose spheres do not overlap are skipped; remaining pairs route to `objects_collide` (`0x00466170`). Up to 10 collision passes run; on the tenth, the game displays "collision" on screen.

`objects_collide` checks the two objects' classes (`ShipCombat.class`, `+0x28`) and component lists:

| The pair | What happens |
|---|---|
| Two of one type, where either is a torpedo | Nothing |
| A torpedo that is already going off | Nothing |
| Either lists components, but not both, and neither is the limpet pod (`0xBC`) | The ship is tested against the other's collision tree, up to nine times over (`0x00465C50`), a torpedo once |
| Both list components | Nothing |
| Two torpedoes, two pieces of debris, or two satellites (`0x71`) | Nothing |
| Either is a mine, against a fighter | The fighter's fore quadrant takes 500 as a collision, the fighter named as its own attacker, and the mine is destroyed |
| A torpedo against anything else | What it met takes 5001 to its fore quadrant as a crash, named as its own attacker, and the torpedo is destroyed, ejecting no pilot |
| Anything else | The impact's damage, then both move again and are set apart |

Before separation, the two objects apply an impulse shove (`0x00464E80`). The contact point on each sphere moves with the object between steps, so a turning ship strikes with its wingtip speed. The impulse is calculated from closing velocity over both masses and `angular_response`, doubled so the bounce preserves relative impact speed, and applied equally and oppositely via `object_knock`. Attached objects and the Ripper with a captured victim receive no shove.

Two spheres collide along the line between their centers, applying no torque, so neither ship is set spinning. Hull faces do apply torque ([#143](https://github.com/OpenReliant/openreliant/issues/143)).

The pair is then separated along that line: each object is placed at 1.1 times its own radius from the midpoint between the two, preventing overlapping on the next step.

A ship colliding with an object that lists components tests against that object's collision tree ([Models](../formats/shp.md#tree-node-tag-0x07)): parts are traversed down to leaf nodes, and leaf faces within reach of the ship's sphere determine the nearest contact point. These are the file's own indexed faces, not the merged polygons the renderer draws. The ship is shoved at its center and the hull at the hit point, rotating the hull around the impact while the ship does not rotate.

A torpedo that strikes a hull (`collision_test_hull`, `0x004656CF`) takes no damage of its own:

- The hull lurches, unless its listing is disabled (`DisableListing`), or its current order is already a lurch, a jump or a warp: it takes Make capship list left (115) where the torpedo came in heading to its left, and right (116) otherwise ([Orders](orders.md)).
- The part struck takes 5001 as a crash (`component_damage`).
- Where that part belongs to an assembly and starts with less than 1000 armour, the first hull part the hull's model shows takes 5001 as well, of kind 4: unless the part struck is itself a hull part or the Ulysses' fin (`0x004F7480`), or that hull part is of its own assembly. For a part of a model mounted on the hull, the hull's first hull part shown whatever the part.
- The torpedo is destroyed (`object_destroyed`), and the pair is tested no more.

Impact damage is calculated from the collision impulse (`collision_damage`, `0x00465CA0`): 1/5 of the impulse divided by the lighter mass, halved, applied to the struck quadrant. The Ripper takes no damage. The player's fore or aft [shield reserve](controls.md#the-shield-balance) absorbs damage first. If the reserve is depleted, the shield takes damage; when down, armor absorbs the damage, updating armor condition, and the shield [flares](effects.md#shields). A ship striking a hull takes damage similarly, drawing twice the damage from reserve. Collisions do not count toward recent damage taken from an attacker, so they do not trigger retaliatory orders; weapon hits do.

Ported so far: the sweep, ignored pairs, shove impulse, object separation, hull collision tree tests, a torpedo's strike on a hull, and damage ([`collision.zig`](../../src/engine/game/collision.zig)). Collisions do not damage components but for a torpedo's strike.

A destroyed torpedo or mine runs Explode ([Destruction](objects.md#destruction)), through `object_destroyed_net` (`0x00402100`), which first tells the other players where a network session runs a mission that is not multiplayer's. Not ported: that message, and a mine's 5000 in a multiplayer game, which credits the kill to its owner ([#55](https://github.com/OpenReliant/openreliant/issues/55)).

Difficulty scales collision damage ([Destruction](objects.md#destruction)).
