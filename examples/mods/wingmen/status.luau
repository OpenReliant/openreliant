-- A panel of the wingmen nearby, over the flight display: how much armour each has left, and
-- whether it has pulled out of the fight. F9 shows and hides the panel, and F11 calls
-- every wingman that pulled out back to the formation at once. This is a player script: it draws
-- what the player sees, and changes the game only through the event it sends the global script.

local hud = require("openreliant.hud")
local nearby = require("openreliant.nearby")
local core = require("openreliant.core")

-- How far from the player's ship the panel looks for wingmen.
local reach = 50000

-- The colours of a wingman's line: plenty of armour left, some, and little.
local healthy = vector.create(0.3, 1, 0.3)
local hurt = vector.create(1, 1, 0.3)
local failing = vector.create(1, 0.3, 0.3)

local shown = true

local function colourOf(hull)
    if hull > 0.6 then
        return healthy
    elseif hull > 0.3 then
        return hurt
    end
    return failing
end

return {
    engine_handlers = {
        on_key_press = function(key)
            if key == "f9" then
                shown = not shown
            elseif key == "f11" then
                core.send_global_event("WingmenRegroup", {})
            end
        end,
        on_frame = function()
            if not shown or not hud.shown then
                return
            end
            local right = hud.width - 16
            local line = hud.measure("W").height * 1.5
            local y = hud.height * 0.3
            hud.text(vector.create(right, y, 0), "WINGMEN", { align = "right" })
            local count = 0
            for _, ship in nearby.objects(reach) do
                if ship.class == "fighter" and ship.side == "friendly" then
                    count += 1
                    y += line
                    local hull = ship.hull or 1
                    local out = if ship.order == "run_away" then "  OUT" else ""
                    local text = string.format("%d  %d%%%s", count, math.floor(hull * 100 + 0.5), out)
                    hud.text(vector.create(right, y, 0), text, { colour = colourOf(hull), align = "right" })
                end
            end
        end,
    },
}
