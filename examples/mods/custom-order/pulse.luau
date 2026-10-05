-- A custom AI order: a short pulse of throttle, which ends by itself after two seconds. This is a
-- global script: it registers the order, gives it to the first fighter other than the player as
-- each mission starts, and again whenever the menu script's action sends CustomOrderPulse.

local orders = require("openreliant.orders")
local world = require("openreliant.world")
local elapsed = {}

local pulse = orders.register("pulse", {
    flags = { avoidance = true },
    init = function(ship)
        elapsed[ship] = 0
    end,
    update = function(ship, target, seconds)
        elapsed[ship] += seconds
        ship.throttle = 0.25
        return elapsed[ship] < 2
    end,
    exit = function(ship)
        elapsed[ship] = nil
        ship.throttle = 0
    end,
})

local function startPulse()
    for _, ship in world.objects() do
        if not ship.is_player and ship.class == "fighter" then
            ship:give_order(pulse)
            break
        end
    end
end

return {
    engine_handlers = { on_mission_start = startPulse },
    event_handlers = {
        CustomOrderPulse = startPulse,
    },
}
