-- Gives OpenReliant Theme a track of the CD player in the rooms. The Rise, the Yamato's last track,
-- plays Spirit of War's piece again in the game. Here it plays the main menu's piece instead, which
-- this mod replaces, under the theme's own name.
local records = require("openreliant.records")

records.cd_player[24] = { piece = "New_Pensive", name = "OpenReliant Theme" }
