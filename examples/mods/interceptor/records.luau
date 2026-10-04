-- The Interceptor's records. This is a load script: it runs once at startup, and changes the records
-- before the game uses them. A ship type a mod adds starts with a copy of its base's record, and
-- scripts name it by its qualified name: the mod's folder name, a colon and the type's own name.

local records = require("openreliant.records")

local interceptor = records.ships["interceptor:interceptor"]
interceptor.max_speed *= 1.3
interceptor.shield_power *= 0.6
interceptor.armor_class *= 0.8
