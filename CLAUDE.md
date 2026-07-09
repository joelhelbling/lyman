# CLAUDE.md

Lyman is a composable agentic harness — and a framework for building harnesses —
in Ruby, built on the [shifty](https://github.com/joelhelbling/shifty) gem's
pipeline-of-workers model. It targets people building narrow, purpose-built
agentic workflows on local/open-weight models, where fast iteration is the edge.

Read `docs/vision.md` (the why, the values, the architecture decisions),
`docs/design/circuit-pattern.md` (how the model⇄tool loop works in a linear
pull pipeline), and `docs/design/deployment.md` (lyman as a pure generator:
manifest-tracked planted modules, eject-to-own, unit of upgrade = unit of
extraction) before making design-level changes. Those documents are the
source of truth for intent; this file is a summary plus working conventions.

## Commands

- Ruby version is pinned in `mise.toml` (currently 4.0.5).
- `bundle install` — install dependencies.
- `bundle exec standardrb` — lint. **standardrb is the project linter**; run it
  before committing and keep the tree offense-free. `bundle exec standardrb --fix`
  handles most issues. Prefer fixing code over disabling cops; when a disable is
  genuinely warranted (rare), scope it to the line and add a comment saying why.
- `bundle exec rake test` — run the Minitest suite (it covers the generator
  CLI; tests drive observable behavior — CLI in, files/manifest/output out).
- `ruby harness/chat.rb` — run the interactive chat harness against a local
  OpenAI-compatible endpoint (defaults: Ollama at `http://localhost:11434/v1`,
  model `gemma4:latest`; override with `LYMAN_MODEL` / `LYMAN_BASE_URL`).
  Verifying behavior end-to-end requires a local model server to be running.
- `bundle exec exe/lyman` — the generator CLI (`new` / `add` / `update` /
  `eject` / `diff` / `doctor` / `list`). `LYMAN_SOURCE_ROOT` points it at an
  alternate artifact-source tree — how tests simulate a newer lyman release.

## Layout

- `lib/lyman/` — the plantable library: `Conversation` (the item that flows
  through pipelines) and `Workers` (factories like `chat_completion`,
  `tool_execution`). These files are both what this repo runs and what the
  generator plants into client projects — one copy, kept alive by use.
- `lib/lyman/cli/` — generator machinery (Thor CLI, registry, manifest,
  planter). Never planted into client projects. The boundary between what
  lyman *does* (this directory) and what it *installs* is the registry,
  `lib/lyman/cli/registry.rb` — every plantable artifact is declared there;
  add to that list, don't invent a parallel convention.
- `templates/` — plantable artifacts that aren't this repo's own working
  files (the client `CLAUDE.md` and `Gemfile`, the glob-based client
  `lib/lyman.rb` entry point).
- `harness/chat.rb` — the shipped example harness: the one legible wiring
  script. It is a deliberately top-level Ruby script, not a class — and it is
  the source planted by `lyman new`, owned by the user from day one. Its
  display layer (styling, think-preview filter, spinner, printers) lives in
  `harness/chat/`, one file per widget, each registered as its own owned
  artifact. The harness loads local files with `require_relative` — it uses
  the files in `lib/`, not the lyman gem.
- `test/` — Minitest suite for the generator CLI.
- `docs/` — vision and design notes. Design decisions get written down here.

## Core principles (apply these to every change)

1. **Legibility — one paradigm everywhere.** Everything is a pipeline of
   workers. Don't introduce a second paradigm or hide the existing one behind
   abstractions. DSLs are used sparingly; convenience must not cost transparency.
2. **Guts on the outside.** Nothing important happens where a user can't see,
   name, or splice into it. This is the deliberate opposite of black-box agent
   SDKs. When a decision is balanced, favor whatever lets a user see and change
   behavior faster — that's the design razor.

Concrete consequences:

- **The shell stays boring.** The enclosing scope (e.g. `harness/chat.rb`'s
  loop) is state + a driving process, nothing more. If a shell is getting
  interesting, the interesting part belongs in a worker.
- **State lives in the shell's scope, visibly** — the conversation and the
  circuit's `rounds` queue are declared right in the wiring script, not
  smuggled inside the pipeline.
- **Item-as-control discipline:** an item may tell a worker *whether* to act,
  never *which of several things* to do. A worker that switches between jobs
  based on item state is the named anti-pattern (multi-way dispatch) — split it
  into stages or use a splitter.
- **Swappable seams:** model transport, tool calling, and the model⇄tool loop
  are each ordinary workers/gangs. New capabilities should be alternate
  implementations of a seam, not special cases wired into the core.
- **Dependency isolation:** confine each gem/library to the single worker or
  gang that needs it, so only that worker knows the dependency exists.

## Sharp edges to respect

- **The nil footgun:** in shifty, a source returning `nil` ends the stream
  permanently. The circuit's queue-backed source must never be pulled while the
  queue is empty — the shell enqueues before shifting.
- **Runaway turns:** the model⇄tool circuit is bounded by the round counter on
  `Conversation` (`runaway?` / `max_rounds`). Keep that guard intact when
  rewiring.
- **Wire vs. conversation:** reasoning/thinking content is kept on messages in
  the `Conversation` for observability but stripped from API payloads
  (`wire_messages`). Preserve that separation.

## Working conventions

- Messages use string keys throughout, matching the OpenAI-compatible wire
  format — no symbol-key message hashes.
- Match the existing comment style: comments explain *why* and record design
  intent, not what the next line does.
- Verify pipeline changes against a live local model when possible; the harness
  is the integration test bed for the library. The Minitest suite covers the
  generator CLI — keep tests driven from observable behavior (inputs, outputs,
  worker interactions), not internal implementation detail.
- Record significant design decisions in `docs/design/` rather than letting
  them live only in code or commit messages.
