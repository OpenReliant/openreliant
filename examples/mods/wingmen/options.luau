-- The page of options the Wingmen mod offers on the mods screen (GAME OPTIONS, then MODS, then
-- OPTIONS). This is a load script: it declares the page as OpenReliant starts, and the mod's other
-- scripts read the values with settings.get.

local settings = require("openreliant.settings")

settings.register_page({
    title = "WINGMEN",
    options = {
        {
            key = "pull_out_below",
            label = "PULL OUT BELOW",
            kind = "choice",
            default = 0.3,
            choices = {
                { value = 0.2, label = "20%" },
                { value = 0.3, label = "30%" },
                { value = 0.4, label = "40%" },
            },
            description = "A wingman with less armour than this pulls out of the fight.",
        },
        {
            key = "rejoin_after",
            label = "REJOIN AFTER",
            kind = "number",
            min = 5,
            max = 60,
            step = 5,
            default = 20,
            description = "The seconds a wingman stays out of the fight before it rejoins you.",
        },
        {
            key = "show_panel",
            label = "SHOW PANEL",
            kind = "toggle",
            default = true,
            description = "Shows the panel of the wingmen nearby when a game starts. F9 shows and hides it in flight.",
        },
    },
})
