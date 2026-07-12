# Design note: the harness archetypes — one circuit, three shells

**Status:** accepted (shipped with the repl, daemon, and script harnesses)
**Builds on:** [circuit-pattern.md](circuit-pattern.md) (the model⇄tool loop)
and the shell concept in [../vision.md](../vision.md)

## The claim these examples exist to prove

The vision document makes a structural claim: lyman is **turn-shaped, not
chat-shaped**. A human REPL is one shell; an autonomous email triager is
another; *same architecture, different shells*. One example harness can't
demonstrate that — a single example reads as "the way," and a chat example
reads as "lyman is a chat framework."

So lyman ships three harnesses. They are not three random examples; they are
**archetypes** — the three answers to the two questions every agentic
workflow must settle before any code is written:

1. **Where do work items come from?** (a human at a prompt, an inbound event
   stream, the launch itself)
2. **When does the process end?** (when the human leaves, never, when the
   item is done)

Everything else — which model, which tools, what the items mean — is
configuration *within* an archetype. The archetype is the shell shape.

## The invariant: the circuit does not change

Recall the two-part anatomy from the circuit-pattern note:

- The **circuit** is the linear pipeline that runs one work item to
  completion: source-from-queue → model call → finish-or-continue check →
  tool execution → re-enqueue-if-unfinished → only-finished-items-escape.
  N model⇄tool rounds happen inside a single `pipeline.shift`, driven by
  shifty's own demand semantics.
- The **shell** is the enclosing scope: state (the conversation, the `rounds`
  queue) plus a driving process. Deliberately boring.

Across all three shipped harnesses, **the circuit is the same pipeline**
(the repl adds display side-workers; the daemon adds a logging side-worker;
those are splices, not rewiring). What differs is entirely in the shell:

|                        | REPL (`harness/repl.rb`) | Daemon (`harness/daemon.rb`) | Script (`harness/script.rb`) |
|------------------------|--------------------------|------------------------------|------------------------------|
| **Work items from**    | a human at a prompt      | an inbound event stream (socket, queue, webhook) | launch arguments or stdin |
| **Driving process**    | `loop { read, enqueue, shift }` | `loop { accept, enqueue, shift, answer }` | no loop: enqueue, shift once, halt |
| **Ends when**          | the human leaves (blank line, ctrl-c) | never (until killed)   | the one item is done         |
| **Human in the loop**  | yes — the human *is* the supplier | no (unless spliced in) | no                           |
| **Conversation state** | one conversation, accreting turn by turn | fresh conversation per event | one conversation, one turn |
| **Output**             | streamed to the terminal as it happens | reply to the event's sender; log to stdout | final answer on stdout |
| **Launched by**        | a person                 | an init system, `ruby harness/daemon.rb &` | cron, a Makefile, another script |

That table *is* the design: three columns of shell decisions, zero rows that
touch the circuit.

## The archetypes

### REPL — human-in-the-loop-as-driver

The classic formula. The shell reads a line, enqueues the turn, shifts, and
repeats until the human ends it. Because the same human sees every answer,
the conversation **accretes**: the shell keeps one conversation binding
across the whole session, extending it with `with_user_message` on the way
into the circuit and rebinding to the finished turn that comes back
(`Conversation` is an immutable value — see
[immutable-conversation.md](immutable-conversation.md)).

The repl is also where a display layer earns its keep — a human is watching,
so the harness streams tokens, previews `<think>` blocks, and shows tool
calls as they happen. All of that lives in `harness/repl/` (one widget per
file, each an owned artifact), and its dependencies (cli-ui, reline) are
confined there: delete the display layer and the circuit doesn't notice.

### Daemon — launch once, loop on events

The shell starts an event supplier and loops forever: accept an event,
enqueue it, shift, deliver the answer back. No human is in the loop; the
model runs on its own recognizance, bounded by the same `max_rounds` guard
as every other harness. (A human *approval gate* can be spliced in as a side
worker that blocks on whatever collaborator the shell provides — see
"intervention" in the circuit-pattern note — but the archetype's default is
autonomy.)

The shipped daemon listens on a TCP socket, one line per event, because
that's stdlib and demoable with `nc`. **The supplier is this archetype's
variable**: a webhook server, an AMQP consumer, an IMAP poller, a filesystem
watcher — all daemon harnesses, differing only in the few lines that turn
"something arrived" into an enqueued work item. The circuit never knows
where events come from; only the queue does.

Each event gets a **fresh conversation** — a daemon's work items are
independent, so context doesn't accrete across them unless you decide it
should (a memory is a splice, not a default).

### Script — one work item, then halt

The shell is launched by something out of scope — cron, CI, a person who
wants one answer — and the work item arrives *with the launch*: `ARGV` or
stdin. Enqueue, shift once, print the final answer, exit. The exit code and
stdout are the interface, because the caller is a program.

The script archetype is the starkest demonstration that **repetition lives
in the pipeline, not the shell**: there is no loop anywhere in the file, yet
the model⇄tool circuit still runs as many rounds as the task needs, all
inside the single `pipeline.shift`.

## Shared sharp edges, per archetype

The library's sharp edges (see CLAUDE.md) show up in each shell in a
characteristic way — worth naming, because each archetype tempts a different
mistake:

- **The nil footgun** (a source returning `nil` ends the stream forever).
  All three shells obey the same rule: *enqueue before you shift*. The repl
  and daemon are tempted to shift inside their loops before anything
  arrived; the script's straight-line shape makes the ordering obvious —
  which is why it's the best archetype to read first.
- **Runaway turns.** The repl has a human who would notice a model stuck in
  tool-call loops; the daemon and script do not. The `runaway?` /
  `max_rounds` guard on `Conversation` is load-bearing in exactly the
  harnesses where nobody is watching.
- **Blocking vs. streaming.** The repl streams (`on_delta`) because a human
  is waiting; the daemon and script use the blocking transport because their
  consumers want the finished answer, not tokens. Same
  `Workers.chat_completion` seam either way.

## Choosing an archetype

Ask the two questions from the top:

- A person supplies work items interactively → **repl**.
- Events arrive on their own schedule, forever → **daemon**.
- The work item is known at launch and the process should end → **script**.

Then change the parts the archetype marks as variable: the system prompt,
the tools, the supplier (daemon), the output channel (script). The circuit
only needs rewiring when the *workflow* changes shape (approval gates,
fan-out, multi-model routing) — and then it's the same stock parts,
re-plumbed, per the circuit-pattern note.

## Deployment notes

- `lyman new` plants the **repl** — the archetype you can talk to sixty
  seconds after scaffolding. The daemon and script are opt-in artifacts
  (`lyman add daemon_harness`, `lyman add script_harness`): a narrow,
  purpose-built agent wants one shell shape, not three files two of which
  are dead weight.
- All three are **owned from day one** — wiring scripts, never targets of
  `lyman update`. Improvements to archetypes ship as new examples to
  `add`/`diff` against, never as merges into your harness.
- The daemon and script deliberately have **no display-layer dependencies**;
  they are stdlib + the planted `lib/lyman` modules. Only the repl pulls in
  cli-ui and reline, and only inside `harness/repl/`.
