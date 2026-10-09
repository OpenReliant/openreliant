# The ion cannon

The ion cannons of the Dark Reign, the Boridin and the rogue base (`aiioncan.cpp`, `0x0040D210` to
`0x0040E780`, with the routines either side of it that do its work). Dark Reign shoot (33) picks
the nearest ship of its target, and Dark reign shoot (110) fires the cannon at it: the cannon turns
to the ship, paints it with a red targeting laser as it charges, crackles with blue rays as the
lights on its barrel come on, glows along its barrel, and fires a beam that destroys the ship.

## In OpenReliant

[`game/aiioncan.zig`](../../src/engine/game/aiioncan.zig) ports order 110 and the cannons' state,
and [`game/aifuncs.zig`](../../src/engine/game/aifuncs.zig) order 33. The order queue it goes
through is in [`game/aigeneric.zig`](../../src/engine/game/aigeneric.zig)
([Orders](orders.md#the-queue)).

Not ported: what a network game adds: the wait for every player at each step
(`ai_sequence_sync`, `0x00401000`), the towers that give up a long search, and the cannon's turn
and kill sent to the other players ([#55](https://github.com/OpenReliant/openreliant/issues/55)).

## Picking a ship

Dark Reign shoot (33, `order_dark_reign_shoot`, `0x0040BAD0`) has no init. Each update walks the
ships its target names ([Orders](orders.md#targets-that-name-several-ships)) with `0x0040BA40`,
which keeps the nearest ship, by where both will be next, that the Dark Reign can aim at and that
is neither fully invulnerable nor cloaked. It queues order 110 at that ship, due at once
(`order_queue`), and with none it pops. The queued order starts over it at the object's next
orders, and once order 110 is done, order 33 runs again and picks again.

## The parts

| Type | Turns | Fires from | Rays | Lights |
|---|---|---|---|---|
| Dark Reign (`0x44`) | `Dark Low Body` | `Dark Focus` | 4 | 5 |
| Boridin (`0x48`) | `Bor Ion Cannon` | the same | 3 | 3 |
| Rogue base (`0xA5`) | `cannon` | the same | none | none |

Any other type is taken for the Dark Reign, with no focus. The cannon's points are
[point lists](../formats/shp.md#point-list-tags-0x0d-0x0e) of kinds 11 to 15: the barrel's two
ends, pairs for the rays and for the lights on the cannon, and where the beam (14) and the
targeting laser (15) leave the focus.

## The record

`ion_cannon_record_alloc` (`0x0040E7A0`) makes the cannon's record (`0x005185C8`, 0x60 bytes) as
the order starts: its lights, `Ioncannon Light`, white point lights with an intensity of 9 and a
range of 2000. `ion_cannon_record_free` (`0x0040E8A0`) lets the record's effects go: when the
order ends, when the ship goes, when the lock breaks, and when the ship is destroyed.

**Improvement:** the game has room for one record, which every cannon takes, so two cannons firing
at once spoil each other's effects. OpenReliant keeps one for each cannon.

**Fix:** the game means to stand each light in the middle of a pair of the cannon's light points,
hanging from the cannon, but its test is the wrong way round (`0x0040D10F`), so the lights stay at
the world's origin, where they were made, and their sounds come from there. OpenReliant stands them
on the cannon, one for each pair it lists.

## Each update

Each update of order 110 (`order_fire_ion_cannon`), the Boridin stops dead, and the order pops
where the cannon's part or its focus is gone. Then:

1. Where the ship stands more than the angle whose cosine is 0.98 off the cannon's Z axis, either
   way along it, on the plane of its X and Z axes, the cannon turns about its Y axis toward it:
   0.2 radians every hundred ticks for a ship in one of the first five slots, the player's among
   them, and 0.4 for another.
2. Where the ship has gone, explodes or runs Explode, the order pops.
3. From the charge step to the glow step, unless the ship is the Victorious, the lock breaks where
   the ship is cloaked, more than 190000 from where the beam leaves (400000 for the Boridin), off
   the cannon's line by an angle whose cosine is under 0.90631, or, for a player's ship, nearer
   than 8000 across the world's X and Z axes (110000 in mission 28, [Rules by mission number](missions.md#rules-by-mission-number)). The order then pops and
   pushes itself again at the ship, so the cannon starts again. While the mission's script sets
   `ion_cannons_hold_lock` ([Script VM](script-vm.md#the-games-variables)), the lock holds.
4. Before the glow step, the cannon gives up once it has searched for 2500 ticks, and the order
   pops; the ready step starts the count again.

## The steps

Each step lasts its ticks (`0x004E1C04`), and the next begins once they are up:

| Step | Ticks | What happens |
|---|---|---|
| 0, start | | It goes on at once. |
| 1, aim | | Once the ship stands within the angle whose cosine is 0.9063 of the cannon's line, the targeting laser goes up (`Ioncannon Mesh1`): three blades over `laser2`, 600 wide either side, 200 at the Victorious. |
| 2, charge | 300 | The laser turns toward the ship, reaches out to it over the first 0.3 of the charge and reddens with it (`ion_cannon_laser_aim`, `0x0040E970`). Moose warns the player (`MOO_ICW001.ut`) where the ship is the player's, at most every 1500 ticks. |
| 3, power | 300 | Each light comes on for a frame in turn, a fifth of the step after the one before, heard (`BIGON`). As the step ends, the cannon is heard charging (`ICHARGE`), and blue electric rays crackle between its pairs of points. |
| 4, ready | 150 | The lights shine. As the step ends, the barrel's glow (`Ioncannon Mesh2`, four blades over `ionc`, unlit) stands between the barrel's ends, and five rings (`Ioncannon Mesh3`, squares 6000 across over `warpin3`) across the barrel. |
| 5, glow | 200 | The glow widens from 0.5 to 2000 over the step's first tenth, and its blades' texture runs along them, each 0.01 a tick faster than the blade before. The rings run up the barrel twice, a fifth of it apart. As the step ends, the cannon is heard firing (`ILASER`): the beam, three strands from where it leaves to the ship, its light reaching 100000; and five lit fireballs about the ship, up to 0.7 of its radius off it and across, 20 ticks apart. |
| 6, fire | 100 | The beam's end follows the ship, 300 above it on the world's Z axis, and the rays fade. Over the step's last tenth the glow flares to 5000 and narrows to 0.5. |
| 7, destroy | | The ship is destroyed, though not while the director's view shows the player's ship being fired at. A ship of a type with a component loss routine ([Objects](objects.md#a-components-destruction)) loses its hull, the first part of its model of the hull's class; another, unless it is fully invulnerable, is destroyed, spinning, with no pilot ejecting. The order pops. |

The beam's strands are white, violet and violet, the first over `laser3`; the rogue base's are
two violets and a lighter one. The rogue base's cannon neither crackles nor lights up nor glows,
and its laser goes down as it fires. Each effect shows on the frames its step puts it up.

**Fix:** where a ship with a component loss routine has no hull part, the game stops with an
assertion; OpenReliant destroys it as it destroys another.

**Improvement:** the laser reaches out by the charge over 0.3, where the game multiplies by
3.3333333, and the glow's blades are turned by a computed quarter of a half turn.
