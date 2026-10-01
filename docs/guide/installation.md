# Installation

OpenReliant needs the assets from a legally obtained copy of StarLancer (discs or disc images).

## Prerequisites

- StarLancer game media:
  - Retail CD-ROMs (disc 1 and disc 2), or
  - Disc image files (.bin with .cue, or .iso), or
  - Extracted disc folders.
- OpenReliant binary:
  - Download the latest release from the [releases page](https://github.com/vdmkenny/openreliant/releases/latest), or
  - Build from source using Zig 0.16.

## Quickstart

### 1. Extract OpenReliant

Download and extract the archive for your system (Linux, macOS, or Windows). Open a terminal in that folder:
- On Windows: right-click inside the folder and choose Open in Terminal.
- On macOS: right-click the folder in Finder and choose Services, then New Terminal at Folder.
- On Linux: right-click in your file manager and choose Open in Terminal.

On Windows, type `.\openreliant.exe` wherever these steps say `./openreliant`.

### 2. Allow the download to run (macOS only)

Release builds are not signed, so macOS blocks them until you run this once:

```bash
xattr -d com.apple.quarantine openreliant
```

### 3. Install game files

#### From physical discs

Insert StarLancer disc 1 into your drive and run:

```bash
./openreliant install StarLancer
```

The installer detects the CD drive, unpacks `LANCER.CAB` and copies required files (about 1.2 GB) into a folder named `StarLancer`. Any other folder name or path works too.

When prompted, insert disc 2 and press Enter to finish copying. If you do not have disc 2 at hand, type `skip` when asked for it. You can run the installer again later with disc 2 alone to add its files to an existing install.

#### From disc images (.bin or .iso)

If you have disc images or folders with the discs' files, name them with `--from`, once for each disc. Each disc is optional and the two can come in either order. For a `.bin` with a `.cue` next to it, name the `.bin`:

```bash
./openreliant install --from "StarLancer Disc 1.bin" --from "StarLancer Disc 2.bin" StarLancer
```

#### Other releases

If the installer says it does not recognize your disc (for example, from a regional release), add `--force` to install from it anyway:

```bash
./openreliant install --force StarLancer
```

Please also open an issue on GitHub stating which release you have and the size the installer gives for `LANCER.CAB`, so support can be added.

### 4. Launch the game

Run the executable with the installed folder:

```bash
./openreliant StarLancer
```

The game opens in its main menu. SINGLE PLAYER leads to the pilot roster, where you type your call sign or pick one of the last ten, and choose your pilot. START GAME asks the game's difficulty, then starts a campaign: Enriquez shows a new pilot round the Reliant, and the Reliant's rooms open, walked through with the mouse. The door to the briefing room starts the first mission, and Escape opens the in-game options. QUIT leaves the game. The other screens are still to come.

To play a mission at once, give its number, such as 1 for the first campaign mission, or 0 for OpenReliant's sandbox:

```bash
./openreliant StarLancer --mission 1
```

While flying:
- Escape opens the pause menu. In it, RESTART restarts the mission, and LEAVE MISSION leaves it for the restart screen, or from INSTANT ACTION for the main menu.
- When a mission of the campaign ends, the ITAC opens with its debriefing, whose REPLAY MISSION flies it again; then the campaign goes on to the next mission's briefing. Where you were killed or captured, or left the mission, the restart screen replays it from its briefing or its launch, or goes back to the main menu. A total failure, or a third rescue by a nanny ship, ends your career. INSTANT ACTION goes back to the main menu.
- A mission started with `--mission` starts flying at once. Its LEAVE MISSION quits, and when the mission ends the pause menu opens, where RESTART or CONTINUE flies it again.
- Keys 1 to 8 switch camera views: 1 cockpit, 2 left, 3 right, 4 rear, 5 flyby, 6 target, 7 external, and 8 missile.
- Press C for the radio menu, whose number keys call your wingmen and the base; F5 to F8 give orders to your wingmen and request landing.
- Press 0 to save a screenshot, a PNG in the `screenshots` folder of the game directory. In the briefing, O does the same.
- In the sandbox, press F2 or F3 to start it again in the previous or next ship, and F4 to bring in another enemy wing.

## Building from source

To compile OpenReliant, install [Zig 0.16](https://ziglang.org). Dependencies (SDL3, OpenAL Soft, libarchive) build from source automatically:

```bash
zig build -Doptimize=ReleaseFast
zig-out/bin/openreliant install StarLancer
zig-out/bin/openreliant StarLancer
```

## Next steps

- [Controllers and input](controllers.md): Set up gamepads, flight sticks, HOTAS devices, and button mappings.
- [Configuration and options](configuration.md): Command-line options for graphics, sound, and display settings.
