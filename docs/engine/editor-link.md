# The editor link

Digital Anvil's own mission editor and script debugger, which never shipped, could drive the
original while it ran. The two share a block of named memory: the editor replaces the loaded
mission's tables, moves and remakes its ships, and stops, steps and runs the script, and the game
reports where the script stopped. Nothing public speaks this link.

LordBlacksun decoded the link ([#539](https://github.com/OpenReliant/openreliant/issues/539)), and
the disassembly bears out what follows.

## The block

`editor_link_open` (`0x00457630`) opens the link on the first check. It makes the block,
`CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, 0xD4A08, "FileMappingObject")`
(`0x00457B90`, the name at `0x004F0F3C`), which opens the editor's block where the editor made it
first; maps a view of it (`MapViewOfFile` with `FILE_MAP_ALL_ACCESS`, `0x00457BB0`); zeroes the
editor's message count; and flushes the view (`FlushViewOfFile`, `0x00457BE0`). A view that can't be
mapped stops the game. The game maps a view for each exchange where it holds none, and lets it go
after (`0x00457BD0`).

| Offset | Size | Field |
|---|---|---|
| `0x00` | 2 | Messages from the editor waiting |
| `0x02` | 2 | Messages from the game waiting |
| `0x04` | 1 | Open: the game reads nothing while it is 0, and sets it to 1 as it writes a message into an empty outbox |
| `0x08` | 32 x 8 | The editor's messages |
| `0x108` | | The editor's payloads, at the offsets its messages give |
| `0x40108` | 32 x 8 | The game's messages |
| `0x40208` | | The game's payloads, at the offsets its messages give |

A message is 8 bytes: its tag (`u16`), its payload's size (`u16`) and its payload's offset (`u32`),
counted from the start of the payloads. The game posts a message after the last one waiting, its
payload after the last payload, and leaves out a tag that is waiting already (`0x00457A80`). It
flushes the view after the count, the message and the payload.

## When the game reads it

Only `mission_script_start` (`0x0045CBC0`) reads the editor's messages, through `editor_link_check`
(`0x00457670`): twice as the script starts, 200 milliseconds apart, and then after each start part,
again and again a millisecond apart for as long as the editor holds the script. Nothing else in the
executable reads them, so a hold set later in the mission is never released.

A check that finds messages takes them one by one and acts on each (`editor_link_read`,
`0x00457730`), counting the editor's count down to 0, and takes the editor as there
(`editor_absent`, `0x004F634C`, cleared). A check that finds none counts a miss
(`editor_link_misses`, `0x0052A1D4`); on the 513th miss in a row it takes the editor as gone.
`mission_script_start` sets `editor_absent` before its first check, so with no editor the game sends
nothing and its script never stops. While the editor is there, a check where `vm_clock` is a
multiple of 5 and nothing holds the script sends tag `0x1B` with `vm_first_finished`.

## From the editor

| Tag | What the game does |
|---|---|
| `0x00` | Sets each mission ship's runtime place and angles, `runtime_position`, `runtime_yaw`, `runtime_pitch` and `runtime_roll`, from the ships table it sends (`0x004520A0`) |
| `0x01` | Places the object of the mission ship whose `object_id` it names at the place it gives, then builds the curves again (`0x0045A6D0`, `curves_rebuild`) |
| `0x02` | Sets the counts of the mission's tables from the 50 halfwords it sends, by the table of their addresses at `0x004EE978`, then resets the script's threads (`0x0045A730`, `vm_threads_reset`) |
| `0x03` to `0x05`, `0x07` to `0x0E` | Copies its payload over a table of the loaded mission, the table's count times its record's size (`0x0045A770`): `0x03` the script, `0x04` the parts, `0x05` the triggers, `0x07` the flight groups, `0x08` the objects, `0x09` the script's flags, `0x0A` the squads, `0x0B` the squads' members, `0x0C` the formations, `0x0D` the formations' points, `0x0E` the curves |
| `0x06` | Copies some fields of each mission ship from the ships table it sends (`0x0045AD80`): `object_id`, `name` with the halfword after it, `flight_group`, `kind`, `launch_from` to `launch_gate`, `formation_point` with the halfword after it, `marker_curve` with the two bytes after it, and `marker_at`. The places, the angles, the pilots and the flags stay as they are |
| `0x0F` | Binds the mission's tables again (`mission_bind_tables`) |
| `0x10` | Hands its first halfword to each of the script's timers through `0x00451440`. **Unknown:** what for |
| `0x11` | Retires the object of the mission ship it sends (`0x0045A800`) |
| `0x12` | Retires the object of the mission ship it sends, and makes it again from that record (`0x0045A820`, `mission_ship_create`) |
| `0x13` | Nothing |
| `0x14` | Stands the player's ship four of its radii behind the mission ship it names by index, looking at it (`0x0045A850`) |
| `0x15` | Runs the script, by its first `u32` (`editor_run_control`, `0x0045A900`): 0 pauses the mission, or lets it go on, by the second (`editor_paused`, `0x00537581`); 1, 2 and 3 release the script (`vm_hold`, `0x005373F8`, to -1) and set the step (`vm_step_mode`, `0x00537582`) to that value, 1 only while the script is held; 4 runs the part the second names by its index (`part_run`) |
| `0x16` | Picks a mission ship by its index (`0x0052A1D8`), which nothing reads |
| `0x17` | Copies 32 bytes to `0x005270E4`, which nothing reads |
| Above `0x17` | Stops the game (`fatal_error`) |

While the mission is paused, `mission_frame` leaves out its work (`0x0049288E`), and the timer runs
none of its routines (`0x004A6F80`).

## From the game

| Tag | Payload |
|---|---|
| `0x1A` | The script stopped: the offset in the script of the byte it stopped before, 4 bytes |
| `0x1B` | `vm_first_finished`, 4 bytes |

## Stopping and stepping

While the editor is there, `vm_run` (`0x0045C980`) stops a thread before a byte whose flag in the
script's flags (section 10) has bit 0 set: it holds the script (`vm_hold` 1), sends tag `0x1A` and
returns with the thread at that byte. While the script is held, `vm_clock_tick` leaves the clock
alone, and the threads, the timers and the watches wait; the timer also passes over the script
clock's routine (`0x004A6F80`, the routine `vm_clock_start` sets at `0x0052A1E4`). The step the
editor's release sets acts as the script goes on:

| Step | Then |
|---|---|
| 1 | Runs on, past the byte it stopped before, to the next flagged byte: the step goes back to -1 |
| 2 | Stops before the next instruction that starts a statement (`vm_starts_statement`, `0x004575C0`: opcodes `0x16` to `0x1A`, `0x21` to `0x25`, `0x37` to `0x3A`, `0x4A`, `0x4D` and `0x4E`) |
| 3 | Steps over: notes the running block's end (`vm_block_end`) in the thread's `+0x14`, and stops before a statement only once the running block's end is that again, or once a return has happened (`vm_step_returned`, `0x00537414`, which `vm_return` sets) |

## In OpenReliant

Not ported ([#539](https://github.com/OpenReliant/openreliant/issues/539)). OpenReliant will do what
the link does, the holds, the steps and the editor's changes to the mission, and carry the same
messages over a transport that works on all three systems, in place of the named Win32 block. It will
read the editor's messages every frame as an improvement, since the original reads them only as the
script starts.
