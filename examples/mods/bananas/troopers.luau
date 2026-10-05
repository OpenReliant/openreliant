-- The Troopers. This is a global script: it runs for the whole game, in every mode, so each rule
-- checks the mode first. In BANANA ARENA, every enemy fighter is flown by a Trooper, and nothing a
-- Trooper fires ever hits.

local core = require("openreliant.core")
local hooks = require("openreliant.hooks")
local world = require("openreliant.world")

local trooper = "bananas:trooper"

-- How often the enemy fighters are checked for pilots who aren't Troopers, in seconds.
local check_every = 0.5
local since_check = 0

local function in_arena()
    return core.game_mode == "bananas:arena"
end

-- A Trooper's shots and missiles do nothing to what they strike.
for _, name in { "object_damage", "object_armor_damage", "component_damage" } do
    hooks.add(name, function(e)
        local attacker = e.attacker
        if in_arena() and attacker ~= nil and attacker:is_valid() and attacker.pilot == trooper then
            return false
        end
    end)
end

return {
    engine_handlers = {
        -- Every enemy fighter gets a Trooper. A mission gives each of its ships the pilot its record
        -- names as the ship is made, so the script checks for new fighters as the mission goes on.
        on_update = function(seconds)
            if not in_arena() then
                return
            end
            since_check += seconds
            if since_check < check_every then
                return
            end
            since_check = 0
            for _, object in world.objects() do
                if object.side == "hostile" and object.class == "fighter" and object.pilot ~= trooper then
                    object.pilot = trooper
                end
            end
        end,
    },
}

-- The simulator's long talk about the display (ms_hudtr_001.ut on), which mission 29 starts with,
-- is skipped in the arena. Its script waits for each line, so with none said, the fight starts at
-- once.
hooks.add("radio_say", function(e)
    if in_arena() and e.speech:find("ms_hudtr", 1, true) then
        return false
    end
end)
