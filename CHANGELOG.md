# Changelog

## Unreleased

### Added

- **File editor agent** (`harness/agents/file_editor.rb`, planted by
  `lyman new`, registry `file_editor_agent`, needs `search_files_tool`,
  `read_file_tool`, `patch_tool`): the file reader's write-side twin. One
  param, `request`, describing the change; a sub-agent finds the code with
  `search_files`/`read_file` and edits it with `search_replace` (swap to
  `apply_diff` by editing one line), fixing its own patch and check
  failures within `max_rounds` (default 12). Tests are out of its reach
  structurally: two `relay_worker` stages after the circuit's
  `filter_worker` re-check each changed file and run the tests once (only
  if something changed), and nothing downstream of the filter feeds the
  model. Changed files are tracked by comparing bytes before/after each
  patch. The report: the agent's summary (or a runaway line — the change
  may be partial, so changes are still listed and tests still run),
  `Changed: …` / `No files were changed.`, any `Check still failing —`
  findings, and `Tests: passed.` or `Tests: failed —` with the output's
  tail (4000 chars). Factory `file_editor(default_model:,
  default_base_url:, root:, check: "bundle exec standardrb", test: "bundle
  exec rake test", model:, base_url:, max_rounds:, trace:)`; `test:` is a
  command String/Array (argv from root, no shell), a callable returning
  `nil` or a failure string, or `nil`, and bad `check:`/`test:` types
  raise `ArgumentError` at wiring time. `LYMAN_FILE_EDITOR_MODEL` /
  `LYMAN_FILE_EDITOR_BASE_URL` override the model. Runnable standalone
  (`ruby harness/agents/file_editor.rb "REQUEST"`, report on stdout,
  inner tool activity on stderr — it edits files under the cwd for real).
  `harness/repl.rb` lists `file_editor` in `TOOLS` after `file_reader`,
  with new `CHECK_COMMAND` / `TEST_COMMAND` constants it hands in, so the
  patch tool is the editor's, not the main model's. Closes part 6 of the
  tools-and-agents design (issue #17).
- **Patch tool** (`lib/lyman/tools/patch.rb`, registry `patch_tool`,
  planted by `lyman new`, stdlib only): two factories, one per patch
  format — `Lyman::Tools.search_replace(root:, check:)` (exact
  search-and-replace blocks, the default) and
  `Lyman::Tools.apply_diff(root:, check:)` (unified diff) — sharing the
  check step, so choosing a format is choosing which one to list in
  `TOOLS`. Each applies one patch to one file, root-confined (including
  new files, via their nearest existing ancestor), and never raises on
  model input. `search_replace` refuses ambiguous matches with their line
  numbers, answers a whitespace-only near miss with the exact lines to
  resend, and creates a file from an empty `search`. `apply_diff` places
  hunks by context (line numbers only break ties), tolerates trailing
  whitespace without rewriting context, applies all hunks or none, and
  refuses multi-file diffs. CRLF files round-trip. `check:` is a command
  String/Array (touched path appended, argv via `Open3`, no shell), a
  callable given the absolute path, or `nil`; the result is "Check:
  passed." or the findings. Not handed to the main model directly — the
  file editor agent (#17) builds it internally. Closes part 5 of the
  tools-and-agents design (issue #18).
- **Agent-as-tool, and the file reader agent** (`harness/agents/file_reader.rb`,
  planted by `lyman new`, registry `file_reader_agent`): an agent-as-tool is
  the script archetype run inside a tool handler — the work item arrives
  with the tool call (its args play `ARGV`), and the return value plays
  stdout, the same relationship `harness/compactor.rb` has to the daemon
  archetype. It's an owned Ruby file, not a markdown/YAML agent
  definition: a top-level factory returning `{schema:, handler:}`, its own
  tool set declared explicitly inside the file, a fresh conversation and
  `rounds` queue built per call, its own `max_rounds` runaway guard, an
  optional `trace:` callable for nested display/logging/persistence (`nil`
  by default, silent), and `model:`/`default_model:` (plus
  `base_url:`/`default_base_url:`) so a harness can hand down its own model
  choice. Runnable standalone
  (`ruby harness/agents/file_reader.rb PATH [QUERY] [SHAPE]`, answer on
  stdout, inner tool activity on stderr) for tuning its prompt and model
  directly. The file reader takes `path` (file or glob), an optional
  `query`, and `shape` (`excerpts` default, `outline`, or `answer`) — the
  caller names the shape, so the agent never switches on file type. Its
  handler shortcuts the model entirely when there's no query and the
  path/glob resolves to exactly one file; any query, or several matched
  files, delegates. Its tools are `search_files`/`read_file` (needs
  `search_files_tool`/`read_file_tool`). `harness/repl.rb` now lists
  `file_reader` in `TOOLS` instead of the raw primitives, so file text
  never enters the main conversation, and shows its nested tool activity
  indented under the call (`ToolPrinter` gained `indent:`). Closes parts 2
  and 4 of the tools-and-agents design (issues #14, #16) — shipped
  together since a toy agent would have proven nothing about the pattern.
- **File primitives** (`Lyman::Tools.search_files(root:, max_hits: 100)`,
  `Lyman::Tools.read_file(root:, max_chars: 20_000)`): plain handlers, no
  model, stdlib only, planted by `lyman new` alongside `current_time`.
  `search_files` matches a literal, case-insensitive `pattern` against file
  contents (returning `path:LINE: text` hits), or without a `pattern` lists
  matching paths by name, restrictable by `glob` or `path`; it skips binary
  files and dotfiles/dotdirs and caps output at `max_hits` with a
  truncation note. `read_file` returns line-numbered text, optionally by
  `start_line`/`end_line`, truncating on a line boundary with a hint naming
  the next `start_line`. Both confine every path to `root` by resolving it
  with `File.realpath`, refusing `..` traversal and symlinks that point
  outside it, and never raise on bad model input — every failure (missing
  file, escape attempt, binary content) comes back as a message string.
  `harness/repl.rb` lists both in `TOOLS`; the daemon and script harnesses
  don't, since giving a TCP-listening or scripted harness file access
  should be the owner's deliberate choice. These are the primitives the
  upcoming file reader agent (#16) will be built from. Closes part 3 of
  the tools-and-agents design (issue #15).
- **The compaction sidecar** (`lyman add compactor`): a daemon-archetype
  shell (`harness/compactor.rb`, owned) that runs in its own thread beside
  a root harness and keeps a ledger of the conversation current with a
  small fast model — so compaction, when the shell asks for it with
  `Lyman::Compaction.request(inbox, conversation)`, is a drain and a
  handoff rather than a summarization stall. The ledger's entries (facts,
  decisions, open items) cite the addresses of the elements they
  summarize; the compacted conversation is the system prompt plus the
  ledger, then the last turn verbatim, with `parent_id` pointing at the
  original. `Lyman::Workers.compaction_feed(inbox)` is the sidecar's one
  side worker in the root circuit. `Lyman::Compaction` and
  `compaction_feed` are stdlib-only and planted by `lyman new`; the
  sidecar itself is opt-in. Registry entries gained `advice:` — a line
  `add` prints after planting. Closes part 4 of the context-control
  design (issue #11).
- **The recall tool** (`lyman add recall_tool`): `Lyman::Tools.recall(store:,
  max_chars: 8000)` lets the model re-expand context an abridgement policy
  or a compaction ledger entry compressed away, by element address
  (`conv:abc#17-23`) or plain-word search — the first tool with a
  dependency, registered with `needs: ["store"]` so `add` advises `lyman
  add store` when it isn't planted yet. Output is bounded by `max_chars`
  so a wide recall can't blow the very context it's meant to relieve.
  Closes part 5 of the context-control design (issue #12).

### Fixed

- **`lyman add`'s "planted but not wired" advice no longer goes quiet on
  mere mentions.** The check ignores whole-line comments, so a
  commented-out wiring line (`# Lyman::Tools.recall(store: store)`) now
  gets the reminder (issue #27). It also skips the artifact's own file,
  and no longer counts a name that follows a word character or a slash,
  so an agent file defining its own factory, or a harness that only
  `require_relative`s it, no longer counts as the agent being wired.
  Trailing comments and `=begin`/`=end` blocks still count; handling them
  would mean parsing Ruby.

## 0.3.0

The harness archetypes and immutable conversation release. Lyman now ships
three archetype harnesses — one circuit, three shells — and adopts shifty
0.6's frozen handoffs: `Conversation` became an immutable value. This is a
breaking change for planted projects; see the migration notes below.

### Breaking changes

- **`Conversation` is an immutable value** (a `Data` subclass). Change is
  expressed as new values: `with_user_message`, `with_assistant_message`,
  `with_tool_result`, and `finish` replace `add_user_message`,
  `add_assistant_message`, `add_tool_result`, and `finish!`, each returning
  a new conversation. Shells rebind instead of mutating
  (`conversation = pipeline.shift`). The round counter moved into
  `with_assistant_message` — a round *is* one model reply — so a swapped-in
  transport can no longer forget the runaway guard. Reasoning and design in
  `docs/design/immutable-conversation.md`.
- **shifty ~> 0.6 is required** (was 0.5). Shifty's default handoff policy
  deeply freezes every value at a worker boundary; a worker that mutates
  its input raises `Shifty::PolicyViolation`. The planted
  `chat_completion` and `tool_execution` workers are rewritten
  non-destructively and declare no policy escapes.
- **The chat harness is renamed to the repl harness**: `harness/chat.rb` →
  `harness/repl.rb`, display layer `harness/chat/` → `harness/repl/`.
  Registry artifact names follow: `harness` → `repl_harness`,
  `chat_style` → `repl_style`. Existing projects are unaffected in place —
  harness artifacts are owned, `lyman update` never touches them, and
  manifest entries unknown to this release are left alone — but a fresh
  `lyman add` plants the new names at the new paths.

### Migrating a planted project

1. `bundle update shifty` (and take `gem "shifty", "~> 0.6"` in your
   Gemfile).
2. `lyman update` — refreshes the managed `conversation`,
   `chat_completion`, and `tool_execution` modules (halting first, as
   always, if you've modified them).
3. Port your own harness and workers: `add_*` → `with_*`, `finish!` →
   `finish`, and rebind shell state to what the pipeline returns. A
   `Shifty::PolicyViolation` names the offending worker if you miss one.

### Added

- **The daemon archetype** (`lyman add daemon_harness`): launch once, loop
  indefinitely on an inbound event stream — shipped as a stdlib-only,
  line-per-event TCP listener (port 1216, the Lyman-alpha wavelength in
  Ångströms), fresh conversation per event, tool calls logged by a spliced
  side worker.
- **The script archetype** (`lyman add script_harness`): work item from
  ARGV or stdin at launch, one enqueue and one shift, final answer on
  stdout, halt. No loop in the shell at all — repetition lives in the
  pipeline.
- **Opt-in artifacts as a registry concept matured**: `lyman new` plants
  the repl; the daemon and script archetypes are a `lyman add` away, so a
  narrow, purpose-built agent gets one shell shape, not three.
- **The repl's display layer, one owned artifact per widget**
  (`repl_style`, `think_filter`, `wait_spinner`, `round_printer`,
  `tool_printer`), so ownership — and any drift `lyman diff` reports —
  stays per-file. Its cli-ui/reline dependencies stay confined to
  `harness/repl/`.
- **Design notes**: `docs/design/harness-archetypes.md` (one circuit,
  three shells) and `docs/design/immutable-conversation.md` (the shifty
  0.6 adaptation).
- **A documentation wiki** — [guided tour on GitHub](https://github.com/joelhelbling/lyman/wiki):
  Getting Started, Core Concepts, the archetypes, and the generator CLI.
  Sourced from `wiki/` in this repo and published with `wiki/publish.sh`.
- Scaffolded guidance (`CLAUDE.md` / the `claude_skill` variant) now
  carries five load-bearing facts — frozen handoffs joined the list — and
  describes the archetypes.

## 0.2.1

- The chat harness display grew a proper face: cli-ui styling (colored
  labels, glyphs), reline line editing and history at the prompt, a wait
  spinner for prefill silence, a streamed dim preview of `<think>` blocks,
  and one-line tool-call/result reporting. The scaffolded Gemfile gains
  `cli-ui` and `reline` (display-layer only; drop them if you restyle).

## 0.2.0

### Added

- **`claude_skill` artifact** (`lyman add claude_skill`): the scaffolded
  CLAUDE.md guidance packaged as a Claude Code skill at
  `.claude/skills/lyman/SKILL.md`, for projects that already have a
  `CLAUDE.md` lyman shouldn't clobber. First **opt-in** artifact
  (`optional:` in the registry): skipped by `new`, reached with `add`;
  `lyman add claude_md` suggests it when refusing to overwrite an existing
  file. `lyman list` labels opt-in artifacts.

## 0.1.0

Initial release: lyman as a **pure generator** (the shadcn/ui model) — the
gem plants legible, manifest-tracked source into client projects and is
never a runtime dependency.

- The plantable library: `Conversation` (the item that flows through
  pipelines) and the `chat_completion` (OpenAI-compatible, streaming +
  blocking) and `tool_execution` workers.
- The chat harness: the circuit pattern wired as one legible top-level
  script, owned by the user from day one.
- The generator CLI: `new`, `add`, `update`, `eject`, `diff`, `doctor`,
  `list`, backed by a path-aware manifest (`.lyman/manifest.yml`) with a
  pristine cache, three-tier `update` (pristine/modified/untracked),
  eject-to-own with tombstones and upstream-change advisories, and a
  pipeline smoke test (`doctor`) that needs no model server.
