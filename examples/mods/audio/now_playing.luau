-- Tells which piece of music plays: as a piece starts, a chime of the mod's own plays, and the
-- piece's name shows at the top of the menus and the rooms for a few seconds. This is a menu
-- script: it runs from the moment OpenReliant starts, and hears the music change everywhere.

local audio = require("openreliant.audio")
local ui = require("openreliant.ui")

-- How long the name shows, in seconds.
local shown_for = 4

local title = nil
local left = 0

return {
    engine_handlers = {
        -- `piece` is the piece's name as audio.play_music takes it, such as "New_Pensive.wav", or
        -- nil as the music stops.
        on_music_changed = function(piece)
            if not piece then
                return
            end
            title = string.upper((string.gsub(piece, "%.%w+$", "")))
            left = shown_for
            -- The mod's own file, at a third of the effects volume, a little to the right.
            audio.play_sound("chime.wav", { volume = 0.35, pan = 0.5 })
        end,
        on_frame = function(seconds)
            left = math.max(left - seconds, 0)
            if left == 0 or not ui.shown then
                return
            end
            ui.text(vector.create(ui.width / 2, 12, 0), "NOW PLAYING: " .. title, {
                align = "center",
                color = vector.create(0.6, 0.9, 1),
                alpha = math.min(left, 1),
            })
        end,
    },
}
