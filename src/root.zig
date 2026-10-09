//! The `openreliant` module: readers for the game's file formats, and the reimplementation of the
//! game's code, shared by the engine and every tool in this repository.

/// Reading fixed layouts in place, which the readers below share.
pub const layout = @import("formats/layout.zig");
/// Checking the names of files that discs and archives hold, before a tool writes them.
pub const paths = @import("formats/paths.zig");

/// Containers the game shipped in, rather than formats the game itself reads.
pub const cdimage = @import("formats/cdimage.zig");
pub const iso9660 = @import("formats/iso9660.zig");

/// The game's files.
pub const bink = @import("formats/bink.zig");
pub const dte = @import("formats/dte.zig");
pub const fat = @import("formats/fat.zig");
pub const fnt = @import("formats/fnt.zig");
pub const frc = @import("formats/frc.zig");
pub const hog = @import("formats/hog.zig");
pub const mp3 = @import("formats/mp3.zig");
pub const refpack = @import("formats/refpack.zig");
pub const riff = @import("formats/riff.zig");
pub const scramble = @import("formats/scramble.zig");
pub const shp = @import("formats/shp.zig");
pub const spr = @import("formats/spr.zig");
pub const stats = @import("formats/stats.zig");
pub const tcache = @import("formats/tcache.zig");
pub const tga = @import("formats/tga.zig");
pub const wave = @import("formats/wave.zig");

/// Windows executables: the game binary and its libraries.
pub const pe = @import("formats/pe.zig");

/// Images: the ones the tools write, and the pictures in mods, some compressed for the GPU.
pub const png = @import("formats/png.zig");
pub const dds = @import("formats/dds.zig");
pub const ktx2 = @import("formats/ktx2.zig");
pub const texels = @import("formats/texels.zig");

/// Models from modelling tools, which `sltool shp from-obj` and `from-gltf` build the game's
/// models from.
pub const obj = @import("formats/obj.zig");
pub const gltf = @import("formats/gltf.zig");

/// Checksum files, used to check mod archives.
pub const checksums = @import("formats/checksums.zig");

/// The Dreamcast version of StarLancer.
pub const dreamcast = @import("formats/dreamcast.zig");

/// Other games on StarLancer's engine, and the formats of the consoles they run on.
pub const games = @import("formats/games.zig");
pub const playstation = @import("formats/playstation.zig");
pub const xbox = @import("formats/xbox.zig");

/// The payload, the game executable: its structures and tables, laid out as its source tree.
pub const engine = @import("engine.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
