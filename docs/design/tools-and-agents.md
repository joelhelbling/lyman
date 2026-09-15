# Design note: tools, and agents as tools

**Status:** accepted direction (pre-implementation)
**Tracked by:** the "tools" GitHub issues (tools convention, agent-as-tool,
file primitives, file reader agent, patch tool, patch agent)

## The problem

The harness ships one demo tool, declared inline. Lyman wants a scaffoldable
arsenal: tools a client project can plant with `lyman add`, some of which
are themselves agents — a dedicated model working a narrow job on behalf of
the root agent, so the root agent's context is spent on the answer rather
than on the raw material.

## Tools need a home

Tools keep the shape the harness already uses — schema and handler side by
side, guts on the outside — but move to one file per tool, declared in the
registry like any other plantable artifact, and picked up by the harness.
This comes before any particular tool.

## An agent-as-tool is a script shell inside a handler

A handler that builds a fresh conversation, runs a small circuit, and
returns the final answer *is* the script archetype (see
[harness-archetypes.md](harness-archetypes.md)) invoked in-process. That
single pattern underlies every agent below, so it is built once: its own
tool set, its own runaway guard, and a way for the outer display layer to
show nested activity. The file reader and the patch agent are two wirings
of it.

## File access

**Primitives** (plain handlers, no model):

- `search_files` — search a tree, restrictable by file name or glob,
  matching on content; returns paths with line hits.
- `read_file` — read a file, optionally by line range.

**The reader agent** takes a path or glob plus an optional query, uses the
primitives, and returns only what was asked. To avoid one agent that
switches on file type (the multi-way dispatch anti-pattern from
[circuit-pattern.md](circuit-pattern.md)), the *caller* names the result
shape it wants — excerpts with line ranges, a symbol outline, a prose
answer — and the agent has one job: extract to that shape.

**Routing rule.** Delegation costs a model call, so the question is when to
shortcut. The query is what decides, not file size:

- No query, and the path/glob resolves to a single file → return the file
  whole, whatever its size (there is nothing to extract *against*).
- A query is present → always go through the reader, even for a small
  file. A small file with a question still deserves the part of the file
  that answers it.

## Patching

**The patch tool** applies a patch to one file, then runs a configured
check command (e.g. `standardrb`, `eslint`) on the touched file and
returns its output. Two patch formats are supported, selected by
configuration:

- **search-and-replace blocks** (the default) — robust against models
  that can't reproduce exact context lines and line numbers;
- **unified diff** — for models that can; local models are improving
  quickly enough that this should be a switch, not a rewrite.

Language-server integration is deferred; the check command is the seam,
and an LSP client can be an alternate implementation of it later.

**The patch agent** accepts a collection of patches, applies them all,
checks, and then runs the tests. It may correct minor patch and check
failures inside a bounded fix loop (the existing round counter is the
bound). It must never attempt to fix a failing test — and that is enforced
structurally, not by prompt: the agent's circuit has only apply and check
tools; the tests run in a plain worker *after* the agent's circuit
finishes, so the agent cannot react to their outcome.

Results are structured — per-patch status and check output — and follow
"no news is good news": test output is included only when tests failed.

## Order of work

1. Plantable tools convention.
2. Agent-as-tool pattern.
3. File primitives.
4. File reader agent.
5. Patch tool.
6. Patch agent.
