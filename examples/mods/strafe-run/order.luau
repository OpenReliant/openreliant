-- The strafe run: a custom AI order, registered through the built-in interface I.AI. The ship
-- flies at half throttle and turns gently right for three seconds. This is a global script: it
-- gives the order to the first fighter other than the player when the player script sends
-- StrafeRunStart.

local I = require("openreliant.interfaces")
local world = require("openreliant.world")
local elapsed = {}
local order = I.AI.register("strafe_run", {
    flags = { avoidance = true },
    init = function(ship) elapsed[ship] = 0 end,
    update = function(ship, target, seconds)
        elapsed[ship] += seconds
        ship.throttle = 0.5
        ship.yaw_input = 0.25
        return elapsed[ship] < 3
    end,
    exit = function(ship)
        elapsed[ship] = nil
        ship.yaw_input = 0
    end,
})

return {
    event_handlers = {
        StrafeRunStart = function()
            for _, ship in world.objects() do
                if not ship.is_player and ship.class == "fighter" then
                    ship:give_order(order)
                    break
                end
            end
        end,
    },
}
