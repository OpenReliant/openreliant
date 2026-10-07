# OpenReliant

OpenReliant is an open-source, faithful engine reimplementation of **StarLancer**, the space combat simulator developed by Warthog and Digital Anvil and published by Microsoft in 2000.

Written in **Zig** and built on **SDL3**, OpenReliant renders with Vulkan (Metal on macOS) via SDL's GPU API. It runs natively on Linux, macOS, and Windows using assets directly from your retail copy of the game.

**[Website](https://openreliant.github.io/openreliant/)** · **[Download](../../releases/latest)** · **[Mods](https://openreliant.github.io/openreliant-mods/)**

<p align="center">
  <img src="docs/images/predator-wireframe.svg" width="560"
       alt="Wireframe of the Predator light fighter exported from its .SHP model">
</p>

---

## Legal & Asset Policy

OpenReliant is an independent, non-commercial open-source project. It is not affiliated with, endorsed by, or associated with Warthog Games, Digital Anvil, or Microsoft. StarLancer is a trademark of its respective owner.

**This repository contains no copyrighted game assets**: no textures, 3D models, sound effects, music, cinematics, mission scripts, or game binaries. OpenReliant requires assets extracted from a legally owned copy of StarLancer to run. We do not support or condone software piracy.

---

## Current Status

OpenReliant is in active development. The first campaign missions are playable from start to finish.

- **Flight & Combat**: All ships, with the original flight model, weapons, damage, AI and cockpit displays, and 8 camera views including 3D cockpits.
- **Missions**: Retail and custom mission files load. The scripts of the first missions run in full, and the commands used by later missions are in progress.
- **Controls**: Mouse and keyboard, flight sticks, HOTAS and gamepads, with force feedback played as rumble, and the bindings set in the game's controls screen.
- **Graphics**: Per-pixel shading with gamma-corrected lighting, and real-time shadows. Rendering runs at native resolution in 32-bit colour, with bloom, anti-aliasing, smooth motion at high frame rates, and more detailed explosions, shields and planets. `--original` restores the original graphics and sound.
- **Audio**: 3D positional sound with reverb and headphone HRTF.
- **Mods**: Archives and folders in the game's `mods` folder can replace or add to any of the game's files: models, sounds, music, speech, movies and missions. PNG pictures of any size can replace textures, with material maps for physically based shading (normal maps, highlights, glow and sky reflections), and the interface's shapes and backgrounds, including widescreen ones. Mods can add ship types, guns, missiles and pilots with their own faces and voices, and models built from OBJ or glTF. Scripts in Luau can change the game's records, hook its functions and the missions' commands, run on ships, missiles and turrets, draw on the display and the menus, offer a page of options, add game modes and campaigns, and add shaders. A mods screen turns mods on and off, sets their load order, and shows which mods replace each other's files and which mods a mod needs ([What mods can do](docs/guide/what-mods-can-do.md), [Modding](docs/guide/modding.md), [Scripting](docs/guide/scripting.md)).
- **Front End**: The main menu, the settings screen with its audio, controls, video and graphics, the pilot roster, the saved games and the Reliant's rooms, with a new pilot's induction, the news reports, the in-game options, the simulator pod, the locker, the CD player, the briefings, the loadout and the ITAC's debriefings.
- **In Development**: The remaining campaign missions, and multiplayer. See the [milestones](../../milestones) for the roadmap.

---

## Documentation

- [User guide](docs/guide/README.md): installing, configuring and playing OpenReliant.
- [Developer and technical documentation](docs/README.md): the engine, the file formats, the reverse engineering and the toolchain.

---

## Quickstart

Download the archive for your system from the [latest release](../../releases/latest) and extract it, then follow the [installation guide](docs/guide/installation.md): it installs the game's files from your StarLancer discs or disc images, and starts the game.

---

## Building from Source

Building OpenReliant needs [Zig 0.17](https://ziglang.org): see [Building from source](docs/guide/installation.md#building-from-source). [CONTRIBUTING](CONTRIBUTING.md) has the workflow for working on it.

---

## Reverse Engineering & Analysis Tools

The repository includes tools used during reverse engineering. `make help` lists the workflows, and [CONTRIBUTING](CONTRIBUTING.md#getting-started) and the [toolchain](docs/toolchain.md) describe them.

The `sltool` utility, included with `openreliant` in each release, inspects, exports and packs the game's file formats. `zig build sltool` builds it alone from the sources, without the game. It exits with 0 on success, 2 for an unknown command (after printing its usage) and 1 on failure (with the error on stderr), so a mod's build scripts can use it:

| Command | Description | Documentation |
|---|---|---|
| `sltool cd` | Inspect CD images and ISO 9660 filesystems | [disc-images](docs/formats/disc-images.md) |
| `sltool hog` | Extract and pack `.HOG` archives (`BIGF` container / RefPack) | [hog](docs/formats/hog.md), [refpack](docs/formats/refpack.md) |
| `sltool shp` | Inspect `.SHP` 3D models; export Wavefront OBJ or glTF; build a mod's model from OBJ or glTF | [shp](docs/formats/shp.md) |
| `sltool spr` | Inspect `.SPR` 2D interface sprites; export PNG | [spr](docs/formats/spr.md) |
| `sltool tcache` | Extract texture caches to PNG | [tcache](docs/formats/tcache.md) |
| `sltool fat` | Extract `.fat` sound banks to WAV | [fat](docs/formats/fat.md) |
| `sltool speech` | Decode the radio's speech files to WAV; encode WAV to a speech file for a mod | [speech](docs/formats/speech.md) |
| `sltool fm8` | Extract the radio's face films to PNG frames; encode PNG frames to a film for a mod | [fm8](docs/formats/fm8.md) |
| `sltool fnt` | Render `.fnt` bitmap fonts into glyph atlases | [fnt](docs/formats/fnt.md) |
| `sltool dte` | List a `.DTE` mission's ships, triggers and script parts; disassemble its bytecode | [dte](docs/formats/dte.md) |
| `sltool save` | Show what saved games hold | [save](docs/formats/save.md) |
| `sltool stats` | Parse ship, weapon, and pilot stat tables | [stats](docs/formats/stats.md) |

---

## Repository Layout

| Directory | Contents |
|---|---|
| `src/openreliant/` | Main application entry point, CLI parser, and installer. |
| `src/engine/` | Reimplemented engine modules mirroring original source layout. |
| `src/platform/` | Platform abstraction layer: SDL3, Vulkan/Metal GPU backend, audio, and inputs. |
| `src/formats/` | Parsers and decoders for StarLancer file formats. |
| `src/tools/sltool/` | Command-line asset inspection and extraction tool. |
| `src/tools/tablegen/` | Generates static engine lookup tables from the original executable. |
| `docs/` | Documentation (see [docs/README.md](docs/README.md)). |
| `ghidra/` | Ghidra scripts, symbol annotations, and type maps. |

---

## License

Copyright 2026 the OpenReliant contributors.

- Source code is licensed under the [Mozilla Public License 2.0](LICENSE).
- Documentation under `docs/` is licensed under [Creative Commons Attribution-ShareAlike 4.0](docs/LICENSE).
- Statically linked libraries: [OpenAL Soft](https://github.com/kcat/openal-soft) is licensed under the GNU LGPL 2.1, the part of [FFmpeg](https://ffmpeg.org) that decodes the movies under the GNU LGPL 2.1 or later, [FreeType](https://freetype.org), which draws the outline fonts, under the FreeType License, and [Luau](https://luau.org), which runs mod scripts, under the MIT License. Portions of this software are copyright © 2026 The FreeType Project (https://freetype.org). All rights reserved. Luau is copyright (c) 2019-2025 Roblox Corporation and copyright (c) 1994-2019 Lua.org, PUC-Rio, under the MIT License; see `LICENSE-luau.txt`.
- The interface's text is drawn in Newtown, by Roger White, from Roger's Fonts, in the public domain ([deps/newtown](deps/newtown/README.md)).
- The runtime shader compiler uses [glslang](https://github.com/KhronosGroup/glslang), under its BSD and MIT notices (`LICENSE-glslang.txt`), and [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross), under Apache 2.0 or MIT (`LICENSE-spirv-cross.txt`).
- Mods' pictures are compressed for the GPU with Richard Geldreich's bc7enc and rgbcx from [bc7enc_rdo](https://github.com/richgel999/bc7enc_rdo), under the MIT licence (`LICENSE-bc7enc.txt`). PNG files inflate with [zlib](https://zlib.net), under the zlib licence.
- The installer reads the game's cabinet with [libarchive](https://www.libarchive.org), under its BSD licence (`LICENSE-libarchive.txt`).
- The window, the input and the GPU go through [SDL](https://libsdl.org), under the zlib licence.
- The movies' upscale is ported from [AMD FidelityFX Super Resolution 1.0](https://github.com/GPUOpen-Effects/FidelityFX-FSR), under the MIT licence.
