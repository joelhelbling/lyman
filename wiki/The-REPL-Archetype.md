# The REPL Archetype

**Human-in-the-loop-as-driver.** A person supplies work items at a prompt,
watches every answer, and ends the session when they're done — blank line,
ctrl-c, or ctrl-d. This is the archetype `lyman new` plants, as
[`harness/repl.rb`](https://github.com/joelhelbling/lyman/blob/main/harness/repl.rb),
because it's the one you can talk to sixty seconds after scaffolding.

```sh
ruby harness/repl.rb
```

## The shell

Strip away comments and display and the repl's shell is three declarations
and a loop:

```ruby
conversation = Lyman::Conversation.new(system_prompt: "…")
rounds = []            # the circuit's queue — visible right here

loop do
  input = read_a_line_from_the_human
  break if input.nil? || input.empty?

  rounds << conversation.with_user_message(input)  # enqueue…
  conversation = pipeline.shift                    # …then shift, and rebind
end
```

Two things to notice:

- **The conversation accretes.** The shell keeps one conversation binding
  across the whole session: `with_user_message` extends the history on the
  way in, and the shell rebinds to the finished turn the circuit hands
  back (`Conversation` is an immutable value — shifty freezes every worker
  handoff, so change is expressed as new values, never mutation). That's
  the repl's defining state decision — contrast the
  [daemon](The-Daemon-Archetype), which starts fresh per event.
- **Enqueue before shift.** The queue is only ever pulled right after
  something was pushed — the nil-footgun rule every archetype follows.

## The circuit

The standard circuit ([Core Concepts](Core-Concepts)), with display
side-workers spliced in — a round-start hook, streamed deltas, tool-call
and tool-result printers:

```ruby
pipeline =
  source_worker { rounds.shift } |
  side_worker { |_c| printer.start_round } |
  Lyman::Workers.chat_completion(
    base_url: BASE_URL, model: MODEL, tools: schemas,
    on_delta: printer.method(:delta)          # streaming: a human is waiting
  ) |
  side_worker { |_c| printer.finish_round } |
  relay_worker { |c|
    (c.pending_tool_calls.empty? || c.runaway?) ? c.finish : c
  } |
  side_worker { |c| tool_printer.calls(c) unless c.finished? } |
  Lyman::Workers.tool_execution(handlers) |
  side_worker { |c| tool_printer.results(c) unless c.finished? } |
  side_worker { |c| rounds << c unless c.finished? } |
  filter_worker { |c| c.finished? }
```

Every display concern is a `side_worker` — remove them all and the circuit
still works, silently. That's the demonstration that observability is a
splice, not a feature.

## The display layer

A human is watching, so the repl is the one archetype that streams: the
transport's `on_delta` feeds a small stack of widgets in `harness/repl/`,
one file each, every one an owned artifact:

| Widget | Job |
|---|---|
| `style.rb` | terminal styling codes shared by the others |
| `wait_spinner.rb` | a spinner for the silence before the first token |
| `think_filter.rb` | streams a dim preview of `<think>` blocks, then elides the rest |
| `round_printer.rb` | one round's output: spinner, model label, think preview, reply |
| `tool_printer.rb` | `⚙` tool calls on the way in, `✓` results on the way out |

Their dependencies — cli-ui for color, reline for line editing and history —
are confined here. Restyle or delete the display layer freely; the circuit
never knew it existed.

## Making it yours

- **Add tools** in the `TOOLS` hash — schema and handler side by side.
- **Change the personality** in the `system_prompt`.
- **Persist the conversation** with a `side_worker` after the model call
  that appends to a file or database — durability is a splice, not a
  built-in.
- **Swap the endpoint** with `LYMAN_BASE_URL` / `LYMAN_MODEL`, or replace
  `Workers.chat_completion` outright — the transport is an ordinary worker.

Next: [The Daemon Archetype](The-Daemon-Archetype) ·
[The Script Archetype](The-Script-Archetype) ·
[Harness Archetypes overview](Harness-Archetypes)
