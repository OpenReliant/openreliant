# Contributing to OpenReliant

OpenReliant reimplements StarLancer's engine function by function from the original executable,
in idiomatic Zig. This guide describes how the code, the documentation and the history are kept,
with examples from the codebase. It is written for people and coding agents alike: `AGENTS.md`
and `CLAUDE.md` point agents here.

## Getting started

- Install [Zig 0.16](https://ziglang.org). `zig build` builds everything, and `zig build test`
  runs the tests.
- Run `make hooks` once. It installs a pre-commit hook that keeps the game's files out of the
  repository.
- `make help` lists every workflow, and `make doctor` reports which parts of the environment are
  in place. The reverse-engineering toolchain (`make setup`, Ghidra) is described in
  [docs/toolchain.md](docs/toolchain.md).
- Bring your own copy of the game: `openreliant install` sets it up
  ([installation guide](docs/guide/installation.md)).

## Working on an issue

Every change beyond a trivial one has an issue, and its pull request closes it.

1. Read the issue together with its comments: `gh issue view 183 --comments`. Comments often carry
   hints from related projects. Treat them as leads, check them against the disassembly, and thank
   the author in a comment when one helps.
2. Work on one feature at a time, on its own branch.
3. Give anything you find and leave for later an issue of its own, under the milestone of its area,
   and link it from the code and the docs where the gap is:

   ```zig
   /// Not ported: the display shaking from interference (`hud_blit`,
   /// [#236](https://github.com/OpenReliant/openreliant/issues/236)).
   ```

## Following the original

OpenReliant does what the original does, step by step and in the same order. Where the decompiled C
is unclear, the assembly decides.

**Each function lives in the module of its original source file.** The engine mirrors the
original tree: `C:\lancer\game\guns.cpp` becomes `src/engine/game/guns.zig`, with a submodule such
as `game/guns/nova.zig` for a part of it. The source file of each address is in
[`src/engine/sources.zig`](src/engine/sources.zig) and
[docs/binary/sources.md](docs/binary/sources.md). A function between two files' known code goes
with the neighbour whose work it does, marked **Unverified:**. The payload stays apart from the
driver, and a platform replacement (SDL3 for Win32 and DirectX) has its own tree.

**Each ported function cites the original's name and address**, and says what it does:

```zig
/// `nova_release` (`0x0047B3D0`), called when the player releases the trigger with the cannon
/// charged. If a beam slot is free and the charge is at least `least_charge`, the ship plays the
/// blast sound, ...
pub fn release(world: gameobj.World, index: u16) void {
```

**Name as you port.** Every function or global you port or understand gets its row in
`ghidra/names/LANCER.EXE.tsv` in the same change, in plain text without double quotes. Prefer the
original's own name where an assert string gives one. `make ghidra-annotate` then reports 0
failed.

```text
0047b3d0	function	nova_release	void __thiscall (GameObject *object, char remote, float charge)	Fires a Phoenix's Nova Cannon when the trigger is released, ...
```

### Improvements and fixes

OpenReliant is faithful by default, and every difference is marked where it is made.

- An **Improvement** is a deliberate change, such as widescreen, per-pixel lighting or a smoother
  effect. `--original` brings back the original's behaviour.
- A **Fix** corrects a clear bug of the original, such as reading the wrong variable. A fix needs
  no switch: it stays in under `--original`, which brings back the original's look and sound, not
  its bugs.

Both appear in the doc comment and in the docs where the behaviour is described:

```zig
/// **Fix:** the game works out where the beam enters the bounding box in the object's local
/// coordinates, then uses that point as a world position, both to pick the quadrant hit and to
/// place the shield flare, so both end up in the wrong place. OpenReliant uses the actual entry
/// point.
```

A few kinds of improvement recur:

- **Exact maths.** OpenReliant computes with `std.math` and `@Vector` where the original uses a
  lookup table or a rounded constant, so `3.14159` becomes `std.math.pi`. Design values such as
  `0.25` or 200 ticks stay as the game has them.
- **Modern randomness.** Random numbers come from `std.Random` rather than the MSVC runtime's
  `rand`; [#234](https://github.com/OpenReliant/openreliant/issues/234) moves the remaining code
  over.
- **High settings.** A quality or detail setting defaults to the original's highest.
- **Graceful limits.** An enhancement with a hard limit keeps the most important items on the
  enhanced path, and sends the rest through the original's.

### Missions and custom content

OpenReliant plays any mission made for StarLancer, not only the ones the game ships, so the mission
files stay the standard format:

- **Read what the original reads.** Missions load and run exactly as the original loads and runs
  them. Accept every file the original accepts, and keep fields that are not understood yet, rather
  than rely on anything the shipped missions happen to share. A command or order that is not yet
  ported never stops a mission from loading or running.
- **No mission-specific code.** Nothing in OpenReliant singles out a mission by its number, name or
  file: a mission does what its file says, through the engine every mission goes through. What the
  original executable itself does by mission number, such as mission 25's second part, is ported as
  the engine's own behaviour.
- **No format of OpenReliant's own.** OpenReliant's own missions, such as mission 0, the sandbox,
  are standard `.DTE` files. Anything OpenReliant adds stays outside the file format, so that the
  files work in the original too. The one exception is a mission's name, which OpenReliant keeps in
  a section the game never reads
  ([OpenReliant's mission name](docs/formats/dte.md#openreliants-mission-name)): it is optional,
  OpenReliant never depends on it, and the game ignores it.

`openreliant missions` binds every mission a game's folder holds; run `make check-missions` after a
change to how missions load or run.

## Writing Zig

Write idiomatic Zig 0.16. A decompiled C shape is a starting point: express the same behaviour
with Zig's types. The standard library changes between releases, so check the installed `lib/std`
for an API.

### Name every number

Give each value a named constant, with its address in the executable, and compare against the name:

```zig
/// The smallest charge that fires when the trigger is released; a smaller charge is lost
/// (`0x004DC408`).
const least_charge: f32 = 0.5;

if (fired < least_charge) return;
```

### Enums for codes, with exhaustive switches

Give an id space (types, orders, opcodes) an `enum`, and compare with its tags or `switch`:

```zig
/// Whether this is a turret gun (the Turret Flak, the Turret Lasers or a Huge Gun) rather than a
/// fighter gun (the Laser Cannon to the Nova Cannon).
pub fn onTurrets(gun_type: GunType) bool {
    return switch (gun_type) {
        .turret_flak, .turret_lasers, .allied_huge_gun, .coalition_huge_gun => true,
        else => false,
    };
}
```

A value read from a file may fall outside the named ones, so make its enum open (`_`) and give it a
`format` method. The method covers every value, and callers print it with `{f}`:

```zig
pub const Format = enum(u16) {
    pcm = 1,
    ima_adpcm = 0x11,
    _,

    pub fn format(tag: Format, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return switch (tag) {
            _ => writer.print("format {d}", .{@intFromEnum(tag)}),
            inline else => |named| writer.writeAll(@tagName(named)),
        };
    }
};
```

### Tagged unions for variants

When a value is one of several kinds, each with its own data, use a `union(enum)` and switch on it:

```zig
pub const Item = union(enum) {
    shape: struct { index: usize, at: [2]i32 },
    string: struct { id: u16, at: [2]i32 },
    rounds: struct { count: i32, at: [2]i32 },
};

for (items(shown.slot, shown.wire_frame, &buffer)) |item| switch (item) {
    .shape => |shape| try hud.drawShapeWith(art, gpa, target, shape.index, ...),
    .string => |string| ...,
    .rounds => |rounds| ...,
};
```

### Packed structs for flag words

Give a word of flags a `packed struct` with a field for each bit, `_unknown_N` for the bits not
understood yet:

```zig
pub const Flags = packed struct(u32) {
    hidden: bool = false,
    components: bool = false,
    no_collisions: bool = false,
    // ...
};

if (object.flags.stand_in or object.flags.disabled) continue;
```

### Extern structs for fixed layouts

Give a record with a fixed layout an `extern struct`, pin its offsets with `comptime` asserts, and
read it in place (`formats/layout.zig`):

```zig
/// The damage a hit does to a shield and to a hull.
pub const Damage = extern struct {
    shield: f32,
    hull: f32,

    /// The factor that turns damage getting through a shield into hull damage (`object_damage`):
    /// hull damage divided by shield damage.
    pub fn hullShare(damage: Damage) f32 {
        return damage.hull / damage.shield;
    }
};

comptime {
    assert(@offsetOf(Gun, "damage") == 0x48);
    assert(@sizeOf(Gun) == record_size);
}
```

### Optionals for "none"

Where the original marks "none" with a sentinel such as -1, keep the record as it is and let a
method return an optional:

```zig
pub const Group = struct {
    first: i16 = -1,
    second: i16 = -1,

    /// The index of its first gun, if it has one.
    pub fn lead(group: Group) ?usize {
        return place(group.first);
    }
};

const first = gunAt(fitted, table[group].lead()) orelse return null;
```

### Comptime for invariants

Check a rule that must always hold with `comptime`, so a mistake fails the build rather than
reaching a player. This ties the quadrants' fields to the order of the `Quadrant` enum:

```zig
comptime {
    for (std.enums.values(collision.Quadrant), @typeInfo(Quadrants).@"struct".fields) |quadrant, field| {
        assert(std.mem.eql(u8, @tagName(quadrant), field.name));
        assert(@offsetOf(Quadrants, field.name) == @as(usize, @intFromEnum(quadrant)) * @sizeOf(f32));
    }
}
```

### One place for each piece of logic

Look for an existing helper before writing one, and share code rather than copy it. For example,
`guns.starMesh` builds the star-shaped meshes of the shots and of the Nova Cannon's beam, and
`Damage.hullShare` gives the hull's share of a hit for guns and missiles alike.

### Tests with every change

Add `test` blocks next to the code in the same change. Build their inputs by hand so that they run
without the game's files. A new module's tests run once its parent's `test` block references it;
`zig build test --summary all` shows the count. The Nova Cannon's charge, for example:

```zig
test charge {
    var object = std.mem.zeroes(gameobj.GameObject);
    object.gun_factor = 100;
    var shake: f32 = 0;
    // At a quarter charge, the view doesn't shake.
    charge(&object, &shake);
    try std.testing.expectApproxEqAbs(0.25, object.nova_charge, 1e-6);
    try std.testing.expectEqual(0, shake);
    // ...
}
```

## Documentation

Document each finding under [`docs/`](docs/README.md), by topic, in the same change as the code.

- **Reference style.** Write plain, present-tense reference: what a format holds and what the code
  does, with addresses as evidence. Mark open points plainly with **Unknown:** or **Unverified:**.
  The history of how something was found belongs in the pull request.
- **Structural numbers.** Keep the numbers that define the format or the engine: offsets, sizes,
  capacities, magic values. State verification as a property, such as "in every shipped file".
  Tallies and timings go out of date as tools and readings change.
- **Its name.** Call the project OpenReliant, and the game it reimplements the original;
  `openreliant` is the executable.
- **Plain English.** Use ordinary technical English in normal sentence order: "the key bindings",
  "is presented to the game as a joystick device".
- **Punctuation.** Use colons, commas, parentheses or a second sentence. The project's text keeps
  to these in place of em and en dashes.

For example, from [docs/engine/guns.md](docs/engine/guns.md):

> `bullet_fire` (`0x0047C5F0`) allocates the first available of 200 projectile records at
> `0x00563148` (`0xC4` bytes each), and `bullet_place` (`0x0047BDB0`) populates it.

## Checks

Before you open a pull request, run:

```bash
zig build test --summary all
zig fmt --check src build.zig
make check-files
```

When names or Zig types exported to Ghidra changed, also run `make ghidra-annotate`, which needs
the reverse-engineering toolchain.

The repository holds the engine and its tools. The game's files, and everything extracted or
derived from them, live in the git-ignored `game/` directory. The pre-commit hook, `make
check-files` and CI keep it that way.

## Commits and pull requests

- **Branches.** Branch from `main` (`feat/blind-fire`, `fix/...`, `docs/...`) and open a pull
  request. `main` changes only through squash-merged pull requests.
- **Titles.** Title the pull request in [Conventional Commits](https://www.conventionalcommits.org)
  form, since squashing makes it the commit on `main` that release-please turns into the changelog
  and the version:

  ```text
  feat: blind fire aims the player's shots at the lead cursor
  fix: missiles hurt the player's raised shields
  docs: the software device draws the display's text
  refactor: name the damage pair and share the star mesh helpers
  ```

  `feat` is for what a player gets, `fix` for a bug fixed, and `docs`, `refactor`, `test`, `perf`,
  `build`, `ci` and `chore` for the rest.
- **Bodies.** Keep the body short: what changed and what is left, a few lines each. End with
  `Closes #N` for each issue the pull request finishes.
- **Commit messages.** Explain why the change exists.
