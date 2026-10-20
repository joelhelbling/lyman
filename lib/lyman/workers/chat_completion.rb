require "shifty"
require "net/http"
require "json"
require "uri"

module Lyman
  module Workers
    extend Shifty::DSL

    # Every way this worker can fail to get a reply, in one class: the
    # server isn't reachable, the request was refused, the response wasn't
    # usable. A failed model call *should* raise — there's no honest value
    # to hand downstream — but it has to raise a name a shell can catch and
    # a user can grep for, not a socket error from inside someone else's
    # framework. See docs/design/transport-failure.md.
    class TransportError < StandardError; end

    # The wire breaking, as opposed to a reply that's wrong: anything the
    # socket layer can do to a request in flight.
    NETWORK_FAILURES = [
      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::EHOSTDOWN,
      Errno::ENETUNREACH, Errno::ENETDOWN, Errno::ETIMEDOUT, Errno::EPIPE,
      SocketError, Net::OpenTimeout, Net::ReadTimeout, IOError, EOFError
    ].freeze

    # A non-2xx body is the server's own explanation (Ollama's 404 names the
    # missing model), so it goes into the message — collapsed onto one line
    # and capped, since a server error page can be a wall of HTML.
    MAX_ERROR_BODY = 300

    # Relay worker: sends the conversation to an OpenAI-compatible chat
    # completions endpoint and hands off a new conversation with the
    # assistant's reply (which may include tool calls) appended.
    #
    # Pass an on_delta callable to stream: it receives each content
    # fragment as it arrives. The worker still returns the conversation
    # with the fully-assembled message appended, so the circuit sees no
    # difference between streamed and unstreamed rounds.
    #
    # Servers disagree about where thinking goes: some put <think> tags
    # inline in the content, others (e.g. Ollama) stream a separate
    # reasoning field. The worker normalizes the latter to the former,
    # so on_delta always sees one convention: <think>...</think> inline.
    # The raw reasoning text still lands on the message unaltered.
    #
    # +abridgement+ is a wire-time projection policy (see
    # lib/lyman/abridgement.rb): when given, a *view* of the conversation
    # is built (elements dropped or stubbed, series untouched), and that
    # view's wire messages go out over HTTP — the reply still lands on the
    # ORIGINAL conversation. nil sends everything, as before.
    # +send_reasoning+ opts into Conversation#wire_messages(reasoning:
    # true) — see that method for why the default stays false.
    #
    # The transport's usage report (prompt/completion/total tokens) is
    # stamped onto the returned conversation via with_usage, so a
    # whether-to-act stage (e.g. Abridgement.over_budget) has something to
    # consult on the next round. See docs/design/context-control.md
    # ("Two kinds of reduction, kept apart").
    #
    # This is the only part of lyman that speaks the chat wire format;
    # facts outside it (like the context window) are Lyman::Providers'.
    # Everything it raises is a TransportError: either a conversation with a
    # reply appended comes back, or that does.
    def self.chat_completion(base_url:, model:, tools: nil, read_timeout: 300, on_delta: nil, abridgement: nil, send_reasoning: false)
      uri = URI("#{base_url.chomp("/")}/chat/completions")

      relay_worker do |conversation|
        view = abridgement ? abridgement.call(conversation) : conversation
        payload = {"model" => model, "messages" => view.wire_messages(reasoning: send_reasoning)}
        payload["tools"] = tools if tools && !tools.empty?
        if on_delta
          payload["stream"] = true
          # Streaming responses otherwise omit usage entirely; this asks
          # the server to append it to the final chunk. It's the standard
          # OpenAI field (Ollama, llama.cpp, vLLM, LM Studio honor it); a
          # strict server that rejects unknown fields would fail here — eject
          # chat_completion (`lyman eject`) and drop this line if yours does.
          payload["stream_options"] = {"include_usage" => true}
        end

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.read_timeout = read_timeout

        message, usage =
          with_transport(base_url: base_url, read_timeout: read_timeout) do
            if on_delta
              stream_message(http, uri, payload, on_delta)
            else
              fetch_message(http, uri, payload)
            end
          end

        conversation.with_assistant_message(message).with_usage(usage)
      end
    end

    # One seam around the exchange: whatever the wire does, what leaves the
    # worker is a TransportError, so a shell has exactly one class to catch.
    # (TransportError itself is raised deeper in — by the non-2xx and
    # no-message checks — and passes through unwrapped.)
    def self.with_transport(base_url:, read_timeout:)
      yield
    rescue *NETWORK_FAILURES => e
      raise TransportError, unreachable(base_url: base_url, read_timeout: read_timeout, error: e)
    rescue JSON::ParserError => e
      raise TransportError, "#{base_url} sent a response lyman couldn't parse (#{e.message})"
    end

    # The two states almost every first run is actually in: nothing
    # listening, and a model that hasn't been pulled. Each message names
    # the thing to check.
    def self.unreachable(base_url:, read_timeout:, error:)
      detail =
        case error
        when Net::ReadTimeout
          # The timeout a slow server legitimately hits: a model loading for
          # the first time can outlast the default.
          "no response within read_timeout: #{read_timeout}s — a model still loading can take " \
            "longer than that; pass a longer read_timeout: to chat_completion"
        when Net::OpenTimeout
          "no connection within the open timeout (#{error.message})"
        when SocketError
          "no such host (#{error.message})"
        else
          "#{error.message} — is your server running? (ollama serve, LM Studio, vLLM…)"
        end

      "can't reach #{base_url}: #{detail}"
    end

    def self.one_line(body)
      text = body.to_s.gsub(/\s+/, " ").strip
      (text.length > MAX_ERROR_BODY) ? "#{text[0, MAX_ERROR_BODY]}…" : text
    end

    def self.rejected(code, body)
      reason = one_line(body)
      message = reason.empty? ? "chat completion failed (#{code})" : "chat completion failed (#{code}): #{reason}"
      # 404 is the other first-run wall: the default model isn't on the server.
      message += " — is the model pulled? (e.g. ollama pull <model>)" if code == "404"
      message
    end

    # Returns [message, usage] — usage is the raw "usage" hash from the
    # response body, or nil when the server didn't send one.
    def self.fetch_message(http, uri, payload)
      response = http.post(
        uri.path,
        JSON.generate(payload),
        "Content-Type" => "application/json"
      )

      raise TransportError, rejected(response.code, response.body) unless response.is_a?(Net::HTTPSuccess)

      body = JSON.parse(response.body)
      message = body.dig("choices", 0, "message")
      raise TransportError, "chat completion response had no message: #{one_line(response.body)}" unless message
      [message, body["usage"]]
    end

    # Returns [message, usage]. Usage, when the server honors
    # stream_options.include_usage, arrives as a top-level "usage" key on
    # some chunk — typically the final one, whose "choices" array is
    # often empty, so this must not assume a delta is present.
    def self.stream_message(http, uri, payload, on_delta)
      request = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
      request.body = JSON.generate(payload)

      message = {"role" => "assistant", "content" => nil}
      tool_calls = {}
      state = {thinking: false}
      buffer = +""
      usage = nil

      http.request(request) do |response|
        unless response.is_a?(Net::HTTPSuccess)
          raise TransportError, rejected(response.code, response.read_body)
        end

        response.read_body do |chunk|
          buffer << chunk
          # SSE events arrive as "data: {json}" lines, but chunks don't
          # align with line boundaries.
          while (newline = buffer.index("\n"))
            line = buffer.slice!(0..newline).strip
            next unless line.start_with?("data:")

            data = line.delete_prefix("data:").strip
            next if data == "[DONE]"

            event = JSON.parse(data)
            usage = event["usage"] if event["usage"]

            delta = event.dig("choices", 0, "delta")
            apply_delta(message, tool_calls, delta, on_delta, state) if delta
          end
        end
      end

      on_delta.call("</think>") if state[:thinking] # reasoning ran to stream end
      unless tool_calls.empty?
        message["tool_calls"] = tool_calls.keys.sort.map { |index| tool_calls[index] }
      end
      [message, usage]
    end

    # Content deltas concatenate; tool-call deltas arrive as fragments
    # keyed by index, with the arguments string dribbling in over many
    # chunks. Reasoning-field deltas stream to on_delta wrapped in
    # synthesized <think> tags (see chat_completion).
    def self.apply_delta(message, tool_calls, delta, on_delta, state)
      reasoning = delta["reasoning"] || delta["reasoning_content"]
      if reasoning && !reasoning.empty?
        unless state[:thinking]
          state[:thinking] = true
          on_delta.call("<think>")
        end
        message["reasoning"] = (message["reasoning"] || +"") + reasoning
        on_delta.call(reasoning)
      end

      if (text = delta["content"]) && !text.empty?
        if state[:thinking]
          state[:thinking] = false
          on_delta.call("</think>")
        end
        message["content"] = (message["content"] || +"") + text
        on_delta.call(text)
      end

      (delta["tool_calls"] || []).each do |fragment|
        entry = tool_calls[fragment["index"]] ||= {
          "id" => nil,
          "type" => "function",
          "function" => {"name" => +"", "arguments" => +""}
        }
        entry["id"] = fragment["id"] if fragment["id"]
        entry["type"] = fragment["type"] if fragment["type"]

        function = fragment["function"] || {}
        entry["function"]["name"] << function["name"] if function["name"]
        entry["function"]["arguments"] << function["arguments"] if function["arguments"]
      end
    end
  end
end
