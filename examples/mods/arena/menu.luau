-- Registers the arena game mode, which the main menu's GAME MODES lists. This is a menu script: it
-- runs as OpenReliant starts, when game modes are registered. The mode flies Instant Action's
-- mission, 29, in a Phoenix, and starts it again each time it ends, until the player leaves it from
-- the pause menu. Its rules (rules.luau) and its board (board.luau) apply while it runs alone.

local core = require("openreliant.core")

core.register_game_mode({
    name = "arena",
    label = "ARENA",
    description = "Wave after wave in the Instant Action arena, in a Phoenix. Your shots hit harder, the enemy's softer, and the board keeps your kills.",
    missions = { 29 },
    ship = "phoenix",
    loop = true,
})
