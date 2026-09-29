# Documentation

Reference notes on StarLancer (Digital Anvil / Microsoft, 2000; developed by Warthog), on how OpenReliant reimplements its engine, and on the repository's tooling, derived from static analysis of a legally owned copy. The repository holds none of the game's files.

## User guide

Guides for installing, configuring and playing OpenReliant:

| Path | Contents |
|---|---|
| [`guide/installation.md`](guide/installation.md) | Installing the game files from retail discs or disc images, and running OpenReliant. |
| [`guide/controllers.md`](guide/controllers.md) | Joysticks and gamepads, default controls, button bindings, and controller settings. |
| [`guide/configuration.md`](guide/configuration.md) | Command-line options, graphics and sound settings, and starlancer.ini. |

## Reference documentation

| Path | Contents |
|---|---|
| [`toolchain.md`](toolchain.md) | What `make setup` installs, and the Ghidra workflow. |
| [`binary/executables.md`](binary/executables.md) | The shipped binaries and the middleware they are built on. |
| [`binary/runtime.md`](binary/runtime.md) | The C runtime linked into the game: Visual C++ 6.0's `LIBCMT`. |
| [`binary/sources.md`](binary/sources.md) | The game's source files, their link order, and which code each holds. |
| [`formats/disc-images.md`](formats/disc-images.md) | Raw CD images and the discs' ISO 9660 filesystem. |
| [`formats/hog.md`](formats/hog.md) | `.HOG` archives: EA's `BIGF` container. |
| [`formats/refpack.md`](formats/refpack.md) | RefPack, the compression inside them. |
| [`formats/shp.md`](formats/shp.md) | `.SHP` models: chunks, parts, levels of detail, geometry, coordinate frame. |
| [`formats/spr.md`](formats/spr.md) | `.SPR` sprites: the WinVFX interface imagery. |
| [`formats/tcache.md`](formats/tcache.md) | Texture caches: every model and effect texture, their palettes and colour cubes. |
| [`formats/fat.md`](formats/fat.md) | `.fat` sound banks. |
| [`formats/speech.md`](formats/speech.md) | Speech files: the radio's lines, their scrambling and their codec. |
| [`formats/fm8.md`](formats/fm8.md) | Face films: the pilots' faces the radio's window plays, their chunks and their codec. |
| [`formats/fnt.md`](formats/fnt.md) | `.fnt` bitmap fonts. |
| [`formats/bink.md`](formats/bink.md) | `.bik` movies: the Bink container. |
| [`formats/frc.md`](formats/frc.md) | `.frc` force-feedback effects. |
| [`formats/dte.md`](formats/dte.md) | `.DTE` missions: directory, ships, triggers, and the script VM. |
| [`formats/stats.md`](formats/stats.md) | Ship, gun, missile and pilot stat tables. |
| [`engine/missions.md`](engine/missions.md) | Missions: how a mission's start finds its file, reads it and binds it. |
| [`engine/script-vm.md`](engine/script-vm.md) | The script VM at run time: threads, calls, commands, timers, events. |
| [`engine/camera.md`](engine/camera.md) | The camera: the projection, the views, and where each puts the camera. |
| [`engine/backdrop.md`](engine/backdrop.md) | The backdrop: sky dome, nebula, stars, dust, sun, lens flares and the default lights. |
| [`engine/rendering.md`](engine/rendering.md) | Rendering: layers, depth, shading modes as materials, lighting, blending, highlights. |
| [`engine/objects.md`](engine/objects.md) | Live objects: the object array, model hierarchies, components, the flight model. |
| [`engine/guns.md`](engine/guns.md) | Guns: the guns a model holds, their groups, the trigger and the step that fires them. |
| [`engine/cloak.md`](engine/cloak.md) | The cloak: which objects cloak, how it comes on and goes, what it draws and what shows through it. |
| [`engine/ejection.md`](engine/ejection.md) | The ejection: the pod, the ship left behind, the pickup by tractor, and the mission's end. |
| [`engine/effects.md`](engine/effects.md) | Effects: the particles explosions send out. |
| [`engine/sound.md`](engine/sound.md) | Sound: the banks' sounds on their voices, the 3D effects, the player's engine, the music and the speech. |
| [`engine/loop.md`](engine/loop.md) | The game loop: the 100 Hz tick, the 25 Hz simulation step, collisions. |
| [`engine/front-end.md`](engine/front-end.md) | The front end: its screens, the main menu, the pilot roster, the dialogs and the backgrounds. |
| [`engine/rooms.md`](engine/rooms.md) | The Reliant's rooms: their views and movies, the pointer, the fish tank, the news report, a new pilot's induction and the in-game options. |
| [`engine/briefing.md`](engine/briefing.md) | The briefing: the door, the way into the briefing room, Enriquez with the mission's movie, his last word, and the campaign's end. |
| [`engine/loadout.md`](engine/loadout.md) | The loadout: its hologram, GenILib's 3D interface, the ship page, choosing a ship, the missile page and the racks, the internal guns view, the exit, its panels and figures, and the ship and racks it leaves the mission. |
| [`engine/movies.md`](engine/movies.md) | Movies: how the game plays them, the discs' archives, the intro, the transitions, the hangar's, the landing and the chapters' ends, and the stand-in for Bink. |
| [`engine/controls.md`](engine/controls.md) | Player input: devices, bindings, settings, steering and throttle. |
| [`engine/screenshots.md`](engine/screenshots.md) | Screenshots: the keys that save the screen, and where the pictures go. |
| [`engine/hud.md`](engine/hud.md) | The head-up display: how it is reached, where an element stands, its text and its art. |
| [`engine/radio.md`](engine/radio.md) | The radio: the lines the pilots say, their queue, the window with the speaker's face, and the speech. |
| [`engine/orders.md`](engine/orders.md) | Orders: the table of what objects can be told to do, each object's stack, and how orders run. |
| [`engine/launch.md`](engine/launch.md) | Launches: the Launch order, its styles, the Reliant's launch and its cutaways, the torpedoes'. |
| [`engine/jump.md`](engine/jump.md) | Jumps: Jump Out and Jump In, the player's formation, their motions and views, and the JumpedIn event. |
| [`engine/gates.md`](engine/gates.md) | Gates: the tunnels ships jump through, the worm, and the orders that open, close and collapse them. |
| [`engine/director.md`](engine/director.md) | The director's camera: the script's shots, the mission's curves they fly along, and the ships they hold. |
| [`engine/maneuvers.md`](engine/maneuvers.md) | Combat maneuvers: the scripts Fight runs, their language, and how it chooses them. |
| [`port/platform.md`](port/platform.md) | The platform: the `openreliant` executable on SDL3, how to build and run it on each system, the installer, and joysticks and gamepads. |
| [`port/renderer.md`](port/renderer.md) | The renderer: Surrender's pipeline and Direct3D driver as ported, the software reference device, improvements and what is not yet ported. |
| [`port/sound.md`](port/sound.md) | Sound: the stand-in for the Miles Sound System, and its output through SDL3. |

## Conventions

Addresses are virtual addresses for the payload executable's image base of `0x400000` unless stated otherwise. The shipped binaries carry no symbols. Function and data names are those `make ghidra-annotate` gives the Ghidra project; names of the form `FUN_<address>` are Ghidra's placeholders.

Fixed layouts, in the game's files and in its executable's data, are `extern struct`s in the code, their fields the layout's own: enums for codes, packed structs for flag words, arrays for runs, with `comptime` asserts on the offsets. The readers view the bytes as those structs in place ([`formats/layout.zig`](../src/formats/layout.zig)), which needs a little-endian host; the few big-endian fields, the hog archive's and the mission script's jumps, are `layout.Big`.

Claims are marked where they are not directly verified:

- **Unknown:** not yet determined.
- **Unverified:** inferred from surrounding evidence but not confirmed.
