-- Kill tally's board over the flight display: the enemies destroyed in this game and the most of
-- any game, which the global script counts (tally.luau), and the missions flown in this game. A
-- message shows for a few seconds after each kill.
--
-- The missions are the script's own count. It goes with each saved game through on_save and
-- on_load, and back to where it was when the player restarts a mission. The message is hidden by a
-- timer, which is kept with the saved game too.

local hud = require("openreliant.hud")
local storage = require("openreliant.storage")
local async = require("openreliant.async")

local game = storage.game_section("tally")
local best = storage.global_section("best")

-- How long the message shows after a kill, in seconds, its size, and the board's colour.
local message_seconds = 3
local message_scale = 1.5
local colour = vector.create(1, 0.8, 0.3)

local missions = 0
-- The kills the board has seen, so that it knows when there's a new one.
local seen = 0
local message = nil

-- Timers name the function they run, so that one kept with a saved game finds it after a load.
async.register_timer("hide_message", function(data)
    -- A later kill's message stays until its own timer.
    if data.kills == seen then
        message = nil
    end
end)

return {
    engine_handlers = {
        on_init = function()
            seen = game.kills or 0
        end,
        on_save = function()
            return { missions = missions }
        end,
        on_load = function(saved)
            missions = saved and saved.missions or 0
            seen = game.kills or 0
        end,
        on_mission_start = function()
            missions += 1
        end,
        on_frame = function()
            local kills = game.kills or 0
            if kills > seen then
                seen = kills
                message = "KILL " .. kills
                async.after(message_seconds, "hide_message", { kills = kills })
            end
            if not hud.shown then
                return
            end
            local middle = hud.width / 2
            local y = hud.height * 0.12
            local board = string.format("KILLS %d IN %d MISSIONS    BEST GAME %d", kills, missions, best.kills or 0)
            hud.text(vector.create(middle, y, 0), board, { colour = colour, align = "centre" })
            if message then
                y += hud.measure(board).height * 2
                hud.text(vector.create(middle, y, 0), message, { colour = colour, align = "centre", scale = message_scale })
            end
        end,
    },
}
