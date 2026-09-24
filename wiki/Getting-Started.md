# Getting Started

By the end of this page you'll have a scaffolded project of your own and a
tool-using agent answering you from a local model.

## Prerequisites

- **Ruby** ≥ 3.2 (any recent Ruby works; the lyman repo itself pins its own
  via [mise](https://mise.jdx.dev), but your project doesn't have to).
- **A local model server speaking the OpenAI-compatible API.**
  [Ollama](https://ollama.com) and [LM Studio](https://lmstudio.ai) both
  work out of the box. Pull a model with **native tool support** — e.g.
  `qwen3.5`, `gemma4`, or `mistral`:

  ```sh
  ollama pull gemma4
  ```

## Install and scaffold

```sh
gem install lyman
lyman new my-agent
cd my-agent
bundle install
```

`lyman new` plants a complete, working project — and then gets out of the
way. The gem is a **generator**, not a framework: your project's only
runtime dependency is `shifty`, and every planted file is legible source
sitting in your own tree. (More on this in
[The Generator CLI](The-Generator-CLI).)

## First conversation

```sh
ruby harness/repl.rb
```

```
lyman ⇢ gemma4:latest @ http://localhost:11434/v1

you> what time is it?

gemma4:latest> ✻ The user wants the current time. I have a current_time tool…

  ⚙ current_time {}
  ✓ current_time → 2026-07-08 18:13:29 EDT

gemma4:latest> It's 6:13 PM on Wednesday, July 8th.
```

The `✻` aside is a streamed preview of the model's thinking; the `⚙` and
`✓` lines show a tool call and its result. Between the question and the
answer, **two model round-trips completed inside a single pull on the
pipeline** — that's the circuit pattern at work
([Core Concepts](Core-Concepts) explains how).

Point it at a different server or model with environment variables:

```sh
LYMAN_MODEL=qwen3.5:2b LYMAN_BASE_URL=http://localhost:1234/v1 ruby harness/repl.rb
```

## What got planted

```
my-agent/
├── CLAUDE.md              # guidance for coding agents working in your project
├── Gemfile
├── harness/
│   ├── repl.rb            # the wiring script — YOURS from day one
│   └── repl/              # the repl's display layer, one widget per file
├── lib/
│   ├── lyman.rb           # entry point; requires shifty + planted modules
│   └── lyman/
│       ├── conversation.rb            # the item that flows through pipelines
│       ├── workers/
│       │   ├── chat_completion.rb     # model transport (the only file that knows HTTP exists)
│       │   └── tool_execution.rb      # executes pending tool calls
│       └── tools/
│           └── current_time.rb        # one tool, schema + handler side by side
└── .lyman/manifest.yml    # what was planted, at which version — commit it
```

Two kinds of files, one important boundary:

- **Managed** (`lib/lyman/**`) — planted library modules that
  `lyman update` can refresh from newer releases. Extend them, don't edit
  them (or run `lyman eject <name>` to take ownership explicitly).
- **Owned** (`harness/**`, `CLAUDE.md`, `Gemfile`, …) — yours from day one.
  `lyman update` never touches them. The harness is your wiring diagram;
  editing it is the expected case.

## Give it a real tool

Tools live one file per tool under `lib/lyman/tools/`, each a factory
returning `{schema:, handler:}` — schema and handler side by side, guts on
the outside. The one you already have:

```ruby
# lib/lyman/tools/current_time.rb
module Lyman
  module Tools
    def self.current_time
      {
        schema: {
          "type" => "function",
          "function" => {
            "name" => "current_time",
            "description" => "Returns the current local date and time",
            "parameters" => {"type" => "object", "properties" => {}, "required" => []}
          }
        },
        handler: ->(_args) { Time.now.strftime("%Y-%m-%d %H:%M:%S %Z") }
      }
    end
  end
end
```

Open `harness/repl.rb` and find the `TOOLS` array, where every tool the
model can call is listed by name:

```ruby
TOOLS = [
  Lyman::Tools.current_time
]
```

Write your own the same way — a weather lookup, a database query, a
shell command — in your own directory rather than `lib/lyman/` (that tree
is managed by lyman): say `lib/tools/weather.rb` defining `Tools.weather`.
`require_relative "../lib/tools/weather"` it from the harness, add
`Tools.weather` to `TOOLS`, restart the repl, and ask for it. That's the
whole tool-registration story: no runtime registries, no decorators, one
file plus one line in an array you own.

Lyman also ships one ready-made tool with a dependency: `lyman add store`
then `lyman add recall_tool` gets you `Lyman::Tools.recall(store: store)`,
which lets the model re-expand context an abridgement policy or
compaction stubbed away — see [The Generator CLI](The-Generator-CLI).

## Where to next

- **Your agent isn't a chat?** Most aren't. Read
  [Harness Archetypes](Harness-Archetypes) and plant the shell shape that
  matches — `lyman add daemon_harness` for an event-driven agent,
  `lyman add script_harness` for a cron-launched one.
- **Want to understand what you just ran?** [Core Concepts](Core-Concepts)
  walks the pipeline stage by stage.
- **`lyman doctor`** smoke-tests the planted pipeline against a stub
  transport — no model server needed. Run it whenever something feels off.
