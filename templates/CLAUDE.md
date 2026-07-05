# CLAUDE.md

This project was scaffolded by [lyman](https://github.com/joelhelbling/lyman):
an agentic harness built on the [shifty](https://github.com/joelhelbling/shifty)
gem's pipeline-of-workers model. `harness/chat.rb` wires a model⇄tool loop
against any OpenAI-compatible chat completions endpoint (Ollama by default).

## Running it

- `bundle install` — install dependencies (just `shifty` and `ostruct`; this
  project has no runtime dependency on the `lyman` gem itself).
- `ruby harness/chat.rb` — run the interactive chat harness. Defaults to
  Ollama at `http://localhost:11434/v1`; override with `LYMAN_MODEL` and
  `LYMAN_BASE_URL` env vars.

## The managed/owned boundary

Everything under the `Lyman::` namespace (`lib/lyman.rb`, `lib/lyman/`) is
**managed** by the lyman CLI: it was planted here, and `lyman update` can
refresh it from newer lyman releases. Treat it as a library to extend, not a
file to hand-edit — if you need to change one, run `lyman eject <name>` first,
which takes ownership explicitly rather than leaving it silently forked.
`.lyman/manifest.yml` is the record of what's managed, what's owned, and what
you've ejected; commit it.

`harness/chat.rb` and everything outside `Lyman::` is **owned** — yours from
day one, never touched by `lyman update`. Put your own workers in your own
namespace or directory, not inside `lib/lyman/`.

## Four load-bearing facts

1. **The nil-source footgun.** In shifty, a source returning `nil` ends the
   stream permanently. If you're driving a pipeline off a queue, enqueue
   before you shift — never pull a source worker while its queue is empty.

2. **The runaway-turn guard.** The model⇄tool circuit is bounded by
   `Conversation#runaway?` / `max_rounds`. Keep that guard intact when
   rewiring the circuit; without it, a model that keeps calling tools never
   lets a turn end.

3. **Item-as-control discipline.** An item may tell a worker *whether* to
   act, never *which of several things* to do. A worker that switches
   between jobs based on item state is the anti-pattern to avoid
   (multi-way dispatch) — split it into stages, or use a splitter, instead.

4. **Wire vs. conversation.** Reasoning/thinking content stays on messages in
   the `Conversation` for observability, but `Workers.wire_messages` strips
   it before anything goes out over the wire. Preserve that separation if
   you touch message handling.

## Other conventions

- `lyman doctor` smoke-tests the pipeline end to end against a stub
  transport — run it after `lyman update` or whenever something feels off.
- `lyman list` shows what's managed, owned, or ejected in this project.
- Messages use string keys throughout, matching the OpenAI-compatible wire
  format — no symbol-key message hashes.
