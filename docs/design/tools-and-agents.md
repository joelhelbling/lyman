# Design note: tools, and agents as tools

**Status:** accepted direction; all six parts (plantable tools convention
#13, agent-as-tool pattern #14, file primitives #15, file reader agent #16,
patch tool #18, file editor agent #17) are implemented
**Tracked by:** the "tools" GitHub issues (tools convention, agent-as-tool,
file primitives, file reader agent, patch tool, file editor agent)

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
show nested activity. The file reader and the file editor are two wirings
of it.

**As built (issue #14).** Work arrives with the launch — tool-call args play
`ARGV` — and the return value plays stdout; nothing about the shape changes
by running inside a handler instead of a process. By the archetypes note's
own definition (the archetype is the shell shape; the launcher is out of
scope; the output channel is the script archetype's variable part), this
isn't a fourth archetype — the same way `harness/compactor.rb` isn't: a
daemon-archetype shell run in a thread. An agent-as-tool is deliberately an
*owned Ruby file*, not a markdown/YAML agent definition — the latter would
be a second paradigm, config read by a hidden runtime, which is exactly what
"guts on the outside" rules out. The circuit is written out in the file, so
it's spliceable like any harness: an abridgement policy, a store, a gate can
all go in. Anatomy, common to every agent-as-tool:

- a top-level factory method returning `{schema:, handler:}`, the same
  shape as every other tool;
- its own tool set, listed explicitly inside the file — its identity, and
  the structural guarantee the file editor #17 relies on to keep it from
  seeing tools it shouldn't;
- a fresh conversation, `rounds` queue, and pipeline built per call ("a
  memory is a splice, not a default" — nothing persists between calls
  unless the agent deliberately wires one in);
- its own runaway guard, the existing round counter via `max_rounds:`,
  returning one short line on runaway rather than a flood of partial work
  — the return value is the whole product a caller sees;
- `trace:` — an optional callable given the inner conversation after each
  round: the seam for nested display (the repl), logging, or persistence
  (`->(c) { store.append(c) }`). It only observes; nothing it sees enters
  the outer conversation. `nil` (the default) is silent, which is what a
  daemon or script harness wants;
- model settings via `model:` and `default_model:` (plus `base_url:`/
  `default_base_url:`) — the harness passes its own `MODEL` constant as
  `default_model:` because the agent file can't see the harness's
  constant. How an agent resolves beyond that is its own business (see the
  file reader below); a general config service is out of scope for now;
- runnable standalone, `if __FILE__ == $PROGRAM_NAME` — the script
  framing's practical payoff: an agent's prompt and model can be tuned
  directly, without coaxing the main model into calling it.

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

**As built (issue #16).** `harness/agents/file_reader.rb`, owned, planted
by `lyman new` (registry `file_reader_agent`, needs `search_files_tool`/
`read_file_tool`). Params: `path` (file or glob, required), `query`
(optional), and `shape` — `excerpts` (default; relevant passages with
`path:line` ranges, so the caller can follow up precisely), `outline`
(symbols/sections with line numbers), or `answer` (short prose citing
`path:line`). The caller names the shape it wants; the agent has one job,
extract to that shape — no switching on file type. The routing rule above
is decided in the handler *before* any model call: a no-query path that
resolves to exactly one file skips the model entirely; a query, or several
matched files, always delegates. Its tools are `search_files` and
`read_file` (root-confined, #15) — the file primitives are the reader's
tools now, not the main model's. `harness/repl.rb` lists
`file_reader(root: Dir.pwd, default_model: MODEL, default_base_url:
BASE_URL, trace: ...)` in `TOOLS` *instead of* `search_files`/`read_file`,
so raw file text never enters the main conversation — enforced by the
wiring, not a prompt. The repl shows nested activity indented under the
tool call (`ToolPrinter` gained `indent:`), so the delegation is visible
rather than a black box.

## Patching

**The patch tool** applies one patch to one file, then runs a configured
check command (e.g. `standardrb`, `eslint`) on the touched file and
returns its output. Two patch formats, as **two tool factories** rather
than one factory with a `format:` switch — the format changes the tool's
schema, not just its behavior, and a switch would be a mode where the
rest of the design uses a choice of file or line:

- **search-and-replace blocks** (the default) — robust against models
  that can't reproduce exact context lines and line numbers;
- **unified diff** — for models that can; local models are improving
  quickly enough that this should be a choice of tool, not a rewrite.

The two share the check step. The check is a seam: a string command (the
touched path appended, run as an argv via `Open3`, never through a
shell), a callable given the path, or `nil` for no check. It reports and
does not rewrite by default — a `--fix` style check changes the file out
from under the model's picture of it, so that is an opt-in. The model
never supplies any part of the command; it is fixed at wiring time.
Language-server integration is deferred; an LSP client can be an
alternate callable later.

**As built (issue #18).** `lib/lyman/tools/patch.rb`, one managed file
(registry `patch_tool`, planted by `lyman new`, stdlib only) holding both
factories: `Lyman::Tools.search_replace(root:, check:)` and
`Lyman::Tools.apply_diff(root:, check:)`. Root confinement works like
`read_file`'s, extended to files that don't exist yet: the nearest
existing ancestor is realpath'd, so a symlinked directory can't smuggle a
new file outside the root. Nothing raises on model input; every failure
is a message that says nothing was changed and what to send instead:

- `search_replace` requires `search` to match exactly once. Several
  matches are refused with their line numbers ("include more surrounding
  lines"). No exact match, but one match ignoring whitespace, returns the
  file's exact lines to resend — the tool shows the model its mistake
  rather than guessing which indentation it meant. An empty `search`
  creates a file (and never overwrites one).
- `apply_diff` takes `path` explicitly and ignores the diff's `---`/`+++`
  headers (models mangle the `a/`/`b/` prefixes). Hunks are placed by
  their context and `-` lines, exact first and then ignoring trailing
  whitespace; the `@@` line numbers only break ties between equal matches,
  since models get numbers wrong far more often than text. Context lines
  keep the file's own text, so a tolerant match never rewrites its
  anchor. All hunks apply or none do; a multi-file diff is refused;
  add-only hunks on a missing path create the file.
- CRLF files are matched as LF (models send LF) and written back as CRLF.
- The check: `nil` (no check), a command String or Array (split with
  `Shellwords`, the touched path appended relative to root, run from root
  with `Open3` — exit 0 passes), or a callable given the absolute path
  and returning `nil`/`""` for a pass or its findings. The result is one
  word on a pass and the (capped) findings on a failure; a command that
  can't run says so rather than raising. The schema only mentions the
  check when one is configured.

**One patch at a time, not a batch.** An earlier plan had a batch-apply
tool (a collection of patches in, apply all, check, test). It was
dropped: the patches would already sit in the caller's context, so a
batch saves little, and when a batch goes wrong it goes wrong across a
larger surface that takes more analysis to untangle. Small changes,
checked as they land, are the better habit.

**The file editor** (issue #17) is the write-side twin of the file
reader: the caller hands it a prompt describing a change, and a
sub-agent with its own `search_files`, `read_file`, and patch tools finds
the code, writes the exact edits, applies them, and checks them. The
point is the same as the reader's — raw file text stays out of the
caller's context, in both directions now — plus one the reader doesn't
have: small local models are bad at reproducing exact context lines, so
turning "in `#bar`, make the loop a `map`" into a patch that applies is
work worth delegating.

The prompt can be narrow (a location plus an intent) or broad (a goal
across files); that is a spectrum, not two modes, and the name
`file_editor` is what tells the calling model how to prompt it. A
markedly different editing strategy is a different agent file, not a
mode of this one.

It may correct its own patch and check failures inside a bounded fix
loop (the existing round counter is the bound). It must never attempt to
fix a failing test — and that is enforced structurally, not by prompt:
the agent's circuit has no tool that runs tests; the tests run in a
plain worker *after* the circuit finishes, so the agent cannot react to
their outcome. The scope of one `file_editor` call is therefore the
"change" the tests run after — which is an argument for prompting it
with small changes.

Configuration follows the file reader's precedent: the harness declares
its settings as constants beside `MODEL` and hands them in as factory
arguments — `file_editor(check: CHECK_COMMAND, test: TEST_COMMAND,
default_model: MODEL, ...)` — and the editor passes `check:` on to the
patch tool it builds inside its own file. No config file, no shared
settings object.

Results follow "no news is good news": what changed and any check output
that remains; test output only when tests failed.

**As built (issue #17).** `harness/agents/file_editor.rb`, owned, planted
by `lyman new` (registry `file_editor_agent`, needs `search_files_tool`,
`read_file_tool`, `patch_tool`). One param, `request` — a prompt
describing the change. The factory is `file_editor(default_model:,
default_base_url:, root: Dir.pwd, check: "bundle exec standardrb", test:
"bundle exec rake test", model: nil, base_url: nil, max_rounds: 12,
trace: nil)`, with `LYMAN_FILE_EDITOR_MODEL`/`LYMAN_FILE_EDITOR_BASE_URL`
overrides resolved like the reader's. `check:` takes the patch tool's
forms; `test:` is a command String/Array run from root (argv, no shell),
a callable returning `nil` or a failure string, or `nil`. Both are
normalized at wiring time, so a bad type raises `ArgumentError` there
rather than on the model's first call. The sub-agent's tools are
`search_files`, `read_file`, and `search_replace` — switching it to
unified diffs is editing the one line that builds the patch tool to
`apply_diff`.

- **The trailing stages are the guarantee.** Two `relay_worker` stages
  follow the circuit's `filter_worker`: one builds a `FileEditor::Outcome`
  (a `Data` value) and re-checks each changed file, the next runs the
  tests once — only if something changed and a runner is set. Nothing
  downstream of the filter feeds `rounds`, so no model request can carry
  test output. The placement in the pipeline *is* the enforcement.
- **Changed files are tracked by bytes, not by reading replies.** The
  patch handler is wrapped to snapshot the target file before and after;
  the patch tool's wording stays its own business.
- **The re-check sweep** reruns the check on every changed file after the
  circuit finishes, since the agent may have given up on a failure; any
  that still fail are reported.
- **A runaway still reports and still tests.** Unlike the reader, where a
  runaway returns one short line, the editor may already have changed
  files — so the caller gets "stopped after N rounds before finishing —
  the change may be partial.", followed by the changed files and the test
  result. The caller needs to know what state the tree is in.
- **The report:** the agent's one- or two-sentence summary (or the
  runaway line), `Changed: …` or `No files were changed.`, `Check still
  failing —` with findings per file, then `Tests: passed.` or `Tests:
  failed —` plus the output, tail kept (test runners summarize last),
  capped at 4000 chars. No test line when nothing changed.

`harness/repl.rb` lists `file_editor(root: Dir.pwd, check: CHECK_COMMAND,
test: TEST_COMMAND, default_model: MODEL, default_base_url: BASE_URL,
trace: ...)` in `TOOLS` after `file_reader`, with `CHECK_COMMAND = "bundle
exec standardrb"` and `TEST_COMMAND = "bundle exec rake test"` declared
beside `MODEL`. The patch tool is the editor's, not the main model's, so
raw file text stays out of the main conversation in both directions.
Standalone, `ruby harness/agents/file_editor.rb "REQUEST"` edits files
under the cwd for real (report on stdout, inner tool trace on stderr),
using the factory defaults — so it expects a Bundler project with
standardrb and a rake test task. Verified live with `gemma4:latest`:
`search_files` → `read_file` → `search_replace`, applied, tests passed;
a follow-up change that broke a test came back `Tests: failed`, and the
model never saw it.

**Open question: does sequestering reading and writing fragment
context?** The reader and the editor each keep raw file text out of the
caller's context, but a larger effort may need reading and writing to
cohere in one place. It may turn out that general-purpose sub-agents,
each owning one coherent slice of a decomposed task, are the better unit
— and wire-time abridgement and sidecar compaction
([context-control.md](context-control.md)) are a competing strategy for
the same problem. Not answerable on paper; the plan is to use the reader
and the editor in realistic sessions and see.

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
- **Structural guarantees replace prompt discipline.** The file editor
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
2. Agent-as-tool pattern. **Done** (issue #14) — shipped together with #4,
   since a toy agent would prove nothing; the reader is what proves the
   pattern.
3. File primitives. **Done** (issue #15) — landed before #2, so the
   agent-as-tool pattern will be built around a real sub-agent working
   real tools rather than a hypothetical.
4. File reader agent. **Done** (issue #16).
5. Patch tool. **Done** (issue #18).
6. File editor agent. **Done** (issue #17).
