-- BANANA ARENA: the Instant Action arena, flown in the Banana Boat. This is a menu script: it runs
-- as OpenReliant starts, when game modes are registered.

local core = require("openreliant.core")

core.register_game_mode({
    name = "arena",
    label = "BANANA ARENA",
    description = "The Instant Action arena, flown in the Banana Boat, against fighters flown by Troopers, who never hit anything.",
    missions = { 29 },
    ship = "bananas:banana_boat",
    loop = true,
})
