# Shipped binaries

Every file listed here comes from the two discs, most of it by way of `LANCER.CAB`. `make game` reproduces that layout under `game/install/`. The analysis reads the game executable, with its code readable, from `game/decrypted/LANCER.EXE`, which the repository does not provide.

All binaries are 32-bit x86 PE images (`machine = 0x14C`).

## The game

| File | Size | Linker | Image base | Notes |
|---|---|---|---|---|
| `LANCER.EXE` (loader) | 249,119 | 5.0 | `0x400000` | SafeDisc 1 loader, not the game. |
| `LANCER.ICD` | 1,151,021 | 6.0 | `0x400000` | The game, encrypted. Entry point `0x004D1210`. |
| `LANGUAGE.DLL` | 122,951 | 6.0 | `0x10000000` | Localised strings, as a `.rsrc` string table the game reads by ID. |
| `ITACLANG.DLL` | 692,282 | - | - | In-flight communication system language resources. |

`LANCER.ICD` carries no symbols, so Ghidra names its functions `FUN_<address>`. It is built with Visual C++ 6.0 and links the C runtime statically; see [`runtime.md`](runtime.md).

## Middleware

The game is a thin layer over several late-1990s SDKs. Source paths in the payload's `.rdata` show the original tree as `lancer\game\*.cpp`, `lancer\interface\loadout` and `lancer\surrender\surrenderlib`.

| Library | Files | Role |
|---|---|---|
| **Surrender** | `srddraw.dll`, `srd3d.dll`, `srfastmath.dll`, `srmemory.dll` | 3D renderer, with DirectDraw and Direct3D 7 back ends, its own math library and allocator. `srmemory.dll` is the payload's only statically imported middleware. Build paths name `srAPI.cpp`. |
| **WinVFX** | `winvfx8.dll`, `winvfx16.dll`, `vfx.dll`, `w32sal.dll` | 2D sprite and overlay drawing, in 8-bit and 16-bit variants, plus a system abstraction layer. |
| **Miles Sound System** | `mss32.dll`, `MSS*.M3D`, `MP3DEC.ASI` | Audio. The `.m3d` files are selectable 3D providers: EAX, Aureal A3D, RSX, Dolby Surround, DirectSound3D. |
| **Bink** | `binkw32.dll` | Video playback for briefings, cutscenes and interface transitions. |

DirectDraw, Direct3D, DirectInput and DirectPlay are reached through those libraries or loaded dynamically; only `DINPUT.dll` is imported statically, for `DirectInputCreateEx`.

## Data files

| Path | Contents |
|---|---|
| `CD1.HOG`, `CD2.HOG`, `resource.hog`, `ms_speech/msspeech.hog`, `pilots/pilots.hog` | Asset archives: see [`hog.md`](../formats/hog.md). |
| `shipstats.bin`, `gunstats.bin`, `missilestats.bin`, `pilotstats.bin` | Stat tables: see [`stats.md`](../formats/stats.md). |
| `missions/*.dte` | Missions 18 and 25, installed loose; `resource.hog` holds all 44. See [`dte.md`](../formats/dte.md). |
| `*.ccb` | Surrender's colour cubes: see [`tcache.md`](../formats/tcache.md#palettes). The game reads `palette`, `softpal` and `palette3` from `resource.hog` (`SR_CCB_load`); the loose copies, `power` and `palette2` go unused. |
| `Forces/*.FRC` | Force-feedback effects: see [`frc.md`](../formats/frc.md). |
| `interface/*.bik`, `inter/`, `*.bik` | Bink video: menu transitions, branding, cutscenes. |
| `music/*.wav` | Music, one file per mission and state. |

## Protection dependencies

`SECDRV.SYS` is the SafeDisc kernel driver. Windows Vista and later disabled it, and Windows 10 removed it, so the shipped `LANCER.EXE` cannot start on a current system.
