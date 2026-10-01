# Controls

How the payload reads the player's keyboard, joystick and mouse, and turns them into the inputs of the [flight model](objects.md#motion). The names below are those `make ghidra-annotate` gives the Ghidra project; [`src/engine/input.zig`](../../src/engine/input.zig) defines the structures.

## Devices

`input_init` (`0x004BCD90`) creates DirectInput 7 and three devices:

- the keyboard, shared with other programs and read only while the game is in the foreground;
- the mouse, held exclusively while the game is in the foreground;
- a joystick. `input_init` first enumerates the attached joysticks that have force feedback, and `joystick_found` (`0x004BD190`) opens each it is handed. With none, `input_init` enumerates any attached joystick and clears `force_feedback` (`0x50E1A4`); otherwise, while that flag is set, `load_force_effects` (`0x004BD800`) loads the effects from `forces\*.frc` ([Force feedback](#force-feedback)).

For the joystick, `joystick_object_found` (`0x004BD050`) sets the range of each axis the game uses and records that the device has it in `joystick_axes` (`0x5DDC4C`), a `JoystickAxes` with a flag for each axis in the order of `DIJOYSTATE`:

| Axis | Range | Flag |
|---|---|---|
| X | -1000 to 1000 | `x` |
| Y | -1000 to 1000 | `y` |
| Z | 0 to 1000 | `z` |
| Rz, the twist | -1000 to 1000 | `rz` |
| First slider | 0 to 1000 | `slider` |

A dead zone of a tenth of the range applies to the whole device. `joystick_buttons` (`0x5DDC54`) holds the button count and `joystick_name` (`0x5DDB48`) the product name.

`input_acquire` (`0x004BD780`) acquires the three devices, or unacquires them while the word at `0x5DDD28` is set, and `input_shutdown` (`0x004BD3F0`) releases them.

## Reading

`simulation_step` reads the three devices at the start of each step, so 25 times a second (see
[the game loop](loop.md)):

| Function | Into | State |
|---|---|---|
| `read_keyboard` (`0x004BD490`) | `keyboard` (`0x595C68`) | 256 bytes by DirectInput scan code (`DIK_*`), nonzero while the key is down |
| `read_joystick` (`0x004BD300`) | `joystick` (`0x588340`) | `JoystickState`, DirectInput's `DIJOYSTATE` |
| `read_mouse` (`0x004BD3A0`) | `mouse` (`0x588398`) | `MouseState`, DirectInput's `DIMOUSESTATE2`: the movement since the previous read, and eight buttons |

The front-end screens read the keyboard themselves.

## Bindings

`control_bindings` (`0x4E2380`) holds a `ControlBinding` for each action: a scan code, a modifier
(none, Shift, Ctrl or Alt, either key of the pair), the name the game shows, and a joystick button
or -1. [`src/engine/input/controls.zig`](../../src/engine/input/controls.zig) lists the actions,
numbered as the game numbers them, with the bindings the game starts with; `make control-tables`
transcribes it from the executable.

`load_key_config` (`0x0042C800`) reads the input settings and the bindings from the `KeyConfig`
and `JoyConfig` sections of `starlancer.ini` in the game's directory. The settings are in
`KeyConfig`:

| Entry | Default | Meaning |
|---|---|---|
| `ForceFeedback` | 1 | `force_feedback_setting` (`0x51DA4C`). While it is 0, no force-feedback effect plays ([Force feedback](#force-feedback)). |
| `JoystickInvert` | 1 | `joystick_invert` (`0x51D610`). While it is 0, pitch is reversed, from the stick, the keys and the mouse. |
| `HatEnable` | 1 | `hat_enabled` (`0x52029C`). While it is set, the hat looks around ([The hat](#the-hat)). |
| `TwistEnable` | 0 | `twist_enabled` (`0x595D88`). While it is set, the joystick's twist rolls the ship. |
| `Controller` | 0 | `control_mode` (`0x57E064`), the device the player steers with: 0 the joystick, 1 the keyboard, 2 the mouse. With no joystick, `load_key_config` makes 0 into 1 (`0x0042C8A5`), and `key_config_defaults` chooses 1 (`0x0042CAF2`). |

Each action also has an entry in each section, named after the action. In `KeyConfig` the value is
a scan code in decimal, optionally after `SHIFT `, `CONTROL ` or `ALT ` for a modifier, or
`JOY BUTTON ` and a button number; in `JoyConfig` it is `JOY BUTTON ` and a button number. Button
numbers start at 0. A missing entry keeps the default binding: `load_key_config` formats the current
binding the way it writes it, and passes that as the default to `GetPrivateProfileStringA` for both
sections.

That has two bugs, which only show when the file is edited by hand, since the game always writes
both sections:

- When the `KeyConfig` entry has a modifier, the check for `JOY BUTTON ` in the `JoyConfig` value
  starts after the modifier's length, so an action bound to a key with a modifier can never also
  have a joystick button.
- The `JoyConfig` default is the binding as it was before the `KeyConfig` entry was read, so a
  `JOY BUTTON` in `KeyConfig` is overwritten by the old button when `JoyConfig` has no entry.

**Improvement:** OpenReliant fixes both: it checks the `JoyConfig` value from its start, and uses
the button from `KeyConfig` as the `JoyConfig` default.

### The defaults

`key_config_defaults` (`0x0042CAA0`) sets the input settings and the bindings to the game's
defaults, which `load_key_config` then changes from `starlancer.ini`. `hud_init` calls the two for
each mission (`0x00483F06`), the controls screens as they open, and RESET DEFAULTS the first alone.
The settings are those of the table above, but for `Controller`, which it makes 1 where no joystick
is attached (`0x0042CAF2`), and the twist, whose setting it turns off (`twist_setting`,
`0x51D458`) but not `twist_enabled`, which goes on rolling until `load_key_config` sets it from the
setting.

The bindings come from `default.txt` in the game's directory (`game_directory`), an ini file of the
same two sections, which the game ships. It clears each action's button first, so that an action
has a button only where the file gives it one, in either section. A `KeyConfig` value names a key by
the executable's English name, as `key_names_english` (`0x004E6958`, a copy of `key_names`) holds
it, after `SHIFT ` or `CONTROL `: `]`, `CURSOR UP` or `SHIFT E`. An action the file doesn't name
keeps its key and its modifier, and a name the keys lack keeps the key. It compares four bytes of
`ALT`, its terminator among them, so that only a value of `ALT` alone is read as Alt, and as no key.
A `JoyConfig` value gives a button where a digit follows `JOY BUTTON `, looked for past
`KeyConfig`'s modifier, as `load_key_config` looks.

The shipped `default.txt` differs from the executable's table in three bindings, which are so the
game's defaults: FULL THROTTLE is `]` rather than `\`, JOYSTICK ROLL `/` rather than Insert, and
COUNTERMEASURES has joystick button 6 besides H.

**Fixes:**

- OpenReliant looks for `JOY BUTTON ` in a `JoyConfig` value from its start, as it does for
  `load_key_config`.
- It chooses the joystick, which steers once one is attached ([Porting](#porting)).
- It turns the twist off with its setting, where the game leaves it rolling, its box shown off,
  until the bindings load again.

**Improvement:** where the game's directory has no `default.txt`, OpenReliant keeps the
executable's table, its buttons too, where the game leaves every action without a button. A mod's
`default.txt` stands in for the game's, and a gamepad keeps the buttons of its own layout.

## Whether an action is active

`control_active` (`0x00412630`) takes an action and a flag, `once`. Without `once` an action counts
for as long as its button or key is down; with it, only once for each press.

1. **The joystick button**, if the action has one and it is down. With `once` it counts only while
   the button is not latched, and latches it; `read_joystick` clears the latch in
   `button_latched` (`0x5DDC98`) once the button is up.
2. **The key.** The keys 1 to 8, scan codes 2 to 9, never count while the word at `0x501EE8` is
   3: that is the phase of the display's window 11, the communications menu, open, whose number
   keys call the units in range ([`hud.md`](hud.md#the-windows)). Otherwise, without `once`, a key
   bound with no modifier counts while it is down and neither Shift nor Ctrl is; a key with a
   modifier counts while it and either key of the modifier are down. With `once`,
   `control_active` asks `key_pressed`.

`key_pressed` (`0x004BD570`) takes a scan code, a modifier and `once`, and is what the front-end
screens use too. It keeps a latch for each key, `key_latched` (`0x5D54EC`), and one for each
modifier, `shift_latched`, `control_latched` and `alt_latched`. `read_keyboard` clears a key's
latch once the key is up, and a modifier's once both its keys are up.

- **With `once`**, the key counts while it is down and not latched, and, with no modifier, while
  no Shift, Ctrl or Alt key is down, or with one, while either key of the modifier is down. Then
  it latches the key and the modifier.
- **Without `once`**, the key counts while it is down and, with no modifier, while no modifier is
  latched, or with one, while either key of the modifier is down. Then it clears the key's latch
  and the modifier's.

## The hat

`frame_controls` reads the joystick's first hat while `hat_enabled` is set and the joystick has a
hat. Held straight forward, left, right or back, the hat switches to the cockpit's front, left,
right or rear view, every frame while it is held; diagonals do nothing. `hat_glancing`
(`0x51CF8C`) records that the hat is in use, so that the view returns to the front once it is
released. Camera keys pressed in the same frame take priority.

## Steering

`player_controls` (`0x00413410`) is the update of the order numbered 100, `Player Control`, which
the player's ship follows in flight (see [orders](orders.md)). It runs whenever the ship's orders
run: once a frame, from `orders_update`, and once each simulation step, from `simulation_step`,
before the objects move. The devices are read only at each step, so the runs in between see the
same state, and what `player_controls` steps each time it runs changes at a rate that depends on
the frame rate. It sets the ship's roll, pitch, yaw and lateral inputs and its throttle. Axis
values are scaled by 0.001, so the stick's travel spans -1 to 1.

- **Joystick** (`control_mode` 0). X yaws and Y pitches. The keys ROLL SHIP CLOCKWISE and ROLL SHIP
  ANTI-CLOCKWISE roll at 1 and -1, and while JOYSTICK ROLL is held, X rolls instead of yawing.
  With `twist_enabled` and a twist axis, X, Y and the twist yaw, pitch and roll. The throttle
  axis, Z or else the first slider, sets the throttle to `1 - value * 0.001`, so 0 is full
  throttle and 1000 none. Without either, the keys set it (see below).
- **Keyboard** (1). Each run while ROTATE CLOCKWISE or ROTATE ANTI-CLOCKWISE is held steps yaw by
  -0.3 or 0.3, and NOSE UP or NOSE DOWN steps pitch by 0.3 or -0.3; with neither key of a pair
  held, that input is zero. The flight model clamps each input to between -1 and 1, so a held key
  reaches full deflection on the fourth run. The roll keys roll as with the joystick. While the
  word at `0x539A34` is 6 or 12, yaw and pitch stay zero.
- **Mouse** (2). The mouse's movement gathers into a stick position, which the order's own data
  keeps as two 16-bit counts, each held to within `mouse_range` (`0x4E2378`), 800, of the centre.
  As a fraction `v` of 800, each axis gives 0 while `|v|` is under `mouse_dead_band`
  (`0x4E237C`), 0.3, and `1.3 * v - 0.3` above it or `1.3 * v + 0.3` below it. X yaws, and Y
  pitches reversed, so that moving the mouse forward raises the nose; the roll keys roll and the
  throttle keys set the throttle. The left button fires the lasers as FIRE LASERS does, and the
  right launches a missile as LAUNCH MISSILE does, once for each press, which
  `mouse_missile_latched` (`0x51CEFA`) records.

  **Fix:** `player_controls` adds the movement of the last read each time it runs, once a frame as
  well as once a step, so the faster the frames, the further a movement steers. OpenReliant adds
  each read's movement once. OpenReliant holds the mouse to the window, its pointer hidden, while
  the player flies in this mode, as the game holds DirectInput's mouse, and lets it go for the pause
  menu.

In each mode, half the yaw input is added to the roll input, so the ship banks into turns, and
`joystick_invert` sets the sign of pitch. STRAFE LEFT and STRAFE RIGHT set the lateral input to -1
and 1. While the player holds the `reversed_controls` deathmatch power-up (9), all four inputs are
reversed.

While SHIELD BALANCING or POWERBALL WINDOW is held, or the flag at `0x51CF04` is set, the stick
doesn't steer: the four inputs are zeroed, the throttle isn't read, and the stick's position goes
to [the shield balance](#the-shield-balance) or [the power distribution](#the-power-distribution)
instead, in that order of priority. The joystick's X and Y are the stick; with the keyboard,
ROTATE CLOCKWISE and ROTATE ANTI-CLOCKWISE count as -1 and 1 across and NOSE UP and NOSE DOWN as
-1 and 1 down; the mouse gives its movement times 64 over 800. `0x51CF04`'s routine
(`0x00413200`) turns two angles at `0x51CF30` and `0x51CF00` by the stick, and `frame_controls`
clears the flag on every frame OBJECTIVES WINDOW isn't pressed. **Unknown:** what sets the flag,
and what the angles turn.

## Throttle

With the keyboard or the mouse, or a joystick without a throttle axis, `player_controls` calls
`player_throttle_keys` (`0x004132C0`). It steps `throttle_setting` (`0x51CF7C`) and the ship's
throttle by 0.02 each run while ACCELERATE or DECELERATE is held, fifty runs from none to full,
and ZERO THROTTLE and FULL THROTTLE, once for each press, set them to 0 or 1 and stop MATCH
SPEED. Then it sets the ship's throttle to `throttle_setting`; its check of `afterburner` first
always passes there, since `object_orders` has cleared the flag. `player_controls` keeps the
throttle between 0 and 1, and at most 0.5 while the player holds the `half_throttle` deathmatch
power-up (7).

MATCH SPEED, once for each press, flips `matching_speed` (`0x579984`), putting back
`throttle_before_match` (`0x566794`) as it turns off and matching at once as it turns on. While it
is set, `match_target_speed` (`0x00412C10`) runs each update: it sets the throttle to the player's
target's speed over the player's cruise speed, at most 1, while the target is within 330000 units
and not exploding, keeping the throttle it found in `throttle_before_match`; a cloaked target
leaves the throttle as it is. Past that range it puts back `throttle_before_match` and stops
matching, as it does with no target at all, then without putting anything back. Since it keeps
the throttle each time, what it puts back is the throttle of its last match. OpenReliant runs this
part of `player_controls` after the rest (`input.matchSpeed`), where the game runs it among the
keys after the throttle's and the strafe keys; nothing between reads the throttle.

## Afterburner and reverse thrust

AFTERBURNERS, while held, and AFTERBURNER TOGGLE, which flips `afterburner_toggled` (`0x51CEFE`)
once for each press, set the ship's `afterburner`. REVERSE THRUST, while held, sets its
`reverse_thrust`. `object_orders` clears both before each order update, so each lasts until the
order next runs unless set again. After the update it clears both when the ship has no afterburner
fuel, both and the throttle while its engines are disabled (`DisableEngines`), and `reverse_thrust`
unless the ship has the `can_reverse` flag.

While the player asks for either, a warning sounds when fewer than 20 seconds of fuel are left and
another when it is out, each at most once every 1000 ticks, ten seconds; `fuel_warning_tick`
(`0x5799C0`) holds the tick before which neither sounds again.

`frame_controls` reads ATTACK MY TARGET, BACK OFF and HELP ME once for each press, outside a
multiplayer mission, outside the front end's simulator (`0x0057E044`) and where the game's mode
(`0x00524FE4`) is 0, and only while the player's target is a hostile ship that can be aimed at:
each gives its command to a wingman the game picks
([The wingmen's commands](radio.md#the-wingmens-commands)). It reads PERMISSION TO LAND next, once
for each press outside a multiplayer mission, which asks the carrier the player launched from to
clear the ship to land ([Landing](orders.md#landing)).

`player_controls` also reads FIRE LASERS, LAUNCH MISSILE, CLOAK SHIP, JUMP DRIVE, EJECT and
COUNTERMEASURES, all but FIRE LASERS once for each press. LAUNCH MISSILE and COUNTERMEASURES are in
[Missiles](missiles.md#the-players). While the byte at `0x529FB8` is set, it
reads none of them, nor MATCH SPEED, AFTERBURNER TOGGLE, the throttle keys or the keys that turn
the ship. **Unknown:** what sets that byte.

## The power distribution

The player shares the ship's power between its shields, guns and engines by moving a point on a disc
of radius 64, the power ball (`GameObject.power_setting`, `+0x728`). Each system has an anchor on
the ball, a third of a turn from the next: the shields at (0, 1), the guns at (0.866, -0.5) and the
engines at (-0.866, -0.5), the game's 0.866 standing for √3/2, which OpenReliant uses itself.
`power_distribute` (`0x00412560`) works out each system's share: `power_reach` (`0x004124E0`)
measures the distance from the point to the edge of the disc going away from the system's anchor,
which is 128 at the anchor, 64 in the middle and 0 opposite, and a share is that distance over the
three together. A share `s` gives a factor of `(1.75 - 0.75 * s) * s + 0.5`: 1 for an even third,
1.5 for all of the power and 0.5 for none.

| Offset | Factor | What it scales |
|---|---|---|
| `0x734` | Guns | How fast the guns recharge (`0x004770E0`) |
| `0x738` | Engines | The cruise speed ([Motion](objects.md#motion)) |
| `0x73C` | Shields | How fast the shields recharge ([Shields](objects.md#shields)) |

`create_object` puts the point at (1, 1) and the three factors at 1.

- FULL POWER TO GUNNERY, FULL POWER TO ENGINES, FULL POWER TO SHIELDS and EQUALIZE POWER, while
  held and the radio's window is shut, put the point at (54.17, -30.32), (-55.79, -27.94),
  (0.699, 61.98) and (1, 1), work out the factors and open the power window. EQUALIZE POWER's
  point is a little off the middle, toward the shields, so its factors aren't all 1.
- While POWERBALL WINDOW is held (`powerball_held`, `0x51CEF8`), `power_move` (`0x00413180`)
  moves the point against the stick by the frame's ticks times its deflection each time
  `player_controls` runs, brings it back to the edge of the disc if it leaves it, and works out
  the factors again.

The display shows the point and the shares in its [power window](hud.md#the-power-distribution).

## The shield balance

While SHIELD BALANCING is held (`0x51CEFC`), `shield_balance` (`0x00412D40`) shifts shields fore or
aft by the stick's Y. Each time `player_controls` runs with Y past half-way, a quarter of the ship's
shield power moves: from the fore shield to the aft one while Y is above 0.5, and back while it is
below -0.5, as long as the shield it comes from has any left. The quarter comes out of that side's
reserve first (`0x51CF78` for the fore shield, `0x51CF34` for the aft one), then out of the shield.
The shield it goes to holds at most five times the shield power, and what goes beyond that is added
to its reserve, which holds as much again. A reserve keeps the other side's shield from
[recharging](objects.md#shields) to full. The ship status display shows each reserve as a second arc
outside the fore or aft shield's ([Head-up display](hud.md#the-elements)).

## Force feedback

With a force-feedback joystick, `load_force_effects` reads 13 of the files in `forces\`
([`.frc`](../formats/frc.md)) into `force_effects` (`0x5DDC58`), each through the SideWinder Force
Feedback SDK (`force_effects_read`, `0x004BDB10`), and downloads the missile's. While
`ForceFeedback` is on, each place that plays an effect starts the first of its file's:

| File | Played by |
|---|---|
| `lc`, `pc`, `mb`, `gl`, `tc`, `np`, `cg`, `gp`, `vb`, `nc` | The player's shot of that gun type, from the Laser Cannon to the Nova Cannon (`bullet_place`); `nc` also as the Nova Cannon releases its charge (`nova_release`) |
| `prc` | Nothing: `bullet_place`'s switch has no case for the Proton Cannon, whose shot plays `lc` |
| `Missile` | The player's missile launch (`missile_launch`) |
| `Shake` | A shot striking the player's ship, and each frame while the camera shakes from hits by more than 0.1 (`force_shake`, `0x004BE000`), unless it is playing |

A blow to the player's ship, with a force-feedback joystick only (`damage_feedback`, `0x00463E10`,
from `object_damage` and `object_armor_damage`, with the damage after the difficulty's scaling):

- A shot's starts `Shake`, and raises the camera's shake (`hit_shake`) by 0.05 of its damage while
  it is below 1, up to 1.
- Any other adds a push of 300 times its damage on the side struck to the frame's hits
  (`force_hits`, the latest 20), and raises the shake as much, up to 2.

Each frame `mission_frame` sums the frame's hits by side (`force_hit_pushes`, `0x004BE060`): the
left's less the right's push across, the fore's less the aft's along. A net above 1 plays a push, a
one-second sine at 2 Hz toward that side, as strong as the net out of 10000, in the next of nine
play slots (`force_slots`), freeing what played there. A push from the left is aimed at 90000, a
typo for 9000 hundredths of a degree, which DirectInput turns down.

The game never reads the folder's other files: `Accl`, `AcDc`, `Afterburn`, `Decl`, `Guns` (the
same as `lc`), `Hullshock` to `Hullshock3`, `landhard`, `Shield`, `Shock` and `shiver`.

### In OpenReliant

[`input/force.zig`](../../src/engine/input/force.zig) reads the effects as `load_force_effects`
does (`load`), whatever the controller, and plays them as rumble. Each frame it works out how hard
every effect playing pushes at that moment: a waveform slower than 10 Hz swings
the controller's low-frequency motor as it swings, a faster one buzzes the high-frequency motor at
its strength, and envelopes and gains scale both. A file of several effects plays whole, a
sequence one member after the other and a superimposition all at once; the game starts only the
first of the effects the SDK made of it. The platform sends the motors' speeds to SDL at most every
40 ms. Rumble cannot show which way an effect or a push pushes, which a force-feedback joystick
would ([#244](https://github.com/vdmkenny/openreliant/issues/244)).

- **Improvement:** any controller that rumbles plays the effects, gamepads among them.
- **Fix:** the Proton Cannon's shot plays `prc`.
- **Improvement:** a blow shakes the camera whatever the controller (`input.force.HitShake`).
- **Improvement:** the files the game never reads play where they fit (`input.force.Unread`):
  `Shield` as a blow strikes the player's shields, the `Hullshock` of the side struck as one
  strikes the hull (left, right, fore and aft in turn), `landhard` for a collision, `Shock` as a
  shockwave passes, and `Afterburn` while the afterburner burns.

`--original` plays the game's own effects alone, and shakes the camera for blows only while the
controller rumbles.

## Porting

The bindings and `starlancer.ini` hold DirectInput scan codes, which follow the IBM PC's set 1
scan codes, with the extended keys at `0x80` and up. OpenReliant names them in `input.Key` and
maps SDL's scan codes to them ([`platform/keyboard.zig`](../../src/platform/keyboard.zig)).

[`input.zig`](../../src/engine/input.zig) ports the input code: `key_pressed` and
`read_keyboard`'s latches (`Keyboard`), the joystick (`Joystick`: `joystick_found`,
`joystick_object_found` and `read_joystick`), and `control_active` with both keys and buttons
(`Devices.active`). The joystick is read through `JoystickDevice`, an interface with the calls the
game makes on its DirectInput device: capabilities, axis ranges, dead zone and polling.
[`platform/joystick.zig`](../../src/platform/joystick.zig) implements it for SDL's joysticks and
gamepads ([Platform](../port/platform.md#joysticks-and-gamepads)). `Devices` holds what the game
keeps in globals: the device states, the bindings and the settings.

`playerControls` and `playerThrottleKeys` port the joystick and keyboard parts of the two
routines above. `Player` holds `throttle_setting`, `matching_speed`, `afterburner_toggled`, the
two held flags and the shield reserves. The engine runs them where `simulation_step` does, once
per step, before the objects move. The game also runs `player_controls` once a frame from
`orders_update`, which isn't ported yet ([#32](https://github.com/vdmkenny/openreliant/issues/32)),
so for now the keyboard steers, the stick moves the power and SHIELD BALANCING shifts the shields
more slowly than in the game.

[`input/power.zig`](../../src/engine/input/power.zig) ports the power distribution and the shield
balance: `reach`, `shares`, `distribute`, `choose` for the power keys, `move` and
`balanceShields`.
`Camera.frameControls` ports the hat. `load_key_config` is ported in
[`game/interface.zig`](../../src/engine/game/interface.zig), with the fixes above, and with it
`save_key_config`, `control_binding_find` and `key_config_defaults`; the controls screen that sets
them is the settings screen ([Front end](front-end.md#controls));
[`profile.zig`](../../src/engine/profile.zig) reads the file as `GetPrivateProfileIntA` and
`GetPrivateProfileStringA` do.

**Improvement:** OpenReliant reads `starlancer.ini` again whenever a controller is connected or
disconnected, since the settings and bindings depend on the controller. A gamepad gets its own
default bindings, and keeps its buttons in a section of its own, `GamepadConfig`, since
OpenReliant numbers them otherwise than a joystick's; its right stick, the twist, always rolls
(`input.Devices.twistRolls`). `DeadZone` in `JoyConfig` sets the dead zone, which the original
fixes at a tenth. A joystick that is disconnected is closed and reads as centered, where the
original tries to acquire it again.

**Fix:** with no joystick attached, the game makes `Controller` 1 itself, which its controls screen
then writes, so that a game started once without the joystick steers with the keyboard ever after.
OpenReliant keeps the joystick as the choice and steers with the keyboard while none is attached
(`input.Devices.controlMode`); and its settings screen writes the controls as it is left only
where they are not what the file gives already ([Front end](front-end.md#controls)).

Not yet ported: force feedback ([issue 83](https://github.com/vdmkenny/openreliant/issues/83)), the
weapons and other actions `player_controls` reads, and the special cases for the byte at `0x529FB8`,
the player's deathmatch power-up and the flags at `0x51CEF8`, `0x51CEFC` and `0x51CF04`.
`object_orders` clears the two burns before each order update and, after it, when the ship is out of
fuel or its engines are disabled; only the fuel check is ported, in `playerControls` itself, since
nothing runs orders yet.
