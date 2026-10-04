-- A main menu of the mod's own, which stands in for the game's (ui.replace_screen). This is a menu
-- script: it runs in the front end, and draws the screen while the front end shows the main menu,
-- over the main menu's picture, with the pointer over it. Each item asks the front end to go on:
-- to another of its screens, or out of the game.

local ui = require("openreliant.ui")

local items = {
    { label = "CAMPAIGN", screen = "pilot_roster" },
    { label = "GAME MODES", screen = "game_modes" },
    { label = "OPTIONS", screen = "game_options" },
    { label = "QUIT" },
}

-- The items' size and spacing, as shares of the window's height, and their colours.
local item_scale = 2
local first_share = 0.45
local spacing_share = 0.08
local plain = vector.create(0.4, 0.7, 1)
local lit = vector.create(1, 0.8, 0.3)

-- The item the keys have chosen, and whether the pointer's button was down at the last frame, so
-- that a press chooses once.
local chosen = 1
local was_down = false

local function choose(item)
    if item.screen then
        ui.go_to(item.screen)
    else
        ui.quit()
    end
end

-- The item under the pointer, if any: each item takes a band of the window's height.
local function itemAt(y)
    local spacing = ui.height * spacing_share
    local first = ui.height * first_share - spacing / 2
    local at = math.floor((y - first) / spacing) + 1
    return items[at] and at or nil
end

local screen = ui.register_screen("main_menu", {
    frame = function()
        local pointer = ui.pointer
        local under = pointer and itemAt(pointer.at.y)
        if under then
            chosen = under
        end
        if pointer and pointer.down and not was_down and under then
            choose(items[under])
        end
        was_down = pointer ~= nil and pointer.down
        for at, item in items do
            local y = ui.height * (first_share + (at - 1) * spacing_share)
            ui.text(vector.create(ui.width / 2, y, 0), item.label, { colour = at == chosen and lit or plain, align = "centre", scale = item_scale })
        end
    end,
    key = function(key, down)
        if not down then
            return
        end
        if key == "up" then
            chosen = (chosen - 2) % #items + 1
        elseif key == "down" then
            chosen = chosen % #items + 1
        elseif key == "enter" then
            choose(items[chosen])
        end
    end,
})

ui.replace_screen("main_menu", screen)
