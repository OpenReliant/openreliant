-- Sounds in 3D, and the music. In flight, Shift F4 drops a beacon that pings once a second from
-- where the player's ship was, until Shift F4 picks it up again: it's heard at its full volume
-- within 40,000 units, more quietly farther off, and not at all past 400,000. A Predator at full
-- throttle covers 8,000 units a second, so that's five seconds of flight and fifty. Shift F3 has
-- the player's target ping, from the target as it flies. Anywhere, Shift F2 fades the music out,
-- or brings the main menu's piece in where none plays. This is a player script: it runs for the
-- whole game.

local audio = require("openreliant.audio")
local hud = require("openreliant.hud")
local input = require("openreliant.input")
local ship = require("openreliant.self")

-- The beacon's sound, by the number play_sound gave it; nil for none.
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
                -- The sounds in 3D play in flight alone.
                return
            elseif key == "f4" then
                -- A sound that loops plays until it's stopped, or its mission ends.
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
                    -- The chime an octave up, at the guns' shots' distances.
                    audio.play_sound("chime.wav", { object = target, pitch = 2 })
                end
            end
        end,
    },
}
