# Notes for coding agents

[CONTRIBUTING.md](CONTRIBUTING.md) holds the project's conventions: follow it in full. These notes
add how the maintainer works with an agent.

- **Starting an issue.** Begin with `gh issue view N --comments`, and read the comments on related
  closed issues too.
- **Trying a change.** When the maintainer tries a change in the game, build and launch it right
  away: `make play`, or `zig build -Doptimize=ReleaseSafe` and then
  `zig-out/bin/openreliant <game directory>`. Once they are happy with it, run the checks and
  commit.
- **Pull requests.** Push the feature branch and open the pull request when the change is ready.
  The maintainer merges it. See one pull request merged before starting the next feature.
- **Attribution.** Commits and pull requests carry the maintainer's git identity alone. End commit
  messages and pull request bodies with their content, leaving out trailers such as
  `Co-Authored-By` and "Generated with" footers.
- **Gaps.** File an issue for each gap you leave, under its milestone, and name the issues in your
  reply.
- **Plain English.** Write docs, comments, log messages, issues, pull requests and replies in
  plain, simple technical English, the way you would explain the code to a colleague: normal word
  order, common words, short sentences. Older parts of the project use a stilted style that the
  maintainer doesn't want, such as "a mod's file stands in for every file of the game's of the same
  name" for "a file in a mod replaces every game file with the same name", or "each key is
  optional, and found whatever its case" for "keys are optional and can be written in any case".
  Never write in that style.
- **Old text.** When you change code or docs written in that style, rewrite the related comments,
  docs and messages plainly in the same change.
- **Replies.** Use the docs' punctuation in replies too: no em or en dashes.
- **Disk space.** `.zig-cache` grows by gigabytes; `make zig-clean` frees it when the disk fills.
