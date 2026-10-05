-- The records of what the mod adds. This is a load script: it runs once at startup, and changes the
-- records before the game uses them. Each starts with a copy of its base's record, and scripts name
-- it by the mod's folder name, a colon and its own name.

local records = require("openreliant.records")

-- The Banana Gun's shots fly faster and hit harder than the Pulse Cannon's.
local gun = records.guns["bananas:banana_gun"]
gun.speed *= 1.5
gun.damage.shield *= 1.5
gun.damage.hull *= 1.5

-- A Banana locks on in half the time of a Bandit.
local missile = records.missiles["bananas:banana"]
missile.lock_time = math.floor(missile.lock_time / 2)

-- The Trooper fires whenever the target is anywhere near the nose, and flies like a beginner.
local trooper = records.pilots["bananas:trooper"]
trooper.tier_b = "level_0"
trooper.skill = "low"
