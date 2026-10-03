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
