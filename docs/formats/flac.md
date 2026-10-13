# FLAC files

FLAC stores audio losslessly in less space than 16-bit PCM: about two thirds of the space for music,
and less for speech. The original reads no FLAC files. OpenReliant reads them from mods, in place
of a piece of music or a line of speech ([Music](../guide/modding.md#music),
[Lines](../guide/modding.md#lines)).

A file starts with the marker `fLaC`, followed by its metadata blocks and then the audio frames
(RFC 9639). Each block starts with a four-byte header: the top bit of the first byte is set on the
last block, the other seven bits give the block's type, and the next three bytes give its length.
The first block is always the STREAMINFO, 34 bytes long:

| Bits | Field |
|---|---|
| 16, 16 | The smallest and largest block size, in samples |
| 24, 24 | The smallest and largest frame size, in bytes; 0 if unknown |
| 20 | The sample rate, in Hz |
| 3 | The number of channels, minus one |
| 5 | The bits per sample, minus one, for 4 to 32 bits |
| 36 | The number of samples in each channel; 0 if unknown |
| 128 | The MD5 signature of the decoded audio |

## In OpenReliant

[`formats/flac.zig`](../../src/formats/flac.zig) reads the STREAMINFO. FFmpeg's FLAC decoder
([Platform](../port/platform.md#movies)) then decodes the file into a WAVE file of 16-bit PCM at the
file's rate and channels, which a voice or the music plays (`bink.AudioDecoding`). The whole file
goes to the decoder as one packet: the decoder reads the marker and the metadata, then decodes one
frame at a time. Samples of more than 16 bits keep their top 16 bits, as FFmpeg's own conversion
does. A line of speech decodes all at once, and a piece of music a few seconds of music each frame
of the game, starting once it's decoded ([The driver](../port/sound.md#the-driver)).

For a mod's recording, OpenReliant looks for a WAVE file first, then a FLAC file, then an MP3 file
(`recordings.find`).
