-- HUD layout: a display that stands in for the game's radar and draws a radar of its own in its
-- place, with the guns and missiles beside it, read from what the game's instruments show. Its
-- layout draws the targeting cluster larger and moves the clock to the radar's left.
--
-- A game's instrument that a display replaces isn't drawn while the display is on, but it keeps
-- working: RADAR RANGES still changes how far this radar reaches. Turning the mod off, or an error
-- in the display, brings the game's radar back where it was.

local hud = require("openreliant.hud")
local nearby = require("openreliant.nearby")
local util = require("openreliant.util")
local ship = require("openreliant.self")

-- The colours of the ships on the radar by their side, and the ring's.
local sides = {
    friendly = vector.create(0.3, 0.8, 1),
    hostile = vector.create(1, 0.25, 0.2),
    neutral = vector.create(1, 0.85, 0.3),
}
local ring = vector.create(0.3, 1, 0.4)
-- How many lines draw the ring, and the size of a ship on it, in the window's pixels.
local segments = 32
local blip = 2
-- The gap between the radar and the weapons' lines, in the window's pixels, and their spacing, in
-- lines of text.
local gap = 12
local spacing = 1.4

-- Draws the radar in `box`, where the game's radar draws, reaching `reach` from the player's ship.
local function drawRadar(box, reach)
    local center = vector.create((box.left + box.right) / 2, (box.top + box.bottom) / 2, 0)
    local radius = math.min(box.right - box.left, box.bottom - box.top) / 2
    local last = center + vector.create(radius, 0, 0)
    for step = 1, segments do
        local angle = step / segments * 2 * math.pi
        local point = center + vector.create(math.cos(angle), math.sin(angle), 0) * radius
        hud.line(last, point, { color = ring })
        last = point
    end
    hud.line(center, center - vector.create(0, radius, 0), { color = ring, alpha = 0.4 })
    -- Each ship within reach, seen from above: to the ship's right is right, and ahead is up.
    local size = vector.create(blip, blip, 0)
    for _, object in nearby.objects(reach) do
        if object.class then
            local seen = util.to_local(ship.position, ship.orientation, object.position)
            local at = center + vector.create(seen.x, -seen.z, 0) / reach * radius
            hud.rectangle(at - size, at + size, { color = sides[object.side] or ring })
        end
    end
end

-- Writes the guns' and the armed missile's state to the right of `box`.
local function drawWeapons(box)
    local at = vector.create(box.right + gap, box.top, 0)
    local line = vector.create(0, hud.measure("A").height * spacing, 0)
    local guns, missiles = hud.guns, hud.missiles
    if guns then
        local charge = if guns.full_charge > 0 then guns.charge / guns.full_charge else 0
        local mode = if guns.all then "ALL GUNS" else string.format("GROUP %d OF %d", guns.group + 1, guns.groups)
        hud.text(at, string.format("%s  %d%%", mode, math.floor(charge * 100)), { color = ring })
    end
    if missiles and missiles.armed then
        hud.text(at + line, string.format("%s  %d", string.upper(tostring(missiles.armed)), missiles.left), { color = ring })
    end
end

hud.register_display("radar", {
    replaces = { "radar" },
    layout = {
        gauges = { scale = 1.25 },
        clock = { offset = vector.create(-120, 70, 0) },
    },
    frame = function()
        -- Only where the game's instruments show: in the view ahead from the cockpit.
        if not hud.instruments_shown or not ship or not ship:is_valid() then return end
        -- The game's radar, though not drawn, still notes where it would draw.
        local box, radar = hud.bounds("radar"), hud.radar
        if not box or not radar then return end
        drawRadar(box, radar.reach)
        drawWeapons(box)
    end,
})
