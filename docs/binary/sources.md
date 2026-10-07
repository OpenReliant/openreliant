# Source files

[`src/engine/sources.zig`](../../src/engine/sources.zig) lists the payload's source files in link order, each with the code known to be its own. `make source-map` derives it from the payload and its Ghidra export. `make ghidra-annotate` builds a Ghidra program tree, Sources, from it; `make ghidra-export` writes each function's place in that tree to the `source` column of `functions.tsv`.

## Paths

A file that uses the assertion macro holds its own path. The payload holds 77:

| Directory | Files |
|---|---|
| `C:\lancer\game` | `Ai.cpp`, `aidefend.cpp`, `aidock.cpp`, `aifight.cpp`, `aifuncs.cpp`, `aigeneric.cpp`, `aiioncan.cpp`, `ailand.cpp`, `airipper.cpp`, `jump.cpp`, `launch.cpp`, `tractor.cpp`, `wgate.cpp`, `interface.cpp`, `itac.cpp`, `videoreports.cpp`, `Executor.cpp`, `mission.cpp`, `attach.cpp`, `camera.cpp`, `cbox.cpp`, `cloak.cpp`, `collision.cpp`, `Create.cpp`, `environfx.cpp`, `erayfx.cpp`, `explode.cpp`, `gameflow.cpp`, `gameobj.cpp`, `guns.cpp`, `hog_gen.cpp`, `hog_SND.CPP`, `hud.cpp`, `hudmovie.cpp`, `language.cpp`, `main.cpp`, `matmanager.cpp`, `missiles.cpp`, `nebula.cpp`, `objects.cpp`, `particles.cpp`, `pilots.cpp`, `shield.cpp`, `shieldfx.cpp`, `shockwave.cpp`, `sparks.cpp`, `sprites.cpp`, `srofiles.cpp`, `timer.cpp`, `winmain.cpp`, `xtrabits.cpp`, `deathmatch.cpp`, `dmscenarios.cpp`, `DPBits.cpp`, `DPReceivePackets.cpp`, `DPSendPackets.cpp`, `DPSession.cpp`, `hog_file.cpp`, `bigfile.cpp` |
| `C:\lancer\GenILib` | `interf.cpp` |
| `C:\lancer\interface\loadout` | `loadout.cpp` |
| `C:\lancer\surrender\surrenderlib` | `srAPI.cpp`, `srAPIext.cpp`, `srstars.cpp`, `srMesh.cpp`, `srCore.cpp`, `srImage.cpp`, `srTexture.cpp`, `srTGA.cpp`, `srFile.cpp`, `srColor.cpp`, `srClip.cpp`, `srMemCpy.cpp`, `srLight.cpp`, `srBMO.cpp`, `srballs.cpp`, `srline.cpp` |

The Rich header records 147 objects from the game's C++ compiler. The files without a path lie among these.

`tablegen sources` takes the paths from the strings Ghidra defines and from any address the code names that holds one, so a table typed in Ghidra over a path doesn't lose its file.

## Link order

Each object's code, and its data, is one contiguous run, in the same order for both. The files come in runs, each alphabetical:

1. `Ai.cpp` to `airipper.cpp`, `jump.cpp`, `launch.cpp`, `tractor.cpp`, `wgate.cpp`.
2. `interf.cpp`, `interface.cpp`, `itac.cpp`, `loadout.cpp`, `videoreports.cpp`.
3. `Executor.cpp`, `mission.cpp`.
4. `attach.cpp` to `xtrabits.cpp`.
5. `deathmatch.cpp` to `DPSession.cpp`.
6. The Surrender files, not alphabetical, with `hog_file.cpp` and `bigfile.cpp` among them.

The `srmemory.dll` import thunks and the [C runtime](runtime.md) follow. A file without a path between two files of one run sorts between them.

## Placing code

- A function that refers to a file's path is in that file.
- Identical literals are merged into the data of the first file to use them, so a literal lies no later than the file of any user.
- A literal with one user and no pointer to it in the data lies in its user's file.
- A literal between two literals of one file is that file's.
- A function between two functions of one file is that file's.

Placed functions place their literals, which place further functions, until nothing changes. A literal that contradicts the others has a user the listing does not show, and is left out.

Code no string places lies between two placed files: the end of one, the start of the next, or files without a path. The Sources tree puts it under `unplaced`, named for the files around it (`aidock.cpp .. aifight.cpp`).

Variables used by one function usually lie in that function's file, but not always, so they place nothing here.

The map depends on Ghidra's function bodies. A function that jumps through a table of others, such as `order_dock` through `dock_styles`, can come out of Ghidra's analysis holding their code, and their strings then place it. The names table names each function such a table holds, so that each keeps its own body.
