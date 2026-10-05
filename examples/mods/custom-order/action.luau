-- Shift F12, an action the player can rebind on the controls screen, asks the global script to
-- start the pulse. This is a menu script: actions are registered from menu scripts, and a menu
-- script changes the game only through the events it sends.

local input = require("openreliant.input")
local core = require("openreliant.core")
local pulse = input.register_action("pulse", {
    label = "Custom order: throttle pulse",
    key = "f12",
    modifier = "shift",
})

return {
    engine_handlers = {
        on_action = function(action)
            if action == pulse then
                core.send_global_event("CustomOrderPulse", {})
            end
        end,
    },
}
