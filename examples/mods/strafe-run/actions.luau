local input = require("openreliant.input")
local ui = require("openreliant.ui")
input.register_action("start", { label = "Start strafe run", key = "f12", modifier = "shift" })
input.register_action("camera", { label = "Strafe chase camera", key = "f10", modifier = "shift" })
input.register_action("help", { label = "Strafe help panel", key = "f9", modifier = "shift" })
local help = ui.register_screen("help", {
    frame = function()
        ui.rectangle(vector.create(20, 60, 0), vector.create(500, 160, 0), { alpha = 0.8 })
        ui.text(vector.create(30, 70, 0), "Shift F12: strafe run. Shift F10: chase camera.")
        ui.text(vector.create(30, 100, 0), "Escape closes this panel.")
    end,
    key = function(key, down) if key == "escape" and down then ui.show_screen(nil) end end,
})
return {
    engine_handlers = {
        on_action = function(action)
            if action == "strafe-run:help" then ui.show_screen(help) end
        end,
    },
}
