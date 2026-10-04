-- Registers the CRT post effect (crt.frag), drawn after the flight display so that the display
-- curves with the scene. Shift F8 turns it on and off, and Shift F7 steps the scanlines through
-- three strengths. This is a player script: it runs for the whole game.

local postprocessing = require("openreliant.postprocessing")
local input = require("openreliant.input")

-- How dark the scanlines are, how far the glass bulges, and how dark the corners are. The shader
-- reads them as frame.parameters.
local strengths = { 0.15, 0.3, 0.5 }
local strength = 2
local bulge = 0.08
local corners = 0.6

local shown = true

local function parameters()
    return { strengths[strength], bulge, corners }
end

postprocessing.register({
    name = "crt",
    shader = "crt.frag",
    stage = "after_hud",
    parameters = parameters(),
})

local function shifted()
    return input.key_down("left_shift") or input.key_down("right_shift")
end

return {
    engine_handlers = {
        on_key_press = function(key)
            if not shifted() then
                return
            end
            if key == "f8" then
                shown = not shown
                postprocessing.set_enabled("crt", shown)
            elseif key == "f7" then
                strength = strength % #strengths + 1
                postprocessing.set_parameters("crt", parameters())
            end
        end,
    },
}
