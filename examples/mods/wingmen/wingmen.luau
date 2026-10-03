-- Keeps track of the wingmen that pull out of the fight (wingman.luau), and sends each back to the
-- player's formation a little later, or at once when the player asks (status.luau). Other mods can
-- ask how many have pulled out through the Wingmen interface. This is a global script: it runs for
-- the whole game.

local world = require("openreliant.world")

-- How long a wingman stays out of the fight before it rejoins the player, in seconds of game time.
local rejoin_after = 20

local pulled_out = 0
-- The wingmen out of the fight, with the seconds left until each rejoins.
local resting = {}

-- Sends `ship` back to the player's formation.
local function rejoin(ship)
    resting[ship] = nil
    if ship:is_valid() then
        ship:give_order("formation", world.player)
        print(tostring(ship) .. " rejoins the formation")
    end
end

return {
    interface_name = "Wingmen",
    interface = {
        -- How many times a wingman has pulled out in this game.
        pulled_out = function()
            return pulled_out
        end,
    },
    engine_handlers = {
        on_update = function(seconds)
            for ship, left in resting do
                left -= seconds
                if not ship:is_valid() then
                    resting[ship] = nil
                elseif left > 0 then
                    resting[ship] = left
                else
                    rejoin(ship)
                end
            end
        end,
        on_mission_end = function()
            resting = {}
        end,
    },
    event_handlers = {
        WingmanPulledOut = function(data)
            pulled_out += 1
            resting[data.ship] = rejoin_after
            print(tostring(data.ship) .. " pulls out of the fight")
        end,
        -- The player calls them all back (status.luau).
        WingmenRegroup = function()
            for ship in resting do
                rejoin(ship)
            end
        end,
    },
}
