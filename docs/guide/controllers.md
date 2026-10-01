# Controllers and input

OpenReliant supports joysticks and gamepads: flight sticks, sticks with a throttle, HOTAS sets that connect with a single USB cable, old gameport sticks on USB adapters, and gamepads such as Xbox, PlayStation and Nintendo Switch controllers. You can connect a controller before starting the game or while it is running. The keyboard still works when a controller is connected.

## Which controller is used

OpenReliant uses one controller at a time. If several are connected, it prefers a joystick over a gamepad, and it never picks a standalone throttle while a stick is connected. To choose a controller yourself, see [Choosing a controller](#choosing-a-controller).

## Gamepad controls

| Control | Action |
|---|---|
| Left stick | Pitch and turn. Push forward to pitch the nose down |
| Right stick left and right | Roll |
| Right stick up and down | Increase and decrease speed |
| Right trigger | Fire lasers |
| Left trigger | Launch missile |
| A (bottom button) | Afterburner, while held |
| B (right button) | Match target speed |
| X (left button) | Countermeasures |
| Y (top button) | Target nearest enemy |
| Right bumper | Next enemy target |
| Left bumper | Previous enemy target |
| Left stick click | Toggle afterburner |
| Right stick click | Target what is under the reticle |
| Back, View or Share | Change radar range |
| D-pad | Look left, right or back while held; up looks forward |

The face buttons are identified by position, not by label: the bottom button is A on an Xbox controller, cross on a PlayStation controller and B on a Nintendo controller.

Some mapped actions (such as gun groups, comms and damage windows) are not implemented in OpenReliant yet. They are mapped now so they work once they are added.

The left stick works like a flight stick: pushing it forward points the nose down. To invert this, set `JoystickInvert=0` (see [Settings](#settings)).

## Rumble

A controller with rumble motors, such as an Xbox, PlayStation or Nintendo Switch controller, plays StarLancer's force-feedback effects as rumble: each gun has its own, and so do launching a missile, hits on your shields and hull, crashes, shockwaves and the afterburner. `ForceFeedback=0` turns it off (see [Settings](#settings)).

Rumble can't push a stick the way the original's force-feedback joysticks did. Flight sticks without motors play nothing.

## Flight stick controls

| Control | Action |
|---|---|
| Stick left and right | Turn, banking into the turn |
| Stick forward and back | Pitch the nose down and up |
| Throttle | Speed: fully forward is full throttle |
| Twist | Nothing by default; set `TwistEnable=1` to roll with it |
| Hat | Look left, right or back while held; forward looks forward |
| Button 0 (trigger) | Fire lasers |
| Button 1 | Launch missile |
| Button 2 | Afterburner, while held |
| Button 3 | Target nearest enemy |
| Button 4 | Strafe right |
| Button 5 | Next friendly target |
| Button 7 | Strafe left |

These are StarLancer's own defaults. Button numbers start at 0, as shown by `openreliant joysticks`, so the button your stick calls 1 is button 0 here. To roll with the stick instead of turning, hold the Insert key. If your stick has no throttle, use the keyboard throttle keys.

## Checking your controller

`openreliant joysticks` lists the connected controllers, shows which one the game will use, and for joysticks shows which axis is used for what. Open a terminal in the folder where you extracted OpenReliant, and run:

```bash
./openreliant joysticks StarLancer
```

On Windows, use `.\openreliant.exe` instead of `./openreliant`. `StarLancer` is the folder the game is installed in; the tool reads your settings from there. For a joystick it prints something like this:

```text
1. Logitech Extreme 3D (used by the game)
   joystick, USB ID 046d:c215, 4 axes, 12 buttons, 1 hat
   X: axis 0, Y: axis 1, throttle: axis 3 (automatic), twist: axis 2 (automatic)
   To choose it: Joystick=Logitech Extreme 3D
```

The third line says which axis the game uses for what. `(automatic)` marks OpenReliant's guess from the number of axes, and `(ThrottleAxis)` or `(TwistAxis)` marks a choice from your `starlancer.ini`. The last line is the setting that picks this controller when several are connected.

To see live input as the game reads it, add `--watch`:

```bash
./openreliant joysticks StarLancer --watch
```

```text
X  1000  Y     0  throttle   500  twist  1000  hat   -
Buttons down: 0
Axis  0:  100% (X)
Axis  1:    0% (Y)
Axis  2:  100% (twist)
Axis  3:    0% (throttle)
```

The view updates in place as you move the controls. The first line shows the values as the game reads them. The second shows the buttons held down, by their numbers; on a gamepad, each with its name. For a joystick, a line for each axis follows: its number, how far it is moved, from -100% to 100% of its travel, and what the game uses it for. Move a control or press a button and see which number changes: that is the number to give `ThrottleAxis`, `TwistAxis` or `JOY BUTTON`. Axis and button numbers start at 0. Press Ctrl+C to stop.

## Settings

StarLancer stores its settings in `starlancer.ini` in the game folder, and OpenReliant reads the same file. If it does not exist, create it with a text editor:

```ini
[KeyConfig]
JoystickInvert=1
TwistEnable=1
HatEnable=1
Controller=0

[JoyConfig]
DeadZone=5
Joystick=Extreme 3D
ThrottleAxis=3
TwistAxis=2
ThrottleInvert=0
FIRE LASERS=JOY BUTTON 0
LAUNCH MISSILE=JOY BUTTON 1
```

A setting you leave out keeps its default.

| Setting | Section | Default | Description |
|---|---|---|---|
| `JoystickInvert` | `KeyConfig` | 1 | 1: pull back to pitch up. 0: inverted |
| `TwistEnable` | `KeyConfig` | 0 (1 for gamepads) | 1: the stick's twist, or a gamepad's right stick, rolls the ship |
| `HatEnable` | `KeyConfig` | 1 | 1: the hat, or a gamepad's D-pad, looks around |
| `Controller` | `KeyConfig` | 0 | 0: use the joystick or gamepad. 1: use the keyboard |
| `ForceFeedback` | `KeyConfig` | 1 | 1: the controller rumbles, where it can. 0: it doesn't |
| `DeadZone` | `JoyConfig` | 10 | How far an axis must move before it registers, in percent of its travel (0 to 100) |
| `Joystick` | `JoyConfig` | | Part of the name of the controller to use |
| `ThrottleAxis` | `JoyConfig` | automatic | Number of the throttle axis, or -1 for none |
| `TwistAxis` | `JoyConfig` | automatic | Number of the twist axis, or -1 for none |
| `ThrottleInvert` | `JoyConfig` | 0 | 1: reverse the throttle axis |

**Improvement:** `DeadZone`, `Joystick`, `ThrottleAxis`, `TwistAxis` and `ThrottleInvert` are OpenReliant settings; the original game ignores them. Axis numbers are the ones `openreliant joysticks` shows.

### Button bindings

To bind a button to an action, add `ACTION NAME=JOY BUTTON number` to the `JoyConfig` section. For a joystick, use the button numbers shown by `openreliant joysticks --watch`. For a gamepad, the numbers are always these:

| Number | Gamepad button | Number | Gamepad button |
|---|---|---|---|
| 0 | A / cross (bottom) | 16 | Right paddle 1 |
| 1 | B / circle (right) | 17 | Left paddle 1 |
| 2 | X / square (left) | 18 | Right paddle 2 |
| 3 | Y / triangle (top) | 19 | Left paddle 2 |
| 4 | Back, View or Share | 20 | Touchpad click |
| 5 | Guide (Xbox or PS button) | 21 to 25 | Other extra buttons |
| 6 | Start or Menu | 26 | Left trigger |
| 7 | Left stick click | 27 | Right trigger |
| 8 | Right stick click | 28 | Right stick up |
| 9 | Left bumper | 29 | Right stick down |
| 10 | Right bumper | 30 | Right stick left |
| 11 | D-pad up | 31 | Right stick right |
| 12 | D-pad down | | |
| 13 | D-pad left | | |
| 14 | D-pad right | | |
| 15 | Capture, mute or other extra button | | |

The action names are:

COCKPIT CAMERA, LEFT VIEW CAMERA, RIGHT VIEW CAMERA, REAR VIEW CAMERA, FLYBY CAMERA, TARGET CAMERA, EXTERNAL CAMERA, MISSILE CAMERA, NEXT ENEMY TARGET, PREVIOUS ENEMY TARGET, NEXT FRIENDLY TARGET, PREVIOUS FRIENDLY TARGET, NEXT SUBTARGET, PREVIOUS SUBTARGET, TARGET UNDER RETICULE, TARGET NEAREST ENEMY, TARGET NEAREST FRIENDLY, TARGET TORPEDO, SMART TARGET, PRIMARY TARGET, AFTERBURNERS, AFTERBURNER TOGGLE, REVERSE THRUST, JUMP DRIVE, MATCH SPEED, ACCELERATE, DECELERATE, ZERO THROTTLE, FULL THROTTLE, ROLL SHIP CLOCKWISE, ROLL SHIP ANTI-CLOCKWISE, NOSE UP, NOSE DOWN, ROTATE CLOCKWISE, ROTATE ANTI-CLOCKWISE, STRAFE LEFT, STRAFE RIGHT, JOYSTICK ROLL, FIRE LASERS, FULL GUNS, GUNNERY WINDOW, GUNNERY WINDOW LOCKED, SYNCHRONISE GUNS, TOGGLE BLINDFIRE, LAUNCH MISSILE, MISSILE WINDOW, ROTATE MISSILES CLOCKWISE, ROTATE MISSILES ANTICLOCKWISE, COMMS WINDOW, POWERBALL WINDOW, POWERBALL WINDOW LOCKED, FULL POWER TO GUNNERY, FULL POWER TO ENGINES, FULL POWER TO SHIELDS, EQUALIZE POWER, OBJECTIVES WINDOW, WING STATUS WINDOW, WING STATUS WINDOW LOCKED, DAMAGE WINDOW, DAMAGE WINDOW LOCKED, RADAR RANGES, SHIELD BALANCING, COUNTERMEASURES, EJECT, CLOAK SHIP, ECM, SPECTRAL SHIELDS, ATTACK MY TARGET, BACK OFF, HELP ME, PERMISSION TO LAND, DISPLAY KILLS, SEND COMMS MESSAGE, KEY CONFIG.

For example, `STRAFE LEFT=JOY BUTTON 13` and `STRAFE RIGHT=JOY BUTTON 14` strafe with the D-pad. In that case also set `HatEnable=0`, otherwise the D-pad looks around as well.

### Choosing a controller

If several controllers are connected, `Joystick` selects the first one whose name contains the given text (not case-sensitive). For example, `Joystick=xbox` uses an Xbox controller even when a stick is connected.

## Common controllers

- **Xbox, PlayStation, Nintendo Switch and most other gamepads**: work out of the box with the gamepad controls above.
- **Sticks with a twist and a throttle**, such as the Logitech Extreme 3D Pro: work out of the box. Set `TwistEnable=1` if you want to roll with the twist.
- **HOTAS sets with a single USB cable**, such as the Saitek/Logitech X52: work out of the box. Use `openreliant joysticks --watch` to check that the right axis is used as the throttle, and set `ThrottleAxis` if it is not.
- **Stick and throttle with separate USB cables**: OpenReliant only reads the stick for now ([#114](https://github.com/vdmkenny/openreliant/issues/114)). Use the keyboard for the throttle, or bind ACCELERATE and DECELERATE to buttons on the stick.
- **Old gameport sticks on a USB adapter**: steering and buttons work; use the keyboard for the throttle.
- **Gamepads listed as a joystick**: SDL, the library OpenReliant uses for controllers, does not recognize the gamepad, so its right stick is treated as a throttle. Set `ThrottleAxis=-1` and `TwistAxis=2`. Alternatively, add a mapping for the gamepad to a `gamecontrollerdb.txt` file in the game folder to get the full gamepad controls. The [SDL_GameControllerDB](https://github.com/mdqinc/SDL_GameControllerDB) project has mappings for thousands of gamepads.

If your controller needs any of these settings, or does not work at all, please open an issue on GitHub and include the output of `openreliant joysticks`, so support can be improved.

## Troubleshooting

- **The controller is not listed**: Check that your system detects it. On Linux, you need read access to its device in `/dev/input`; desktop sessions normally give this to the logged-in user.
- **The ship drifts or turns by itself**: Your stick does not rest exactly in the center. Increase `DeadZone`.
- **Small movements do nothing**: Decrease `DeadZone`. The default of 10 is large for a modern stick.
- **The throttle works in reverse**: Set `ThrottleInvert=1`.
- **The wrong axis controls the throttle or twist**: Find the right axes with `openreliant joysticks --watch` and set `ThrottleAxis` and `TwistAxis`.
