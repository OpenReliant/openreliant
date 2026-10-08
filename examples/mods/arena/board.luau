-- The arena's board over the flight display, while its game mode runs (menu.luau): the kills in
-- this arena, which the global script counts (rules.luau), and the best arena of all. This is a
-- player script: it draws what the player sees.

local core = require("openreliant.core")
local hud = require("openreliant.hud")
local storage = require("openreliant.storage")

local arena = storage.game_section("arena")
local best = storage.global_section("best")

local color = vector.create(1, 0.4, 0.2)

return {
    engine_handlers = {
        on_frame = function()
            if core.game_mode ~= "arena:arena" or not hud.shown then
                return
            end
            local board = string.format("ARENA    KILLS %d    BEST %d", arena.kills or 0, best.kills or 0)
            hud.text(vector.create(hud.width / 2, hud.height * 0.12, 0), board, { color = color, align = "center" })
        end,
    },
}
