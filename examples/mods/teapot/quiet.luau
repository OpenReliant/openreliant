-- The simulator's long talk about the display (ms_hudtr_001.ut on), which mission 29 starts with,
-- is skipped in TEAPOT ARENA. This is a global script: it runs in every mode, so it checks the mode.
local core = require("openreliant.core")
local hooks = require("openreliant.hooks")

hooks.add("radio_say", function(e)
    if core.game_mode == "teapot:arena" and e.speech:find("ms_hudtr", 1, true) then
        return false
    end
end)
