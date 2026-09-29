# Providers: what the server knows beyond the wire format

Lyman talks to every model server through one surface: OpenAI-compatible
chat completions (`Workers.chat_completion`). That surface is deliberately
all the circuit needs, and it's what makes Ollama, LM Studio, llama.cpp and
vLLM interchangeable.

Some facts a harness wants aren't on that surface. The first one that
mattered was **the context window**. The repl shows `ctx: 2.4k/131k` above
each prompt. The numerator comes from the transport's `usage` report, which
`chat_completion` already stamps on the conversation. The denominator is not
in any OpenAI-compatible response. Each server exposes it only through its
own native API, and each spells it differently:

| Server    | Where                        | Field                   |
|-----------|------------------------------|-------------------------|
| Ollama    | `GET /api/ps`                | `context_length`        |
| LM Studio | `GET /api/v0/models`         | `loaded_context_length` |

## Decision: one class per server, one interface

`Lyman::Providers` (`lib/lyman/providers.rb`, stdlib only, managed) holds a
class per server. All of them answer the same three calls:

```ruby
provider.name                  # "ollama", "lmstudio", "openai-compatible"
provider.preload(model)        # load the model now; see below
provider.context_window(model) # Integer, or nil when unknown
```

The harness is handed a provider and never learns which server it is.
`Providers::OpenAICompatible` is the base class and the fallback, and it
knows nothing (`nil`) and preloads nothing. A new server is a new subclass.

`Providers.detect(base_url)` picks a provider by probing each class's native
endpoint (`recognizes?`) in `DETECTION_ORDER`, and falls back to the generic
provider. Detection is a convenience, not a requirement. A harness that knows
its server names the class instead, and the wiring script says so right where
`PROVIDER` is set.

### Why not fold this into `chat_completion`?

The transport's job is the chat wire format. A context-window query is a
different request, to a different endpoint, at a different time (once per
prompt, not once per round), and it feeds a different consumer (a display
or a whether-to-act check, not the circuit). Keeping it in its own object:

- leaves `chat_completion` unchanged and server-agnostic;
- keeps the question visible in the wiring script, following the
  guts-on-the-outside principle;
- gives later per-server facts (loaded models, a llama.cpp `/props` reader,
  and so on) an obvious home.

### Loaded, not maximum, so preload

Both servers report a model's trained maximum as well as the size it
actually loaded with, and the two differ. On LM Studio, a model with a 64k
maximum loaded at 8k. Only the loaded size is the real window, so that's
the only figure a provider reports, and an unloaded model reads as `nil`.

That creates a problem at startup. The model isn't loaded until the first
request, so the first prompt would show `?`. Guessing the maximum would be
wrong by up to 8×, so the harness asks the server to load the model instead:
`provider.preload(model)`, called once under a spinner before the first
prompt. The load happens exactly once either way. Preloading only moves its
cost from the first reply to startup.

- **Ollama:** an empty-prompt `POST /api/generate`, Ollama's documented way
  to load without generating. For a model that's already loaded, it only
  refreshes the idle timer.
- **LM Studio:** `POST /api/v1/models/load`, but only when the model isn't
  already loaded. Loading a loaded model starts a *second* instance.

The meter asks for the window at every prompt, because servers unload
models on their own schedule (Ollama after 5 idle minutes). When the answer
comes back `nil` after it was once known, the meter keeps showing the last
known size. The model will reload at that size on the next request.

### Never raise

A provider query that fails (the server is down, the endpoint is missing,
the JSON is malformed) returns `nil`. These facts decorate a turn. They
must never be able to crash one.

## The meter

`harness/repl/context_meter.rb` (owned) turns a conversation and a provider
into the plain text `ctx: used/window`, and the shell paints it gray. `used`
is the last reply's `total_tokens`: prompt plus completion, which is roughly
what the next request carries before the new user message. Because usage
counts the wire *view*, abridgement's savings show up in it. Before any
reply, the conversation is empty and reads `0`. Either side reads `?`
when unknown, for example on a resumed conversation or from a server
that doesn't report usage.
