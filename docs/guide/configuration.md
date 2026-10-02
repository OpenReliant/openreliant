# Configuration and options

Pass options when running `openreliant`:

```bash
./openreliant [<game-directory>] [<option>...]
```

If omitted, `game-directory` defaults to the current working directory `.`.

## The original

OpenReliant improves on the original's look and sound. `--original` turns the improvements off, and an option after it turns one back on.

| Option | Description |
|---|---|
| `--original` | The original's look and sound: 16-bit colour, one sample a pixel, bilinear filtering, lighting each vertex, light worked out on encoded colours, no shadows, motion that moves on with the game's ticks, a launching ship a frame behind the retainer that lowers it, lights from the latest shots only, muzzle flashes that light nothing and none from the turrets, a jump's flare that lights nothing, the force feedback's own effects only, a blow shaking the camera only while the controller rumbles, an explosion's debris lit by every light, its fireballs, rings, particles and burning bits as few, plain and brief as the original's, the Uber Explode as coarse, unlit and tied to the frame rate as the original's, a damaged ship's smoke as even as the original's, the shields' bubbles as coarse as the original's, the tractor beams as thin as the original's, the hangar's beacons falling short of the launching ship, a ship landing on the Reliant tilted as it came, its tube's door left open, the planets' atmospheres as coarse and fleeting as the original's and their terminators as hard, the Ice Field's rocks drawn only near the middle of the view, the loading screen's picture picked by the screen's width, the movies drawn at their size in the middle of the screen with Bink's blocks and its colour in steps of two pixels, the gates' tunnels as coarse as the original's, the ride through the worm rumbling the more often the higher the frame rate, the sun and its lens flares from their small textures and the sun's glow going out at once behind what hides it, the levels of detail changing as near as the original's, as little drawn a frame as the original allows, the marker for a target out of sight placed as the original misplaces it, a missile's sound left where it was launched, the radio's lines cut flat at their loudest and heard dry, Enriquez's last word in the briefing as loud as its recording, the interface's text in the game's bitmap fonts, and the sound mixed plainly in stereo |

## The mission

| Option | Description |
|---|---|
| `--mission <number>` | Play this mission at once rather than open the main menu: the number the game names its file by, `mission<number>.dte`, from a mod, the game's `missions` folder or `resource.hog`; 0 is OpenReliant's sandbox, which `openreliant` carries where the game has no mission 0 |
| `--ship <type>` | The ship type to fly, by its number in `shipstats.bin`, in place of the loadout screen's choice, with its default missiles; the mission's own by default, the Predator in mission 0 |
| `--view <0\|1\|2>` | The view it starts in, as the game's settings keep it: 0 the cockpit; 1 the chase view; 2 no cockpit. The settings' own by default, which the settings screen's VIDEO changes, or 0 without them |
| `--difficulty <easy\|medium\|hard>` | The game's difficulty: how hard hits land on your ship, and shots on the enemy. By default, as in the game, medium with `--mission`, where a new campaign's starts, and easy in the main menu until SET GAME DIFFICULTY sets it |
| `--music <file>` | A piece from the game's music folder to play from the start, until the mission's script plays its own; none by default |
| `--no-pause-menu` | With `--mission`, fly the mission again as soon as it ends, where it otherwise ends in the game's pause menu |

## Display

| Option | Description |
|---|---|
| `--fullscreen` | Fill the display; Alt and Enter switch while playing |
| `--size <width>x<height>\|<percent>%` | Draw frames of this size in pixels whatever the window's, which shows them scaled, as for a screenshot larger than the display; or a share of the window's own, such as `50%`, to draw faster; the window's own by default |
| `--fps <rate>` | Frames a second at most; without vsync, the display's rate by default; 0 for no limit |
| `--no-vsync` | Draw without waiting for the display |

## Graphics

| Option | Description |
|---|---|
| `--software` | Draw on the software device, OpenReliant's reference, rather than the GPU |
| `--16-bit` | 16-bit colour, dithered |
| `--msaa <1\|2\|4\|8>` | Samples a pixel, for smooth edges; 4 by default |
| `--filter <original\|trilinear\|crisp>` | How textures are filtered; `crisp` by default (trilinear, sixteen times anisotropic, and magnified with a Catmull-Rom filter, or the nebulae with a smooth cubic one; the bitmap fonts' text is drawn crisp from its glyphs' coverage) |
| `--no-bloom` | Draw without the bloom around bright things |
| `--no-dither` | Draw 32-bit colour without dithering |
| `--no-pixel-lighting` | Light each vertex rather than each pixel, as the original does |
| `--gamma-space` | Light, blend and filter the encoded colours, as the original does, rather than in linear light |
| `--no-materials` | Light the mods' textures without their material maps: no normal maps or reflections, and the original's highlights in place of the maps' ([Modding](modding.md#material-maps)) |
| `--shadows <off\|low\|high>` | Shadows from the sun: low is soft and light on older GPUs, high sharp and smooth; high by default, and none without lighting each pixel |
| `--no-cockpit-shadows` | Leave the shadows out of the cockpit, keeping them on the ships |
| `--no-smooth-motion` | Move what moves on with the game's ticks, a hundred a second, as the original does, rather than on every frame |
| `--few-shot-lights` | Light only the latest two of the player's shots and the latest two of everyone else's, as the original does |
| `--bitmap-fonts` | Write the interface's text in the game's own bitmap fonts, magnified to the window, rather than in outline fonts drawn at its resolution: Newtown, built in, or a mod's ([Modding](modding.md#fonts)) |

## Sound

| Option | Description |
|---|---|
| `--hrtf` | Place the sounds for headphones whatever the output; by default they are while the output is headphones |
| `--no-hrtf` | Place the sounds for speakers whatever the output |
| `--no-reverb` | Play the sounds around you, the cockpit's voice and the Reliant's rooms without reverb |
| `--no-compressor` | Leave the mix's loudness as it is, only keeping its peaks in check |
| `--no-sound` | Play without sound |

## Other options

| Option | Description |
|---|---|
| `--no-mods` | Play the game's own files alone, without the mods in its `mods` folder ([Modding](modding.md)) |
| `--no-intro` | Start without the three movies the game plays as it starts, as `--mission` and `--screenshot` do |
| `--screenshot <file.png>` | Draw one frame, with the camera settled, to a PNG, and quit; the controls, the `[OpenReliant]` settings and the details in `[Device]` are not read, so that it comes out the same each time |
| `--screenshot-ticks <ticks>` | With `--screenshot`, how many game ticks to run first, one a frame, so that the scene plays out; 2 by default |
| `--version` | Show the version |
| `-h`, `--help` | Show the help page |

## Commands

| Command | Description |
|---|---|
| `openreliant install` | Install the game's files from the StarLancer discs into a directory |
| `openreliant joysticks` | List the joysticks and gamepads, and which one the game uses |
| `openreliant missions` | List the game's missions, its own and those added to its `missions` folder, and check that each loads |

Each command's `--help` shows its options.

### Missions of your own

A mission file named `mission<number>.dte`, stored expanded, in the `missions` folder of the game's directory plays in place of that mission, as it does in the original: the game reads a loose file before its own copy in `resource.hog`. The retail game ships two, `mission18.dte` and `mission25.dte`. Check that a mission loads with:

```bash
./openreliant missions StarLancer
```

It lists every mission, where each comes from (`loose` or `archive`), and what its file holds, including the ship type and name of the player's own record, and says which fail to load. A mission can carry a name for OpenReliant to show, in a section of the file the original game ignores: see [OpenReliant's mission name](../formats/dte.md#openreliants-mission-name).

## In-flight keys

The flight keys are the game's own, as `starlancer.ini` binds them. Among them:

| Key | Action |
|---|---|
| Escape | Open the pause menu |
| F1 | Open the controls ([Controllers and input](controllers.md#the-controls-screen)) |
| 1 to 8 | Camera views: 1 cockpit, 2 left, 3 right, 4 rear, 5 flyby, 6 target, 7 external, 8 missile |
| C | Open the radio menu, whose number keys call your wingmen and the base |
| F5 to F8 | Give orders to your wingmen, and request landing |
| 0 | Save a screenshot, a PNG in the `screenshots` folder of the game directory; O does the same in the briefing |

In the target view (6) and external view (7), arrow keys orbit around the object and Shift with Up or Down zooms.

OpenReliant adds:

| Key | Action |
|---|---|
| F2, F3 | In the sandbox, start it again in the previous or next ship type |
| F4 | In the sandbox, bring in another wing |
| Alt+Enter | Switch between windowed and fullscreen mode |

## Configuration file (starlancer.ini)

Settings are read from `starlancer.ini` in the game directory. The game keeps its volumes, its view and its brightness there:

```ini
[Sound]
Mastervolume=127
Fxvolume=80
Musicvolume=80
Speechvolume=127

[Device]
View=0
gamma=100
Transitions=1
```

`[Sound]` keeps the four volumes, from 0 to 127, which the settings screen's AUDIO changes. `[Device]` keeps the view a mission starts in (`View`: 0 the cockpit, 1 the chase view, 2 no cockpit), the brightness in hundredths (`gamma`), whether the movies between the front end's screens and into the Reliant's rooms play (`Transitions`, 1 or 0), and the details, which take effect at the next start: the texture detail (`Tdetail`: 0 low, 1 medium, 2 high), the graphic detail (`Gdetail`, the same) and the light maps (`Lmaps`, 1 or 0). The settings screen's VIDEO changes them all. A screenshot taken with `--screenshot` draws at the highest details, whatever the file says. The controller's settings and the bindings, in `[KeyConfig]` and `[JoyConfig]`, are in [Controllers and input](controllers.md#settings).

### OpenReliant's settings

OpenReliant keeps its own settings in the same file, in its `[OpenReliant]` section, which the original game never reads. They are the options above, kept from one run to the next. Options on the command line change them for that run only.

```ini
[OpenReliant]
Original=1
Bloom=1
Samples=8
```

| Setting | Values | Option |
|---|---|---|
| `Original` | 1 for the original's look and sound; the settings below then change it. VIDEO's GRAPHICS writes it: ORIGINAL as 1, MODERN by taking it out | `--original` |
| `Fullscreen` | 1 or 0, which VIDEO's FULL SCREEN sets | `--fullscreen` |
| `Size` | `<width>x<height>`, or a share of the window's own such as `50%`, which VIDEO's RESOLUTION sets | `--size` |
| `FrameRate` | Frames a second at most, which VIDEO's FRAME RATE LIMIT sets; 0 for no limit, and without it, the display's rate where vsync is off | `--fps` |
| `Vsync` | 1 or 0, which VIDEO's VSYNC sets | `--no-vsync` |
| `Software` | 1 or 0 | `--software` |
| `SixteenBit` | 1 or 0, which VIDEO's COLOR DEPTH sets: 16-BIT or 32-BIT | `--16-bit` |
| `Samples` | 1, 2, 4 or 8, which VIDEO's ANTI-ALIASING sets | `--msaa` |
| `Filter` | `original`, `trilinear` or `crisp`, which VIDEO's TEXTURE FILTER sets | `--filter` |
| `Bloom` | 1 or 0, which VIDEO's BLOOM sets | `--no-bloom` |
| `Dither` | 1 or 0, which VIDEO's DITHER sets | `--no-dither` |
| `PixelLighting` | 1 or 0, which VIDEO's PER-PIXEL LIGHTING sets | `--no-pixel-lighting` |
| `LinearLight` | 1 or 0, which VIDEO's LINEAR LIGHT sets | `--gamma-space` |
| `Materials` | 1 or 0, which VIDEO's MATERIALS sets | `--no-materials` |
| `Shadows` | `off`, `low` or `high`, which VIDEO's SHADOWS sets | `--shadows` |
| `CockpitShadows` | 1 or 0, which VIDEO's COCKPIT SHADOWS sets | `--no-cockpit-shadows` |
| `SmoothMotion` | 1 or 0, which VIDEO's SMOOTH MOTION sets | `--no-smooth-motion` |
| `ShotLights` | 1: every shot lights the ships it passes; 0: the latest two of each side's, as the original; which VIDEO's SHOT LIGHTS sets | `--few-shot-lights` |
| `OutlineFonts` | 1 or 0, which VIDEO's OUTLINE FONTS sets: the interface's text drawn from outline fonts, or in the game's bitmap fonts | `--bitmap-fonts` |
| `Hrtf` | `auto`, `on` or `off`, which AUDIO's 3D SOUND sets: AUTOMATIC, HEADPHONES or SPEAKERS | `--hrtf`, `--no-hrtf` |
| `Reverb` | 1 or 0, which AUDIO's REVERB sets | `--no-reverb` |
| `Compressor` | 1 or 0, which AUDIO's COMPRESSOR sets | `--no-compressor` |

In the example, the game has the original's look and sound, but with the bloom and eight samples a pixel. A setting you leave out keeps its default, or `Original`'s where it is 1.

The settings screen keeps the graphics' settings so: a preset chosen with VIDEO's GRAPHICS is written as `Original` alone, and a graphics option changed after it is written only where it differs from what `Original` gives, and taken out where it is the same. As `Original` plays the original's mixer, ORIGINAL writes `Hrtf`, `Reverb` and `Compressor` beside it while OpenAL Soft plays the sound, so that the sound stays as AUDIO has it. A screenshot taken with `--screenshot` leaves this section out, so that it comes out the same for everyone.
