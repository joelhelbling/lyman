# Immutable Conversation: adapting to shifty 0.6 frozen handoffs

Shifty 0.6.0 changed what crosses a worker boundary. Under the new default
handoff policy (`:frozen`), every value a worker receives is deeply frozen
via `Ractor.make_shareable` at intake; a task that mutates its input raises
`Shifty::PolicyViolation` at the offending worker. Per-worker escape hatches
exist (`policy: :isolated` for a private scratch copy, `policy: :shared` for
raw pre-0.6 references), and a global opt-out reproduces 0.5 behavior.

## The decision

`Conversation` became an immutable value, and no worker declares a policy.
This is shifty's own preferred migration path (rewrite non-destructively),
and it wins on lyman's design razor — whatever lets a user see and change
behavior faster:

- **Policy declarations are the second paradigm.** A pipeline where some
  workers carry `policy: :shared` and some don't makes handoff semantics a
  per-stage thing a reader must track. With an immutable item, every handoff
  means the same thing everywhere.
- **Silent aliasing was the circuit's real risk.** The circuit re-enqueues
  the item back into shell scope; a mutable conversation is shared between
  the queue, the shell binding, and whatever a spliced-in worker holds onto.
  Frozen handoffs turn that class of bug into an immediate, named error.
- **`:shared` restores exactly the protection-free semantics 0.6 exists to
  end** — the escape hatch stays reserved for genuinely uncopyable values
  (IO handles, procs), which the conversation is not.

## The shape

`Conversation < Data.define(...)` — Ruby's stdlib immutable value, the
idiom shifty's own docs recommend. `Data#with` allocates one new outer
object and structurally shares unchanged members between old and new
values; that sharing is safe precisely because handed-off values are
frozen. The two mechanisms are a matched set, and the per-handoff freeze
traversal only visits structure created since the last handoff, so the
combination stays cheap.

Consequences, visible in the code:

- Mutators became `with_*` methods returning a new conversation:
  `with_user_message`, `with_assistant_message`, `with_tool_result`, and
  `finish` (no bang — nothing mutates). `Data#with` remains public for
  splicing in custom state.
- The round counter moved into `with_assistant_message`: a round *is* one
  model reply, so counting it there means a swapped-in transport cannot
  forget the runaway guard.
- Workers hand off what they build: `chat_completion` and `tool_execution`
  return `conversation.with_*(...)` results instead of returning a mutated
  input. Their internal message assembly (streaming deltas accumulating
  into a hash) is untouched — closure and local state stay freely mutable;
  the freeze happens at handoff. "Mutable within, immutable between."
- The shell rebinds instead of mutating: `harness/chat.rb` enqueues
  `conversation.with_user_message(input)` and then does
  `conversation = pipeline.shift`. Turn state flowing back to the shell is
  now an explicit assignment sitting in the wiring script — state lives in
  the shell's scope, visibly.

## What to watch when adding workers

- Never mutate the item; build a new one (`with_*`, `Data#with`, `merge`,
  `+`). A `PolicyViolation` names the worker and object if you slip.
- A builder that keeps a reference to what it handed off will find it
  frozen — hand off snapshots (`dup`, `join`, `with(...)`), keep the live
  accumulator private.
- Unshareable values (IO, procs, lazy enumerators) cannot cross a default
  boundary; if a worker must pass one, declare `policy: :shared` on that
  worker and say why in a comment.
- `Shifty::Testing.mutates_input?(worker, input)` (opt-in
  `require "shifty/testing"`) is the mutation detector — use it when
  vetting a worker whose task you don't fully control.
