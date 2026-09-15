# Design note: fine-grained control of context

**Status:** accepted direction (pre-implementation)
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

## Order of work

1. Conversation as a series of identifiable elements, with the wire
   projection. Foundation.
2. SQLite conversation store with lineage and full-text index.
3. Wire-time abridgement policies.
4. Compaction sidecar.
5. Recall tool.
