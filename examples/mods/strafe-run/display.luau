local I = require("openreliant.interfaces")
local core = require("openreliant.core")
local active = false
local view = I.Camera.register_view("chase", {
    frame = function(ship)
        return {
            position = I.Flight.to_world(ship.position, ship.orientation, vector.create(0, -200, -1000)),
            orientation = ship.orientation,
        }
    end,
})
I.HUD.register_display("status", {
    frame = function()
        I.HUD.text(vector.create(20, 30, 0), active and "Strafe run requested" or "Shift F12: strafe run")
    end,
})
return {
    engine_handlers = {
        on_action = function(action)
            if action == "strafe-run:start" then
                active = true
                core.send_global_event("StrafeRunStart", {})
            elseif action == "strafe-run:camera" then
                I.Camera.set_view(I.Camera.view == view and "cockpit" or view)
            end
        end,
        on_mission_end = function() active = false end,
    },
}
