-- Mission 0, OpenReliant's own: the sandbox, which openreliant plays where no other mission is
-- chosen. The build compiles this source into a standard mission file, mission0.dte, which the
-- original plays too (docs/formats/mission-source.md).
--
-- The Reliant stands at the origin, facing along Z. The player's ship and three wingmen, a Grendel,
-- a Wolverine and a Reaper, listed in the player's wing, launch from its first four tubes. Ahead, a
-- wing of four Sabres faces the Reliant; beyond them, the Badanov, the smallest of the Coalition's
-- capital ships, is turned across the way; and past the Badanov, outside the action's sphere, lies a
-- field of twelve rocks, the seven asteroids in turn.

mission({ name = "Sandbox" })

-- Flight groups. Only the player's own is listed in a wing, the player's.

alpha = flight_group("(FG)Alpha", { wing = "player" })
reliant_group = flight_group("(FG)Reliant")
badanov_group = flight_group("(FG)Badanov")
sabres = flight_group("(FG)Sabres")
rocks = flight_group("(FG)Rocks")

-- The player's ship comes first: the first ship is the player's. The wing launches through the
-- Reliant's first four tubes.

player = ship("Player", {
    type = "predator",
    group = alpha,
    launch = { from = "reliant", gate = 0 },
})
grendel = ship("(A2)Grendel", {
    type = "grendel",
    group = alpha,
    launch = { from = "reliant", gate = 1 },
})
wolverine = ship("(A3)Wolverine", {
    type = "wolverine",
    group = alpha,
    launch = { from = "reliant", gate = 2 },
})
reaper = ship("(A4)Reaper", {
    type = "reaper",
    group = alpha,
    launch = { from = "reliant", gate = 3 },
})

-- The capital ships: the Reliant, and the Badanov turned across the wing's way.

reliant = ship("The Reliant", { type = "reliant", group = reliant_group })
badanov = ship("The Badanov", {
    type = "badanov",
    group = badanov_group,
    position = { 6000, -9000, 190000 },
    yaw = 63,
})

-- The Sabres, 150000 ahead of the Reliant and 3000 apart, facing it. Their pilot, "jackel", record
-- 42 of pilotstats.bin, is one of its weakest, where the game gives a Sabre the sharp pilot of
-- record 66, "sabre", so that the player's missiles mostly get past their countermeasures.

sabre_1 = ship("Sabre 1", {
    type = "sabre",
    group = sabres,
    pilot = "jackel",
    position = { -4500, 0, 150000 },
    yaw = 180,
})
sabre_2 = ship("Sabre 2", {
    type = "sabre",
    group = sabres,
    pilot = "jackel",
    position = { -1500, 0, 150000 },
    yaw = 180,
})
sabre_3 = ship("Sabre 3", {
    type = "sabre",
    group = sabres,
    pilot = "jackel",
    position = { 1500, 0, 150000 },
    yaw = 180,
})
sabre_4 = ship("Sabre 4", {
    type = "sabre",
    group = sabres,
    pilot = "jackel",
    position = { 4500, 0, 150000 },
    yaw = 180,
})

-- The field of rocks: three rows of four about { 6000, -9000, 250000 }, 26000 apart, each moved up
-- to 7000 along and across and 12000 up or down, and turned at random, each the asteroid three on
-- from the last. They were placed once from a fixed seed, and are kept here as they came out.

rock_1 = ship("Rock 1", {
    type = "asteroid_1",
    group = rocks,
    position = { -27377.045, -19938.695, 226743.86 },
    yaw = 43,
    pitch = 352,
    roll = 216,
})
rock_2 = ship("Rock 2", {
    type = "asteroid_4",
    group = rocks,
    position = { -7223.2935, 39.6084, 227587.1 },
    yaw = 331,
    pitch = 61,
    roll = 242,
})
rock_3 = ship("Rock 3", {
    type = "asteroid_7",
    group = rocks,
    position = { 13703.617, -20444.492, 230932.94 },
    yaw = 215,
    pitch = 323,
    roll = 296,
})
rock_4 = ship("Rock 4", {
    type = "asteroid_3",
    group = rocks,
    position = { 48243.93, -13353.814, 222084.22 },
    yaw = 213,
    pitch = 21,
    roll = 235,
})
rock_5 = ship("Rock 5", {
    type = "asteroid_6",
    group = rocks,
    position = { -39423.36, -4386.264, 244922.1 },
    yaw = 329,
    pitch = 120,
    roll = 31,
})
rock_6 = ship("Rock 6", {
    type = "asteroid_2",
    group = rocks,
    position = { -10433.783, -16488.854, 253691.7 },
    yaw = 95,
    pitch = 330,
    roll = 318,
})
rock_7 = ship("Rock 7", {
    type = "asteroid_5",
    group = rocks,
    position = { 22923.52, 1088.9326, 243209.75 },
    yaw = 334,
    roll = 245,
})
rock_8 = ship("Rock 8", {
    type = "asteroid_1",
    group = rocks,
    position = { 48002.38, -11427.822, 256852.6 },
    yaw = 293,
    pitch = 323,
    roll = 132,
})
rock_9 = ship("Rock 9", {
    type = "asteroid_4",
    group = rocks,
    position = { -38997.773, -2217.7075, 280758.6 },
    yaw = 7,
    pitch = 67,
    roll = 107,
})
rock_10 = ship("Rock 10", {
    type = "asteroid_7",
    group = rocks,
    position = { -6264.5557, 1719.1816, 270284.7 },
    yaw = 298,
    pitch = 86,
    roll = 217,
})
rock_11 = ship("Rock 11", {
    type = "asteroid_3",
    group = rocks,
    position = { 15109.219, -10838.495, 282347.75 },
    yaw = 104,
    pitch = 3,
    roll = 82,
})
rock_12 = ship("Rock 12", {
    type = "asteroid_6",
    group = rocks,
    position = { 40693.15, -11636.012, 277072.9 },
    yaw = 335,
    pitch = 343,
    roll = 86,
})

-- The script: one part, which runs as the mission starts.

start = part("(F)Start", function()
    -- The Reliant's flight group first, so that the wing finds the Reliant to launch from as it is
    -- made, then every other.
    CreateFlightGroup(reliant_group)
    CreateFlightGroup(alpha)
    CreateFlightGroup(badanov_group)
    CreateFlightGroup(sabres)
    CreateFlightGroup(rocks)
    -- An ejected pilot is as likely to be rescued as captured or killed.
    SetRescueProbabilities(33, 33, 34)
    SetAI(rocks, "random_spin_slow", 1, nil)
    -- The capital ships hold their fire over the launch. Their Huge Guns lead a target a quarter of
    -- their shots' life away, which reaches well past the Badanov, so they would fire beside the
    -- player's hangar.
    DisableGuns(reliant_group, 1)
    DisableGuns(badanov_group, 1)
    -- The wing's launch, to the launch's music, as mission 1 starts it, and the wait for the wing to
    -- be out.
    PlayMusic("new_launch.wav", 0)
    StartLaunch(alpha)
    WaitForJumpOrLaunch(alpha)
    -- The capital ships fly on, free to fire, at a tenth of the 100 the Reliant's type cruises at.
    DisableGuns(reliant_group, 0)
    Fly(reliant_group, nil, 10)
    DisableGuns(badanov_group, 0)
    Fly(badanov_group, nil, 10)
    -- The Sabres fight the player, and each wingman fights a Sabre.
    SetAI(sabres, "fight", 1, player)
    SetAI(grendel, "fight", 1, sabre_1)
    SetAI(wolverine, "fight", 1, sabre_2)
    SetAI(reaper, "fight", 1, sabre_3)
    PlayMusic("New_Mission01.wav", 0)
    -- The player may land, as in mission 1 once the Reliant jumps in: PERMISSION TO LAND brings the
    -- player's ship down on the Reliant, which ends the mission.
    game.landing_cleared = 1
    return 1
end, { start = true })
