# Toolchain

`make setup` installs everything this project needs into `tools/`, which is git-ignored. Nothing is installed system-wide and nothing outside the repository is modified, with one exception noted under [Ghidra](#ghidra).

## Prerequisites

| Tool | Used for |
|---|---|
| Zig 0.17 | Building `sltool` and everything else in `src/`. |
| `uv` | Creating the virtualenv for the `ghydra` CLI and MCP bridge. |
| A C++ toolchain | Compiling Ghidra's native helpers. On macOS, the Xcode command line tools. |
| Gradle 8.5+ | Driving that native build. |

`make doctor` reports which of these, and which build products, are present.

## What make setup installs

| Target | Installs |
|---|---|
| `make jdk` | Eclipse Temurin JDK 21, the minimum Ghidra 12 accepts. |
| `make ghidra` | Ghidra, verified against its published SHA-256, plus native helpers. |
| `make ghydra` | The GhydraMCP Ghidra plugin and the `ghydra` CLI. |

Versions are pinned in [`mk/config.mk`](../mk/config.mk) and can be overridden on the command line, for example `make setup GHIDRA_VERSION=12.1.2 GHIDRA_DATE=... GHIDRA_SHA256=...`.

Each step writes a stamp under `tools/.stamps/`, so re-running `make setup` does only what is missing. Downloaded archives are order-only prerequisites: re-fetching one never forces a rebuild.

### Ghidra

Ghidra's release archives contain native binaries for Windows and Linux x86-64 only. On any other host, including Apple Silicon, the decompiler and demangler must be compiled locally, which is what `make ghidra` does via Ghidra's own `support/gradle/buildNatives`. Without them the decompiler cannot run at all.

`make ghidra` also sets `JAVA_HOME_OVERRIDE` in `support/launch.properties`, so Ghidra starts with the project JDK even when launched outside of make.

### GhydraMCP

[GhydraMCP](https://github.com/starsong-consulting/GhydraMCP) exposes an open Ghidra program over an HTTP API, which the `ghydra` CLI and an MCP client can drive. Its Ghidra plugin is version locked: the extension's `ghidraVersion` must equal the Ghidra version exactly, and the published releases are built against other versions. `make ghydra` therefore builds the plugin from source against the pinned Ghidra.

Installing it touches one path outside the repository, the per-user Ghidra settings directory (`~/Library/ghidra/ghidra_<version>_PUBLIC` on macOS, `~/.config/ghidra/ghidra_<version>_PUBLIC` elsewhere):

- `Extensions/Ghydra/` receives the built plugin, which is what `File > Install Extensions` would do.
- `tools/_code_browser.tcd` is written with the plugin already enabled, so a fresh install serves the API without opening `File > Configure`. An existing file is never overwritten.

The plugin listens on port 8192, one port per open program. [`.mcp.json`](../.mcp.json) registers the MCP bridge for Claude Code. `make ghydra-status` lists the instances the CLI can reach.

## Working with Ghidra

The project lives at `ghidra/projects/starlancer.gpr` and is git-ignored: it embeds the game's code. Programs are grouped into project folders, one group per make target:

| Group | Programs |
|---|---|
| `game` | The game executable, with its code readable, and `LANGUAGE.DLL`. |
| `surrender` | The renderer DLLs: `srd3d.dll`, `srddraw.dll`, `srfastmath.dll`, and `srmemory.dll`. |
| `vfx` | WinVFX and the system abstraction layer: `vfx.dll`, `winvfx8.dll`, `winvfx16.dll`, and `w32sal.dll`. |

```bash
make ghidra-import           # import and auto-analyse every group, headless
make ghidra-import-game      # or one group
make ghidra-export           # dump each program as text under ghidra/export/
make ghidra-run SCRIPT=Name.java [ARGS="..."] [GROUP=game] [PROGRAM=name]   # run one script, programs writable
make ghidra-annotate         # name and type the payload's and the Direct3D driver's known functions and data
make ghidra-gui              # open the project
```

Imports are one-shot: every prerequisite is order-only, `-overwrite` is never passed, and a stamp records that a group was imported, so nothing in the Makefile replaces a program annotated by hand. To re-import deliberately, run `make ghidra-forget-<group>` and delete the folder in the GUI first.

The project is single-user: close the GUI before running a headless target, and vice versa.

`ghidra-export` runs [`ghidra/scripts/ExportProgram.java`](../ghidra/scripts/ExportProgram.java), which writes per program: `segments.tsv`, `imports.tsv`, `exports.tsv`, `strings.tsv`, `functions.tsv`, `disassembly.asm` and `decompiled.c`. The output is derived from the game and is git-ignored.

`make ghidra-annotate` runs [`Annotate.java`](../ghidra/scripts/Annotate.java) on the payload. It first defines the data types that `src/tools/ghidragen` writes from the Zig definitions (`ghidragen types`): the engine's run-time structures in [`src/engine.zig`](../src/engine.zig) and the mission records of [`src/formats/dte.zig`](../src/formats/dte.zig), which the engine uses in place. They go in the `/StarLancer` category and replace earlier versions, so a change to a Zig definition reaches the project on the next run. It then applies names, comments, data types and function signatures from tables of address, kind, name, type and comment:
[`ghidra/names/LANCER.EXE.tsv`](../ghidra/names/LANCER.EXE.tsv), kept by hand as functions and data are identified; [`ghidra/names/LANCER.EXE.runtime.tsv`](../ghidra/names/LANCER.EXE.runtime.tsv), the C runtime linked into the payload (see [`binary/runtime.md`](binary/runtime.md)); and one `ghidragen names` writes for the code the payload reaches only through its tables: each VM opcode handler after its opcode, each command implementation after its command, each order routine after its order and each maneuver opcode handler after its opcode, and the tables themselves. Auto-analysis never finds that code, so the script disassembles it first. Names are user-defined, re-running changes nothing that is already in place, and the tables are the record of what is named and typed: re-import a program and one command restores it. The hand tables' rows are applied after the generated ones and so override them; `zig build test` checks that every row is well formed and that no address is named twice among the hand tables. [`ghidra/names/README.md`](../ghidra/names/README.md) describes their format. Then [`ApplySources.java`](../ghidra/scripts/ApplySources.java) builds the Sources program tree from `ghidragen sources`' rows for [`src/engine/sources.zig`](../src/engine/sources.zig) ([`binary/sources.md`](binary/sources.md)). `functions.tsv` gives each function's place in it. Last, `Annotate.java` runs on `srd3d.dll` with the same types and [`ghidra/names/srd3d.dll.tsv`](../ghidra/names/srd3d.dll.tsv).

To read code that auto-analysis missed before naming it, `make ghidra-run SCRIPT=DefineFunctions.java ARGS="0x00405010 ..."` defines functions at those addresses under Ghidra's default names, and the next export includes them. `GROUP` picks the project folder and `PROGRAM` one program in it, such as `GROUP=surrender PROGRAM=srd3d.dll`; without `PROGRAM` the script runs on every program of the group.

`make vm-opcodes` reads the export back: `src/tools/tablegen` derives the opcode table from the payload's dispatch table and its handlers and writes [`src/engine/vm/opcodes.zig`](../src/engine/vm/opcodes.zig). `make vm-commands` and `make vm-conditions` read the Executor command catalogue and the trigger condition catalogue from the binary alone and write [`src/engine/game/executor/commands.zig`](../src/engine/game/executor/commands.zig) and [`src/engine/vm/conditions.zig`](../src/engine/vm/conditions.zig). `make model-tables` reads the ship type table from the binary and follows the code that loads the attachment models in the export, and writes [`src/engine/game/create/models.zig`](../src/engine/game/create/models.zig). `make combat-tables` reads the words of each ship type's combat stats that the binary holds, its class, its side, its name and whether it can be targeted, into [`src/engine/game/create/combat.zig`](../src/engine/game/create/combat.zig). `make control-tables` reads the player's actions and their default bindings from the binary and writes [`src/engine/input/controls.zig`](../src/engine/input/controls.zig), `make order-tables` reads the order table into [`src/engine/game/ai/orders.zig`](../src/engine/game/ai/orders.zig), and `make maneuver-tables` reads the combat maneuvers and their scripts into [`src/engine/game/aidefend/maneuvers.zig`](../src/engine/game/aidefend/maneuvers.zig). `make gun-tables` re-derives each gun type's kind, sound and sound period from the payload executable. `make sound-tables` re-derives the 3D sounds, their voice classes and the engines' sounds from the payload executable. `make view-tables` re-derives the camera views, their naming strings and flags from the payload executable. `make source-map` writes [`src/engine/sources.zig`](../src/engine/sources.zig), the source file of each stretch of code, from the binary and the export. The tables are committed, so building the tools never needs the game.
