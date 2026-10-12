# Privateer 2

Privateer 2: The Darkening (Origin Systems, 1996) is a DOS game by the developers who went on to
make StarLancer. This page compares the two games: what StarLancer carried over from it, and what
is new. `sltool` reads the formats they share. OpenReliant doesn't play Privateer 2.

```bash
sltool hog ls DANI.BIG                 # an archive's files: the .BIG files and some .IFF files
sltool hog extract SPEECH.BIG <dir>    # copy them out
sltool spr ls INSERT.SHP               # a picture set's shapes and palettes
sltool spr extract INSERT.SHP <dir>    # its pictures, as PNG files
sltool fat ls C10A.fat                 # a sound bank of the format's first version
sltool fat extract C10A.fat <dir>      # its sound, as stored
```

The page covers the files of the installed game, the `DARK` folder. The CDs' files aren't covered.

## The files

| File | Contents |
|---|---|
| `DARK.EXE` | The game, a 32-bit DOS program built with Watcom C/C++, which runs under the DOS/4GW extender, `DOS4GW.EXE` |
| `DANI.BIG`, `SPEECH.BIG` | Archives of sound banks: 31 and 406 banks of one sound each |
| `PILOTS.BIG` | An archive of 112 pictures named for the game's characters and ships, such as `jaren.shp` and `CARGO0.shp` |
| `SPACEGEO.IFF`, `SPACETEX.IFF`, `ISETS.IFF` | Archives despite their extension: the space objects' models, their textures, and five more IFF files |
| `INSERT.SHP` | A picture set: the screen that asks for a CD, with its palette |
| `GAMEFLOW.IFF`, `MISSION*.IFF`, `UNIV.IFF`, `SPACE.IFF`, `BOOTH.IFF`, `PAD.IFF`, `MUSIC.IFF` | Origin's IFF files: the game's flow, the missions, the universe, space, the scenes and the music |
| `GAME00.IFF` to `GAME09.IFF` | The saved games, IFF files too |
| `*.MDI`, `*.DIG`, `AILDRVR.LST` | The sound drivers of Miles' Audio Interface Library for DOS |

## Carried over

### Archives

Privateer 2's archives are the `BIGF` container of StarLancer's `.HOG` files, with the same
big-endian header and directory ([`.HOG` archives](../formats/hog.md)). No member is compressed:
StarLancer added RefPack compression ([RefPack](../formats/refpack.md)). Three of the `.IFF` files
are archives too, of IFF files.

### Sprites

Privateer 2's `.SHP` pictures are StarLancer's `.SPR` sprite sets, version `1.40`, block for block
([`.SPR` sprites](../formats/spr.md)). `INSERT.SHP` carries its palette. The pictures in
`PILOTS.BIG` carry none, so `sltool spr extract` writes them in greyscale. **Unknown:** which
palette the game draws them with.

Despite the extension, they aren't StarLancer's `.SHP` files. StarLancer kept this format for its
sprites under the name `.SPR`, and used `.SHP` for its 3D models, a format of its own
([`.SHP` models](../formats/shp.md)). Privateer 2's models are BRender's, in IFF files ([New in
StarLancer](#new-in-starlancer)). So a Privateer 2 picture renamed to `.SPR` reads as a StarLancer
sprite, as `sltool spr` shows, and a mod could use one. A picture without a palette is drawn with
whichever palette StarLancer has loaded, so its colours come out wrong unless it's given one.

### Sound banks

Privateer 2's `.FAT` sound banks are the format's first version, `1.00`, where StarLancer's are
`2.00` ([Version 1.00](../formats/fat.md#version-100)). The header is the same. The entries are
longer and give each sound's size decoded rather than stored, and the sounds are raw 4-bit samples
rather than WAVE files. **Unknown:** their codec, so `sltool fat extract` writes them as stored
([#1074](https://github.com/OpenReliant/openreliant/issues/1074)).

### The game's code

`DARK.EXE` reads its archives through a "BigFile", and keeps the game's flow and the missions'
flags in `GAMEFLOW.IFF`. StarLancer has a `bigfile.cpp` and a `gameflow.cpp`, which keeps the
campaign's flags. The archives of pilots and speech, `PILOTS.BIG` and `SPEECH.BIG`, have StarLancer
counterparts in `pilots.hog` and its speech archive. Both games play their sound through Miles: the Audio
Interface Library for DOS here, the Miles Sound System for Windows in StarLancer.

## New in StarLancer

| Privateer 2 | StarLancer |
|---|---|
| DOS, Watcom C/C++, DOS/4GW | Windows, Visual C++ 6.0 ([Executables](../binary/executables.md)) |
| Argonaut's BRender 1.x, whose source files' tags the executable carries, such as `zbmesh.c` | Surrender, with a Direct3D 7 driver ([Rendering](../engine/rendering.md)) |
| Models and textures as IFF files of BRender's structures, in archives | `.SHP` models and texture caches ([Models](../formats/shp.md), [Texture caches](../formats/tcache.md)) |
| Missions, the game's flow and the universe in Origin's IFF files | `.DTE` missions, with a script that a virtual machine runs ([`.DTE` missions](../formats/dte.md)) |
| Movies in EA's TGV format, such as `movies\origin.tgv` | Bink movies ([Bink](../formats/bink.md)) |
| Characters' pictures, 90 by 90 pixels | Animated face films ([Face films](../formats/fm8.md)) |
| Uncompressed archives | RefPack compression |
| Raw 4-bit sounds | WAVE files, mostly IMA ADPCM |
