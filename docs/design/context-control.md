# Design note: fine-grained control of context

**Status:** accepted direction; parts 1 (elements, issue #8), 2 (store,
issue #9), 3 (abridgement, issue #10), and 5 (recall tool, issue #12) are
implemented. Part 4 (compaction sidecar, issue #11) is not done yet.
**Tracked by:** the "context control" GitHub issues (elements, store,
abridgement, compaction sidecar, recall tool)

## The problem

A conversation grows until it no longer fits the model's context, and the
usual remedy — summarize everything and start over — is slow (it happens
at the worst moment, blocking the turn) and lossy (whatever the summary
dropped is gone). Lyman wants the opposite on both counts: compaction that
is ready *before* it is needed, and compaction that never destroys the
original, so anything abridged away can be recovered.

Two ideas fall out of that, and they turn out to be one feature with two
halves: a **persistent, indexed conversation store** is the substrate, and
**compaction** is a derived conversation whose entries link back into it.
Links need addresses, so the store — or at minimum stable identity — comes
first.

## Elements, not messages

Today a `Conversation` is a list of wire-shaped message hashes. One
assistant message bundles its text, its reasoning, and every tool call it
made. That is too coarse to abridge selectively.

The storage form becomes a flat, append-only series of typed **elements**:

| element | one per… |
|---|---|
| `system` | system prompt |
| `user` | user message |
| `reasoning` | reasoning/thinking block |
| `assistant` | assistant text |
| `tool_call` | *each* tool call |
| `tool_result` | *each* tool result |

Every element carries the conversation's id and its sequence position, so
`conv:abc#17` names one element and `conv:abc#17-23` names a run of them.
A conversation lies where it falls: elements are never revised or
rearranged. Immutability was already the rule (see
[immutable-conversation.md](immutable-conversation.md)); identity makes it
addressable.

### Shapes

Each element's `content` is a string-keyed hash — `{"text"=>...}` for
system, user, reasoning, and assistant; the raw tool call hash for
tool_call; `{"tool_call_id"=>..., "text"=>...}` for tool_result. Sequence
numbers are 1-based.

Every model reply decomposes to an optional reasoning element, exactly one
assistant element, then one tool_call element for each tool call — in order
received. This structure makes the regrouping back onto OpenAI-style
messages unambiguous: a single assistant message carries its tool calls
back in their original order.

The OpenAI-compatible message list becomes a **projection**: elements are
regrouped into wire messages (reasoning stripped, a reply's tool calls
gathered back onto one assistant message). This generalizes the existing
wire-vs-conversation split into a general notion of a *view* of the
series, which is the hook everything below hangs on.

## Two kinds of reduction, kept apart

**Abridgement** is deterministic and needs no model. Examples: suppress
`reasoning` elements from turns before the current one; condense
`tool_result` elements older than a couple of rounds to a one-line stub.
These are *wire-time projection policies*, not new conversations: the
series is untouched, nothing is stored, and the policy is a plain object
the harness chooses. Cheap, instant, and the first thing to reach for.

**Compaction** needs a model, and produces a **new conversation** with a
`parent` pointer to the one it compacted. Its body is a **ledger** rather
than a prose block — entries such as facts established, decisions taken,
open items — where each entry carries the ids of the source elements it
summarizes. A ledger stays stable as it is extended step by step, and a
single entry can legitimately collapse many elements (with many
backlinks). Iterative compaction is just a longer ancestor chain.

A compacted conversation should by default keep a short verbatim tail —
the most recent turn — after the ledger, since the model usually needs the
immediate exchange intact.

### Abridgement policies

`Lyman::Abridgement` (`lib/lyman/abridgement.rb`, stdlib only) is the first
half made concrete. The protocol is deliberately thin: a policy is any
object responding to `call(conversation) -> conversation`, plain lambdas
included. Calling it returns a *view* — the same conversation with
`elements` substituted (`conversation.with(elements: ...)`), never the
conversation mutated and never a new one stored. `Lyman::Workers.chat_completion`
builds the view, projects it to wire messages, and discards it; the reply
it appends goes onto the **original** conversation, so an abridged-away
element is still there — a stand-in only ever hides it from this one wire
call. Stand-ins keep their `conversation_id`, `seq`, and `type`, so an
address taken before or after abridgement still means the same thing.

Two policies ship, plus two combinators:

- `Lyman::Abridgement::SuppressPriorReasoning.new` drops `reasoning`
  elements belonging to turns before the current one (the current turn is
  everything after the last `user` element; with no `user` element yet,
  nothing is dropped). Reasoning is usually only useful to the model that
  produced it, in the turn it produced it — carrying yesterday's scratch
  thoughts forward mostly just spends tokens.
- `Lyman::Abridgement::StubToolResults.new(keep_rounds: 2)` replaces
  `tool_result` elements older than `keep_rounds` model replies with a
  one-line stand-in — `{"tool_call_id" => ..., "text" => stub}` — naming
  the tool, the original size, and the original element's `address` (e.g.
  `"[abridged: current_time result, 1234 chars — conv:abc#12]"`). That
  address is exactly what the recall tool (issue #12) uses to
  re-expand it, so abridging a tool result is a wire-time compression, not
  a decision to forget it. A stub is only used when it's actually shorter
  than the original text; a `nil` result is left as is. `keep_rounds` must be at least 1 —
  a result with no reply after it is one the model hasn't seen yet, so
  stubbing it would leave the model acting on a stub it can't expand.
- `Lyman::Abridgement.chain(*policies)` returns a lambda that applies
  policies left to right, so composing reductions is just listing them.
- `Lyman::Abridgement.over_budget(max_prompt_tokens, policy)` returns a
  lambda that applies `policy` only when the conversation's `prompt_tokens`
  (see below) is known and over the threshold — otherwise the conversation
  passes through unchanged. This is the item telling a stage *whether* to
  act, never *which* policy to run; the gating stays a plain conditional
  a harness can read at a glance, not a mode hidden inside a worker.

None of this needs a model, which is why it's the first thing to reach for:
it's synchronous, free, and reversible by construction (the series it
projects from is never touched).

#### Usage stamping

A policy that reacts to context pressure needs to know the pressure exists.
The transport already gets told: OpenAI-compatible chat completions
responses report `usage` (`prompt_tokens`, `completion_tokens`,
`total_tokens`). `Conversation` now carries that raw hash as `usage`
(string keys, nil until a reply has landed), with `with_usage` to set it
and `prompt_tokens` as the one field `over_budget` needs. It's control
data, not series — the store doesn't persist it, and `with_user_message`
deliberately leaves it alone, because the last report is still the best
estimate of context size going into the *next* turn. The one thing to keep
in mind: usage always lags one request — it describes the prompt that was
*just* sent, not the one about to be. `over_budget` is still a useful gate
on that basis; it just can't be exact about the turn in flight. And since
the report describes the request as sent — already abridged, if the gate
fired — a policy that pulls the prompt back under budget turns itself off
again the next round. Set the threshold with headroom below the real limit.
Streaming responses omit usage unless asked, so a streaming
`chat_completion` sends `stream_options: {include_usage: true}` and picks
the report off the final chunk.

#### Reasoning back on the wire

`wire_messages` still strips reasoning by default — some providers (e.g.
DeepSeek) reject it on input, so "off unless asked" stays the safe
default. But interleaved-thinking local models (gpt-oss, qwen3) expect
their own current-turn chain of thought back between tool calls, so
`chat_completion(..., send_reasoning: true)` passes `reasoning: true` into
`wire_messages`, riding each assistant message's `"reasoning"` key. Turn
this on paired with `SuppressPriorReasoning` — otherwise every earlier
turn's thoughts ride along too, defeating the point.

A harness wires a policy in visibly, the same way it wires anything else:

```ruby
# ── Context policy: what each round shows the model ─────────────────────────
# The conversation keeps every element; this only shapes the wire projection.
# Swap, chain (Lyman::Abridgement.chain), or drop it — nil sends everything.
abridgement = Lyman::Abridgement::StubToolResults.new(keep_rounds: 2)
```

and then `Lyman::Workers.chat_completion(..., abridgement: abridgement)`.

## The compactor is a sidecar shell

Compaction is prepared *all the time*, so that when it is called for it is
nearly instant. In lyman terms the compactor is a **daemon archetype
harness** (see [harness-archetypes.md](harness-archetypes.md)) running in
its own thread:

- A `side_worker` spliced into the main circuit pushes each new element
  onto a queue. That is the sidecar's entire footprint in the root circuit.
- The compactor thread runs its own small circuit against a small, fast
  model, consuming elements and maintaining the ledger.
- When the root agent asks for compaction, the compactor drains whatever
  is still queued, renders the ledger (plus tail) into a new conversation,
  and hands it back. The root shell rebinds and proceeds.

Two things come for free. Shifty 0.6's frozen handoffs make sharing
elements across threads safe without locks. And a "compaction strategy" is
simply which compactor shell was wired in — alternate strategies are
alternate wiring scripts, not modes of one component.

The root agent otherwise stays in its own conversation. Nothing is swapped
in until an abridgement policy or a compaction is deemed necessary; the
transport's `usage` report is the natural input for that decision, and
"over budget?" is a clean whether-to-act stage.

## Store and recall

`Lyman::Store` (`lib/lyman/store.rb`) is the persistent side of the
element series, and the only file in the plantable library that requires
the `sqlite3` gem — dependency isolation applied to a native-extension
dependency for the first time in the plantable set. `Store.new(path)`
opens (and creates, if needed) a SQLite database at a file path or
`:memory:`.

Two tables carry the schema described above almost verbatim: `conversations`
(`id`, `parent_id`, `created_at`) and `elements` (`conversation_id`, `seq`,
`type`, `content` as JSON), keyed on `(conversation_id, seq)`. An FTS5
table, `element_text`, indexes each element's searchable text — the text
itself for `system`/`user`/`reasoning`/`assistant`/`tool_result`, and the
function name plus arguments for `tool_call` — so `search` works without
the caller thinking about how a tool call differs from a message.

`append(conversation)` is **idempotent**: it records the conversation row
once, then inserts only the elements whose `seq` is beyond what's already
stored. Because elements are immutable and append-only, "beyond the
highest stored seq" is an exact test, not a heuristic — calling `append`
repeatedly on a growing conversation, or replaying the same round, never
duplicates a row. That's what makes the store safe to splice into the
circuit as a plain side worker rather than something with its own
buffering or dedup logic.

The read side mirrors element addressing: `conversation(id)`,
`elements(id, range = nil)`, `element(id, seq)`, and `fetch(address)` —
where `address` is what `Element#address` produces (`"conv:abc#17"`),
widened to a whole conversation (`"conv:abc"`) or a run
(`"conv:abc#17-23"`), so a value read out
of a ledger entry round-trips straight back into a store lookup with no
translation layer. `search(query, conversation_id: nil, limit: 20)` takes
plain words rather than FTS syntax, ranked by SQLite's `bm25`; given a
`conversation_id` it searches that conversation *and its ancestors*, so a
search from inside a compacted conversation still finds material that was
compacted away. `lineage(id)` returns the ancestor chain
(`[id, parent, grandparent, …]`) that both `search` and, later, the
recall tool walk. `load(id)` rebuilds a full `Lyman::Conversation` from
its stored elements. Only the series and its lineage are durable: a loaded
conversation starts with fresh control state (`rounds` 0, not finished),
ready for a new user message — a turn isn't resumable mid-turn.

`parent_id` therefore lives on `Conversation` itself (default `nil`), not
bolted onto the store schema alone — it's the compaction lineage pointer
a compacted conversation uses to name the one it compacted, and the store
just persists it. Identity and lineage are conversation-level concepts;
the store is one place (of potentially several) that can persist them.

Wiring the store in is a `side_worker`, `Lyman::Workers.store_append`,
spliced after `tool_execution` and before the finished filter so it sees
every round, including the one that finishes the turn:

```ruby
store = Lyman::Store.new("conversations.db")
pipeline =
  source_worker { rounds.shift } |
  Lyman::Workers.chat_completion(base_url: BASE_URL, model: MODEL, tools: schemas) |
  relay_worker { |c| (c.pending_tool_calls.empty? || c.runaway?) ? c.finish : c } |
  Lyman::Workers.tool_execution(handlers) |
  Lyman::Workers.store_append(store) |
  side_worker { |c| rounds << c unless c.finished? } |
  filter_worker { |c| c.finished? }
```

`store_append` never mentions sqlite — it calls `store.append(conversation)`
against whatever object it's given, so a fake or an alternate store
implementation stands in without the worker changing. Durability is
therefore an opt-in splice, not a built-in assumption: the shipped
harnesses stay stdlib-only, and a developer who wants a store adds it to
their own wiring script with `lyman add store` / `lyman add store_append`.

**The recall tool** (`Lyman::Tools.recall`, `lib/lyman/tools/recall.rb`,
issue #12) lets the model re-expand what a stub or a ledger entry points
at. It follows the plantable tools convention (docs/design/tools-and-agents.md):
a factory taking its dependency as a keyword argument —
`Lyman::Tools.recall(store:, max_chars: 8000)` — self-contained and
stdlib-only itself, since `store` is duck-typed (anything answering
`fetch(address)` and `search(query, conversation_id:, limit:)`) rather
than required to be `Lyman::Store`. The model can pass an `address`
(`"conv:abc"`, `"conv:abc#17"`, `"conv:abc#17-23"`) to re-expand exactly
what a stub or ledger entry names, or a plain-word `query` (optionally
scoped to a `conversation_id`, which walks that conversation's ancestor
chain via the store's `lineage` the same way `search` does) when it
doesn't have an address to hand. Output is rendered as one block per
element — its address, type, and text — and capped at `max_chars`
(default 8000): a recall of a whole conversation must not blow the very
context the abridgement was protecting, so an over-wide result is
truncated with a note telling the model to ask again with a narrower
range. Over-compaction is thereby redressable rather than fatal.

Registered as `recall_tool` (`optional: true`, since a fresh scaffold has
no store yet, and `needs: ["store"]`, so `lyman add recall_tool` advises
`lyman add store` if it isn't planted). Wiring a harness with a store
looks like:

```ruby
store = Lyman::Store.new("conversations.db")

TOOLS = [
  Lyman::Tools.current_time,
  Lyman::Tools.recall(store: store)
]

# ...spliced into the circuit so the store actually gets what recall reads back:
pipeline =
  source_worker { rounds.shift } |
  Lyman::Workers.chat_completion(base_url: BASE_URL, model: MODEL, tools: schemas) |
  relay_worker { |c| (c.pending_tool_calls.empty? || c.runaway?) ? c.finish : c } |
  Lyman::Workers.tool_execution(handlers) |
  Lyman::Workers.store_append(store) |
  side_worker { |c| rounds << c unless c.finished? } |
  filter_worker { |c| c.finished? }
```

## Developer experience: what changes, and what it costs

These notes should drive the README and wiki updates that accompany each
issue as it lands — the documentation change is part of the change.

What gets better:

- **Conversations become something you can point at.** Today a conversation
  is a list of hashes inspectable only by index. With elements and
  addresses, a developer can name a reasoning block or a single tool
  result, log it, query it, or hand it to a tool. Debugging changes most:
  "what did the model see on round three" becomes a query against the
  store instead of a print statement placed in advance.
- **Context management is a wiring choice, not a mode.** An abridgement
  policy is an object picked when wiring the chat completion worker;
  compaction is a sidecar shell spliced in with one side worker. A
  developer who wants no context management still gets today's plain
  circuit. This is "guts on the outside" extended to the part of agent
  frameworks that is usually most hidden.
- **Compaction stops being a stall.** Because the ledger is kept
  continuously, a compaction request is a drain and a handoff, not a full
  summarization pass — removing the worst pause in a long local-model
  session.
- **Losing context stops being permanent.** The recall tool and the
  ancestor chain make an over-aggressive compaction a recoverable mistake,
  which lowers the stakes of experimenting with compaction strategies —
  exactly the experimentation lyman wants to invite.

What it costs, stated plainly:

- **A breaking change to the conversation shape.** Anything reading
  messages directly — the repl's printers included — must move to elements
  or the wire projection. The elements issue is small in concept but
  touches everything.
- **A second model and a thread.** The compactor needs a fast model running
  alongside the main one, and a thread with a request-and-handoff
  protocol. Both are new kinds of thing in a codebase that has so far been
  single-threaded and single-model.
- **A SQLite dependency.** Confined to one worker, but the first
  native-extension gem in the plantable set. And because the planted
  entry point (`lib/lyman.rb`) requires every planted module, planting the
  store means nothing loads — harness or `lyman doctor` — until the client
  Gemfile gains `sqlite3` and `bundle install` runs. `lyman add store`
  says so up front.

## Order of work

1. Conversation as a series of identifiable elements, with the wire
   projection. Foundation. **Done** (issue #8).
2. SQLite conversation store with lineage and full-text index. **Done**
   (issue #9).
3. Wire-time abridgement policies, plus usage stamping so a policy can
   gate on context pressure. **Done** (issue #10).
4. Compaction sidecar.
5. Recall tool. **Done** (issue #12).
