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

[`game/main.zig`](../../src/engine/game/main.zig) holds the clocks as `Clock`, with `frameBegin`, `frameReset`, `nextTick`, and `runTicks` for `mission_run` pacing (one game tick per timer tick). The ticking functions live in their respective files: `hog_snd.tickTimer` for `tick_timer` logic, and `gameobj.gameTick` and `gameobj.simulationStep`. OpenReliant runs the timer in the loops that wait on it: the missions, the rooms and their screens, the movies, and the second before the hangar's movie ([Movies](movies.md#the-hangar)). `Clock.start` starts a loop's clocks again: the mission's from zero, while `timer_ticks` and `game_ticks` keep running, as the original's do from `sound_init`, so the sound's fades, which it times by `game_ticks`, carry on.

**Improvement:** OpenReliant has no periodic timer. `advanceTo` takes the platform's monotonic count of hundredths of a second, and ticks come from the difference between counts rather than frame durations, so clocks keep to that count and nothing accumulates. The frame rate is decoupled from the tick rate in both directions: a frame shorter than 1/100 second runs no tick, a frame spanning several runs all of them in catchup, and a second of play is always 100 ticks and 25 simulation steps regardless of display refresh rate.

**Improvement:** `objects.stepFraction` counts elapsed time past the last tick, which `advanceToFine` maintains from a higher-precision timer, so moving entities update smoothly on every frame rather than stepping on ticks. The drawn frame alone places them so ([Game frames and drawn frames](#game-frames-and-drawn-frames)). Visual effects, which move by a velocity per tick, are drawn that far past the tick as well (`objects.pastTick`, and [Effects](effects.md#drawn-between-the-ticks)), and so is an object the orders place from tick to tick rather than move, by how far they place it a tick (`create.Slot.glide`): the pilot's pod drawn in by a tractor ([Ejection](ejection.md#scoop-up)), and an object with no flight stats under Fly. `--no-smooth-motion` and `--original` move objects on ticks, as the original does.

The simulation step processes objects in sequence ([The object array](objects.md#the-object-array)):

1. Each object's orientation is orthonormalized in turn.
2. Node updates, shield recharge, and the [guns' step](guns.md#the-step).
3. Player controls fly the player's ship while its active order is Player Control.
4. `objects_update` moves all objects, and [shots in flight](guns.md#shots) advance.
5. Each game frame, `mission_frame` interpolates each object between its last two steps and checks shots against potential targets; each drawn frame draws the scene after the camera frame.

Mods' global and object scripts run at the end of each simulation step (`on_step`), and in each game frame, after the orders (`on_update`) ([Scripting](../port/scripting.md#the-games-scripts)).

Ported so far: the clocks, pacing, keyboard, joystick and mouse inputs (read 25 times a second as `read_keyboard`, `read_joystick` and `read_mouse` do, rather than once per frame), simulation step work on objects and [missiles](missiles.md#flight), and per-frame orders and interpolation (`main.missionFrame`), which every mission runs with its script's frame's work.

Not yet: the countdown that `game_tick` steps once a second, and sound streaming that shares `tick_timer`.

### Game frames and drawn frames

**Improvement:** the game runs `mission_frame` once a drawn frame, after all the ticks since the last one. So the orders, the script, the missiles, the shots and the effects run as often as the screen is drawn, and the objects are framed by how far into the step the frame falls. The same mission then plays differently at different frame rates.

OpenReliant splits the frame in two:

- **Game frames.** `main.gameFrames` runs the frame's game work (`main.missionFrame`) once a tick, right after the tick, the way the game runs it on a screen drawn 100 times a second. The game frames run on a thread of their own, which the main thread waits for (`main.runGameFrames`): for now the two take turns, so nothing they share is used by both at once. `frame_start` and `frame_duration` are the game frame's, so `frame_duration` is one tick. Each game frame frames the objects at `simulation_counter / 4` of the step, without the wall clock ([Drawing between steps](objects.md#drawing-between-steps)). It reads the controls first, as `frame_controls` (`0x00414060`) does: the camera keys, the targeting keys and the frame keys, so a key pressed between game frames is read in the next. The targeting keys take the object under the reticle, and blind fire its aim, as drawing found them in the scene it last drew (`hud.State.aim`, [Display](hud.md#the-targeting-cluster)), and the effects that depend on the camera go by where it stood as that scene was drawn ([What the game keeps](camera.md#what-the-game-keeps)). The cloaks change in the game frame too ([Cloak](cloak.md#in-openreliant)), and so does the display's work on the game, such as the devices' charges and the windows opening and closing ([Display](hud.md#how-it-is-reached)).
- **Drawn frames.** Once a drawn frame, the camera, the sound and the display run, timed by the ticks since the drawn frame before (`Clock.drawBegin`, `drawn_start` and `drawn_duration`). They work on a copy of the game, which the next paragraphs describe. The missiles' trails also run here, so that each lays its newest ring where its missile is drawn.

Each drawn frame works on a copy of the game (`main.Drawn`), so whatever drawing changes, such as the planets the atmospheres turn, changes only the copy:

- The objects and the missiles, with their models, guns and shield bubbles. An effect that hangs from a part, such as an electric ray or a capital ship's shield, finds the part's copy there (`objects.PartOf.live`). With smooth motion, the copy stands as far on as the clock has run past the tick in between.
- The records drawing reads: the player's record, with the view, the display's state, the mission's variables, the radio, the clock and the shake from hits.
- The effects, which the game frames move on and drawing draws ([Effects](effects.md#drawn-between-the-ticks)).

The camera, the sound, the HUD, the player and menu scripts and `drawFrame` all read the copy, through the world as the drawn frame sees it (`main.Drawn.world`), so drawing writes nothing into the game's records. What drawing keeps from one drawn frame to the next, it keeps in records of its own, which it makes as it first draws each thing from what the game keeps of it: what the rays and the shields show, the tractors' beams, bubbles and lights, the Rippers' beams, and the portals that cut the copy of the objects ([Rendering](rendering.md)).

The copies share with the game only what it doesn't change once it has made it, such as the types' meshes. Some of that the game lets go of during a game frame: the radio film's bytes as a line ends, a break-up piece's mesh as its flight ends, an ion cannon's or a gate's record, the worm and the warp projection as they go, and an object's extra as it leaves. It hands them to a list instead (`main.retired.Retired`), which the main thread lets go of as the next drawn frame begins, once the frame before is done. So drawing can run beside the game frames without reading memory the game has let go of. Each model's order of parts is copied with the model for the same reason (`objects.Model.copy`).

The game frames don't switch or place the camera themselves: the camera takes up the switches of view they made as it frames ([What the game keeps](camera.md#what-the-game-keeps)). A switch of view made while the frame is drawn, by a mod's script or `--watch`, switches the copy of the view at once. What drawing hands the game, its switches of view, where the camera stood as the frame was drawn and what the player aimed at, the game takes up at the start of the next pass and before a mission starts (`main.Handed`), so it finds them just as if drawing had written them into its records at once.

Every frame drawn until the next game frame shows what an order showed in the game frame before it, as the game adds it to that frame's scene: the tractors, the Rippers' beams, the ion cannons' effects, the gates' flashes, the worm and the Boridin breakaway's projection, and the jumps' effects. The game frame clears these before its orders (`beginFrame`). The electric rays move on, the capital ships' shields go, the gates' tunnels take their shape and the screen's flash counts down in the game frames too ([Effects](effects.md#electric-rays), [Gates](gates.md), [Splits](effects.md#splits)).

What the game frames ask of drawing they give as cues, in order, which each drawn frame takes up as it begins (`main.cues.Cues`): a missile's or a torpedo's trail starting, with where the tail stood as it started, and its missile ending; a planet made or its flight group destroyed, for its atmosphere; the nebula a space's update asks for, and the backdrop placed again as the script asks; and each mission's start, which lets go of the trails and the atmospheres and starts the escort marker's pulse and Planet Bombard's flashes again. So the game frames write nothing into what drawing keeps, and a world that nothing draws gives no cues.

The game frames read devices of their own, which take up what the main thread read of its devices before each tick ([Controls](controls.md#reading)). So they never read the main thread's devices, and a press counts once whichever side reads it.

The game frames ask for their sounds too, which the main thread plays right after them ([Sound](sound.md#the-game-frames-sounds)). So they never touch the sound.

So the game frames' work plays the same way at any frame rate. A run paced one tick per drawn frame, as a screenshot is, plays as before.

The director's shots run in the game frames too, so their CameraReached events come at the same
ticks at any frame rate ([The director's camera](director.md)).

## Random numbers

The game draws its random numbers from the C runtime's `rand` (`0x004CF555`), a linear
congruential generator that steps its seed as `seed * 0x343FD + 0x269EC3` and gives bits 16 to 30,
from 0 to 32767. The game uses a number directly, as in `rand() % n`, or divides it by 32767 to get
a fraction from 0 to 1. Each object also has its own random numbers (`object_random15`,
`0x004ADCE0`), whose seed, at `+0x638` of the object, steps the same way.

**Improvement:** OpenReliant draws the game's numbers from Zig's `std.Random`
([`random.zig`](../../src/engine/random.zig)), in the same range as `rand`, so the game's code uses
them unchanged. The sequences differ from the original's. An object's own numbers still step the
original's way, because the seed is part of the object's record.

**Improvement:** what is only drawn, the camera's shake, the display's flicker, the lights and the
missiles' trails, draws from random numbers of its own, so that how often the screen is drawn
leaves the game's numbers as they are ([Game frames and drawn frames](#game-frames-and-drawn-frames)).
So do the effects the game sets off, the particles, the explosions' fireballs and bits, the sparks,
the rays and the shots' looks (`gameobj.World.effects_random`). The game draws those from its own
numbers only where the effects are drawn, so without this a game that draws nothing would go on from
other numbers. The explosions' sounds' pitch comes from the sound's own numbers
([Sound](sound.md#playing)). Where nothing is drawn, the explosions run only their part in the game
([Effects](effects.md#where-nothing-is-drawn)).

## Collisions

After moving objects, `objects_update` gathers colliding candidates: slot index, collision radius (`0x59C`) times `visibility` (`0x12C`), and bounding sphere reach along X. It sorts the list by that reach (farthest first) and checks each object against subsequent ones whose spheres reach back to it. Pairs where either object lists the other in `passes_through` (`0x618`) or whose spheres do not overlap are skipped; remaining pairs route to `objects_collide` (`0x00466170`). Up to 10 collision passes run; on the tenth, the game displays "collision" on screen.

`objects_collide` checks the two objects' classes (`ShipCombat.class`, `+0x28`) and component lists:

| The pair | What happens |
|---|---|
| Two of one type, where either is a torpedo | Nothing |
| A torpedo that is already going off | Nothing |
| Either lists components, but not both, and neither is the limpet pod (`0xBC`) | The ship is tested against the other's collision tree, up to nine times over (`objects_collide_parts`, `0x00465C50`), a torpedo once. Before each test, a ship meeting a training hoop (`0x83`) may fly through it ([Events](script-vm.md#events)) |
| Both list components | Nothing |
| Two torpedoes, two pieces of debris, or two satellites (`0x71`) | Nothing |
| Either is a mine, against a fighter | The fighter's fore quadrant takes 500 as a collision, the fighter named as its own attacker, and the mine is destroyed |
| A torpedo against anything else | What it met takes 5001 to its fore quadrant as a crash, named as its own attacker, and the torpedo is destroyed, ejecting no pilot |
| Anything else | The impact's damage, then both move again and are set apart |

Before separation, the two objects apply an impulse shove (`0x00464E80`). The contact point on each sphere moves with the object between steps, so a turning ship strikes with its wingtip speed. The impulse is calculated from closing velocity over both masses and `angular_response`, doubled so the bounce preserves relative impact speed, and applied equally and oppositely via `object_knock`. Attached objects and the Ripper with a captured victim receive no shove.

Two spheres collide along the line between their centers, applying no torque, so neither ship is set spinning. Hull faces do apply torque.

The pair is then separated along that line: each object is placed at 1.1 times its own radius from the midpoint between the two, preventing overlapping on the next step.

A ship colliding with an object that lists components tests against that object's collision tree ([Models](../formats/shp.md#tree-node-tag-0x07)): parts are traversed down to leaf nodes, and leaf faces within reach of the ship's sphere determine the nearest contact point. These are the file's own indexed faces, not the merged polygons the renderer draws. The ship is shoved at its center and the hull at the hit point, rotating the hull around the impact while the ship does not rotate.

Before that, the player's ship is tested against the trigger polygons of the hull's parts
([Models](../formats/shp.md#trigger-polygon-tag-0x0f)), each part's in turn (`collision_test_hull`,
`0x00465380`). Where its step, from where it stands to where it goes next, each in the part's frame
as the part stands then, changes side of a polygon's plane and goes through the polygon, through
one of its triangles or a quad's second, the ship posts its InsideObject (`0x1C`) going to the back
of the plane, or its OutsideObject (`0x1D`) to the front ([Script VM](script-vm.md#events)).
Going into a Stalag (`0x45`) sets `0x005883F8` and coming out clears it, as does a mission's start.
While it is set, the Stalag's turrets aim anywhere, whatever their firing arcs
([Guns](guns.md)), and its shots may strike the Stalag itself. Only the Stalag's model ships trigger
polygons, which mission 14 waits on to let the player target the Stalag's interior turrets.
**Fix:** the game takes a step that crosses a triangle's plane anywhere as going through the
triangle; OpenReliant only one that goes through it. No shipped polygon is a triangle.

A torpedo that strikes a hull (`collision_test_hull`, `0x004656CF`) takes no damage of its own:

- The hull lurches, unless its listing is disabled (`DisableListing`), or its current order is already a lurch, a jump or a warp: it takes Make capship list left (115) where the torpedo came in heading to its left, and right (116) otherwise ([Orders](orders.md)).
- The part struck takes 5001 as a crash (`component_damage`).
- Where that part belongs to an assembly and starts with less than 1000 armour, the first hull part the hull's model shows takes 5001 as well, of kind 4: unless the part struck is itself a hull part or the Ulysses' fin (`0x004F7480`), or that hull part is of its own assembly. For a part of a model mounted on the hull, the hull's first hull part shown whatever the part.
- The torpedo is destroyed (`object_destroyed`), and the pair is tested no more.

Impact damage is calculated from the collision impulse (`collision_damage`, `0x00465CA0`): 1/5 of the impulse divided by the lighter mass, halved, applied to the struck quadrant. The Ripper takes no damage. The player's fore or aft [shield reserve](controls.md#the-shield-balance) absorbs damage first. If the reserve is depleted, the shield takes damage; when down, armor absorbs the damage, updating armor condition, and the shield [flares](effects.md#shields). A ship striking a hull takes damage similarly, drawing twice the damage from reserve. Collisions do not count toward recent damage taken from an attacker, so they do not trigger retaliatory orders; weapon hits do.

Ported so far: the sweep, ignored pairs, shove impulse, object separation, hull collision tree tests, the trigger polygons, a torpedo's strike on a hull, and damage ([`collision.zig`](../../src/engine/game/collision.zig)). Collisions do not damage components but for a torpedo's strike.

A destroyed torpedo or mine runs Explode ([Destruction](objects.md#destruction)), through `object_destroyed_net` (`0x00402100`), which first tells the other players where a network session runs a mission that is not multiplayer's. Not ported: that message, and a mine's 5000 in a multiplayer game, which credits the kill to its owner ([#55](https://github.com/OpenReliant/openreliant/issues/55)).

Difficulty scales collision damage ([Destruction](objects.md#destruction)).
