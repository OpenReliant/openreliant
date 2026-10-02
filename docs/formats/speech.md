# Speech files

The radio's lines, one file each in `ms_speech\msspeech.hog` ([`.HOG`](hog.md)), kept without the
`.ut` extension the missions' scripts name them by: `ms1_ban_001.ut` is the member `MS1_BAN_001`;
Enriquez's words in the briefing, from the same archive: her last word before each mission,
`enrbr_tag01` to `enrbr_tag28`, all but 12, and her speech at the campaign's end, `enddebriefing`
([Briefing](../engine/briefing.md)); and the scenes, the `.box` files of the discs' archives,
Enriquez's in the Reliant's rooms and the news reports ([The Reliant's rooms](../engine/rooms.md)).
Each is a stream of the game's own speech codec, scrambled.
[`engine/game/cbox.zig`](../../src/engine/game/cbox.zig) reads a file and
[`engine/game/voice.zig`](../../src/engine/game/voice.zig) decodes its stream.

```bash
sltool speech decode <file> <out.wav>       # one file to 22,050 Hz 16-bit mono WAV
sltool speech extract <archive> <out-dir>   # every line of an archive
```

## Layout

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | The file's length past this field |
| 4 | 4 | `CB00`, or `CB97` for a scene |
| 8 | 4 | The speech's size as 16-bit samples, in bytes: twice the samples it plays |
| 12 | | The stream, to the end of the file |

The game plays a file whatever its tag. The stream is XORed with the key `AB 2D 9A AA`, repeating from its first byte, up to 8 bytes before
the file's end; the last 8 bytes are plain, in every shipped file. The game unscrambles a file in
place as it loads it (`speech_unscramble`, `0x00462000`), writes `man` over the length as its mark
of having done so, and leaves a file so marked, or one beginning `CB`, as it is.

**Fix:** the game unscrambles `length - 0x18` bytes, 8 short of what is scrambled, so it reads the
stream's last 8 bytes scrambled, which end the last frame in noise; OpenReliant unscrambles them.
Where the stream runs out before the samples do, as it does by a few bytes in the shipped files,
the game reads whatever follows the file in memory; OpenReliant reads zeros.

## The codec

The stream is read a bit at a time, least significant first (`0x004A7360`, `0x004A7850`), and
decodes to 22,050 Hz mono in frames of 432 samples, four subframes of 108 each, by linear
prediction: twelve reflection coefficients, a pitch predictor over the past excitation, and a coded
pulse excitation. `voice.State` holds a stream's state as the game does at `+0x18` of its streams
(`speech_streams`, `0x00539AD8`, `0xD64` bytes each). **Unverified:** the source file's name; its
code lies between `timer.cpp`'s and `winmain.cpp`'s, and OpenReliant calls it `voice.cpp`.

The header, once (`0x004A7290`):

| Bits | Field |
|---|---|
| 1 | Whether the subframes read their pulses at a step of two |
| 4 | `n`: the first coefficient's levels below `32 - n` have the frame take the variable pulse code |
| 4 | The first gain, `(value + 1) * 8` |
| 6 | The ratio between gains, `1.04 + value / 1000`: gain `i` is the first times the ratio `i` times |

Each frame (`0x004A73B0`):

| Bits | Field |
|---|---|
| 4 x 6 | The first four coefficients' levels, of the 64 in [`voice/tables.zig`](../../src/engine/game/voice/tables.zig) |
| 8 x 5 | The other eight's, of the 32 from the 17th |
| 8 | Each subframe's pitch lag: the predictor reads the excitation `108 + lag` samples back |
| 4 | Its pitch gain, in fifteenths |
| 6 | Its gain, by number |
| 1, 1 | Stepped: which samples the pulses fall on, and whether the others are nothing or filled in between them by a six-tap filter, the gain then halved |
| | Its pulses (`0x004A76A0`) |

The pulses come in the plain code, `0` for nothing, `01` for -2 and `11` for 2, or the variable
code: two contexts of 256 lookups by the next eight bits into 29 symbols (`tables.symbols`,
`tables.records`, each the next context, a length in bits and a value), a pulse of -6 to 6, a run
of 7 to 70 zeros (six bits more), or an escape: 7, one more for each leading 1 bit, then a sign bit.

The subframe's excitation is the pulses times the gain plus the past excitation at the lag times
the pitch gain. The coefficients step a quarter of the way to the frame's over its first four
blocks of 12 samples, and the all-pole synthesis filter (`0x004A78D0`), its weights from the
reflection coefficients (`0x004A8050`), makes the samples, which the player rounds to 16 bits,
halves to even, and holds at full scale (`speech_fetch`, `0x00462290`; `speech_timer`).

## Playing

`speech_start` (`0x00461EB0`) plays a file through one sample of Miles's, 16-bit stereo at
22,050 Hz with both channels the same, at the speech volume times the master volume's share; a
timer (`speech_timer`, `0x00462190`) decodes 2048 frames at a time into the sample's double buffer.
OpenReliant decodes a line whole and plays it on the sample ([Radio](../engine/radio.md),
[Sound](../engine/sound.md#speech)).
