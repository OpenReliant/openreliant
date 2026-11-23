# Supported editions

OpenReliant plays these editions of StarLancer. `openreliant install` knows each one by the size
of a file, and says which one it found ([Installation](installation.md#releases)).

## Releases

A release is a full copy of the game, on its own discs.

| Release | Text | Voices | Movies | Discs | Known by |
|---|---|---|---|---|---|
| English (North America and Europe) | English | English | English | 2 | `LANCER.CAB`, 226,746,308 bytes |
| French | French | French | French | 2 | `LANCER.CAB`, 222,899,028 bytes |
| German | German | German | German | 2 | `LANCER.CAB`, 226,777,854 bytes |
| Russian, by 7 Wolf | Russian | Russian | Coded again at half size | 1 | `setup.EXE`, 639,042,179 bytes |

The English discs sold in North America and in Europe hold the same game. The Russian release is
not Microsoft's: it is the English game with a translation its makers added
([The Russian release](../formats/russian-release.md)).

The Japanese release is not known to the installer yet
([#1315](https://github.com/OpenReliant/openreliant/issues/1315)). `--force` installs from a disc
the installer doesn't know.

## Fan translations

A fan translation replaces the text of an installed game. The voices and the movies stay as the
release has them. Add one with `--translation`
([Adding a fan translation](installation.md#adding-a-fan-translation)).

| Translation | Text | Voices and movies | Comes as | Known by |
|---|---|---|---|---|
| Spanish, by Clan DLAN | Spanish | The release's | `LANGUAGE.DLL` and `ITACLANG.DLL` | Their sizes: 118,855 and 441,856 bytes |
| Slovak | Slovak | The release's | A program, `StarLancer_SK.exe` | Its size: 495,444 bytes |

OpenReliant reads the Slovak program's files itself and never runs it
([Fan translations](../formats/translations.md)). A translation the installer doesn't know is
added too, when it comes as the two files.

## Letters

OpenReliant works out the alphabet of a game's text from its strings, and draws it with a font
that has the letters ([Fonts](../formats/fnt.md#outline-fonts)):

| Text | Code page | Font |
|---|---|---|
| English, French, German, Spanish | 1252 | Newtown |
| Slovak | 1250 | Newtown, with the letters it lacks from Play Bold |
| Russian | 1251 | Play Bold |

The words OpenReliant adds to the game's screens are English in every edition.
