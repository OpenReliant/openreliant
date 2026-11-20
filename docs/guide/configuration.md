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
| `--original` | The original's look and sound: 16-bit colour, one sample a pixel, bilinear filtering, lighting each vertex, light worked out on encoded colours, no shadows, motion that moves on with the game's ticks, a launching ship a frame behind the retainer that lowers it, lights from the latest shots only, muzzle flashes that light nothing and none from the turrets, a jump's flare that lights nothing, the force feedback's own effects only, a blow shaking the camera only while the controller rumbles, an explosion's debris lit by every light, its fireballs, rings, particles and burning bits as few, plain and brief as the original's, the Uber Explode as coarse, unlit and tied to the frame rate as the original's, a damaged ship's smoke as even as the original's, the shields' bubbles as coarse as the original's, the tractor beams as thin as the original's, the hangar's beacons falling short of the launching ship, a ship landing on the Reliant tilted as it came, its tube's door left open, the planets' atmospheres as coarse and fleeting as the original's and their terminators as hard, the Ice Field's rocks drawn only near the middle of the view, the bombardment of Titan in mission 25 unseen, the loading screen's picture picked by the screen's width, the movies drawn at their size in the middle of the screen with Bink's blocks and its colour in steps of two pixels, the gates' tunnels as coarse as the original's, the ride through the worm rumbling the more often the higher the frame rate, the sun and its lens flares from their small textures and the sun's glow going out at once behind what hides it, the stars shining right up to the sun, the levels of detail changing as near as the original's, the marker for a target out of sight placed as the original misplaces it, a missile's sound left where it was launched, the player's own jump-in sound unheard after a long jump, the radio's lines cut flat at their loudest and heard dry, Enriquez's last word in the briefing as loud as its recording, the loadout's ships and missiles solid, the interface's text in the game's bitmap fonts, and the sound mixed plainly in stereo |

## The mission

| Option | Description |
|---|---|
| `--mission <number>` | Start this mission right away instead of opening the main menu. The number is the one in the mission's file name, `mission<number>.dte`, loaded from a mod, the game's `missions` folder or `resource.hog`. Mission 0 is OpenReliant's sandbox, which is built into `openreliant` for games without a mission 0 |
| `--ship <type>` | The ship type to fly, by its number in `shipstats.bin` or its name, such as `predator` or a mod's `teapot:teapot` ([The records](scripting.md#the-records)), in place of the loadout screen's choice, with its default missiles; the mission's own by default, the Predator in mission 0 |
| `--view <0\|1\|2>` | The view it starts in, as the game's settings keep it: 0 the cockpit; 1 the chase view; 2 no cockpit. The settings' own by default, which the settings screen's VIDEO changes, or 0 without them |
| `--difficulty <easy\|medium\|hard>` | The game's difficulty: how hard hits land on your ship, and shots on the enemy. By default, as in the game, medium with `--mission`, where a new campaign's starts, and easy in the main menu until SET GAME DIFFICULTY sets it |
| `--music <file>` | A piece from the game's music folder to play from the start, until the mission's script plays its own; none by default |
| `--no-pause-menu` | With `--mission`, fly the mission again as soon as it ends, where it otherwise ends in the game's pause menu |
| `--skip-launch` | With `--mission`, play the player's launch through without drawing it, so that the mission shows from the moment the ship is out; `--screenshot-ticks` count from there |
| `--part <name\|number>` | With `--mission`, run this part of the mission's script once the player's launch is over, as a trigger would. Name it by its number, or by its name or a piece of it in any case, as `sltool dte parts` lists them, such as `--part "antanov in"`. Give it again for more parts, up to 8, which run in the order given. The part runs where the mission is, so a part that needs ships from an earlier part may find them missing |
| `--watch <name\|number>` | With `--mission`, watch this ship of the mission once the player's launch is over and the ship is there, from a place beside it that moves with it. Name it by its number, or by its name or a piece of it in any case, as `sltool dte ships` lists them. It is the game's own watch view, with the bars of a cutscene and no head-up display, but it doesn't end the mission after six seconds as the game's does. The mission's script can still take the camera, and then keeps it |
| `--watch-from <x,y,z>` | Where `--watch` watches from, in the ship's own axes, in multiples of its size: `x` to its right, `y` down and `z` ahead. `1,-0.5,2.5` by default: ahead of it, to its right and above |

`--skip-launch`, `--part` and `--watch` wait for the player's launch to end. In a mission whose
player doesn't launch, the launch counts as over 600 ticks, six seconds, into the mission.

## Display

| Option | Description |
|---|---|
| `--fullscreen` | Fill the display; Alt and Enter switch while playing |
| `--size <width>x<height>\|<percent>%` | Draw frames of this size in pixels whatever the window's, which shows them scaled, as for a screenshot larger than the display; or a share of the window's own, such as `50%`, to draw faster; the window's own by default |
| `--fps <rate>` | Frames a second at most; without vsync, the display's rate by default; 0 for no limit |
| `--no-vsync` | Draw without waiting for the display |
| `--fov <degrees>` | How far the views you fly in see up and down, from 34 to 94 degrees; the original's, about 64, by default. A wider window shows more at the sides |
| `--ui-scale <percent>` | How large the display and the pause menu are drawn, from 50 to 100 percent of the size the menus are drawn at; 80 by default, the original's size at 800 by 600 |

## Graphics

| Option | Description |
|---|---|
| `--16-bit` | 16-bit colour, dithered |
| `--msaa <1\|2\|4\|8>` | Samples a pixel, for smooth edges; 4 by default |
| `--filter <original\|trilinear\|crisp>` | How textures are filtered; `crisp` by default (trilinear, sixteen times anisotropic, and magnified with a Catmull-Rom filter, or the nebulae with a smooth cubic one; the bitmap fonts' text is drawn crisp from its glyphs' coverage) |
| `--no-bloom` | Draw without the bloom around bright things |
| `--no-dither` | Draw 32-bit colour without dithering |
| `--no-pixel-lighting` | Light each vertex rather than each pixel, as the original does |
| `--gamma-space` | Light, blend and filter the encoded colours, as the original does, rather than in linear light |
| `--no-materials` | Ignore the material maps of mod textures: no normal maps, reflections or emissive glow, and the original highlights instead of the maps' highlights ([Modding](modding.md#material-maps)) |
| `--shadows <off\|low\|high>` | Shadows from the sun: low is soft and light on older GPUs, high sharp and smooth; high by default, and none without lighting each pixel |
| `--no-cockpit-shadows` | Leave the shadows out of the cockpit, keeping them on the ships |
| `--no-smooth-motion` | Move what moves on with the game's ticks, a hundred a second, as the original does, rather than on every frame |
| `--few-shot-lights` | Light only the latest two of the player's shots and the latest two of everyone else's, as the original does |
| `--baked-lights` | Bake the steady lights of ships and stations into their hulls, as the original does, rather than shine them as lights on what stands near ([Rendering](../engine/rendering.md#static-lights)) |
| `--launch-steam original\|soft` | The Yamato's launch steam: original brightness or softer jets with less glare. Defaults to `soft`; `--original` selects `original` ([Launches](../engine/launch.md#the-yamatos-launch)) |
| `--uncompressed-textures` | Keep the mods' pictures uncompressed on the GPU, as 8-bit RGBA, rather than compressed in BC7 and BC5: four times the memory, and a slower start ([Modding](modding.md#compression)) |
| `--bitmap-fonts` | Draw the interface text with the original bitmap fonts, scaled up to the window, instead of outline fonts drawn at the window's resolution (the built-in Newtown, or a font from a mod) ([Modding](modding.md#fonts)) |
| `--no-mod-effects` | Don't draw the mods' shaders: their post effects, their surface and lighting functions, and their replacements for OpenReliant's shaders ([Post effects](scripting.md#post-effects)) |

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
| `--no-mods` | Start without the mods in the game's `mods` folder ([Modding](modding.md)) |
| `--mods <mod,...>` | Start with only these mods, up to 64, in this order, whatever the mods screen has on. Give the name of a mod in the game's `mods` folder, or the path to a mod's folder or `.hog` file elsewhere. A mod that needs another loads only if that one comes before it. The mods screen stays shut, so its list doesn't change. `--no-mods` overrides it ([The mods screen](modding.md#the-mods-screen)) |
| `--no-intro` | Start without the three movies the game plays as it starts, as `--mission` and `--screenshot` do |
| `--developer-mode` | The tools for writing mods' scripts: the scripting console, which F11 brings up where a mod has scripts, and folder mods' scripts reloading when they or their shaders are saved ([Scripting](scripting.md#the-console)) |
| `--editor-link` | Listen for a mission editor or a script debugger, such as `openreliant debug`, on this computer's own address, 127.0.0.1, which can then pause the mission and stop and step its script, as the original's editor link does ([Debugging mission scripts](debugging.md)) |
| `--editor-link-port <port>` | With `--editor-link`, the port to listen at; 22539 by default |
| `--no-update-check` | Don't check for a newer release of OpenReliant, and don't read the catalogue of mods on the mods screen. By default it checks as it starts, logs a newer release and shows it once in the main menu, and the mods screen says which mods have an update ([Newer releases](#newer-releases)) |
| `--screenshot <file.png>` | Save a PNG from a hidden window and quit. Use `--size` to set the image size. The run skips controls and `[OpenReliant]` settings, uses the highest `[Device]` details, and leaves disabled mods off |
| `--screenshot-ticks <ticks>` | With `--screenshot`, how many game ticks to run first, one a frame, so that the scene plays out; 2 by default |
| `--seed <number>` | Start each mission's random numbers from this seed, so that a run comes out the same each time, for testing; by default, as in the game, from the clock as the mission starts, and from a fixed seed with `--screenshot` |
| `--version` | Show the version |
| `-h`, `--help` | Show the help page |

`--screenshot` uses the hidden window's size by default, including when `--fullscreen` is present.
For automated captures, add `--no-sound` to mute the run.

## Commands

| Command | Description |
|---|---|
| `openreliant install` | Install the game's files from the StarLancer discs into a directory |
| `openreliant joysticks` | List the joysticks and gamepads, and which one the game uses |
| `openreliant missions` | List the game's missions, its own and those added to its `missions` folder, and check that each loads |
| `openreliant debug` | Debug the script of the mission a game started with `--editor-link` plays ([Debugging mission scripts](debugging.md)) |
| `openreliant --headless [<server.ini>]` | Start the headless arena host with the settings in [server.ini](#headless-server-configuration-serverini) |

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
| F11 | In the developer mode, the scripting console, where a mod has scripts, in the menus too ([Scripting](scripting.md#the-console)) |
| Alt+Enter | Switch between windowed and fullscreen mode |

## Configuration file (starlancer.ini)

Settings are read from `starlancer.ini` in the game directory. If the file is missing, every setting keeps its default; if it exists but can't be read, the log says so. A change made in the game is written to the file straight away, and again as the game ends, so closing the window doesn't lose it. **Improvement:** the original writes the file over the old one; OpenReliant writes a new file and puts it in the old one's place in one step, so a crash or a full disk during the write leaves the old file whole. The game keeps its volumes, its view and its brightness there:

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
| `FieldOfView` | Degrees up and down, from 34 to 94, which VIDEO's FIELD OF VIEW sets; without it, the original's | `--fov` |
| `UiScale` | A percentage from 50 to 100, which VIDEO's UI SCALE sets; 80 by default. GRAPHICS' presets and `Original` leave it as it is | `--ui-scale` |
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
| `RealLights` | 1: the steady lights of ships and stations shine on what stands near; 0: they are baked into their hulls, as the original; which VIDEO's REAL LIGHTS sets | `--baked-lights` |
| `OutlineFonts` | 1 or 0, which VIDEO's OUTLINE FONTS sets: the interface's text drawn from outline fonts, or in the game's bitmap fonts | `--bitmap-fonts` |
| `ModEffects` | 1 or 0, which VIDEO's MOD EFFECTS sets: whether the mods' shaders draw: their post effects, their surface and lighting functions ([Post effects](scripting.md#post-effects)), and, from the next start, their replacements for OpenReliant's shaders. GRAPHICS' presets and `Original` leave it as it is | `--no-mod-effects` |
| `Hrtf` | `auto`, `on` or `off`, which AUDIO's 3D SOUND sets: AUTOMATIC, HEADPHONES or SPEAKERS | `--hrtf`, `--no-hrtf` |
| `Reverb` | 1 or 0, which AUDIO's REVERB sets | `--no-reverb` |
| `Compressor` | 1 or 0, which AUDIO's COMPRESSOR sets | `--no-compressor` |
| `DeveloperMode` | 1 or 0; 0 by default | `--developer-mode` |
| `TextureCompression` | 1 or 0; 1 by default: the mods' pictures compressed for the GPU ([Modding](modding.md#compression)) | `--uncompressed-textures` |
| `UpdateCheck` | 1 or 0, which VIDEO's CHECK FOR UPDATES sets: whether OpenReliant checks for a newer release as it starts, and whether the mods screen reads the catalogue of mods for updates to the installed mods ([Newer releases](#newer-releases)) | `--no-update-check` |
| `UpdateSeen` | The newest release the main menu has shown you, such as `0.10.0`, which the main menu writes | |

The mods screen keeps which mods are on, and the order they load in, in a section of its own, `[OpenReliantMods]` ([The mods screen](modding.md#the-mods-screen)). The GET MODS screen reads the repositories of mods on the web from `[OpenReliantModRepositories]`, one line for each: a name of your choosing, and the URL of its `mods.json` ([Repositories](modding.md#repositories)). Without the section, it reads OpenReliant's own repository; an empty section hides GET MODS. It records the mods it installs in `[OpenReliantInstalledMods]`, one line for each: the archive's name, and the repository it came from. OpenReliant refuses a recorded archive whose checksum file is missing or doesn't match ([Getting mods from the catalogue](modding.md#getting-mods-from-the-catalogue)).

```ini
[OpenReliantModRepositories]
openreliant-mods=https://openreliant.github.io/openreliant-mods/mods.json

[OpenReliantInstalledMods]
viper.hog=openreliant-mods
```

In the example, the game has the original's look and sound, but with the bloom and eight samples a pixel. A setting you leave out keeps its default, or `Original`'s where it is 1.

The settings screen keeps the graphics' settings like this: a preset chosen with VIDEO's GRAPHICS is written as `Original` alone, and a graphics option changed after it is written only where it differs from what `Original` gives, and taken out where it is the same. As `Original` plays the original's mixer, ORIGINAL writes `Hrtf`, `Reverb` and `Compressor` beside it while OpenAL Soft plays the sound, so that the sound stays as AUDIO has it. A screenshot taken with `--screenshot` leaves this section out, so that it comes out the same for everyone.

## Headless server configuration (server.ini)

Run `openreliant --headless` to start the host from the command line. It reads `server.ini` in
the current folder. Pass a different file as `openreliant --headless path/to/server.ini`.
The host starts before the game opens a window or initializes sound.

The headless host runs Nuclear Threat from an installed copy of StarLancer. Save this example
as `server.ini` beside the installation, or set `GameDirectory` to its path. Section and key
names can be written in any case.

```ini
[Server]
BindAddress=127.0.0.1
Port=27020
Arena=nuclear-threat
GameDirectory=.
Players=3
```

On first start, the host creates `server.key` beside the INI. It reuses that key on every start
and renews its transport certificate automatically while running. Store the INI in a private
folder and keep a private backup of `server.key`. If you replace the key, share a new invite.

Open **Multi Player** from the main menu. Under **Direct Connect**, type the server address, such as `192.0.2.10` or
`192.0.2.10:27200`, then choose **Connect** or press Enter. The default port is 27020.
For IPv6 with a port, use brackets, for example `[2001:db8::1]:27200`. The client opens
one encrypted connection to the address. Pilots need no credential files.

In Nuclear Threat, use your usual **Fire Lasers** control. The host advances the guns, applies
hits and updates each pilot's shields, armour and kill count. When a carrier is destroyed, their
beacons drop at the wreck. The pilot respawns in the fighter they chose and keeps their score.

Choose **Asteroid Field** for free-for-all combat on the original asteroid map. A LAN host can
choose it under **Change Game Mode**. Hold **Display Kills** in the stock arenas to see pilots ranked
by kills, then by fewest deaths. Asteroid Field has no automatic victory threshold. With at least
two pilots, fly through a ring to collect a power-up. The host uses the original odds and each
fighter can hold one effect. The cockpit shows the held effect above the reticle.

Use **Launch Missile** to fire a Screamer or drop a held mine. Countermeasure pickups add three
decoys. Drop them with the usual **Countermeasures** control. The host checks locks, applies
damage and rolls for decoy diversion. The cockpit shows your inventory, lock and incoming
missile warning. Stock arena spawns have empty racks and zero countermeasures.

In **Dark Reign**, collect the comms relay to keep the tower from targeting you. The tower
picks targets on its own and credits its kills to whoever carries the relay when it strikes.
The relay drops beside a destroyed carrier. If the carrier disconnects, it reappears where
it was last loose. Dark Reign also has random power-up rings.

The arena cockpit uses the usual targeting, radar, gunnery, damage, power, missile and
wing-status controls. The host supplies the gun selection, ammunition, damage and power
readings. The wing-status panel uses the current mission's wing.

In **Tag Bomb**, the first pilot destroyed respawns with an active bomb. Hit another pilot
with your primary guns to pass it. Each pilot has a 45-second fuse that runs only while
they carry the bomb in flight. A detonation awards the last tagger three frags, as the
original executable does. If the carrier disconnects, the next pilot destroyed can arm
their bomb on respawn.

In **Hunt the Shadow**, the first pilot to score a frag becomes the Shadow. The Shadow stays
cloaked, has no shields and cannot collect random power-ups. Killing the Shadow transfers the
role and adds five bonus frags to the normal frag. If the Shadow disconnects or dies without
a credited killer, the next pilot to score a frag takes the role.

In **Vampires**, the first pilot to die becomes a vampire. Vampires keep their role when they
respawn, cannot collect power-ups, and infect humans they kill. The last human to die earns five
frags and everyone becomes human again. Scores and the match clock carry on. As in the original,
any departure when just one human remains also resets the roles, without a score bonus.

To share an invite that also verifies the server's identity, copy the value after `invite` in the host's output and share it with your pilots. They can paste it in the same address field. The invite contains the IP
address, port and public server key. Pilots should get the invite from the host operator so they
can verify the right server. Anyone with the invite can try to join.

For an internet server, listen on an address reachable through your firewall and router. If the
host listens on all interfaces or sits behind a router, set `InviteAddress` to the IP address
your pilots can reach. Allow incoming UDP on `Port` and use the same port if you forward it.

### Server

| Key | Default | Description |
|---|---|---|
| `BindAddress` | `127.0.0.1` | The IPv4 or IPv6 address the host listens on. The default accepts pilots from the host machine |
| `InviteAddress` | `BindAddress` | The IPv4 or IPv6 address to put in the invite. Set this to a specific address when listening on all interfaces |
| `Port` | `27020` | The UDP port to listen on, from 1 to 65535 |
| `Arena` | `nuclear-threat` | `nuclear-threat`, `asteroid-field`, `dark-reign`, `tag-bomb`, `hunt-the-shadow` or `vampires` for the stock missions. `six-beacons` and `training` are small transport test arenas |
| `Mission` | Unset | Installed campaign mission number for co-op. Set either `Arena` or `Mission` |
| `GameDirectory` | `.` | Installed game folder, relative to `server.ini` or an absolute path. Used by stock arenas and co-op missions |
| `Players` | `8` for arenas, `2` for co-op | How many pilots can join. Choose 2 to 8 for an arena or 2 to 4 for co-op |
| `MinPlayers` | `2` for arenas, `Players` for co-op | How many admitted pilots are needed to begin the countdown. Choose at least 2 and at most `Players` |
| `StartDelaySeconds` | `30` for stock deathmatch, `0` otherwise | Time to wait once enough pilots have joined. Each new admission restarts the countdown, even when the lobby fills. Dropping below the minimum clears it |
| `RoundSeconds` | Unset | Optional duration of a round in seconds. Leave it unset for the arena's own ending rules |
| `RoundTicks` | Unset | Set a positive simulation tick limit for scripted tests. Set either this or `RoundSeconds` |
| `Teams` | `0` | Set to `1` for team play in Asteroid Field, Dark Reign, Tag Bomb or Hunt the Shadow. Pilots can choose their team in the lobby during the countdown |
| `AiTurrets` | `0` | Set to `1` to keep the mission's AI turret settings in stock deathmatch arenas |
| `TargetPlayers` | `1` | Set to `0` to make new fighters untargetable in stock deathmatch arenas |
| `RepeatRounds` | `1` for stock deathmatch, `0` otherwise | A stock arena returns to the lobby after a timed round or when everyone leaves. The same countdown starts the next round. Set to `0` to exit after the first timed round |

The dedicated server takes no pilot slot. When co-op's countdown ends, the server opens the
mission briefing and waits for the admitted crew to finish it.

### Optional Prometheus metrics

Add a `[Metrics]` section with a TCP port other than the game's UDP port. Leave out `Port` to
keep the exporter off.

```ini
[Metrics]
Port=9100
```

`BindAddress` defaults to `127.0.0.1`. Set it to the private address your Prometheus server can
reach if it runs on another machine. Scrape `/metrics`. The exporter reports current occupancy,
admission and departure outcomes, rounds by mode, simulation tick count and duration, and the
game message payload bytes sent and received. It handles scrapes outside the simulation loop.

### Optional managed identity

For an operator-managed transport identity, add `[Identity]` and set both keys below.

| Key | Default | Description |
|---|---|---|
| `RootPublicKey` | Unset | The issuer's OpenSSH Ed25519 public key. Pilots use this public key to verify the host |
| `Certificate` | Unset | The host's signed GameNetworkingSockets certificate bundle. Keep this file private |

Relative paths start at the folder containing the INI. The operator supplies and renews the host bundle.
Pilots can still join by IP. Clients with their own managed identity can also use the
[managed certificate command](../port/transport-probe.md#run-a-direct-ip-session-in-openreliant).

## Newer releases

As it starts, OpenReliant asks GitHub's API for its latest release, in the background, and gives up after 5 seconds. The game never waits for the answer, as it starts or as it quits, so a slow or missing connection never holds it up. The request names OpenReliant as the program asking and carries nothing else about you or your game. GitHub sees your address, as it does for any web page. **Improvement:** the original never looks for a newer version of itself.

When a release newer than yours is out, the log says so, with the address of the release's page, and the main menu shows it once, in a dialog like QUIT's: YES opens the page in your default web browser, and NO closes the dialog. `UpdateSeen` keeps the release it showed you, so the dialog comes back only for a newer one. A build from source counts as the release it was built from, and pre-releases are never shown.

The same setting lets the mods screen read the catalogue of mods on the web as it opens, once per run, to say which of your mods have an update ([The mods screen](modding.md#the-mods-screen)). The repository's server sees your address then, as GitHub does for the release check. Nothing is read while GET MODS is hidden, that is, while the settings file names no repository ([Repositories](modding.md#repositories)).

To turn both off, untick CHECK FOR UPDATES on the settings screen's VIDEO tab, set `UpdateCheck=0`, or start with `--no-update-check`. The release check takes the change at the next start, the mods screen at once. A run with `--screenshot` never checks.
