//! `C:\lancer\game`: the game's own source files, a module for each that this project describes.
//! [`sources.zig`](sources.zig) places their code.

const std = @import("std");

pub const ai = @import("game/ai.zig");
pub const aidefend = @import("game/aidefend.zig");
pub const aidock = @import("game/aidock.zig");
pub const airipper = @import("game/airipper.zig");
pub const aieject = @import("game/aieject.zig");
pub const aiexplode = @import("game/aiexplode.zig");
pub const aifight = @import("game/aifight.zig");
pub const aigeneric = @import("game/aigeneric.zig");
pub const ailand = @import("game/ailand.zig");
pub const aiorders = @import("game/aiorders.zig");
pub const backdrop = @import("game/backdrop.zig");
pub const bigfile = @import("game/bigfile.zig");
pub const camera = @import("game/camera.zig");
pub const cbox = @import("game/cbox.zig");
pub const cloak = @import("game/cloak.zig");
pub const collision = @import("game/collision.zig");
pub const create = @import("game/create.zig");
pub const deathmatch = @import("game/deathmatch.zig");
pub const dmscenarios = @import("game/dmscenarios.zig");
pub const environfx = @import("game/environfx.zig");
pub const erayfx = @import("game/erayfx.zig");
pub const explode = @import("game/explode.zig");
pub const hud = @import("game/hud.zig");
pub const hudmovie = @import("game/hudmovie.zig");
pub const hudoptions = @import("game/hudoptions.zig");
pub const executor = @import("game/executor.zig");
pub const friendly_fire = @import("game/friendly_fire.zig");
pub const gameflow = @import("game/gameflow.zig");
pub const gameobj = @import("game/gameobj.zig");
pub const guns = @import("game/guns.zig");
pub const hog_snd = @import("game/hog_snd.zig");
pub const sound3d = @import("game/sound3d.zig");
pub const iff = @import("game/iff.zig");
pub const interface = @import("game/interface.zig");
pub const itac = @import("game/itac.zig");
pub const jump = @import("game/jump.zig");
pub const language = @import("game/language.zig");
pub const launch = @import("game/launch.zig");
pub const main = @import("game/main.zig");
pub const matmanager = @import("game/matmanager.zig");
pub const missiles = @import("game/missiles.zig");
pub const mission = @import("game/mission.zig");
pub const motion = @import("game/motion.zig");
pub const nebula = @import("game/nebula.zig");
pub const objects = @import("game/objects.zig");
pub const particles = @import("game/particles.zig");
pub const pilots = @import("game/pilots.zig");
pub const shield = @import("game/shield.zig");
pub const shieldfx = @import("game/shieldfx.zig");
pub const shockwave = @import("game/shockwave.zig");
pub const sparks = @import("game/sparks.zig");
pub const srofiles = @import("game/srofiles.zig");
pub const table = @import("game/table.zig");
pub const talkie = @import("game/talkie.zig");
pub const tractor = @import("game/tractor.zig");
pub const voice = @import("game/voice.zig");
pub const videoreports = @import("game/videoreports.zig");
pub const wgate = @import("game/wgate.zig");
pub const winmain = @import("game/winmain.zig");
pub const xtrabits = @import("game/xtrabits.zig");

test {
    std.testing.refAllDecls(@This());
}
