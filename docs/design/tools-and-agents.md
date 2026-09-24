# Design note: tools, and agents as tools

**Status:** accepted direction; part 1 (plantable tools convention, issue
#13) and part 3 (file primitives, issue #15) are implemented
**Tracked by:** the "tools" GitHub issues (tools convention, agent-as-tool,
file primitives, file reader agent, patch tool, patch agent)

## The problem

The harness ships one demo tool, declared inline. Lyman wants a scaffoldable
arsenal: tools a client project can plant with `lyman add`, some of which
are themselves agents — a dedicated model working a narrow job on behalf of
the root agent, so the root agent's context is spent on the answer rather
than on the raw material.

## Tools need a home

Tools keep the shape the harness already uses — schema and handler side by
side, guts on the outside — but move to one file per tool, declared in the
registry like any other plantable artifact, and picked up by the harness.
This comes before any particular tool.

**One file per tool, a factory per file.** `lib/lyman/tools/<name>.rb`
defines a factory method on `module Lyman::Tools` that returns the same
`{schema:, handler:}` shape the harness used to write inline, string keys
throughout:

```ruby
module Lyman
  module Tools
    def self.current_time
      {
        schema: {
          "type" => "function",
          "function" => {
            "name" => "current_time",
            "description" => "Returns the current local date and time",
            "parameters" => {"type" => "object", "properties" => {}, "required" => []}
          }
        },
        handler: ->(_args) { Time.now.strftime("%Y-%m-%d %H:%M:%S %Z") }
      }
    end
  end
end
```

A **factory, not a constant**, for two reasons: it mirrors the
`Lyman::Workers.*` factories already in the codebase (one paradigm, not a
second convention for tools), and keyword arguments are where a tool's
dependencies go — the recall tool (`lib/lyman/tools/recall.rb`, issue #12;
see docs/design/context-control.md, "Store and recall") is the first tool
with one, `Lyman::Tools.recall(store: store)`. Its `store:` is duck-typed
(anything answering `fetch`/`search`), so the tool file stays
self-contained and stdlib-only even though its purpose is to read back
from a store. Each tool file is self-contained (no requires of sibling
lyman files), so it can be planted, updated, or ejected on its own;
stdlib only per tool file unless its registry entry declares `gems:`.
Registered as `recall_tool` with `needs: ["store"]` — see the registry
entry's comments for what `needs:` means and why `add` only advises
rather than plants a needed artifact.

**The harness lists its tools explicitly.** No auto-registration: what the
model can call must be visible in the wiring script (guts on the outside),
and some tools need dependencies only the harness holds. Each harness
lists its tools as an explicit array of factory calls:

```ruby
# ── Tools: one file each in lib/lyman/tools/, schema and handler side by side ─
# `lyman add <name>_tool` plants more; list them here to hand them to the model.
TOOLS = [
  Lyman::Tools.current_time
]

schemas = TOOLS.map { |tool| tool[:schema] }
handlers = TOOLS.to_h { |tool| [tool[:schema].dig("function", "name"), tool[:handler]] }
```

**Registry entries are named `<name>_tool`**, each with a `wire:` string —
the expression a harness lists in `TOOLS` to hand the tool to the model.
Because harnesses are owned, `lyman add <name>_tool` plants the tool file
but never edits the harness; it advises the wiring line instead, the same
way `lyman add store` advises the `Gemfile` line rather than editing it.

**Hand-written tools keep the shape, not the location.** `lib/lyman/` is
managed, so a client project's own tools live in its own namespace and
directory (e.g. `lib/tools/weather.rb`, `Tools.weather`), required by the
harness and listed in the same `TOOLS` array.

## An agent-as-tool is a script shell inside a handler

A handler that builds a fresh conversation, runs a small circuit, and
returns the final answer *is* the script archetype (see
[harness-archetypes.md](harness-archetypes.md)) invoked in-process. That
single pattern underlies every agent below, so it is built once: its own
tool set, its own runaway guard, and a way for the outer display layer to
show nested activity. The file reader and the patch agent are two wirings
of it.

## File access

**Primitives** (plain handlers, no model):

- `search_files` — search a tree, restrictable by file name or glob,
  matching on content; returns paths with line hits.
- `read_file` — read a file, optionally by line range.

Both landed as `Lyman::Tools.search_files(root:)` and
`Lyman::Tools.read_file(root:)` (issue #15), confined to `root` by
resolving existing paths with `File.realpath`, so `..` traversal and symlinks
pointing outside it are refused. `search_files`' `pattern` is a literal,
case-insensitive substring — not a regex, since small models write poor
ones — and matching is on content; with no `pattern` it falls back to
listing matching paths by name, so the same tool covers "find this text"
and "find this file". `read_file` returns line-numbered text so the model
can cite a location and ask for more by `start_line`/`end_line`. Neither
raises on bad model input (missing file, escape attempt, binary content) —
every failure comes back as a message string the model can read and act
on, rather than an exception the circuit has to handle.

**The reader agent** takes a path or glob plus an optional query, uses the
primitives, and returns only what was asked. To avoid one agent that
switches on file type (the multi-way dispatch anti-pattern from
[circuit-pattern.md](circuit-pattern.md)), the *caller* names the result
shape it wants — excerpts with line ranges, a symbol outline, a prose
answer — and the agent has one job: extract to that shape.

**Routing rule.** Delegation costs a model call, so the question is when to
shortcut. The query is what decides, not file size:

- No query, and the path/glob resolves to a single file → return the file
  whole, whatever its size (there is nothing to extract *against*).
- A query is present → always go through the reader, even for a small
  file. A small file with a question still deserves the part of the file
  that answers it.

## Patching

**The patch tool** applies a patch to one file, then runs a configured
check command (e.g. `standardrb`, `eslint`) on the touched file and
returns its output. Two patch formats are supported, selected by
configuration:

- **search-and-replace blocks** (the default) — robust against models
  that can't reproduce exact context lines and line numbers;
- **unified diff** — for models that can; local models are improving
  quickly enough that this should be a switch, not a rewrite.

Language-server integration is deferred; the check command is the seam,
and an LSP client can be an alternate implementation of it later.

**The patch agent** accepts a collection of patches, applies them all,
checks, and then runs the tests. It may correct minor patch and check
failures inside a bounded fix loop (the existing round counter is the
bound). It must never attempt to fix a failing test — and that is enforced
structurally, not by prompt: the agent's circuit has only apply and check
tools; the tests run in a plain worker *after* the agent's circuit
finishes, so the agent cannot react to their outcome.

Results are structured — per-patch status and check output — and follow
"no news is good news": test output is included only when tests failed.

## Developer experience: what changes, and what it costs

These notes should drive the README and wiki updates that accompany each
issue as it lands — the documentation change is part of the change.

What gets better:

- **Tools become plantable.** `lyman add` grows from harnesses to an
  arsenal. A new project can start with file search, file reading, and
  patching rather than a clock demo.
- **Sub-agents get a named, boring shape.** Once agent-as-tool is a
  documented pattern, "write a sub-agent" means writing a script-shaped
  wiring inside a handler. There is no second framework to learn, and the
  same runaway guard protects it.
- **Structural guarantees replace prompt discipline.** The patch agent
  cannot fix failing tests because it has no tool that sees them.
  Developers can trust a property of the wiring instead of hoping the
  model obeys an instruction.

What it costs, stated plainly:

- **Latency from delegation.** Every reader-agent call is an extra model
  round trip. The query-decides routing rule limits it, but developers
  will feel it on slow local models.
- **More surface to configure.** Patch format, check command, test
  command, and result shape are all knobs; each should have a default that
  works for a Ruby project out of the box, and be documented where the
  tool is planted.

## Order of work

1. Plantable tools convention. **Done** (issue #13).
2. Agent-as-tool pattern.
3. File primitives. **Done** (issue #15) — landed before #2, so the
   agent-as-tool pattern will be built around a real sub-agent working
   real tools rather than a hypothetical.
4. File reader agent.
5. Patch tool.
6. Patch agent.
