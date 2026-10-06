-- A load script: it runs once at startup and renames Moose to Trent. The radio's window shows a
-- pilot's name from the game's text, so changing the text renames him wherever the game shows it.

local records = require("openreliant.records")

for id, text in records.text do
    if text == "Moose" then
        records.text[id] = "Trent"
    end
end
