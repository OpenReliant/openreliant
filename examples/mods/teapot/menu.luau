-- TEAPOT ARENA: the Instant Action arena, flown in the teapot.
local core = require("openreliant.core")

core.register_game_mode({
    name = "arena",
    label = "TEAPOT ARENA",
    description = "The Instant Action arena, flown in a yellow teapot.",
    missions = { 29 },
    ship = "teapot:teapot",
    loop = true,
})
