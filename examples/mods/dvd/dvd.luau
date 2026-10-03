-- The letters DVD drift across the menus like an old DVD player's screensaver: they bounce off the
-- window's edges, and change colour at each bounce. This is a menu script: it runs from the moment
-- OpenReliant starts, and draws over the menus while they're shown.

local ui = require("openreliant.ui")

-- How fast the letters drift, in the window's pixels a second, and how many times the game's own
-- size they're drawn at.
local speed = 120
local scale = 4

-- The colours they take in turn.
local colours = {
    vector.create(1, 0.25, 0.25),
    vector.create(0.25, 1, 0.25),
    vector.create(0.3, 0.5, 1),
    vector.create(1, 1, 0.25),
    vector.create(1, 0.4, 1),
    vector.create(0.25, 1, 1),
}

local logo = "DVD"
local subtitle = "VIDEO"

-- Where the logo's top left corner is, which way it drifts, and its colour.
local corner = nil
local velocity = vector.create(speed, speed, 0)
local colour = 1

-- Moves the logo on by `seconds`, turning it back at the window's edges. Returns whether it bounced.
local function drift(seconds, width, height)
    corner += velocity * seconds
    local x, y = corner.x, corner.y
    local vx, vy = velocity.x, velocity.y
    local bounced = false
    if x < 0 or x + width > ui.width then
        x = math.clamp(x, 0, math.max(ui.width - width, 0))
        vx = -vx
        bounced = true
    end
    if y < 0 or y + height > ui.height then
        y = math.clamp(y, 0, math.max(ui.height - height, 0))
        vy = -vy
        bounced = true
    end
    corner = vector.create(x, y, 0)
    velocity = vector.create(vx, vy, 0)
    return bounced
end

return {
    engine_handlers = {
        on_frame = function(seconds)
            if not ui.shown then
                return
            end
            local big = ui.measure(logo, scale)
            local small = ui.measure(subtitle, scale / 2)
            local width = math.max(big.width, small.width)
            local height = big.height + small.height
            corner = corner or vector.create((ui.width - width) / 2, (ui.height - height) / 2, 0)
            if drift(seconds, width, height) then
                colour = colour % #colours + 1
            end
            local middle = corner.x + width / 2
            local tint = colours[colour]
            ui.text(vector.create(middle, corner.y, 0), logo, { colour = tint, scale = scale, align = "centre" })
            ui.text(vector.create(middle, corner.y + big.height, 0), subtitle, { colour = tint, scale = scale / 2, align = "centre" })
        end,
    },
}
