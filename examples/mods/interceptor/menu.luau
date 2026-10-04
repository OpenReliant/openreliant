-- INTERCEPTOR ARENA: the Instant Action arena, flown in the Interceptor. This is a menu script: it
-- runs as OpenReliant starts, when game modes are registered. A game mode's ship can be one the
-- mod adds, by its qualified name.

local core = require("openreliant.core")

core.register_game_mode({
    name = "arena",
    label = "INTERCEPTOR ARENA",
    description = "The Instant Action arena, flown in the Interceptor: faster than a Predator, with lighter shields.",
    missions = { 29 },
    ship = "interceptor:interceptor",
    loop = true,
})
