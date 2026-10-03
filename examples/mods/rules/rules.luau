-- Rules of engagement: missiles hit hulls harder, ships on the same side can't hurt each other, and
-- each enemy the player destroys makes the player's guns hit harder until the mission ends. This is
-- a global script: it runs for the whole game, and hooks the game's functions and events.

local hooks = require("openreliant.hooks")

-- How much harder missiles hit hulls and components, and how much harder the player's guns hit for
-- each enemy destroyed.
local missile_factor = 1.5
local streak_step = 0.1

local function is_missile(kind)
    return kind == "missile" or kind == "screamer"
end

-- A missile's damage to a hull, once the shield there is down, and to a capital ship's components.
for _, name in { "object_armor_damage", "component_damage" } do
    hooks.add(name, function(e)
        if is_missile(e.kind) then
            e.value *= missile_factor
        end
    end)
end

-- No damage between ships on the same side: returning false stops the damage. A torpedo or a mine
-- counts what it hits as its own attacker, so those still hurt.
for _, name in { "object_damage", "object_armor_damage", "component_damage" } do
    hooks.add(name, function(e)
        if e.attacker ~= e.object and e.attacker.side == e.object.side then
            return false
        end
    end)
end

-- The player's kill streak in this mission, from the mission's event destroyed.
local streak = 0
hooks.add("destroyed", function(e)
    if e.component == nil and e.attacker and e.attacker.is_player and e.object.side == "hostile" then
        streak += 1
    end
end)

-- The player's shots hit shields and armour harder with the streak.
for _, name in { "object_damage", "object_armor_damage" } do
    hooks.add(name, function(e)
        if e.kind == "bullet" and e.attacker.is_player then
            e.value *= 1 + streak * streak_step
        end
    end)
end

return {
    engine_handlers = {
        -- Each mission starts a new streak.
        on_mission_start = function()
            streak = 0
        end,
    },
}
