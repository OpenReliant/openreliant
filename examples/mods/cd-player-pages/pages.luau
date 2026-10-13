-- Pages for the CD player in the rooms, on both carriers: records.cd_player's tracks, twelve to a
-- page, the Reliant's list on page 1 and the Yamato's on page 2. This is a menu script: it runs
-- from the start, and draws only while the CD player is open (rooms.place). The front end's arrows,
-- drawn from its sprite set on the plate under the player's screen, turn the page, and so do Page
-- Up and Page Down. The CD player opens on its carrier's page, and a piece chosen plays on along
-- its own page, whichever page shows.

local records = require("openreliant.records")
local rooms = require("openreliant.rooms")
local ui = require("openreliant.ui")

-- How many pages the tracks fill.
local pages = #records.cd_player // 12

-- The front end's arrows' box, shape 0x2E of its sprite set, on the game's 640 by 480 screen, its
-- right edge level with the right edge of the CD player's screen. As on the settings screen, the
-- pointer finds its halves 12 by 23 from its corner and 17 to the right of it, and lights them with
-- shapes 0x2F and 0x30.
local sprites = { sprites = "frntend5.spr" }
local box = { shape = 0x2E, x = 511, y = 417 }
local halves = {
    { step = -1, shape = 0x2F, x = 511, y = 417 },
    { step = 1, shape = 0x30, x = 528, y = 417 },
}
local half_width, half_height = 12, 23

-- The page's number and the count, such as 1/2, in the list's blue, left of the arrows and level
-- with their middle.
local marker_right, marker_middle = 505, 430
local marker_style = { color = vector.create(0, 0x79 / 255, 0xFE / 255), align = "right" }

-- Whether the pointer's button was down at the last frame, so that a press turns one page.
local was_down = false

-- Turns the page by `step`, round from the last to the first.
local function turn(step)
    rooms.set_cd_player_page((rooms.cd_player_page - 1 + step) % pages + 1)
end

-- The half of the arrows at the window's pixel `at`, if any, its edges left out as the game's
-- hotspots leave them.
local function halfAt(at)
    local spot = ui.to_game_screen(at)
    local x, y = math.floor(spot.x), math.floor(spot.y)
    for _, half in halves do
        if half.x < x and x < half.x + half_width and half.y < y and y < half.y + half_height then
            return half
        end
    end
    return nil
end

-- Draws the arrows, the half under the pointer lit, and the page's number.
local function draw(over)
    ui.shape(ui.from_game_screen(vector.create(box.x, box.y, 0)), box.shape, sprites)
    if over then
        ui.shape(ui.from_game_screen(vector.create(over.x, over.y, 0)), over.shape, sprites)
    end
    local marker = string.format("%d/%d", rooms.cd_player_page, pages)
    local size = ui.measure(marker, marker_style)
    local at = ui.from_game_screen(vector.create(marker_right, marker_middle, 0))
    ui.text(vector.create(at.x, at.y - size.height / 2, 0), marker, marker_style)
end

return {
    engine_handlers = {
        -- As the CD player opens, it turns to its own page, so that its rows are numbered as the
        -- pages number them: 13 to 24 on the Yamato's.
        on_room_changed = function(view, place)
            if place == "cd_player" then
                rooms.set_cd_player_page(rooms.cd_player_page)
            end
        end,
        on_frame = function()
            local pointer = ui.pointer
            local down = pointer ~= nil and pointer.down
            local pressed = down and not was_down
            was_down = down
            if rooms.place ~= "cd_player" then
                return
            end
            local over = pointer and halfAt(pointer.at)
            if pressed and over then
                turn(over.step)
            end
            draw(over)
        end,
        on_key_press = function(key)
            if rooms.place ~= "cd_player" then
                return
            end
            if key == "page_up" then
                turn(-1)
            elseif key == "page_down" then
                turn(1)
            end
        end,
    },
}
