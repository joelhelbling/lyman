# Lyman — Vision

Lyman is a composable agentic harness — and a framework for building harnesses —
written in Ruby and built on the [shifty](https://github.com/joelhelbling/shifty)
gem.

This document captures *why* lyman exists, the values guiding its creation, the
architectural decisions made so far, and the questions still open. It is meant to
be a compass, not a spec. It should stay legible.

---

## Why lyman exists

Frontier models enjoy an enormous advantage that has nothing to do with their
weights: a massive user base feeding them usage data, context, and rapid
real-world validation. Anyone building their own agentic system on **open-weight
models — or models they train themselves — starts from a less mature place and
with far less data.**

For that builder, the one edge available is **iteration speed**. If experimenting
is cheap and fast, a small team can close a lot of the maturity gap through sheer
cycles.

**Lyman exists to make that iteration fast.** It targets the local-inference
sector: individuals and companies building narrow, purpose-built agentic
workflows on models they run or train themselves. The bet is that shifty's
pipeline model — flexible, composable, extensible — enables the rapid
experimentation this audience needs.

### The name

*Lyman*, as in the Lyman series — a nod to the physicist, and to the concept of
**redshift**, which in turn nods to the **Ruby** language and the **shifty** gem.
(A series is also, fittingly, a sequence of discrete lines — like a sequence of
pipeline stages.)

---

## Core principles

Two principles are the heart of lyman. Nearly every design decision should be
traceable to one of them.

### 1. Legibility — one paradigm, applied everywhere

Everything is a **pipeline of workers**. One mental model, used at every level.
Shifty is not widely known, so lyman should make the paradigm *easy to pick up*
rather than hiding it behind abstractions.

### 2. Guts on the outside — radical transparency

Nothing important should happen in a place you can't see, name, or splice into.
This is deliberately the opposite of the frontier-SDK ethos, where the agent loop
is a black box configured from the edges. In lyman, the workings are exposed.

### The design razor

When a decision is genuinely balanced, **favor the choice that lets a user see and
change behavior faster** — even at the cost of convenience or polish. For a
data-poor tinkerer, legibility and transparency are not aesthetics; they are what
makes fast iteration *possible*.

---

## Who lyman is for, and what it ships

- **A developer's tool.** Aimed at a Ruby developer willing to write worker blocks
  and wire pipelines. **Not a no-code tool.**
- **DSLs are used sparingly.** DSLs tend to obscure inner workings, which fights
  "guts on the outside." Convenience should not cost transparency.
- **Ships with at least one competent harness** that can be altered, extended, or
  wholly replaced — a strong starting point, not a cage.
- **A kit of parts you recombine.** Lyman is a set of swappable worker/gang parts
  plus **one legible pipeline-definition script** that wires them together. The
  pipeline file is legible *precisely because* the workers are defined elsewhere,
  not inline — it reads like an assembly diagram.
- **Scaffolding is a co-equal concept.** "Lyman gives you a working harness *and*
  the means to spin up new ones." With good docs/skills, agentic tools (e.g.
  Claude Code) should be able to author lyman harnesses easily.

---

## Architecture decisions so far

### Multiple pipelines, multiple item types

Lyman is not one pipeline; it is a **composition of pipelines**, each with its own
natural item type, nested or feeding into one another. Shifty's `Gang` — a
pipeline treated as a single worker — is the mechanism.

### The conversation spine

- The central pipeline's item is a **conversation turn**.
- A turn **carries the whole conversation so far** — otherwise it isn't a
  conversation.
- **Context-assembly asymmetry:** on the first turn there is no system prompt or
  prior history, so one is built just-in-time. On later turns, the new prompt is
  appended to the existing series and passed through. A single "context assembler"
  stage at the head of the spine can own this rule.

### State lives in the enclosing scope (the shell)

- One pass through the spine = **one turn**. When a turn finishes, the updated
  conversation (now including the reply) must survive until the next input.
- That state is held in the **shell** — the enclosing scope, a pattern that
  emerges naturally from shifty. A shell is **state + a process**: an
  environment holding the conversation, plus a driving process that is usually
  just a `while` loop (or none at all, for a one-shot agent). The shell is
  *deliberately boring* — if a shell is getting interesting, something in it
  probably belongs in a worker. Durability (disk/db) is then an **optional,
  splice-in side-worker**, not a built-in assumption.
- **Not chat-shaped — turn-shaped.** The spine must not hard-code a human
  REPL/TUI as its home. A human REPL is one shell; an autonomous agent (e.g. an
  email triager whose "turn" is an incoming email) is another. Human-in-the-loop
  and autonomous agents are *the same architecture with different shells.* A TUI
  is not a shell — it runs in parallel with the pipeline, so UI concerns don't
  colonize the shell.

### The LLM/tool cycle is its own gang

- Inference is a **swappable sub-pipeline, one level down** from the spine. From
  the spine's perspective, "produce the assistant's response for this turn" is one
  step — *whether that took one model call or nine is an internal detail.*
- The multi-step agentic loop (model → tool → model → …) lives **inside the
  circuit pattern** (see [design/circuit-pattern.md](design/circuit-pattern.md)):
  a linear sub-pipeline of stock shifty parts that churns until the model stops
  calling tools, then hands **one finished turn** back to the spine.
- Much of a tinkerer's work will happen on this sub-loop — so while it is
  encapsulated as one node to the spine, it must remain **fully inspectable and
  splice-able** on demand. Encapsulated by default, transparent when opened.

> **Note on encapsulation:** worker isolation tends to produce OO-like
> encapsulation of phases and responsibilities. This is an *observed emerging
> pattern*, not a design imperative. Do not over-index on it.

### Model transport

- **OpenAI-compatible endpoints** (Ollama, LM Studio, vLLM, llama.cpp, …) are the
  starting point — a de-facto industry standard.
- The transport itself is **just a swappable worker (or gang)**. Other transports
  are alternate implementations of the same seam.

### Tool calling

- Native tool calling is important and comes first.
- Support for models *without* native tool support (prompt-and-parse emulation) is
  **not an early priority** — but the tool-calling stage should be a **swappable
  worker/gang** so "native" and "emulated" are two implementations of one seam.
  This costs nothing now and avoids a later refactor.

### Dependency isolation

- Shifty's extreme worker isolation + Ruby's duck typing mean most dependencies
  are the concern of **a single worker or gang**.
- **Confine each dependency to the worker that needs it.** Use your favorite
  libraries, but in such a way that only the worker requiring one even knows it
  exists. This is dependency management in the spirit of "guts on the outside":
  each part carries its own guts; the pipeline stays clean.

### Topology as data (a lyman value-add on top of shifty)

For a workflow to be *depicted*, *scaffolded from*, or *reasoned about by another
tool*, lyman must be able to **describe its own topology as data** — its stages,
their names/tags, and their nesting into gangs — separately from executing it as
live fibers. Shifty gives `tags` and a `Roster`, but not a full introspectable
topology; providing one is a genuine lyman value-add.

This directly serves the **visualization vision**: a generated, ideally
interactive diagram of a workflow, where the whole LLM/tool loop shows as a single
node that a viewer can click to drill into its individual workers —
progressive disclosure of the same "encapsulated but inspectable" idea.

---

## Deferred / user-composed (not solved first)

These are real and valued, but lyman does not need to solve them up front — and in
many cases they are "just workers the user composes," consistent with the
multi-pipeline instinct.

- **Observability & tracing** — a lot is achievable with logging `side_worker`s.
  Not a first-order problem to solve.
- **Evaluation** — comparing models or measuring whether a change helped is
  valuable to the mission, but is user-composed / later.
- **Failure, retry, fallback, rollback** — shifty provides little here by design;
  these are workers the user composes (e.g. "model timed out → try the smaller
  local model"). An idea under rumination: **immutability** as an enabler of
  rollback. Logged as a thought, not a commitment.
- **Streaming** — an attractive nice-to-have (esp. for a TUI). Feedback to a UI can
  likely ride on a `side_worker`. How token streaming best fits shifty's
  one-item-at-a-time paradigm needs its own examination.

---

## Non-goals

- **Not a no-code tool.**
- **Not chasing parity** with frontier-model harnesses or popular tools (OpenCode,
  etc.) for parity's sake. Lyman will not brag about feature checklists.
- **Not trying to abstract over every provider's quirks** as a headline goal.
- Bundled integrations may come **much, much later** — worth considering, but not
  the point now.

**What lyman *does* focus on:** rapidly building a **narrow, purpose-built agentic
workflow tailored to the specific problems it solves and the specific models it
uses.** Shifty opens a vast solution space that lyman need not ship, because people
will find it easy to build those solutions *with* lyman.

---

## Open questions

1. ~~**Cycles in a linear-pull model.**~~ **Resolved** — see
   [design/circuit-pattern.md](design/circuit-pattern.md). The model⇄tool cycle
   is the **circuit pattern**: stock shifty parts (source-from-queue,
   splitter/batch fan-out/fan-in, side-worker back-edge, filter-worker loop
   condition), with the queue living visibly in the shell's scope. No third
   primitive; N rounds happen inside a single `shift` via shifty's own demand
   semantics. Includes the item-as-control discipline: *an item may tell a
   worker whether to act, never which of several things to do.*
2. **Streaming in the pipeline paradigm** (see above).
3. **Immutability / rollback** — is there a clean way to give workflows rollback
   semantics, possibly via immutable items?
