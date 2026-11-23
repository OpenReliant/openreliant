# The Russian release

A Russian version of StarLancer, sold on one disc and marked as the work of 7 Wolf (Седьмой
Волк). Microsoft made no Russian release: this is the English game, version 1.0, with a
translation its makers added. They changed more than the strings, so OpenReliant reads it in a
few places of its own:

| What | Where it differs | Read by |
|---|---|---|
| The disc | One disc, the whole game in a Wise installer | [`formats/wise.zig`](../../src/formats/wise.zig), `openreliant install` |
| The strings | In modules of their own names, in Cyrillic | [`language.zig`](../../src/engine/game/language.zig) |
| The fonts | Redrawn with Cyrillic letters | Play Bold, or the game's bitmap fonts ([Fonts](fnt.md#outline-fonts)) |
| The voices | In a format of the makers' own | [`cbox/ddem.zig`](../../src/engine/game/cbox/ddem.zig) |
| The movies | Coded at half size | [`formats/bink.zig`](../../src/formats/bink.zig) |

A later repack of the same release, as an Inno Setup installer, holds the same files installed.
OpenReliant plays its folder, and doesn't read its installer.

## The disc

The disc holds the files of the English disc 1 that Microsoft's setup program needs, and in
place of `LANCER.CAB` and the `GAME` folder one file, `setup.EXE`, 639,042,179 bytes: a Wise
installer with every file of a full install in it, both discs' archives among them.
`openreliant install` knows the release by that file's size
([Installation](../guide/installation.md#releases)).

### The installer

`setup.EXE` is a small Windows program, and after its last section the installer's data: a
header, then each file deflated, without a zlib header, and followed by the CRC-32 of what it
inflates to, some after one byte of padding. The first files are the installer's own: a picture,
its script, and its libraries. The script is a run of commands. Each file it installs has a
command of 0, two bytes of flags, and this record, then its name, which ends in a zero byte:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 | Where the file's stream starts, counted from the first installed file's |
| `0x04` | 4 | Where it ends |
| `0x08` | 2 | The date it was last changed, as MS-DOS writes dates |
| `0x0A` | 2 | The time |
| `0x0C` | 4 | Its size inflated |
| `0x10` | 20 | **Unknown.** |
| `0x24` | 4 | Its CRC-32 |

A name starts with one of the script's variables. `%MAINDIR%` is the game's folder, and the
installer's own files go elsewhere, such as `%SYS%`. `wise.files` finds the records by their
shape rather than reading the script's other commands: a command of 0, a stream no larger than
deflate can make of the file, and a name that starts with a variable. `wise.Installer.read` takes
the first megabyte of the installer, finds the script, and finds where the files start by the
first of them the script lists. `openreliant install` then inflates each file under `%MAINDIR%`
into the game's folder and checks its size and CRC.

**Unverified:** other versions of the Wise installer, which differ.

## What it installs

The installer puts the English game in the folder and adds the translation beside it:

- `rancer.exe`, the game's executable with the names of the two modules of strings changed to
  `ranguage.dll` and `rtaclang.dll`, and the head-up display's two units, `kps` and `k`, changed
  to `км/с` and `к`. OpenReliant keeps `kps` and `k` (`language.display_units`): the only text it holds
  itself is English, and a translation's text comes from its string files alone. The English `lancer.exe`, `Language.dll` and
  `Itaclang.dll` stay, so both languages start from the one folder. The repack keeps the Russian
  ones alone.
- `Resource.hog`, `Cd1.hog`, `Cd2.hog` and `Ms_speech\Msspeech.hog` in place of the English ones.

OpenReliant reads `RANGUAGE.DLL` and `RTACLANG.DLL` where a folder has them, and the game's own
names otherwise (`language.names`), and takes either as the game's strings
(`install.missingGameFile`).

## The text

The Russian strings are Cyrillic. The game reads its strings with `LoadStringA`, which writes
them in the system's code page: 1251 on a Russian Windows. The release's fonts, in
`Resource.hog`, were redrawn with the Russian alphabet at the bytes that page gives it, `0xC0`
to `0xFF`.

OpenReliant takes the page from the strings: the Cyrillic page where any string holds a Cyrillic
letter, and otherwise the Central European page or the Western page, 1252
([Fan translations](translations.md#the-code-page), `language.Page.of`). Everything that turns the game's
text to or from Unicode goes by it (`language.page`). OpenReliant's outline font, Newtown, has
only the Western page's letters, so a game in the Cyrillic page is drawn in Play Bold, the other
font OpenReliant has built in ([Fonts](fnt.md#outline-fonts)).

## The voices

The release's makers recorded the pilots' lines in Russian but had no encoder for the game's
[speech codec](speech.md#the-codec). They stored each line their own way and patched the game to
play it: both executables have a section of 4096 bytes after the game's, `.text$1`, signed
"Patch Generated by DDeM 06/05/2000 especially for 7Wolf", with hooks in `speech_unscramble`
(`0x00462000`), `speech_timer` (`0x004621EB`, `0x00462236`) and `voice_init` (`0x004A7290`).

A line keeps the speech file's 12-byte header, with the size it plays at 22,050 Hz. Its stream:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `DDeM` |
| 4 | | One byte for each two samples the header counts |

The stream isn't scrambled. Each byte is one sample at 11,025 Hz, which the patch looks up in a
table of 256 16-bit samples (`0x00628110`) and writes twice. The table is a companding curve. A
byte is a signed value, and 0 is silence. From 1 to 127 it makes 65535 to the power of the byte
over 127, rounded, and never less than the byte itself: the byte itself up to 43, then 47, 51,
56 and on to 32,589 at 119. A negative byte makes the same with its sign turned. The curve
passes 32,767 at 120, and the table holds 16 bits, so the eight loudest samples either way wrap
round to the other sign, as the patch plays them. -128 makes 1.

OpenReliant plays these lines without the patch (`cbox.Speech.Encoding.ddem`), and works the
table out rather than carrying it (`ddem.table`).

## The movies

To fit one disc, the movies were coded again at half their width, their height or both, with the
flag in their header that has Bink's player show them at twice that
([Bink](bink.md#scaling)). Three of the intro's movies are cut to a few bytes on the disc; the
repack has them whole.
