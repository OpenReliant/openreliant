# Screenshots

`screenshot_save` (`0x004ADC20`) saves the screen as a picture. Four places ask for one, each once a press (`key_pressed` with its once flag):

| Key | Where | Checked at |
|---|---|---|
| 0 | In flight, as `mission_frame` ends, once the frame is drawn | `0x00493480` |
| 0 | In the locker (`medal_display`) | `0x004368B4` |
| O | In the briefing, before Escape ([The briefing](briefing.md#the-stages)) | `0x004375F1` |
| O | In the loadout | `0x0043787E`, `0x00443689` |

The game grabs the screen (`sr + 0x7C`), turns it into 32 bits a pixel unless it has 8, names it `screenshot%04d.tga` (`0x0050A940`) by `screenshot_count` (`0x005D6CA8`), which starts at 0 each run, and writes it as a Targa file (`tga_write`, `0x004CA620`) in the current directory, the game's.

**Unverified:** that `screenshot_save` is `xtrabits.cpp`'s. It lies past the last code the file's assertions place, between `scene_add` and `object_random15`.

## In OpenReliant

[`game/xtrabits/screenshot.zig`](../../src/engine/game/xtrabits/screenshot.zig) saves the screenshots. The driver reads the last frame drawn back from its device (`Screen.capture`, [`openreliant/presenter.zig`](../../src/openreliant/presenter.zig)), at the frame's full resolution, and the file is written as a task of its own, so that the game goes on meanwhile.

**Improvement:** each screenshot is a PNG, from `screenshot0000.png` on, in the `screenshots` folder of the game's directory. `--original` keeps them so: they change nothing of the game's look or sound.

**Fix:** the numbers go on past the screenshots the folder already holds. The game counts from 0 each run, and writes over the last run's.
