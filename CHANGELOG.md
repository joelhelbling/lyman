# Changelog

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
