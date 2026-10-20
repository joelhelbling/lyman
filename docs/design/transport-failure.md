# Transport failure: one named error, three shell answers

**Status:** accepted (issue #33)
**Builds on:** [circuit-pattern.md](circuit-pattern.md) (the model⇄tool loop),
[harness-archetypes.md](harness-archetypes.md) (the shell), and the deferred
"failure, retry, fallback, rollback" paragraph in [../vision.md](../vision.md)

## The problem

The two most likely states of a first lyman run are "Ollama isn't running"
and "you haven't pulled the model lyman defaults to." Both used to arrive as
an unhandled exception: a `Errno::ECONNREFUSED` or a bare `RuntimeError`
escaping `pipeline.shift` through twenty frames of shifty and net/http, the
process dying with the conversation in it. In the repl that reads as "the
framework crashed"; in the daemon it reads as "the daemon is down"; in a
cron-run script it reads as a stack trace in a log that wanted an exit code.

Nothing in the library or the shipped shells rescued anything, so the failure
had no owner. This note assigns one.

## Decision 1: the transport raises one named class

`Lyman::Workers::TransportError` (`lib/lyman/workers/chat_completion.rb`) is
everything the transport worker can fail with:

- the socket failed (`Errno::ECONNREFUSED`, `EHOSTUNREACH`, `ECONNRESET`,
  `SocketError`, `Net::OpenTimeout`, `Net::ReadTimeout`, …);
- the server answered non-2xx (its own body goes into the message — Ollama's
  404 names the missing model — collapsed onto one line and capped, since an
  error page can be a wall of HTML);
- the server answered 2xx with nothing usable in it (no message, malformed
  JSON).

Two things follow from that list, and both are deliberate.

**It still raises.** A failed model call has no honest value to hand
downstream. Returning `nil` would end the stream permanently (the nil
footgun) and would hide the failure one stage away from the shell that has to
answer it. The legible choice is a raise — but a raise with a name a shell
can catch and a user can grep for, not a socket error from inside someone
else's framework.

**One class, not a family.** A shell catches `TransportError` and that's the
whole contract of the transport: *it either hands back a conversation with a
reply appended, or it raises this*. Malformed-reply failures are in the class
even though they aren't wire failures, because the shell's decision — "this
turn didn't happen" — is the same for all of them, and a shell that has to
enumerate failure kinds is a shell that will miss one.

The messages name the thing to check, because the failure is almost always
one of two states:

```
can't reach http://localhost:9999/v1: Connection refused - connect(2) for "localhost" port 9999 — is your server running? (ollama serve, LM Studio, vLLM…)
chat completion failed (404): {"error":{"message":"model 'doesnotexist:1b' not found"}} — is the model pulled? (e.g. ollama pull <model>)
can't reach http://localhost:11434/v1: no response within read_timeout: 300s — a model still loading can take longer than that; pass a longer read_timeout: to chat_completion
```

## Decision 2: the shell owns how a failure reads

`docs/vision.md` defers failure handling to "workers the user composes." That
deferral is about *policy* — retry, fall back to a smaller model, roll back.
Presentation and *what the process does next* belong to the shell already: the
shell is the part that owns state and the driving process. lyman ships the
shells, so shipping one legible failure path in each is the existing paradigm
applied, not a second one.

| Shell | Catches | Does |
|-------|---------|------|
| `harness/repl.rb` | `TransportError` around the shift | paints one red line, keeps the loop; the human's next prompt is a fresh turn |
| `harness/daemon.rb` | `TransportError` around the shift | logs one line, sends that line back to the event's sender, keeps accepting |
| `harness/script.rb` | `TransportError` around the shift | `abort` — one line on stderr, non-zero exit, no trace |
| `harness/agents/*` | `TransportError` around the shift | *returns* it as the sub-agent's answer, since its caller is a model and `tool_execution` would otherwise report "raised …" |
| `harness/compactor.rb` | already caught everything | logs "digest failed", records a gap, keeps running |

State recovery needs no machinery. `conversation` is still bound to the last
good turn (the failed turn's conversation was never rebound to it), and
`rounds` is empty, because the shell enqueued and the circuit pulled that
enqueue out before failing. One bad turn costs one turn.

The repl proves the interesting case: a good turn *after* a failed one still
carries the last good turn, and never sees the failed turn's user message.

## Decision 3: a circuit is a definition, not a live object

Rescuing the error is not enough on its own. In shifty, an exception that
escapes a worker terminates every Fiber between it and the caller: the next
`pipeline.shift` on the same pipeline raises `FiberError: attempt to resume a
terminated fiber`. A pipeline does not survive its first unhandled error.

So `harness/repl.rb` and `harness/daemon.rb` now hold a **circuit lambda** —
the same pipeline definition, built fresh per turn / per event — and the
`rounds` queue stays shell state outside it:

```ruby
circuit = -> do
  source_worker { rounds.shift } |
  …
  filter_worker { |c| c.finished? }
end

rounds << conversation.with_user_message(task)
conversation = circuit.call.shift
```

This is not new machinery: `harness/compactor.rb` already builds its digest
pipeline per batch ("an error raised inside a pipeline ends it for good, and
the sidecar must outlive a flaky model call"), and both agents build theirs
per call. The archetypes were the last places holding one long-lived pipeline,
which is why a daemon's first bad event used to be its last. `harness/script.rb`
shifts once, so its pipeline stays a plain assignment.

The cost is constructing a handful of `Worker` objects per turn — nothing
beside the model call it precedes.

## What this deliberately is not

No retry, no fallback, no circuit breaker in the library. Those are workers a
user composes, and this note only makes them *possible to write*: the seam is
a class you can rescue and a circuit you can rebuild. A retry is a worker in
the wiring script, visible there — and it rebuilds the circuit per attempt,
for the same Fiber reason as above:

```ruby
retry_transport = relay_worker do |conversation|
  attempts = 0
  begin
    attempts += 1
    (source_worker([conversation]) |
      Lyman::Workers.chat_completion(base_url: BASE_URL, model: MODEL)).shift
  rescue TransportError
    retry if attempts < 3
    raise
  end
end
```

Keeping it out of `chat_completion` is what lets one harness decide that a
timeout means "try the 4B model" while another decides a 404 means "stop
asking." That decision is a shell decision.
