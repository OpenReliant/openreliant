-- A balance mod: the Laser Cannon hits harder, missiles lock on faster, and the Predator is a bit
-- faster. This is a load script: it runs once at startup, before the main menu, and changes the
-- game's records before the game uses them.

local records = require("openreliant.records")

-- Look up the Laser Cannon by name. records.guns[1] is the same gun, by number.
local laser = records.guns.laser_cannon
laser.damage.shield *= 1.25
laser.damage.hull *= 1.25

-- Missiles lock on 20% faster. Lock time is in hundredths of a second.
for _, missile in records.missiles do
    missile.lock_time = math.floor(missile.lock_time * 0.8)
end

-- The Predator's top speed goes up 10%.
records.ships.predator.max_speed *= 1.1

-- Rename the gun wherever the game shows its name.
for id, text in records.text do
    if text == "Laser Cannon" then
        records.text[id] = "Laser Cannon Mk II"
    end
end

return {
    engine_handlers = {
        -- Runs after every mod's load scripts, so this shows the final values.
        on_records_loaded = function()
            print(`the Laser Cannon hits shields for {laser.damage.shield} and hulls for {laser.damage.hull}`)
        end,
    },
}
