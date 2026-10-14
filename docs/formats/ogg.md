# Ogg files

Ogg is a container for audio in Vorbis, Opus and other codecs. Vorbis and Opus store audio in much
less space than 16-bit PCM, losing some of the sound, and Opus takes the least for speech. The
original reads no Ogg files. OpenReliant reads them from mods, in place of a piece of music, a line
of speech or a sound ([Music](../guide/modding.md#music), [Lines](../guide/modding.md#lines),
[Sounds](../guide/modding.md#sounds)). A file of Opus usually has the extension `.opus`, and a file
of Vorbis `.ogg`. OpenReliant reads either codec with either extension.

## Pages

A file is a series of pages (RFC 3533), each with a header of 27 bytes:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `OggS` |
| 4 | 1 | Version, 0 |
| 5 | 1 | Flags: bit 0 is set when the page's first segments carry on a packet from the stream's previous page, bit 1 on a stream's first page, and bit 2 on its last page |
| 6 | 8 | Granule position: how far the stream has got at the end of the last packet that ends on the page, in the codec's units; -1 if no packet ends on the page |
| 14 | 4 | The stream's serial number |
| 18 | 4 | The page's number in its stream |
| 22 | 4 | Checksum |
| 26 | 1 | Number of segments |

The lengths of the segments follow, one byte each, and then the segments. A segment shorter than
255 bytes ends its packet, so a packet spans as many segments, and pages, as it needs. The
checksum is a CRC-32 with the polynomial `0x04C11DB7`, starting at 0, neither reflected nor
inverted, over the whole page with the checksum's own bytes as 0.

## Streams

A stream's first packets are its headers:

- **Vorbis** (the Vorbis I specification): three headers, each starting with its type and `vorbis`.
  The identification header (type 1) is 30 bytes, with the channels at offset 11 and the rate at
  offset 12. The comment header (type 3) holds the tags, and the setup header (type 5) the
  codebooks. The granule position counts samples of each channel.
- **Opus** (RFC 7845): the identification header `OpusHead`, of 19 bytes or more, then the comment
  header `OpusTags`. `OpusHead` holds the version, the channels, the pre-skip at offset 10, the
  rate of the audio that the encoder was given, an output gain at offset 16 in 256ths of a decibel,
  and how the channels map to the Opus streams in each packet. Opus always decodes at 48 kHz, and
  the granule position counts samples at 48 kHz. The pre-skip is the encoder's delay: the samples
  that a decoder drops at the start.

The packets after the headers hold the audio. The last page's granule position says where the
stream ends, which can be partway through its last packet, so that the stream holds exactly the
samples that were encoded.

## In OpenReliant

[`formats/ogg.zig`](../../src/formats/ogg.zig) reads the pages and checks their checksums,
reassembles the packets of the file's first stream, and reads the stream's headers. It skips bytes
that don't start a page, pages that are truncated or damaged, and any packet that a missing page
cuts off. FFmpeg's Vorbis and Opus decoders ([Platform](../port/platform.md#movies)) then decode the
packets into a WAVE file of 16-bit PCM at the stream's rate and channels (`bink.AudioDecoding`).
The Vorbis decoder takes the three headers laced together: the byte 2, the lengths of the first two
headers in the way a page gives its segments' lengths, then all three headers. The Opus decoder
takes the identification header, drops the pre-skip and applies the output gain. OpenReliant then
cuts the samples past the stream's end, the last page's granule position minus the pre-skip, so
that a sound or a piece of music loops without a gap. A line of speech or a sound is decoded all at
once, and a piece of music a few seconds at a time, once a frame, starting once it is fully decoded
([The driver](../port/sound.md#the-driver)).
