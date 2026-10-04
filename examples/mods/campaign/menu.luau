-- A short campaign of the game's first three missions, with a briefing screen of the mod's own. This
-- is a menu script: it runs as OpenReliant starts, when game modes are registered, and in the front
-- end, where it draws the briefing before each mission.
--
-- A campaign flies its missions in order. A lost mission is flown again, and the mission the player
-- reached is kept in the mod's storage (the section "campaigns"), so GAME MODES carries on from it.
-- A campaign of new missions lists their numbers the same way: each is a standard .DTE file in the
-- mod's folder.

local core = require("openreliant.core")
local ui = require("openreliant.ui")

-- What the briefing says before each mission, by its place in the campaign.
local briefings = {
    { title = "PATROL", lines = { "Fly the patrol route with your wing.", "Stay with Alpha flight and report contacts." } },
    { title = "ESCORT", lines = { "Escort the convoy to the jump point.", "Keep the transports alive." } },
    { title = "STRIKE", lines = { "Take the fight to the enemy.", "Destroy every target your briefing names." } },
}

-- The movie played before the campaign's first briefing: one of the game's, in its folder.
local opening_movie = "thread01.bik"

-- The items' size and spacing, as shares of the window's height, and their colours.
local title_share = 0.2
local lines_share = 0.4
local line_spacing_share = 0.05
local items_share = 0.7
local item_spacing_share = 0.08
local plain = vector.create(0.4, 0.7, 1)
local lit = vector.create(1, 0.8, 0.3)

local items = {
    { label = "LAUNCH", go = ui.launch_mission },
    { label = "MAIN MENU", go = function()
        ui.go_to("main_menu")
    end },
}

-- The item the keys have chosen, whether the pointer's button was down at the last frame, so that a
-- press chooses once, and the mission the briefing was last shown for.
local chosen = 1
local was_down = false
local briefed = nil

-- The item under the pointer, if any: each item takes a band of the window's height.
local function itemAt(y)
    local spacing = ui.height * item_spacing_share
    local first = ui.height * items_share - spacing / 2
    local at = math.floor((y - first) / spacing) + 1
    return items[at] and at or nil
end

local function centred(share, text, colour, scale)
    ui.text(vector.create(ui.width / 2, ui.height * share, 0), text, { colour = colour, align = "centre", scale = scale })
end

ui.register_screen("briefing", {
    frame = function()
        local mission = core.game_mode_mission
        if not mission then
            return
        end
        -- The first time the briefing shows for a mission: the keys' choice back on LAUNCH, and
        -- before the campaign's first mission, its opening movie.
        if briefed ~= mission.number then
            briefed = mission.number
            chosen = 1
            if mission.place == 1 then
                ui.play_movie(opening_movie)
            end
        end
        local briefing = briefings[mission.place]
        centred(title_share, `MISSION {mission.place} OF {mission.count}: {briefing.title}`, lit, 2)
        for at, line in briefing.lines do
            centred(lines_share + (at - 1) * line_spacing_share, line, plain, 1)
        end
        local pointer = ui.pointer
        local under = pointer and itemAt(pointer.at.y)
        if under then
            chosen = under
        end
        if pointer and pointer.down and not was_down and under then
            items[under].go()
        end
        was_down = pointer ~= nil and pointer.down
        for at, item in items do
            centred(items_share + (at - 1) * item_spacing_share, item.label, at == chosen and lit or plain, 2)
        end
    end,
    key = function(key, down)
        if not down then
            return
        end
        if key == "up" or key == "down" then
            chosen = chosen % #items + 1
        elseif key == "enter" then
            items[chosen].go()
        elseif key == "escape" then
            ui.go_to("main_menu")
        end
    end,
})

core.register_game_mode({
    name = "first_tour",
    label = "FIRST TOUR",
    description = "The game's first three missions as a short campaign, each after a briefing of the mod's own. A lost mission is flown again.",
    missions = { 1, 2, 3 },
    campaign = true,
    briefing = "briefing",
})
