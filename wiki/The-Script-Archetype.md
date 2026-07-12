# The Script Archetype

**Launched with its work item in hand; processes it; halts.** The launcher
is out of scope — cron, CI, a Makefile, another program, a person who wants
one answer — and the interface is a program's interface: arguments or stdin
in, the final answer on stdout, an exit code.

Plant it with:

```sh
lyman add script_harness
```

Run it either way a cron line naturally speaks:

```sh
ruby harness/script.rb "summarize yesterday's error log"
echo "summarize yesterday's error log" | ruby harness/script.rb
```

And schedule it like anything else:

```cron
0 7 * * * cd /srv/my-agent && ruby harness/script.rb "summarize yesterday's error log" | mail -s "Log summary" you@example.com
```

## The shell — no loop, anywhere

The whole shell of
[`harness/script.rb`](https://github.com/joelhelbling/lyman/blob/main/harness/script.rb):

```ruby
task = ARGV.empty? ? $stdin.read.to_s.strip : ARGV.join(" ")
abort "usage: …" if task.empty?

conversation = Lyman::Conversation.new(system_prompt: "…")
rounds = []

rounds << conversation.with_user_message(task)  # enqueue…
result = pipeline.shift                         # …then shift, once

puts result.last_assistant_content
```

This is the starkest demonstration of the circuit pattern's central trick:
**repetition lives in the pipeline, not the shell.** There is no loop in
the file — yet the model⇄tool circuit still runs as many rounds as the task
needs (call a tool, read the result, call another…), all inside the single
`pipeline.shift`. A shell really is just state + a process, and here the
process is a straight line.

That straight line also makes the script the best archetype to *read
first*: the enqueue-before-shift rule, the circuit, and the item's life are
all visible top to bottom with nothing else happening.

## Program-shaped output

- **stdout carries the answer** — the system prompt tells the model to
  reply with the result only, so the output is pipeable.
- **Everything between stays on the conversation.** Tool calls,
  intermediate rounds, reasoning — all on the `Conversation` item. Want to
  see them? Splice a logging `side_worker` into the circuit, or dump
  `result.messages` to a file before exiting.
- **Exit codes are yours to design.** `abort` already covers the no-task
  case; a natural extension is exiting nonzero when
  `result.runaway?` — the turn hit `max_rounds` instead of finishing
  cleanly — so cron can tell success from a wedged model.

## Making it yours

- **The work item can be anything the launch can carry** — a filename to
  read, a JSON blob on stdin, a date range. Parse it in the shell; keep the
  parsing boring.
- **No display dependencies, on purpose.** The script (like the daemon) is
  stdlib + your planted `lib/lyman` modules — nothing to install beyond
  `bundle install`, nothing to strip for a container image.
- **Batch variant:** a backlog of items is still script-shaped — loop the
  enqueue-and-shift over the collection and exit when it's drained. (The
  loop is in the shell because the *item count* is the shell's knowledge;
  each item's rounds still happen inside its own `shift`.)

Next: [The REPL Archetype](The-REPL-Archetype) ·
[The Daemon Archetype](The-Daemon-Archetype) ·
[Harness Archetypes overview](Harness-Archetypes)
