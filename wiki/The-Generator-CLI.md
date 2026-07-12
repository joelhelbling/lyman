# The Generator CLI

Lyman is delivered as a **pure generator**, in the spirit of shadcn/ui: the
gem's whole job is to plant legible, manifest-tracked source into *your*
project — and then get out of the way. Your harness's only runtime
dependency is `shifty`; there is no `require "lyman"` at runtime and no
framework to call into.

Why this shape? "Guts on the outside" is a claim about *whose tree the code
lives in*, not just whether source is public. Code inside a gem can be read
but not casually spliced; code in your own tree can be both. The full
reasoning is in
[docs/design/deployment.md](https://github.com/joelhelbling/lyman/blob/main/docs/design/deployment.md).

## The commands

```sh
lyman new my-agent       # scaffold a project: harness, workers, manifest
lyman list               # every artifact lyman knows, and this project's status
lyman add ARTIFACT       # plant one artifact this project doesn't have yet
lyman update             # refresh pristine managed modules; halt (never clobber) on modified ones
lyman diff ARTIFACT      # your changes, and upstream's since you planted
lyman eject ARTIFACT     # take ownership; lyman stops managing it
lyman doctor             # smoke-test the pipeline against a stub transport
lyman version
```

Commands accept an artifact **name or its path** — `lyman diff
conversation` and `lyman diff lib/lyman/conversation.rb` are the same
command, so you don't have to remember the token while looking at the file.

## Managed, owned, ejected

Every planted file falls on one side of a visible boundary, recorded in
`.lyman/manifest.yml` (commit it):

- **Managed** — the `Lyman::` library modules (`lib/lyman/**`).
  `lyman update` refreshes them from newer releases. Extend, don't edit.
- **Owned** — yours from day one: the harness scripts, the repl's display
  widgets, `CLAUDE.md`, the `Gemfile`. `update` never touches them. The
  namespace *is* the boundary: `Lyman::` = managed, your namespace = owned.
- **Ejected** — a managed module you took ownership of, explicitly:

  ```sh
  lyman eject conversation
  ```

  Modifying a managed module isn't forbidden — it's *adoption*, and eject
  makes the transfer a verb instead of a surprise. The manifest keeps a
  tombstone (when you forked, from which version), which buys you
  advisories: when upstream later improves an ejected module, `lyman
  update` tells you once — "run `lyman diff` to compare" — and the choice
  of whether to port the improvement into your fork stays yours.

## How `update` stays safe

The manifest records each managed artifact's planted version and content
hash, so `update` has three cheap cases per file:

- **Hash matches** → pristine; replaced silently.
- **Hash differs** → you modified it; **halt** with a structured message
  (and a real diff against the pristine copy kept in `.lyman/pristine/`),
  never a clobber, never a merge.
- **Not in the manifest** → not lyman's; never touched.

The unit of upgrade is the unit of extraction: lyman plants *modules*, each
tracked and upgraded independently, which is exactly why the harness script
itself can be owned outright — everything upgrade-worthy lives in a planted
module the harness merely wires together.

## Artifacts worth knowing about

`lyman list` shows the full registry. Highlights:

| Artifact | What / why |
|---|---|
| `repl_harness` | the REPL archetype — planted by `new`, owned |
| `daemon_harness` | the [daemon archetype](The-Daemon-Archetype) — opt-in: `lyman add daemon_harness` |
| `script_harness` | the [script archetype](The-Script-Archetype) — opt-in: `lyman add script_harness` |
| `conversation` | the item that flows through pipelines — managed |
| `chat_completion` | the model transport; the only file that knows HTTP exists — managed |
| `tool_execution` | executes pending tool calls — managed |
| `claude_md` | guidance for coding agents working in your project — owned |
| `claude_skill` | the same guidance as a Claude Code skill, for projects that already have a `CLAUDE.md` lyman shouldn't clobber — opt-in |

## `lyman doctor`

Runs your project's actual planted pipeline — real tool execution, real
requeue plumbing, real finished-turn filter — with a stub standing in at the
model-transport seam, and asserts a well-formed `Conversation` comes out.
No model server needed. It's the closest thing to "it compiles" a
duck-typed pipeline can offer; run it after every `update`.

## For coding agents

Scaffolded projects carry their own guidance: `CLAUDE.md` (or the
`claude_skill` variant) states the managed/owned boundary and the four
load-bearing facts from [Core Concepts](Core-Concepts), so a coding agent
working in your project respects the same lines you do.
