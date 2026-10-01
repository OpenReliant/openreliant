# Modding

OpenReliant plays mods: files that stand in for the game's own, or add to them, without changing
the game's files. A mod replaces a model, a picture of the interface, a sound, a piece of music, a
line of speech, a pilot's face, a movie, a mission or a stats table alike, with a file of the same
name as the one it replaces.

**Improvement:** the original reads its own files alone.

## Where mods go

Mods go in a folder named `mods` in the game's folder, beside `resource.hog`. Each mod is one of:

- **an archive**, a `.hog` file of the game's own format ([`.HOG` archives](../formats/hog.md)),
  as `sltool hog pack` makes one; or
- **a folder** of files, for a mod while it is being made. Its files lie in the folder itself: a
  folder within it is left out, as `sltool hog pack` leaves it.

```text
StarLancer/
  resource.hog
  mods/
    coyote/
      mod.ini
      mod.png
      USA_Coyote.SHP
    music.hog
    music.hog.sha256
```

`--no-mods` plays the game's own files alone.

## How a mod's file stands in

A mod's file stands in for every file of the game's of the same name, wherever the game keeps it:
the members of its archives and its loose files. Names match whatever their case, and by the file's
name alone, without its folders: a mod's `New_Pensive.wav` replaces `music\New_Pensive.wav`. A file
of a name the game has none of adds one, for a mission or a model of the mod's own to use. Where the
game keeps a name in several places, it keeps copies of one file there, such as the stats tables,
which lie both loose and in `resource.hog`, or one picture saved twice. Where an archive repeats a
name, the game reads the first, and the mod's file stands in for that one.

| What | Where the game keeps it | For example |
|---|---|---|
| Models | `resource.hog` | `USA_Coyote.SHP` |
| Pictures, fonts and sprites of the interface | `resource.hog`, `CD1.HOG`, `CD2.HOG` | `brd2cd.tga`, `FONT.FNT`, `medal1.spr` |
| Sound banks | `resource.hog`, `CD1.HOG`, `CD2.HOG` | `betty.fat` |
| Music | `music\` | `New_Pensive.wav` |
| Speech | `ms_speech\msspeech.hog` | `ABRT_001` |
| Pilots' faces | `pilots\pilots.hog` | `45Tigers_Moose_D.fm8` |
| Movies | the game's folder, `interface\`, `inter\`, `CD1.HOG`, `CD2.HOG` | `New_nms.bik`, `int.bik` |
| Missions | `missions\`, `resource.hog` | `mission1.dte` |
| Stats tables | the game's folder | `shipstats.bin` |

`sltool hog ls <archive>` lists an archive's members by name, and `sltool hog extract` copies them
out. Names are flat, so a mod gives the files it adds a prefix of its own, which keeps them apart
from another mod's.

A mod's files are in the game's own formats, which the [developer documentation](../README.md)
describes, but for the textures below. Files in today's formats come later: material maps
([#495](https://github.com/vdmkenny/openreliant/issues/495)), glTF models
([#359](https://github.com/vdmkenny/openreliant/issues/359)), sounds, music, speech and movies
([#496](https://github.com/vdmkenny/openreliant/issues/496)), and pictures of the interface at any
size ([#499](https://github.com/vdmkenny/openreliant/issues/499)).

## Textures

The textures of the models and the effects come from the texture cache, `tcachehw.dat`
([Texture caches](../formats/tcache.md)), each by a name without an extension, such as `yank_2`, the
Coyote's hull. A mod replaces one with a PNG picture of its name, `yank_2.png`, at any size, with
alpha of its own where it needs it. `sltool tcache ls tcachehw.dat` lists the names.

- A picture is made for the model's own texture coordinates, which the cache's texture shows: the
  same layout at more pixels.
- OpenReliant makes its mipmaps as it loads it, each level half the last down to a pixel, in linear
  light and weighted by alpha, so that a picture needs none of its own.
- A side longer than 8192 pixels is halved until it fits, since every GPU takes that much.
- A 4096x4096 picture takes about 85 MB of the GPU's memory with its mipmaps, and as much of the
  computer's; 2048x2048 suits a fighter.

**Improvement:** the original reads the cache's images alone, at most 256x256.

## The order of the mods

The mods are read in the order of their names, whatever their case, and a later mod's file stands in
for an earlier mod's of the same name: names such as `10-ships` and `20-music` set the order. All of
them come before the game's own files, its loose files among them, so that a mod's `mission18.dte`
replaces the loose `missions\mission18.dte` a retail install carries. A mod manager that chooses and
orders the mods in the game is [#497](https://github.com/vdmkenny/openreliant/issues/497).

## A folder's files

A folder mod holds the files as the game reads them, and reads as the archive `sltool hog pack`
makes of the folder:

- A file that holds a RefPack stream, as a member extracted with `sltool hog extract --raw` does,
  is read expanded, as the game reads a packed member. The movies and the pilots' faces, which the
  game reads as they are stored, are read as they are.
- A file's name is printable ASCII, as an archive member's is. Hidden files, such as `.DS_Store`,
  are passed over.

`sltool hog pack coyote coyote.hog` packs the folder into an archive, which stands in the same way.
The manifest and the thumbnail go into it with the rest.

## The manifest

A mod describes itself in `mod.ini`, in its archive or its folder, an ini file of the kind
`starlancer.ini` is:

```ini
[Mod]
Name=Coyote HD
Version=1.0
Author=Someone
Description=The Coyote, modelled again.
Url=https://example.com/coyote-hd
```

Each key is optional, and found whatever its case. `Url` is the mod's page on the web, where a
player finds it and its updates. The game asks for no file of this name, so the archive stays one the original
reads, and the manifest stands in for none of the game's files.

## The thumbnail

A mod may carry a picture of itself, `mod.png`, in its archive or its folder, which a mod manager
shows ([#497](https://github.com/vdmkenny/openreliant/issues/497)). It is a PNG file of any size; a
4:3 picture, such as 320x240, suits the game's screens. Like the manifest, it is the mod's own.

## Checksums

An archive may come with a checksum file beside it, its name with `.sha256` added, as `sha256sum`
writes one: the archive's SHA-256 digest in hexadecimal, two spaces and the archive's name. As the
mod loads, OpenReliant reads the archive through and leaves the mod out where its digest is not the
one the file gives, since the archive is then damaged or not the one the checksum was made for.
`sltool hog pack <folder> <archive> --checksum` writes one beside the archive it packs, and
`sha256sum -c music.hog.sha256` checks one by hand. A folder mod has none.

## What OpenReliant says

As it starts, `openreliant` lists each mod it plays with, in its order, by its manifest's name
where it has one, then each of its files: the game's file or the earlier mod's it replaces, or the
file it adds.

```text
info(mods): music.hog matches music.hog.sha256
info(mods): mod 1 of 2: Coyote HD 1.0, by Someone (coyote)
info(mods): coyote replaces USA_Coyote.SHP
info(mods): mod 2 of 2: music.hog
info(mods): music.hog replaces New_Pensive.wav
info(mods): music.hog adds msc_theme.wav
```

`openreliant missions` lists and checks the missions the mods hold, `mod` in the file column, and
takes `--no-mods` too.

Mods that add to how the game plays, with scripts and new records as OpenMW's do, are
[#498](https://github.com/vdmkenny/openreliant/issues/498).
