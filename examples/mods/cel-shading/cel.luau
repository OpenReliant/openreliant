-- Registers the cel-shading mod's functions: a lighting function that makes each light fall in flat
-- bands (bands.glsl), and a surface function on every lit surface that draws a dark line round its
-- outline (ink.glsl). Shift F6 turns both on and off, and Shift F5 steps through two, three and
-- four bands. This is a player script: it runs for the whole game.

local shaders = require("openreliant.shaders")
local input = require("openreliant.input")

local band_counts = { 2, 3, 4 }
local band_count = 2
-- How wide the outline is in pixels, and how many levels each colour keeps.
local outline = 3
local colour_levels = 8

local shown = true

shaders.register_lighting({
    name = "bands",
    shader = "bands.glsl",
    parameters = { band_counts[band_count] },
})

shaders.register_surface({
    name = "ink",
    shader = "ink.glsl",
    everywhere = true,
    parameters = { outline, colour_levels },
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
            if key == "f6" then
                shown = not shown
                shaders.set_enabled("bands", shown)
                shaders.set_enabled("ink", shown)
            elseif key == "f5" then
                band_count = band_count % #band_counts + 1
                shaders.set_parameters("bands", { band_counts[band_count] })
            end
        end,
    },
}
