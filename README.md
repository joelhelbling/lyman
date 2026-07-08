# Lyman

**A composable agentic harness — and a framework for building harnesses — in
Ruby, built on [shifty](https://github.com/joelhelbling/shifty).**

Lyman is for people building agentic workflows on models they run themselves:
open-weight models on Ollama, LM Studio, vLLM, llama.cpp — or models they've
trained. If that's you, you start with less data, less tooling maturity, and
less margin for error than the frontier labs. Your one real edge is
**iteration speed**. Lyman exists to maximize it.

> *Lyman*, as in the Lyman series — a nod to the physicist, and to
> **redshift**, which is in turn a nod to **Ruby** and the **shifty** gem. A
> series is also, fittingly, a sequence of discrete lines — like the stages of
> a pipeline.

![lyman new, then a first chat with a tool-using local model](demo/demo.gif)

## The idea

An agent harness is a pipeline. Not as a metaphor — literally:

```ruby
pipeline =
  source_worker { rounds.shift }                                             |
  Lyman::Workers.chat_completion(base_url:, model:, tools:)                  |
  relay_worker { |c| c.finish! if c.pending_tool_calls.empty?; c }           |
  Lyman::Workers.tool_execution(handlers)                                    |
  side_worker { |c| rounds << c unless c.finished? }                         |
  filter_worker { |c| c.finished? }
```

That's not pseudocode — it's the working heart of [`harness/chat.rb`](harness/chat.rb),
a tool-using chat agent for local models. Every stage is a plain
[shifty](https://github.com/joelhelbling/shifty) worker. Want logging? Splice
in a `side_worker` — anywhere. Want a guardrail? A `filter_worker`. Want to
swap Ollama for vLLM, or native tool-calling for prompt-and-parse emulation on
a model that lacks it? Replace one worker; nothing else changes. There are
**no hooks**, because there's nothing to hook *into* — the whole loop is
already open.

Two principles drive every design decision:

1. **Legibility.** One paradigm — a pipeline of workers — applied everywhere,
   at every level.
2. **Guts on the outside.** Nothing important happens anywhere you can't see,
   name, or splice into. This is deliberately the opposite of the frontier-SDK
   ethos, where the agent loop is a black box you configure from the edges.

And a razor for when they're in tension with convenience: **favor whatever
lets a user see and change behavior faster.** For a data-poor tinkerer,
transparency isn't an aesthetic — it's what makes fast iteration possible.

## Quick start

You'll need Ruby (see [`mise.toml`](mise.toml)) and a local model server
speaking the OpenAI-compatible API — [Ollama](https://ollama.com) and
[LM Studio](https://lmstudio.ai) both work. Use a model with native tool
support (e.g. `qwen3.5`, `gemma4`, `mistral`).

```sh
bundle install
bundle exec ruby harness/chat.rb
```

```
lyman ⇢ gemma4:latest @ http://localhost:11434/v1

you> what time is it?

gemma4:latest> ✻ The user wants the current time. I have a current_time tool…

  ⚙ current_time {}
  ✓ current_time → 2026-07-08 18:13:29 EDT

gemma4:latest> It's 6:13 PM on Wednesday, July 8th.
```

The `✻` aside is a streamed preview of the model's thinking; the `⚙` and `✓`
lines are side workers showing a tool call and its result — and the reply
after them means two model round-trips completed inside a single pull on the
pipeline. Point it elsewhere with `LYMAN_BASE_URL` and `LYMAN_MODEL`.

## How it works, briefly

- **The item is the conversation.** What flows through the pipeline is a
  `Conversation` — the full message history plus the control data workers
  consult (`finished?`, `pending_tool_calls`). A turn carries its whole
  conversation with it; that's what makes it a conversation.
- **State lives in the shell.** The enclosing scope — the *shell* — is just
  state plus a process: the conversation, a queue, and a deliberately boring
  loop. A human REPL is one shell; an autonomous email-triager is another.
  Lyman is turn-shaped, not chat-shaped.
- **The agentic loop is a circuit, not a special construct.** Shifty pipelines
  are strictly linear, so the model⇄tool cycle is built from stock parts: a
  source reading from a queue, a side worker re-enqueueing unfinished rounds,
  and a filter at the tail that only lets finished turns escape. Demand does
  the rest — N model⇄tool rounds happen inside one `shift`, with no loop
  written anywhere. Full reasoning in
  [docs/design/circuit-pattern.md](docs/design/circuit-pattern.md).
- **Dependencies stay inside the workers that need them.** The HTTP client
  lives in exactly one file. Use your favorite gems — in such a way that only
  the worker requiring one knows it exists.

The longer story — mission, principles, architecture decisions, open
questions — is in [docs/vision.md](docs/vision.md).

## Is lyman a good fit for you?

**Probably yes, if:**

- You're building a **narrow, purpose-built agent** — an email triager, a log
  summarizer, a domain-specific assistant — tailored to specific problems and
  specific models, and you want to iterate on it *fast*.
- You run models **locally or self-hosted** and want to build a harness that
  treats that as the primary case, not an afterthought.
- You want to **understand and modify your whole agent loop**, not configure
  the edges of someone else's.
- You like Ruby, or at least like the idea of an agent harness you can read
  top to bottom in a single coding session.

**Probably not, if:**

- You want a no-code / low-code agent builder. Lyman is a developer's tool.
- You want feature parity with frontier-model harnesses and popular coding
  agents. Lyman isn't chasing checklists — it's chasing the shortest path
  from "what if the workflow did *this*?" to finding out.
- You want a batteries-included platform with every integration bundled.
  Lyman's bet is that shifty makes those things easy enough to build yourself
  that shipping them all would be beside the point.

## The generator

Lyman is delivered as a **pure generator**, in the spirit of shadcn/ui: the
gem's whole job is to plant legible, manifest-tracked modules into *your*
project, individually upgradeable and yours to extend — or eject and adopt
outright. No runtime framework to call into; your harness's only runtime
dependency is shifty. "Guts on the outside" extends to whose tree the code
lives in. The reasoning is written down in
[docs/design/deployment.md](docs/design/deployment.md).

```sh
lyman new my-agent      # scaffold a project: harness, workers, manifest
lyman list              # what lyman installs, and this project's status
lyman update            # refresh pristine modules; halt (never clobber) on modified ones
lyman diff conversation # your changes, and upstream's since you planted
lyman eject conversation# take ownership; lyman stops managing it
lyman doctor            # smoke-test the pipeline against a stub transport
```

`.lyman/manifest.yml` records what was planted, at which version, with which
content hash — so `update` knows pristine from modified, ejected modules get
upstream-change advisories instead of merges, and your harness script is never
touched at all: it's yours from day one.

## Status

Early and moving. What exists today: the vision, circuit-pattern, and
deployment design docs, the core `Conversation` item, chat-completion and
tool-execution workers, a working tool-using chat harness against live local
models, and the generator CLI (`new` / `add` / `update` / `eject` / `diff` /
`doctor` / `list`) with a Minitest suite behind it. Published to
[rubygems.org](https://rubygems.org/gems/lyman) — install it with:

```sh
gem install lyman
lyman new my-agent
```

On deck: tool-call fan-out and a one-shot (non-REPL) harness.

## License

[MIT](LICENSE)
