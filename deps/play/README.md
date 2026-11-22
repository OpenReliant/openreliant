# Play

`Play-Bold.ttf` is Play Bold, a TrueType font by Jonas Hecksher of Playtype. It has the Latin,
Greek and Cyrillic alphabets. OpenReliant has it built in and uses it for a game whose text is
Cyrillic, because [Newtown](../newtown/README.md) has no Cyrillic letters
([Outline fonts](../../docs/formats/fnt.md#outline-fonts)).

It was chosen by eye against the bitmap fonts of the
[Russian release](../../docs/formats/russian-release.md), over Exo 2, Jura and Russo One: its
weight and its squared curves are the closest match.

## Source

The file is `Play-Bold.ttf` from `ofl/play` in [Google Fonts](https://github.com/google/fonts),
unchanged. Its SHA-256 is `45c572eccda4cf335165b750345258e753035bf48ee2fdf37faa07c7db88bce0`, and
its name table gives version 2.101.

## Licence

Play is under the SIL Open Font License, version 1.1, with the reserved font names Play, Playtype
and Playtype Sans. [`OFL.txt`](OFL.txt) holds the licence, and every copy of OpenReliant includes
it as `LICENSE-play.txt`. OpenReliant uses the font file unchanged: it draws the glyphs narrower
or heavier while the game runs, and never writes a changed font.
