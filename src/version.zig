//! The version `openreliant` and `sltool` report: the release Release Please keeps in
//! `build.zig.zon`, and for a build past it, how many commits past and which, from `git describe`
//! (`build.zig`).

const std = @import("std");
const build_options = @import("build_options");

/// Such as `0.2.0` at a release, and `0.2.0+12.gabc1234` twelve commits after it, with `.dirty`
/// where the checkout has changes.
pub const string = named(build_options.version, build_options.describe);

/// `string` as a semantic version, to compare with the version a mod needs (`Mods.open`).
pub const semantic: std.SemanticVersion = std.SemanticVersion.parse(string) catch
    @compileError("the version " ++ string ++ " is no semantic version");

/// `release`, with where `describe` says the checkout is past it as SemVer build metadata. What
/// isn't `git describe --long --dirty`'s leaves `release` as it is.
fn named(comptime release: []const u8, comptime describe: []const u8) []const u8 {
    const past = Past.parse(describe) orelse return release;
    if (std.mem.eql(u8, past.commits, "0") and !past.dirty) return release;
    return release ++ "+" ++ past.commits ++ "." ++ past.commit ++ if (past.dirty) ".dirty" else "";
}

/// Where `git describe --long --dirty` says the checkout is: how many commits past the tag, the
/// commit with its `g`, and whether it has changes.
const Past = struct {
    commits: []const u8,
    commit: []const u8,
    dirty: bool,

    fn parse(describe: []const u8) ?Past {
        const clean = std.mem.cutSuffix(u8, describe, "-dirty");
        const tag_commits, const commit = std.mem.cutScalarLast(u8, clean orelse describe, '-') orelse return null;
        _, const commits = std.mem.cutScalarLast(u8, tag_commits, '-') orelse return null;
        if (commits.len == 0 or commit.len < 2 or commit[0] != 'g') return null;
        for (commits) |digit| if (!std.ascii.isDigit(digit)) return null;
        return .{ .commits = commits, .commit = commit, .dirty = clean != null };
    }
};

test named {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "v0.2.0-0-gabc1234", "0.2.0" },
        .{ "v0.2.0-12-gabc1234", "0.2.0+12.gabc1234" },
        .{ "v0.2.0-12-gabc1234-dirty", "0.2.0+12.gabc1234.dirty" },
        .{ "v0.2.0-0-gabc1234-dirty", "0.2.0+0.gabc1234.dirty" },
        .{ "", "0.2.0" },
        .{ "abc1234", "0.2.0" },
        .{ "v0.2.0-x-gabc1234", "0.2.0" },
    };
    inline for (cases) |case| try std.testing.expectEqualStrings(case[1], comptime named("0.2.0", case[0]));
}
