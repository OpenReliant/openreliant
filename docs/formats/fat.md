# `.fat` sound banks

A sound bank packs RIFF/WAVE files into one file. `resource.hog` holds most of them; `CD1.HOG` and
`CD2.HOG` each add `VRSFX.FAT` and `VRSND.FAT`, and a copy of `wlksmp.fat` identical to
`resource.hog`'s.

```bash
sltool fat ls <bank>                  # every sound: offset, size, priority, format, length, and the
                                      # 3D sounds that play it, for smp3d.fat
sltool fat extract <bank> <out-dir>   # every sound as a WAV file, such as stdsmp_012.wav
make sounds                           # every sound in resource.hog into game/sounds
```

## Layout

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `2.00`, four raw bytes |
| 4 | 4 | Sound count |
| 8 | 12 x count | Entries |

| Offset | Field |
|---|---|
| 0 | Offset of the sound from the start of the bank |
| 4 | Size |
| 8 | Priority |

The sounds follow the entries back to back, to the end of the file, and each is a complete WAVE
file ([`formats/wave.zig`](../../src/formats/wave.zig)) whose RIFF length matches its entry's size. All but one are IMA ADPCM (format `0x11`, 4 bits per
sample, with a `fact` chunk giving the length) at 11,025, 22,050 or 44,100 Hz, mono or stereo; the
other is 16-bit PCM. `sltool fat extract` writes them unchanged.

## Version 1.00

Privateer 2, StarLancer's predecessor, keeps its sounds in banks of the format's first version
([Privateer 2](../games/privateer-2.md#sound-banks)). `sltool fat ls` lists them, and `sltool fat extract` writes their
sounds as stored. The header is the same, with `1.00` as its magic. Each entry is 16 bytes:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | Offset of the sound from the start of the bank |
| 4 | 3 | The sound's size decoded, in bytes |
| 7 | 1 | **Unknown:** 1 in every shipped bank |
| 8 | 4 | Priority, 10 in every shipped bank |
| 12 | 4 | **Unknown:** `01 00 01 00` in the speech banks, and `01 00 01 03` in the others |

An entry gives no stored size, so a sound runs to the next sound or to the end of the bank. Every
shipped bank holds one sound. The sounds aren't WAVE files but raw 4-bit samples: each decodes to
four times its stored size in 16-bit samples. **Unknown:** the codec. Decoded as IMA, OKI or Yamaha
ADPCM, the samples drift far from zero, which recordings don't ([#1074](https://github.com/OpenReliant/openreliant/issues/1074)).

## Playback

The engine reads a whole bank into memory with its generic file loader, `hog_read_file`
(`0x004C7F60`), and plays sound `n` of it with `sound_play` (`0x00481F80`), which passes Miles the
WAVE file at `bank + offset`. The priority decides whether a sound may take over a voice already
playing: the player finds the busy voice of lowest priority and stops it only for a sound whose
priority is higher, then records the new sound's priority on the voice ([Sound](../engine/sound.md)).

The shipped banks use priorities 1, 5, 50 and 10000. Most hold a single sound: those named for the
flyable fighters, such as `PREDATOR.FAT`, each hold one at priority 10000.

## The banks

The payload loads these banks by name:

| Bank | What it holds |
|---|---|
| `stdsmp.fat` | The menus' and the flight display's sounds, which scripts play by number too, and the sounds of a frame placed around the camera ([Sound](../engine/sound.md#positional-sounds-of-a-frame)) |
| `smp3d.fat` | The 3D sounds: guns, missiles, explosions, engines, jumps and more, which `sltool fat ls` names ([3D sounds](../engine/sound.md#3d-sounds)) |
| `betty.fat` | Betty's warnings in the cockpit |
| `ldsmp.fat` | The loadout's |
| `inter\itac\itacsnd.fat` | The ITAC's |
| `vrsnd.fat`, `wlksmp.fat` | A carrier's rooms': the ship's hum and the ways into some views; the player's steps and the doors |
| `vrsfx.fat`, `waitloop.fat` | The briefing's: the way in's doors and the room's chatter; the sound that plays while it loads |
| `newsloop.fat`, `rlanda.fat` to `rlande.fat`, `ylanda.fat` to `ylande.fat` | The landings': the news reports' loop, and a sound for each outcome of a landing on the Reliant or the Yamato |

## Mods' sounds

A mod's sound replaces one of a bank's sounds. It's named after the bank and the sound's number, as
`sltool fat extract` saves it (`fat.soundName`), and is a WAVE, FLAC or MP3 file
([Sounds](../guide/modding.md#sounds)). As OpenReliant reads a bank, it makes a new one in memory
with the mods' sounds in place of the bank's own, each entry keeping its priority (`fat.rebuild`,
`hog_snd.BankFile.of`), so the game plays them as it plays its own. A sound the drivers can't play
stays the bank's own, and the log says so.

**Improvement:** the original plays only its banks' own sounds.
