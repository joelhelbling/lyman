# Design note: fine-grained control of context

**Status:** accepted direction; part 1 (elements, issue #8) is implemented
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

SQLite, confined to one store worker (dependency isolation). Two tables —
`conversations` (id, parent id) and `elements` (conversation id, sequence,
type, JSON content) — plus a full-text index on content. A side worker
appends elements as they flow through the circuit.

A **recall tool** lets the model re-expand what a ledger entry points at:
query by conversation id, element range, or text, walking the ancestor
chain. Over-compaction is thereby redressable rather than fatal. This tool
is the bridge to the tools direction described in
[tools-and-agents.md](tools-and-agents.md).

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
  native-extension gem in the plantable set.

## Order of work

1. Conversation as a series of identifiable elements, with the wire
   projection. Foundation.
2. SQLite conversation store with lineage and full-text index.
3. Wire-time abridgement policies.
4. Compaction sidecar.
5. Recall tool.
