# The Daemon Archetype

**Launch once, loop on an inbound stream of events, indefinitely.** No
human in the loop: each arriving event is a work item, processed to
completion and answered on its own. This is the shape of an email triager,
a webhook responder, a queue consumer — any agent that reacts to the world
rather than to a person.

Plant it with:

```sh
lyman add daemon_harness
ruby harness/daemon.rb
```

The shipped daemon
([`harness/daemon.rb`](https://github.com/joelhelbling/lyman/blob/main/harness/daemon.rb))
listens on a TCP socket, one line per event — chosen because it's stdlib
and demoable in one line from a second terminal:

```sh
echo "what time is it?" | nc localhost 1216
```

```
lyman daemon ⇢ gemma4:latest @ http://localhost:11434/v1, listening on port 1216
[13:51:36] event: what time is it?
  ⚙ current_time {}
[13:51:39] reply: 2026-07-12 13:51:38 EDT
```

(Port 1216 is the Lyman-alpha wavelength in Ångströms. Override with
`LYMAN_PORT`.)

## The shell

```ruby
rounds = []               # the circuit's queue

server = TCPServer.new(PORT)
loop do
  client = server.accept
  event = client.gets&.strip
  next client.close if event.nil? || event.empty?

  # Each event is an independent work item → a fresh conversation.
  conversation = Lyman::Conversation.new(system_prompt: "…")

  rounds << conversation.with_user_message(event)  # enqueue…
  result = pipeline.shift                          # …then shift

  client.puts result.last_assistant_content
  client.close
end
```

Two defining shell decisions:

- **Fresh conversation per event.** A daemon's work items are independent,
  so context doesn't accrete across them. If your daemon *should* remember
  (a per-sender thread, say), that's a deliberate splice — keep a hash of
  conversations keyed however your domain demands, in the shell's scope,
  visibly.
- **The same enqueue-then-shift rhythm as every archetype** — with a socket
  where the human used to be.

## The supplier is the variable

The TCP listener is deliberately the *least interesting* part of the file.
**Every daemon differs from every other daemon almost entirely in its
supplier** — the few lines that turn "something arrived" into an enqueued
work item:

- a webhook: swap `TCPServer` for your favorite HTTP server, enqueue the
  request body, reply with the result
- a message queue: block on an AMQP/SQS/Redis consumer, enqueue each message
- a mailbox: poll IMAP on an interval, enqueue new messages
- a filesystem: watch a directory, enqueue each new file's path

The circuit never knows where events come from — only the queue does. Swap
the supplier and not one worker changes.

## Nobody is watching — design for it

- **The runaway guard is load-bearing.** In the repl a human would notice a
  model stuck calling tools in a loop; here, only
  `Conversation#max_rounds` will. Don't remove it when rewiring.
- **Observability is spliced in, not bolted on.** The shipped daemon adds
  one logging `side_worker` (tool calls) and logs events/replies in the
  shell. Grow that in the same way — more side workers, wherever you need
  eyes.
- **Blocking transport, not streaming.** The event's sender wants the
  finished answer, not tokens. Same `Workers.chat_completion` seam as the
  repl, minus `on_delta`.
- **A human *approval gate* is still possible** — a side worker before
  `tool_execution` that blocks on whatever collaborator the shell provides
  (a queue a human answers, a push notification). Autonomy is the
  archetype's default, not a limitation.

Next: [The Script Archetype](The-Script-Archetype) ·
[The REPL Archetype](The-REPL-Archetype) ·
[Harness Archetypes overview](Harness-Archetypes)
