# Harness Archetypes

Lyman ships three example harnesses. They are not three random examples —
they are **archetypes**: the three answers to the two questions every
agentic workflow must settle before any code is written:

1. **Where do work items come from?**
2. **When does the process end?**

Answer those and you've chosen your harness's *shell* — the enclosing scope
of state plus a driving process ([Core Concepts](Core-Concepts)). Everything
else — which model, which tools, what the items mean — is configuration
*within* an archetype.

## One circuit, three shells

The deep claim the trifecta exists to prove: **the circuit does not
change**. The model⇄tool pipeline is the same in all three harnesses (the
repl adds display side-workers; the daemon adds a logging side-worker —
splices, not rewiring). Every difference lives in the shell:

|                        | [REPL](The-REPL-Archetype) | [Daemon](The-Daemon-Archetype) | [Script](The-Script-Archetype) |
|------------------------|--------------------------|------------------------------|------------------------------|
| **Work items from**    | a human at a prompt      | an inbound event stream      | launch arguments or stdin    |
| **Driving process**    | `loop { read, enqueue, shift }` | `loop { accept, enqueue, shift, answer }` | no loop: enqueue, shift once, halt |
| **Ends when**          | the human leaves         | never (until killed)         | the one item is done         |
| **Human in the loop**  | yes — the human *is* the supplier | no (unless spliced in) | no                    |
| **Conversation state** | one, accreting turn by turn | fresh per event           | one, one turn                |
| **Output**             | streamed to the terminal | reply to the event's sender  | final answer on stdout       |
| **Launched by**        | a person                 | an init system, `&`          | cron, a Makefile, a script   |

That table *is* the design: three columns of shell decisions, zero rows
that touch the circuit.

## Choosing yours

- A person supplies work items interactively, and watches the answers →
  **[REPL](The-REPL-Archetype)**. Planted by `lyman new` as
  `harness/repl.rb`.
- Events arrive on their own schedule and the agent should run
  indefinitely → **[Daemon](The-Daemon-Archetype)**. Plant it with
  `lyman add daemon_harness`.
- The work item is known at launch and the process should end when it's
  done → **[Script](The-Script-Archetype)**. Plant it with
  `lyman add script_harness`.

Real agents are one of these far more often than they first appear. An
email triager is a daemon whose supplier polls IMAP. A nightly log
summarizer is a script launched by cron. A domain assistant is a repl with
domain tools. Start from the archetype, then change what it marks as
variable: the system prompt, the tools, the supplier (daemon), the output
channel (script).

## What stays the same in all three

- **The enqueue-before-shift rhythm.** A shifty source returning `nil` ends
  the stream permanently, so no shell ever pulls an empty queue.
- **The runaway guard.** `Conversation#max_rounds` bounds every turn — most
  load-bearing exactly where no human is watching (daemon, script).
- **Ownership.** All three harnesses are *owned* artifacts: planted once,
  yours from day one, never touched by `lyman update`. They're wiring
  scripts; editing them is the expected case.

## Mixing archetypes

The archetypes compose, because a shell is just scope + process. A daemon
whose events sometimes need human sign-off splices an approval-gate
side-worker into its circuit. A script that processes a backlog wraps its
enqueue-and-shift in a loop over items. When you find yourself designing a
shell shape that's genuinely none of the three, that's worth a design note —
the trifecta covers the ground we've needed so far, and new archetypes are
deliberately added as *documented examples*, not framework features.

Full design reasoning:
[docs/design/harness-archetypes.md](https://github.com/joelhelbling/lyman/blob/main/docs/design/harness-archetypes.md).
