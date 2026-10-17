# Ruby version policy: the floor is a promise, CI is what keeps it

**Status:** accepted

## The problem

`lyman.gemspec` declares `required_ruby_version >= 3.2`, and the wiki tells
people "any recent Ruby works." That claim is about more than the gem: lyman
plants source into *client* projects (see `docs/design/deployment.md`), so the
floor is also the floor of every project the generator scaffolds.

It was a claim nothing enforced. `Conversation#last_assistant_content` used
`Array#rfind`, added in Ruby 4.0 (Feature #21678). The repo pins 4.0.5 in
`mise.toml`, so the whole suite — 323 tests — ran green here while every user
on 3.2–3.4 got `NoMethodError` the moment a harness read a final answer: the
script and daemon archetypes, both agent-as-tool files, and the compactor
(which degraded to recording a digest gap rather than failing loudly). One
method, four minor versions of silent breakage, and no CI to catch it.

## Decision: keep the floor low, and test it

Two ways to make a claim and its code agree — raise the floor, or fix the
code. We keep the floor at 3.2 and fix the code.

- **The floor is a promise about other people's machines.** A planted file is
  the user's file forever; raising the floor to 4.0 would raise it for every
  project lyman scaffolds, including ones stuck on what their distro ships
  (Ubuntu 24.04 ships Ruby 3.2). Lowering a promise is cheap; taking one away
  is not.
- **Nothing in the inventory needs 4.0.** The dependency chain agrees: shifty
  0.6, minitest 6, and sqlite3 2.x all declare `>= 3.2`. The newest language
  feature the inventory uses is `Data.define` (3.2). `rfind` was an
  accident, not a requirement.
- **The 4.0-only method was the bug, not the floor.** Raising the floor would
  have made the code and the docs consistent while quietly discarding the
  users the docs had already promised a working install.

## The rule

> A version claim is only as good as the oldest version something runs it on.

`.github/workflows/ci.yml` runs lint, a parse check of every tracked Ruby
file, and the full suite against a matrix starting at the declared floor
(3.2, 3.3, 3.4, 4.0) with `fail-fast: false`, so a floor violation names
itself instead of being inferred from one red X. The parse check exists
because the suite never loads the repl harness or the standalone archetype
scripts — syntax a newer Ruby introduced could hide in the files a user is
most likely to edit.

Consequences:

- **Prefer methods that exist at the floor.** When a newer Ruby offers a
  nicer spelling, the version it landed in decides whether lyman can use it.
  `Array#rindex` (used in `pending_tool_calls`) works everywhere; `rfind`
  does not. Where a floor-safe spelling is less obvious, say why in a comment
  — `last_assistant_content` carries one.
- **Bump the floor deliberately, in one commit.** If a dependency ever forces
  it, the gemspec, `README.md`, `wiki/Getting-Started.md`, `templates/`, and
  the CI matrix all move together — the failure mode this note exists to
  prevent is the docs and the floor drifting apart.
- **The matrix is the floor's test.** Adding a Ruby to the matrix is free;
  dropping the oldest row is a change to the promise, and should read like one
  in review.
