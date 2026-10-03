-- Kill tally: counts the enemies the player destroys. This global script keeps the count in a game
-- section of the mod's storage, which goes with each saved game and starts empty with each new
-- game, and the most of any game in a global section, which is kept in the game folder across
-- every game. The player script shows them (board.luau).

local hooks = require("openreliant.hooks")
local storage = require("openreliant.storage")

local game = storage.game_section("tally")
local best = storage.global_section("best")

hooks.add("destroyed", function(e)
    if e.component == nil and e.attacker and e.attacker.is_player and e.object.side == "hostile" then
        game.kills = (game.kills or 0) + 1
        if game.kills > (best.kills or 0) then
            best.kills = game.kills
        end
    end
end)
