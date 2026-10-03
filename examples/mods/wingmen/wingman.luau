-- A wingman that's badly damaged pulls out of the fight once: it runs from whoever hit it last, and
-- tells the global scripts. This is an object script: it runs on each fighter, with its own
-- variables, and changes only its own ship.

local self = require("openreliant.self")
local core = require("openreliant.core")

-- The share of its armour left below which a wingman pulls out.
local pull_out_below = 0.3

-- Whether this wingman has pulled out already. Each fighter's script has its own.
local pulled_out = false

return {
    engine_handlers = {
        on_update = function()
            -- Only the player's wingmen.
            if pulled_out or self.is_player or self.side ~= "friendly" then
                return
            end
            local hull = self.hull
            local attacker = self.last_attacker
            if hull and hull < pull_out_below and attacker and self:give_order("run_away", attacker) then
                pulled_out = true
                core.send_global_event("WingmanPulledOut", { ship = self })
            end
        end,
    },
}
