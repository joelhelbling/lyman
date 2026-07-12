---
name: lyman
description: Guidance for working in a lyman-scaffolded agentic harness — the pipeline-of-workers model, the harness archetypes, the managed/owned boundary, and lyman's sharp edges. Use when reading or changing a harness script (harness/*.rb), anything under lib/lyman/, or when running lyman CLI commands (add, update, eject, diff, doctor).
---

# Working in a lyman project

This project was scaffolded by [lyman](https://github.com/joelhelbling/lyman):
an agentic harness built on the [shifty](https://github.com/joelhelbling/shifty)
gem's pipeline-of-workers model. `harness/repl.rb` wires a model⇄tool loop
against any OpenAI-compatible chat completions endpoint (Ollama by default).

## Running it

- `bundle install` — install dependencies (just `shifty` and `ostruct`; this
  project has no runtime dependency on the `lyman` gem itself).
- `ruby harness/repl.rb` — run the interactive repl harness. Defaults to
  Ollama at `http://localhost:11434/v1`; override with `LYMAN_MODEL` and
  `LYMAN_BASE_URL` env vars.

## Harness archetypes

Every lyman harness is the same model⇄tool circuit inside a different
*shell* (state + a driving process). Three archetypes cover the shell
shapes — see the [Harness Archetypes wiki page](https://github.com/joelhelbling/lyman/wiki/Harness-Archetypes):

- **REPL** (`harness/repl.rb`, planted by default) — a human drives the
  loop and ends it. One conversation accretes across turns.
- **Daemon** (`lyman add daemon_harness`) — launch once, loop indefinitely
  on an inbound event stream; no human in the loop. Fresh conversation per
  event.
- **Script** (`lyman add script_harness`) — launched by cron or on demand
  with its work item in hand; processes it and halts. No loop in the shell
  at all.

To build a new harness, start from the archetype whose shell shape matches
— the circuit rarely needs to change; the supplier of work items does.

## The managed/owned boundary

Everything under the `Lyman::` namespace (`lib/lyman.rb`, `lib/lyman/`) is
**managed** by the lyman CLI: it was planted here, and `lyman update` can
refresh it from newer lyman releases. Treat it as a library to extend, not a
file to hand-edit — if you need to change one, run `lyman eject <name>` first,
which takes ownership explicitly rather than leaving it silently forked.
`.lyman/manifest.yml` is the record of what's managed, what's owned, and what
you've ejected; commit it.

The harness scripts (`harness/*.rb`) and everything outside `Lyman::` are
**owned** — yours from day one, never touched by `lyman update`. Put your own
workers in your own namespace or directory, not inside `lib/lyman/`.

## Five load-bearing facts

1. **Frozen handoffs.** Shifty (0.6+) deep-freezes every value at a worker
   boundary; a task that mutates its input raises `Shifty::PolicyViolation`.
   `Conversation` is an immutable value: express change with its `with_*`
   methods (a new conversation comes back) and rebind shell state to what
   the pipeline returns — never mutate in place. Closure state inside a
   worker stays freely mutable; only handed-off values freeze.

2. **The nil-source footgun.** In shifty, a source returning `nil` ends the
   stream permanently. If you're driving a pipeline off a queue, enqueue
   before you shift — never pull a source worker while its queue is empty.

3. **The runaway-turn guard.** The model⇄tool circuit is bounded by
   `Conversation#runaway?` / `max_rounds`. Keep that guard intact when
   rewiring the circuit; without it, a model that keeps calling tools never
   lets a turn end.

4. **Item-as-control discipline.** An item may tell a worker *whether* to
   act, never *which of several things* to do. A worker that switches
   between jobs based on item state is the anti-pattern to avoid
   (multi-way dispatch) — split it into stages, or use a splitter, instead.

5. **Wire vs. conversation.** Reasoning/thinking content stays on messages in
   the `Conversation` for observability, but `Workers.wire_messages` strips
   it before anything goes out over the wire. Preserve that separation if
   you touch message handling.

## Other conventions

- `lyman doctor` smoke-tests the pipeline end to end against a stub
  transport — run it after `lyman update` or whenever something feels off.
- `lyman list` shows what's managed, owned, or ejected in this project.
- Messages use string keys throughout, matching the OpenAI-compatible wire
  format — no symbol-key message hashes.
