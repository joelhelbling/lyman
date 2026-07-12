# Lyman

**A composable agentic harness — and a framework for building harnesses — in
Ruby, built on [shifty](https://github.com/joelhelbling/shifty).**

Lyman is for people building agentic workflows on models they run
themselves: open-weight models on Ollama, LM Studio, vLLM, llama.cpp — or
models they've trained. For that builder, the one real edge is **iteration
speed**, and lyman exists to maximize it.

Two principles drive every design decision:

1. **Legibility.** One paradigm — a pipeline of workers — applied everywhere,
   at every level.
2. **Guts on the outside.** Nothing important happens anywhere you can't
   see, name, or splice into. This is deliberately the opposite of the
   frontier-SDK ethos, where the agent loop is a black box you configure
   from the edges.

And a razor for when those principles are in tension with convenience:
**favor whatever lets a user see and change behavior faster.**

## Where to go

| If you want to… | Read |
|---|---|
| Scaffold a project and talk to a local model in five minutes | [Getting Started](Getting-Started) |
| Understand the pipeline, the item, the shell, and the circuit | [Core Concepts](Core-Concepts) |
| Pick the right shape for *your* agent | [Harness Archetypes](Harness-Archetypes) |
| Walk through the interactive harness | [The REPL Archetype](The-REPL-Archetype) |
| Walk through the event-driven harness | [The Daemon Archetype](The-Daemon-Archetype) |
| Walk through the run-once harness | [The Script Archetype](The-Script-Archetype) |
| Understand `lyman new/add/update/eject/diff/doctor` | [The Generator CLI](The-Generator-CLI) |

## The idea in six lines

An agent harness is a pipeline. Not as a metaphor — literally:

```ruby
pipeline =
  source_worker { rounds.shift }                                             |
  Lyman::Workers.chat_completion(base_url:, model:, tools:)                  |
  relay_worker { |c| c.pending_tool_calls.empty? ? c.finish : c }            |
  Lyman::Workers.tool_execution(handlers)                                    |
  side_worker { |c| rounds << c unless c.finished? }                         |
  filter_worker { |c| c.finished? }
```

That's the working heart of every harness lyman ships. Every stage is a
plain shifty worker. Want logging? Splice in a `side_worker` — anywhere.
Want a guardrail? A `filter_worker`. Want to swap Ollama for vLLM? Replace
one worker; nothing else changes. There are **no hooks**, because there's
nothing to hook *into* — the whole loop is already open.

## Deeper background

The wiki is the guided tour; the repository's design notes are the source
of truth for intent:

- [docs/vision.md](https://github.com/joelhelbling/lyman/blob/main/docs/vision.md) — why lyman exists, the values, the architecture decisions
- [docs/design/circuit-pattern.md](https://github.com/joelhelbling/lyman/blob/main/docs/design/circuit-pattern.md) — how a model⇄tool *cycle* lives in a strictly linear pull pipeline
- [docs/design/harness-archetypes.md](https://github.com/joelhelbling/lyman/blob/main/docs/design/harness-archetypes.md) — one circuit, three shells
- [docs/design/deployment.md](https://github.com/joelhelbling/lyman/blob/main/docs/design/deployment.md) — lyman as a pure generator; the manifest; eject-to-own
