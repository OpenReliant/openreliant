-- 3D sounds and music controls. In flight, Shift F4 drops a beacon that pings once a second at the
-- ship's position, until Shift F4 is pressed again. It plays at full volume within 40,000 units and
-- fades out to silence at 400,000. At full throttle a Predator covers 8,000 units a second, so
-- that's 5 and 50 seconds of flight. Shift F3 plays a ping at the player's target, following it.
-- Anywhere, Shift F2 fades out the music, or starts the main menu's piece if no music plays. This
-- is a player script: it runs for the whole game.

local audio = require("openreliant.audio")
local hud = require("openreliant.hud")
local input = require("openreliant.input")
local ship = require("openreliant.self")

-- The ID of the beacon's sound from play_sound; nil if there's no beacon.
local beacon = nil

local function shifted()
    return input.key_down("left_shift") or input.key_down("right_shift")
end

return {
    engine_handlers = {
        on_key_press = function(key)
            if not shifted() then
                return
            end
            if key == "f2" then
                if audio.music then
                    audio.fade_music()
                else
                    audio.play_music("New_Pensive.wav", { after_fade = true })
                end
            elseif not hud.shown then
                -- 3D sounds only play in flight.
                return
            elseif key == "f4" then
                -- A looping sound plays until it's stopped or the mission ends.
                if audio.sound_playing(beacon) then
                    audio.stop_sound(beacon)
                    beacon = nil
                else
                    beacon = audio.play_sound("beacon.wav", {
                        at = ship.position,
                        loop = true,
                        near = 40000,
                        far = 400000,
                    })
                end
            elseif key == "f3" then
                local target = hud.target and hud.target.object
                if target then
                    -- The chime an octave higher, with the default distances.
                    audio.play_sound("chime.wav", { object = target, pitch = 2 })
                end
            end
        end,
    },
}
