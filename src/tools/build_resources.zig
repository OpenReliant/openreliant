//! `build-resources <program> <script>`: writes the resource script of `openreliant.exe` or
//! `sltool.exe`, which holds the version information Windows shows in the file's properties and in
//! the Task Manager, with the version `src/version.zig` gives. The build compiles the script with
//! the rc package, together with the manifest, `src/windows.manifest`, and links both into the
//! program (`build.zig`). The script holds no build time, so the builds stay reproducible
//! ([Builds and releases](../../docs/port/platform.md#builds-and-releases)).

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const version = @import("version");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const program = (if (args.len == 3) std.meta.stringToEnum(Program, args[1]) else null) orelse {
        std.debug.print("usage: build-resources <openreliant|sltool> <script>\n", .{});
        return 2;
    };
    const text = switch (program) {
        inline else => |known| script(known),
    };
    try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = text });
    return 0;
}

/// The programs that carry version information, by the names of their files.
const Program = enum {
    openreliant,
    sltool,

    /// What Windows shows as the program's name, such as in the Task Manager.
    fn description(program: Program) []const u8 {
        return switch (program) {
            .openreliant => "OpenReliant",
            .sltool => "OpenReliant sltool",
        };
    }
};

const product = "OpenReliant";
/// Who makes it, as the README's copyright line names them.
const company = "OpenReliant contributors";
/// The README's copyright line.
const copyright = "Copyright 2026 the OpenReliant contributors";

/// The release's three numbers, which the version information keeps in 16 bits each, so a larger
/// one fails the build.
const numbers: [3]u16 = .{ version.semantic.major, version.semantic.minor, version.semantic.patch };

/// The ID of the version information (`VS_VERSION_INFO`).
const version_information_id = 1;
/// The flags the version information can set (`VS_FFI_FILEFLAGSMASK`). It sets none.
const valid_flags = 0x3F;
/// That the file runs on Windows NT, 32-bit or 64-bit (`VOS_NT_WINDOWS32`).
const windows_nt = 0x40004;
/// That the file is an application (`VFT_APP`).
const application = 0x1;
/// The language of the strings, U.S. English.
const us_english = 0x409;
/// The code page of the strings, UTF-16. With the language, it names the strings' block.
const utf16 = 1200;
/// The code page of the script, UTF-8.
const utf8 = 65001;

/// The resource script of `program`: its version information, `VERSIONINFO`. Its file version is
/// the release's numbers and a 0, and its strings give the whole version.
fn script(comptime program: Program) []const u8 {
    return comptime std.fmt.comptimePrint(
        \\// The version information of {[name]s}.exe, written by build-resources.
        \\#pragma code_page({[utf8]d})
        \\
        \\{[id]d} VERSIONINFO
        \\FILEVERSION {[major]d},{[minor]d},{[patch]d},0
        \\PRODUCTVERSION {[major]d},{[minor]d},{[patch]d},0
        \\FILEFLAGSMASK 0x{[valid_flags]x}
        \\FILEFLAGS 0x0
        \\FILEOS 0x{[os]x}
        \\FILETYPE 0x{[file_type]x}
        \\FILESUBTYPE 0x0
        \\BEGIN
        \\    BLOCK "StringFileInfo"
        \\    BEGIN
        \\        BLOCK "{[language]x:0>4}{[code_page]x:0>4}"
        \\        BEGIN
        \\            VALUE "CompanyName", "{[company]s}"
        \\            VALUE "FileDescription", "{[description]s}"
        \\            VALUE "FileVersion", "{[version]s}"
        \\            VALUE "InternalName", "{[name]s}"
        \\            VALUE "LegalCopyright", "{[copyright]s}"
        \\            VALUE "OriginalFilename", "{[name]s}.exe"
        \\            VALUE "ProductName", "{[product]s}"
        \\            VALUE "ProductVersion", "{[version]s}"
        \\        END
        \\    END
        \\    BLOCK "VarFileInfo"
        \\    BEGIN
        \\        VALUE "Translation", 0x{[language]x}, {[code_page]d}
        \\    END
        \\END
        \\
    , .{
        .utf8 = utf8,
        .id = version_information_id,
        .major = numbers[0],
        .minor = numbers[1],
        .patch = numbers[2],
        .valid_flags = valid_flags,
        .os = windows_nt,
        .file_type = application,
        .language = us_english,
        .code_page = utf16,
        .company = company,
        .description = program.description(),
        .version = version.string,
        .name = @tagName(program),
        .copyright = copyright,
        .product = product,
    });
}

// The strings go into the script as they are, so none can hold a quote or a backslash, which
// would end the string or start an escape.
comptime {
    for ([_][]const u8{ product, company, copyright, version.string }) |text| assert(std.mem.indexOfAny(u8, text, "\"\\") == null);
    for (std.enums.values(Program)) |program| assert(std.mem.indexOfAny(u8, program.description(), "\"\\") == null);
}

test script {
    const text = script(.sltool);
    for ([_][]const u8{
        std.fmt.comptimePrint("\nFILEVERSION {d},{d},{d},0\n", .{ numbers[0], numbers[1], numbers[2] }),
        "\n        BLOCK \"040904b0\"\n",
        "\n            VALUE \"FileDescription\", \"OpenReliant sltool\"\n",
        "\n            VALUE \"InternalName\", \"sltool\"\n",
        "\n            VALUE \"OriginalFilename\", \"sltool.exe\"\n",
        "\n            VALUE \"ProductVersion\", \"" ++ version.string ++ "\"\n",
        "\n        VALUE \"Translation\", 0x409, 1200\n",
    }) |line| try std.testing.expect(std.mem.indexOf(u8, text, line) != null);
}
