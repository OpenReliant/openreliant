-- The arena's rules, while its game mode runs (menu.luau): the player's shots hit harder and the
-- enemy's hit the player softer, and the player's kills in the arena are counted, in this arena
-- and the best of all. This is a global script: it runs for the whole game, in every mode, so each
-- rule checks the mode first.

local core = require("openreliant.core")
local hooks = require("openreliant.hooks")
local storage = require("openreliant.storage")

-- How much harder the player's shots hit, and how much softer the enemy's hit the player.
local player_factor = 1.5
local enemy_factor = 0.5

local arena = storage.game_section("arena")
local best = storage.global_section("best")

local function in_arena()
    return core.game_mode == "arena:arena"
end

for _, name in { "object_damage", "object_armor_damage" } do
    hooks.add(name, function(e)
        if not in_arena() or e.attacker == nil then
            return
        end
        if e.attacker.is_player then
            e.value *= player_factor
        elseif e.object.is_player then
            e.value *= enemy_factor
        end
    end)
end

hooks.add("destroyed", function(e)
    if not in_arena() then
        return
    end
    if e.component == nil and e.attacker and e.attacker.is_player and e.object.side == "hostile" then
        arena.kills = (arena.kills or 0) + 1
        if arena.kills > (best.kills or 0) then
            best.kills = arena.kills
        end
    end
end)

-- Mission 29 starts with the simulator's long talk about the display (ms_hudtr_001.ut and the
-- lines after it), which is skipped in the arena. The mission's script waits for each line, so with
-- none said, the fight starts at once.
hooks.add("radio_say", function(e)
    if in_arena() and e.speech:find("ms_hudtr", 1, true) then
        return false
    end
end)
