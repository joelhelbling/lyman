# Design note: deployment — lyman as a pure generator

**Status:** accepted direction (pre-implementation)

## The problem

Lyman scaffolds *other projects*; it is not itself the thing users run. That
makes it rails-shaped at first glance: a globally installed gem used to create
and embellish client projects. But the rails analogy bundles two roles that
don't have to travel together:

1. **Generator** — `rails new`, the scaffolding tool.
2. **Runtime dependency** — the framework the app calls into forever.

The second role is in tension with lyman's core value. If
`Lyman::Workers.chat_completion` lives inside a gem, its guts are back inside
a box: users can read the source, but they can't casually splice into it the
way they can with code sitting in their own tree. "Guts on the outside" is a
claim about *whose tree the code lives in*, not just whether the source is
public.

## Shapes considered

| Shape | Verdict |
|---|---|
| **A. Conventional framework gem** — gem is both generator and runtime; client projects `require "lyman"` forever | Rejected. Every worker that lives in the gem is a seam that got harder to splice. The transparency promise erodes one convenience at a time. |
| **B. Template repository** — clone/fork a starter repo, no gem at all | Rejected. No upgrade story, no incremental `add`, no tooling seam for guidance. Fine for a demo; not a deployment model. |
| **C. Pure generator (the shadcn/ui model)** — the gem is a CLI that copies legible source into the client project, which the user then owns | **Accepted.** The framework is delivered as code you own — the deployment-shaped version of the design razor. |

Under shape C, the client project's only runtime dependency is `shifty`. There
is little or no `require "lyman"` at runtime; the lyman gem exists to plant,
diff, and update artifacts.

## The unit of upgrade is the unit of extraction

Copy-in's known trade-off is that copied code can't be `bundle update`d. The
answer is granularity: lyman plucks *modules* from its own codebase and plants
them as individual files, each tracked and upgraded independently.

This creates a forcing function that happens to point the same direction as an
existing principle. "The shell stays boring" was already the rule; now it has
teeth:

> Anything living inside the harness script is frozen the moment the user
> edits that script — and the user editing the harness is the *expected case*;
> it's their wiring diagram. Every behavior with any chance of shipping an
> improvement (a think-filter, `wire_messages`, a streaming printer) belongs
> in a planted module the harness merely references.

The harness script should asymptotically contain nothing but wiring: state
declarations, worker instantiation, the driving loop. If a module upgrade
would be blocked by a harness edit, the module was extracted at the wrong
boundary. Two design pressures — legibility and upgradeability — enforcing the
same rule is a sign the architecture is right.

The harness itself is **owned from day one**: planted once at `lyman new`,
marked owned in the manifest, never a target of `lyman update`. If a new
lyman version has a better harness shape, that ships as an advisory ("a new
example harness is available; see diff"), never a merge.

## The manifest

Comments in planted files ("managed by lyman — extend, don't modify") are
social signaling; the mechanism is a manifest written at plant time —
`.lyman/manifest.yml` — recording each managed artifact's source version and
content hash. `lyman update` then has three cheap cases per file:

- **Hash matches** — pristine; replace silently. Smooth sailing, verified
  rather than hoped-for.
- **Hash differs** — modified; halt with a message. Because lyman knows
  exactly which version it planted, it can show a real three-way diff
  (pristine-as-planted → user's copy, pristine-as-planted → new pristine)
  instead of "something changed."
- **Not in manifest** — user-owned; never touched.

Every entry also records the artifact's planted `path`. Artifact names are
logical identities (the changelog speaks in module names, and a name survives
upstream relocating a file); the path is where *this project's* copy lives.
Recording it keeps each entry self-describing — an entry for an artifact some
future lyman release renamed or dropped still names its file — and lets
lifecycle commands operate from the manifest alone, consulting the registry
only for what the current release would plant. The pristine cache mirrors the
planted tree (`.lyman/pristine/lib/lyman/…`), so neither store depends on
artifact names staying collision-free forever. When a release's destination
disagrees with the manifest's path, `update` halts rather than guessing which
references a move would break.

Per-artifact versioning falls out of the manifest for free: the changelog can
speak in terms of named modules ("`think_filter` 0.3 → 0.4: constructor now
takes…"), and `update` emits deprecation notices only for modules the project
actually has. Breaking changes to any planted artifact are therefore a
first-class release concern — a halt with a clear, specific message is the
contract that lets the programmer (and their coding agent) resolve breakage
before proceeding.

Namespacing reinforces the boundary visibly: `Lyman::` = managed, the
project's own namespace = owned. The line is legible in every constant
reference.

## Eject-to-own

"Don't modify, extend" must not read as glass over the guts. The guidance is
reframed from prohibition to **ownership transfer**: modifying a managed
module is legitimate — it means you've adopted it, and lyman stops managing
it. `lyman eject think_filter` makes the transfer an explicit verb rather than
a hash mismatch discovered later.

Ejection leaves a **tombstone record**, not a deleted entry:

```yaml
think_filter:
  status: ejected                  # was: managed
  ejected_at: 0.3.0                # lyman version when the dev took ownership
  path: lib/lyman/think_filter.rb  # where it was planted; the fork lives here
  pristine_hash: abc123            # hash of the pristine copy at ejection time
```

The tombstone buys three things a bare deletion can't:

1. **Advisories.** `lyman update` gains a third message tier: managed files
   upgrade, unknown files are ignored, ejected files get an informational
   notice — "`think_filter` (ejected at 0.3.0) has upstream changes in 0.5.0;
   run `lyman diff think_filter` to compare." No action, no halt; the dev or
   agent decides whether the upstream improvement is worth porting into their
   fork.
2. **A meaningful diff.** `ejected_at` is the fork point. Without it the only
   diff available is "upstream vs. your file," which mixes upstream's changes
   with the dev's. With it, `lyman diff` shows *only what upstream changed
   since the fork* — the same reason git tracks merge bases.
3. **Collision safety.** A later `lyman add think_filter` knows there's
   history and asks rather than clobbers.

Heritage lives in the manifest, not in the file's identity. Renaming or
re-namespacing an ejected file would sever exactly the thread that makes the
advisory possible, and break every reference in the harness for no gain. The
file stays where it is, named what it is; ejection changes only who the
manifest says maintains it.

Open detail (decide when the command exists): advisories should probably fire
once per new upstream version (a `notified:` field) rather than on every
`update`, so a long-lived fork doesn't nag forever.

## Guidance for coding agents

Deployment includes deploying *understanding* — shifty and lyman are not
complicated once you know how to use them, but how to use them is not obvious.
Three channels, ordered by reach:

1. **Scaffolded into the project.** `lyman new` emits a `CLAUDE.md` (or
   `AGENTS.md`) as a first-class artifact carrying the load-bearing facts: the
   nil-source footgun, the runaway-turn guard, item-as-control discipline,
   wire-vs-conversation separation. Highest-value channel: works with any
   coding agent, zero install steps, travels with the code. For projects that
   already have a `CLAUDE.md` lyman shouldn't clobber, the same guidance
   ships as an opt-in Claude Code skill (`lyman add claude_skill` plants
   `.claude/skills/lyman/SKILL.md`); `lyman add claude_md` points there when
   it refuses to overwrite an existing file. Opt-in artifacts (`optional:` in
   the registry) are skipped by `new` and reached with `add`.
2. **A Claude plugin marketplace** in the `joelhelbling/lyman` repo, for
   richer *procedures* — e.g. a skill that knows how to wire a new tool worker
   correctly, or how to read a stalled pipeline. Skills earn their keep when
   there's a procedure; facts belong in the scaffolded doc.
3. **Published docs / `llms.txt`** for indexing, so agents that installed
   nothing still find accurate usage docs rather than hallucinating a shifty
   API.

## Ruby without a type checker

Copy-in plus extension-over-modification is where statically typed languages
would catch contract drift at compile time. What replaces the compiler here:

1. **A tiny contract surface.** A shifty worker's interface is "take an item,
   yield an item." The real contract is the item shape — `Conversation` and
   its string-keyed messages. One class; most breaking changes will be changes
   to it, so compatibility care concentrates there.
2. **Errors designed for agents.** `lyman update` failures must be structured
   and specific ("`think_filter` modified since 0.3.0; pristine copy at …;
   diff: …") the way a compiler error names file, line, and expectation. A
   good error message is a type checker with one-round-trip latency.
3. **A runnable check.** `lyman doctor`: run the project's pipeline against a
   stub model transport and assert a well-formed `Conversation` comes out the
   other end. A smoke-level contract test `update` can run automatically
   post-upgrade — the closest thing to "it compiles" a duck-typed pipeline can
   offer.

Honest caveat: the manifest catches modified *files*, not broken *extensions*.
A subclass of a managed module can break when the parent changes even though
every hash matches. `doctor` is the backstop, and it's another reason managed
modules keep their public surfaces deliberately small and dull.

## Practical notes

- The `lyman` gem name is unclaimed on rubygems.org as of 2026-07-04; register
  early, even as a placeholder.
- No runtime `lyman chat` command. The moment the CLI *runs* harnesses rather
  than *generating* them, the shell stops being the user's visible loop.
- This repo pins Ruby via `mise.toml`; scaffolded projects should declare a
  looser constraint, and install docs should assume a user starting from zero
  Ruby tooling (the target user is "person with Ollama running," not
  necessarily a Rubyist).
