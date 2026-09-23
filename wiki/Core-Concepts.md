# Core Concepts

Lyman has one paradigm: **a pipeline of workers**. Everything on this page
is that paradigm applied at a different level. If you hold onto four nouns —
*worker*, *item*, *shell*, *circuit* — every lyman harness will read like an
assembly diagram.

## Workers and pipelines (the shifty model)

[Shifty](https://github.com/joelhelbling/shifty) pipelines are **linear,
demand-driven pull chains**. You compose workers with `|`, and nothing runs
until someone calls `pipeline.shift` — then the *last* worker asks its
supplier for a value, which asks *its* supplier, all the way up to the
source. Data flows down only because demand flows up.

The worker vocabulary a harness actually uses:

| Worker | Job in a lyman harness |
|---|---|
| `source_worker` | produces items — in lyman, reads the queue in the shell's scope |
| `relay_worker` | transforms the item — the model call, tool execution |
| `side_worker` | observes (or re-enqueues) without changing the item — logging, display, the circuit's back-edge |
| `filter_worker` | lets only matching items through — the circuit's exit condition |

A pipeline can be treated as a single worker (shifty calls this a `Gang`),
which is how lyman composes pipelines out of pipelines without inventing
anything new.

## The item: a `Conversation`

What flows through the pipeline is a `Lyman::Conversation` — the **whole
conversation history so far** (a turn that didn't carry its history wouldn't
be a conversation), plus the control data workers consult:

- `finished?` — has this turn produced its final answer?
- `pending_tool_calls` — did the model just ask for tools?
- `runaway?` / `max_rounds` — the guard against a model that never stops
  calling tools.

A conversation is an append-only series of typed **elements**: system prompts,
user messages, reasoning blocks, assistant messages, tool calls, and tool
results. Each element carries the conversation's `id` (a UUID) and its `seq`
(sequence position, 1-based), so `conv:abc#17` names one element and
`conv:abc#17-23` names a range. Each element is itself an immutable value;
its `content` is a plain hash with **string keys**.

`Conversation` is an **immutable value** (a `Data` subclass): shifty 0.6
deep-freezes every value it hands across a worker boundary, so change is
expressed as *new* values — `with_user_message`, `with_assistant_message`,
`with_tool_result`, and `finish` each return a new conversation, and the
shell rebinds to what the pipeline hands back. Mutating an item inside a
worker raises `Shifty::PolicyViolation` naming the offender. (Closure state
inside a worker stays freely mutable — only handed-off values freeze:
"mutable within, immutable between." See
[docs/design/immutable-conversation.md](https://github.com/joelhelbling/lyman/blob/main/docs/design/immutable-conversation.md).)

The conversation also exposes a **projection back to OpenAI-style messages**:
`Conversation#messages` regroups elements into wire messages and keeps
reasoning elements for observability; `Conversation#wire_messages` does the
same but strips reasoning before anything goes out over the wire. This lets
code see and work with the full history (elements) or a specific view of it
(messages or wire messages) as the situation demands.

### The store: persistence as a splice, not a mode

`Lyman::Store` gives the element series a durable, queryable home — an
optional, opt-in artifact (`lyman add store`), not something `lyman new`
plants for you. It's a SQLite database (the only file in the plantable
library that requires the `sqlite3` gem — dependency isolation holds even
for a native-extension dependency) with two tables — `conversations`
(id, parent id, created at) and `elements` (conversation id, seq, type,
content) — plus a full-text index over each element's searchable text, so
a tool call is findable by its function name and arguments the same way a
message is findable by its words.

Wiring it in is one `side_worker`:

```ruby
store = Lyman::Store.new("conversations.db")
pipeline =
  source_worker { rounds.shift } |
  Lyman::Workers.chat_completion(base_url:, model:, tools:) |
  relay_worker { |c| (c.pending_tool_calls.empty? || c.runaway?) ? c.finish : c } |
  Lyman::Workers.tool_execution(handlers) |
  Lyman::Workers.store_append(store) |            # persists every round, finished or not
  side_worker { |c| rounds << c unless c.finished? } |
  filter_worker { |c| c.finished? }
```

`append` is idempotent — because elements are immutable and append-only,
it only ever inserts the elements beyond the highest `seq` already stored,
so re-appending a growing conversation never duplicates rows. Reading
back mirrors element addressing: `store.fetch("conv:abc#17-23")` and
`store.search("timezone bug")` both return `Element`s, and `search`
given a `conversation_id` follows `lineage` up through ancestor
conversations too — the same chain a future compaction step will use to
recover what a ledger entry summarized.

### Item-as-control, and its discipline

The item both *is transformed by* workers and *directs their behavior* —
that's what keeps the whole system in stock shifty parts. But it comes with one
rule, worth memorizing because it's the difference between a topology that
tells the truth and one that lies:

> **An item may tell a worker *whether* to act — never *which of several
> things* to do.** If a worker is switching between jobs based on item
> state, you're missing a stage (or a splitter).

## The shell: state + a process

Every harness has an enclosing scope — the **shell** — holding exactly two
things: **state** (the conversation, the queue) and **a driving process**
(usually a small loop; sometimes no loop at all). The shell is *deliberately
boring*: if a shell is getting interesting, the interesting part belongs in
a worker.

State lives in the shell **visibly** — the queue is declared right in the
wiring script, not smuggled inside the pipeline:

```ruby
conversation = Lyman::Conversation.new(system_prompt: "…")
rounds = []   # the circuit's queue — on the table, not in a box
```

Because workers are closures, any worker can reach state in the shell's
scope (shifty's "wormhole effect"). That's how a source reads the queue, and
how you'd splice in, say, an approval gate that consults something the shell
provides.

Crucially, lyman is **turn-shaped, not chat-shaped**: a human REPL is one
shell; an autonomous event-triager is another — *same architecture,
different shells*. That's the whole subject of
[Harness Archetypes](Harness-Archetypes).

## The circuit: a cycle with no loop in it

The agentic core of a turn is a cycle: call the model → *if it called
tools* → execute them → call the model again → … until it answers without
tool calls. But shifty is strictly linear — there are no back-edges. Lyman's
resolution is the **circuit pattern**, built from stock parts:

```ruby
pipeline =
  source_worker { rounds.shift }                                   | # reads the shell's queue
  Lyman::Workers.chat_completion(base_url:, model:, tools:)        | # one model round
  relay_worker { |c|
    (c.pending_tool_calls.empty? || c.runaway?) ? c.finish : c       # loop condition, on the item
  }                                                                |
  Lyman::Workers.tool_execution(handlers)                          | # runs requested tools
  side_worker { |c| rounds << c unless c.finished? }               | # the back-edge: re-enqueue
  filter_worker { |c| c.finished? }                                  # only finished turns escape
```

**The loop needs no loop.** When the shell calls `pipeline.shift`, the tail
filter pulls until it receives a *finished* turn. An unfinished round has
already been re-enqueued by the side worker; the filter rejects it and pulls
again; demand propagates back to the source, which finds the re-enqueued
item waiting. N model⇄tool rounds happen **inside a single `shift`**, driven
entirely by shifty's own demand semantics.

The cycle is a *pattern, not a primitive* — nothing was added to shifty to
make it work, which means every stage stays an ordinary, visible, spliceable
worker. Full reasoning:
[docs/design/circuit-pattern.md](https://github.com/joelhelbling/lyman/blob/main/docs/design/circuit-pattern.md).

## The sharp edges

Five facts that are load-bearing in every harness. They're also in the
`CLAUDE.md` planted into your project, so your coding agent knows them too.

1. **Frozen handoffs.** Shifty deep-freezes every value at a worker
   boundary; a worker that mutates its input raises
   `Shifty::PolicyViolation`. Build new conversations with the `with_*`
   methods and rebind shell state to what the pipeline returns — never
   mutate in place.
2. **The nil footgun.** In shifty, a source returning `nil` ends the stream
   *permanently*. An empty queue naturally returns `nil` from
   `rounds.shift` — so **enqueue before you shift**, always. Every shipped
   harness follows this rhythm; keep it when you rewire.
3. **Runaway turns.** With no guard, a model that keeps calling tools would
   cycle forever inside one `shift`. The round counter on `Conversation`
   (`runaway?` / `max_rounds`) is that guard — it matters most in the
   harnesses where no human is watching.
4. **Wire vs. conversation.** Reasoning elements stay on the conversation
   for observability but are stripped by `wire_messages` before any call to
   the model. A side effect — `messages` includes reasoning for debugging,
   while `wire_messages` never does. Preserve the separation if you touch
   message handling.
5. **Dependency isolation.** Each gem is confined to the single worker (or
   display widget) that needs it. The HTTP client lives in exactly one
   file; cli-ui lives only in the repl's display layer. Use your favorite
   libraries — such that only the worker requiring one knows it exists.

## Where the concepts come from

- [docs/vision.md](https://github.com/joelhelbling/lyman/blob/main/docs/vision.md) — principles, the design razor, architecture decisions
- [docs/design/circuit-pattern.md](https://github.com/joelhelbling/lyman/blob/main/docs/design/circuit-pattern.md) — the shapes considered and rejected before the circuit
