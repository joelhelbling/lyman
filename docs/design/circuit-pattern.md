# Design note: cycles in a linear pipeline — the circuit pattern

**Status:** accepted direction (pre-implementation)
**Resolves:** open question #1 in [../vision.md](../vision.md)

## The problem

The agentic core of a conversation turn is a cycle: assemble request → call
model → *if the model called tools* → execute tools → append results → call
model again → … until the model answers without tool calls (or a guard trips).
The number of round trips is unknown at wire-up time; the model decides it at
runtime, per turn.

Shifty, however, is a strictly **linear, demand-driven pull chain**:

- Every worker has exactly one `supply`. `pipeline.shift` asks the *last*
  worker for a value, which pulls from its supply, and so on up to the source.
  Data flows down only because demand flows up.
- `Gang` is a list; composition is concatenation. There is no fan-in, no
  fan-out, and no back-edge.

A naive back-edge (wiring the tool executor's output in as the model caller's
supply) cannot work: in a pull model, a topological cycle isn't a loop — it's
demand chasing its own tail. Shifty's linearity is load-bearing.

The values tension: the model⇄tool cycle is *the workshop* — where most
tinkering happens. "Guts on the outside" demands the loop be visible and
splice-able, but shifty's natural escape hatch (a `while` loop hidden inside
one fat worker's closure) buries exactly the thing we most want exposed.

## Shapes considered

| Shape | Verdict |
|---|---|
| **A. Fat worker** — one worker with an internal `while` loop doing model calls and tool dispatch | Rejected. The entire workshop becomes one opaque node; no splice points. Fails the design razor hard. |
| **B. Queue-mediated pseudo-cycle** — linear topology; a source reads from a queue; a tail worker re-enqueues unfinished items | Rejected *as originally conceived* (queue hidden inside the pipeline) — but see below: with the queue moved into the shell's scope, this objection dissolves. |
| **C. Unrolled N passes** — wire model→tool→model… a fixed K times | Rejected. K is a lie; the runtime iteration count is the model's decision. |
| **D. Loop lives in the enclosing scope** — linear inner pipeline; a small loop in coordinating scope re-feeds rounds | Right control-location instinct, but as first sketched it implied a new primitive. |

**The resolution is B + D combined:** the queue-mediated shape, with the queue
living in the shell's enclosing scope — declared in the one legible wiring
script, right next to the conversation state. Not smuggled; on the table.

## The circuit pattern

Stock shifty parts only. Illustrative pseudocode — **not committed API**:

```ruby
rounds = []   # the queue: shell scope, visible in the wiring script

inner = source_worker { rounds.shift }                                    \
      | relay_worker    { |c| call_model(c) }                             \
      | splitter_worker { |c| c.pending_tool_calls.any? ? c.split_tool_calls : [c] } \
      | relay_worker    { |c| c.tool_call? ? execute(c) : c }             \
      | batch_worker    { |c, batch| c.round_complete?(batch) }           \
      | relay_worker    { |batch| merge_round(batch) }                    \
      | side_worker     { |c| rounds << c unless c.finished? }            \
      | filter_worker   { |c| c.finished? }
```

**The loop needs no loop.** When the shell calls `inner.shift`, the tail
`filter_worker` pulls until it receives a *finished* turn. Each time an
unfinished round reaches the tail, the `side_worker` has already re-enqueued
it; the filter rejects it and pulls again; demand propagates back up to the
source, which finds the re-enqueued item waiting. **N model⇄tool rounds happen
inside a single `shift` call, driven entirely by shifty's own demand
semantics.**

Role assignments:

- **`source_worker`** — reads from the queue; the only worker that knows where
  items originate.
- **`splitter_worker` / `batch_worker`** — tool-call fan-out/fan-in: one model
  response with three tool calls → three items → three executions → gathered
  back into a round.
- **`side_worker`** — the back-edge: re-enqueues unfinished rounds.
- **`filter_worker`** — the loop condition: only finished turns escape.

Every stage is an ordinary, visible, spliceable worker.

### No third primitive

The cycle is a **pattern, not a primitive**. Shifty keeps exactly `Worker` and
`Gang`; lyman ships the circuit as a documented, scaffolded pattern made of
stock parts. This is "keeping shifty shifty" in the strongest sense.

## The shell

The enclosing scope is called the **shell** (formerly "conductor" in early
discussion). A shell is **state + a process** — an environment holding the
conversation and the queue, plus a driving process that is usually just a
`while` loop (or no loop at all, for a one-shot agent that takes a single
input, runs, and terminates).

The shell is *deliberately boring*. Other than setting up state, it does
nothing interesting — and that is a feature. If a shell is getting
interesting, something in it probably belongs in a worker.

Whether repetition happens via an unsatisfied filter at the tail or via
`while pipe.shift do ... end` in the shell, the shell remains just environment
plus process. A human REPL is one shell; an autonomous email triager is
another; same architecture, different shells.

**A TUI is not a shell.** A TUI is much more interesting than a shell, and
should run in parallel with the pipeline (so it isn't blocked while the
pipeline works). This keeps UI concerns from colonizing the shell.

## Item-as-control, and its discipline

The conversation item both *is mutated by* workers and *directs their
behavior* (e.g. `finished?`, `tool_call?`, pending tool calls). This is the
mechanism that keeps the pattern in stock shifty — but it is a spectrum with a
poisoned end:

- **Pass-through-if-not-mine** — a worker acts only when the item is in its
  jurisdiction, else hands it along unchanged. Fine; same move
  `filter_worker` already makes. The topology still tells the truth.
- **Multi-way dispatch** — a worker that inspects item state and does one of
  several different jobs. A hidden pipeline folded into one worker; the
  diagram lies. **Named anti-pattern.**

**The discipline:** *an item may tell a worker **whether** to act, never
**which of several things** to do. If you're switching, you're missing a stage
(or a splitter).*

## Control granularity: filter-in by default

- **Filter-in** (as sketched): the shell's `shift` returns once per *turn*;
  all rounds happen inside the call.
- **Filter-out**: drop the tail filter; `shift` returns once per *round*, and
  the shell does its own re-enqueueing.

Observability is a non-question either way — logs, TUI updates, and traces are
side workers, spliceable anywhere, and the shell can always inspect the queue
in its own scope. The real difference is **intervention**: with filter-out,
the shell can act between rounds (e.g. human approval of tool calls).

But intervention doesn't require control to return to the shell. A worker
*closes over the shell's scope* (the shifty README's "wormhole effect"), so an
approval gate can be a side worker that calls out to whatever collaborator the
shell scope provides, blocking until answered.

**Scaffold default: filter-in.** The turn is the natural unit at the spine;
rounds are the circuit's internal rhythm. Round-granularity access is a
legitimate *rewiring* — same parts, different wiring — which is the
kit-of-parts promise kept.

## Known sharp edges (must be handled in scaffold + docs)

1. **The nil footgun.** In shifty, a source returning `nil` means *end of
   stream, forever*. An empty queue naturally returns `nil` from
   `rounds.shift` — so a shell that pulls at the wrong moment doesn't get an
   error; it permanently kills the pipeline. The scaffold must handle this
   deliberately (shell only shifts after enqueueing, or the source
   blocks/guards), and the docs must explain why.
2. **Runaway turns.** A model that never stops calling tools would cycle
   forever inside one `shift`. Guard: the item carries a round counter; a
   small guard worker marks the turn finished-with-error past a limit.
   Control data riding on the item — consistent with the discipline above.

## What the visualization shows

The circuit is depicted as a single node annotated with its loop condition
("loops until: no tool calls"); drilling in reveals a plain linear pipeline
with a marked back-edge (the re-enqueueing side worker) and exit (the filter).
A loop *annotation* on a node can be depicted honestly; an actual graph cycle
in a pull model cannot.
