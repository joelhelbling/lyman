require_relative "../test_helper"
require "shifty"
require "lyman"
require "socket"
require "json"

class ChatCompletionTest < Minitest::Test
  include Shifty::DSL

  # Starts a stdlib TCP server that reads exactly one HTTP request, hands
  # its parsed JSON body to the caller, and responds with +response_body+
  # (already-formatted HTTP response bytes, including status line and
  # headers). Returns the base_url to point the worker at. The server
  # thread is joined by the caller via the returned thread.
  def start_fake_server(captured_body, response_bytes)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    thread = Thread.new do
      client = server.accept
      request_line = client.gets
      headers = {}
      while (line = client.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.strip.downcase] = value.strip
      end
      content_length = headers["content-length"].to_i
      body = (content_length > 0) ? client.read(content_length) : ""
      captured_body << JSON.parse(body)
      _ = request_line

      client.write(response_bytes)
      client.close
      server.close
    end

    ["http://127.0.0.1:#{port}", thread]
  end

  def non_streaming_response_json
    {
      "choices" => [
        {
          "message" => {
            "role" => "assistant",
            "reasoning" => "thinking it over",
            "content" => "the answer",
            "tool_calls" => [
              {"id" => "call_1", "type" => "function", "function" => {"name" => "current_time", "arguments" => "{}"}}
            ]
          }
        }
      ]
    }.to_json
  end

  def non_streaming_response_with_usage_json
    {
      "choices" => [{"message" => {"role" => "assistant", "content" => "the answer"}}],
      "usage" => {"prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15}
    }.to_json
  end

  def http_response(body, content_type: "application/json", status: "200 OK")
    "HTTP/1.1 #{status}\r\nContent-Type: #{content_type}\r\nConnection: close\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
  end

  def test_non_streaming_request_and_response_decomposition
    captured = []
    base_url, thread = start_fake_server(captured, http_response(non_streaming_response_json))

    convo = Lyman::Conversation.new(system_prompt: "be terse")
      .with_user_message("what time is it?")
      .with_assistant_message({"role" => "assistant", "reasoning" => "old thought", "content" => "old reply"})

    worker = Lyman::Workers.chat_completion(base_url: base_url, model: "test-model")
    pipeline = source_worker([convo]) | worker
    result = pipeline.shift
    thread.join(5)

    assert_equal convo.wire_messages, captured.first["messages"]
    captured.first["messages"].each { |m| refute m.key?("reasoning") }

    assert_equal 2, result.rounds
    new_types = result.elements[convo.elements.size..].map(&:type)
    assert_equal %w[reasoning assistant tool_call], new_types
    assert_equal "thinking it over", result.elements[convo.elements.size].content["text"]
    assert_equal "the answer", result.last_assistant_content
  end

  def sse_body
    chunks = [
      {"choices" => [{"delta" => {"reasoning" => "hm"}}]},
      {"choices" => [{"delta" => {"reasoning" => "m..."}}]},
      {"choices" => [{"delta" => {"content" => "The "}}]},
      {"choices" => [{"delta" => {"content" => "answer."}}]},
      {"choices" => [{"delta" => {"tool_calls" => [{"index" => 0, "id" => "call_1", "type" => "function", "function" => {"name" => "cur", "arguments" => ""}}]}}]},
      {"choices" => [{"delta" => {"tool_calls" => [{"index" => 0, "function" => {"name" => "rent_time", "arguments" => "{}"}}]}}]}
    ]
    chunks.map { |c| "data: #{c.to_json}\n\n" }.join + "data: [DONE]\n\n"
  end

  # Mirrors what servers honoring stream_options.include_usage actually
  # send: a trailing chunk whose "choices" is empty and whose top-level
  # "usage" carries the report — must not crash on the empty choices.
  def sse_body_with_trailing_usage_chunk
    chunks = [
      {"choices" => [{"delta" => {"content" => "hi"}}]},
      {"choices" => [], "usage" => {"prompt_tokens" => 7, "completion_tokens" => 2, "total_tokens" => 9}}
    ]
    chunks.map { |c| "data: #{c.to_json}\n\n" }.join + "data: [DONE]\n\n"
  end

  def test_streaming_request_deltas_and_decomposition
    captured = []
    base_url, thread = start_fake_server(captured, http_response(sse_body, content_type: "text/event-stream"))

    deltas = []
    convo = Lyman::Conversation.new(system_prompt: "be terse").with_user_message("what time is it?")

    worker = Lyman::Workers.chat_completion(base_url: base_url, model: "test-model", on_delta: ->(text) { deltas << text })
    pipeline = source_worker([convo]) | worker
    result = pipeline.shift
    thread.join(5)

    assert_equal convo.wire_messages, captured.first["messages"]
    assert_equal true, captured.first["stream"]

    assert_equal ["<think>", "hm", "m...", "</think>", "The ", "answer."], deltas

    new_types = result.elements[convo.elements.size..].map(&:type)
    assert_equal %w[reasoning assistant tool_call], new_types
    assert_equal "hmm...", result.elements[convo.elements.size].content["text"]
    assert_equal "The answer.", result.last_assistant_content

    tool_call = result.elements.last.content
    assert_equal "call_1", tool_call["id"]
    assert_equal "current_time", tool_call.dig("function", "name")
    assert_equal "{}", tool_call.dig("function", "arguments")
  end

  def test_usage_stamped_from_non_streaming_response
    captured = []
    base_url, thread = start_fake_server(captured, http_response(non_streaming_response_with_usage_json))

    convo = Lyman::Conversation.new(system_prompt: "be terse").with_user_message("hi")
    worker = Lyman::Workers.chat_completion(base_url: base_url, model: "test-model")
    pipeline = source_worker([convo]) | worker
    result = pipeline.shift
    thread.join(5)

    assert_equal({"prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15}, result.usage)
    assert_equal 12, result.prompt_tokens
  end

  def test_streaming_sends_stream_options_and_stamps_usage_from_trailing_chunk
    captured = []
    base_url, thread = start_fake_server(captured, http_response(sse_body_with_trailing_usage_chunk, content_type: "text/event-stream"))

    convo = Lyman::Conversation.new(system_prompt: "be terse").with_user_message("hi")
    worker = Lyman::Workers.chat_completion(base_url: base_url, model: "test-model", on_delta: ->(_text) {})
    pipeline = source_worker([convo]) | worker
    result = pipeline.shift
    thread.join(5)

    assert_equal({"include_usage" => true}, captured.first["stream_options"])
    assert_equal({"prompt_tokens" => 7, "completion_tokens" => 2, "total_tokens" => 9}, result.usage)
  end

  def test_send_reasoning_true_sends_reasoning_on_the_wire
    captured = []
    base_url, thread = start_fake_server(captured, http_response(non_streaming_response_json))

    convo = Lyman::Conversation.new(system_prompt: "be terse")
      .with_user_message("what time is it?")
      .with_assistant_message({"role" => "assistant", "reasoning" => "prior thought", "content" => "prior reply"})

    worker = Lyman::Workers.chat_completion(base_url: base_url, model: "test-model", send_reasoning: true)
    pipeline = source_worker([convo]) | worker
    pipeline.shift
    thread.join(5)

    reasoning_message = captured.first["messages"].find { |m| m["role"] == "assistant" && m["content"] == "prior reply" }
    assert_equal "prior thought", reasoning_message["reasoning"]
  end

  def test_abridgement_shapes_the_wire_view_but_not_the_returned_conversation
    captured = []
    base_url, thread = start_fake_server(captured, http_response(non_streaming_response_json))

    convo = Lyman::Conversation.new(system_prompt: "be terse")
      .with_assistant_message({
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [{"id" => "call_1", "type" => "function", "function" => {"name" => "current_time", "arguments" => "{}"}}]
      })
      .with_tool_result("call_1", "a very long tool result, long enough to be worth abridging away entirely, " \
        "padded with plenty more filler text so it comfortably outsizes its own stub, address and all")
      .with_assistant_message({"role" => "assistant", "content" => "round 1"})
      .with_assistant_message({"role" => "assistant", "content" => "round 2"})
      .with_user_message("what time is it now?")

    abridgement = Lyman::Abridgement::StubToolResults.new(keep_rounds: 1)
    worker = Lyman::Workers.chat_completion(base_url: base_url, model: "test-model", abridgement: abridgement)
    pipeline = source_worker([convo]) | worker
    result = pipeline.shift
    thread.join(5)

    view = abridgement.call(convo)
    assert_equal view.wire_messages, captured.first["messages"]
    refute_equal convo.wire_messages, captured.first["messages"]

    # The reply lands on the ORIGINAL conversation: full tool result intact.
    assert_equal convo.element(4).content["text"], result.element(4).content["text"]
  end

  # Like start_fake_server, but answers one request per entry in
  # +responses+, in order — for circuits that make several model calls.
  def start_fake_server_sequence(captured_bodies, responses)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    thread = Thread.new do
      responses.each do |response_bytes|
        client = server.accept
        client.gets # request line
        headers = {}
        while (line = client.gets) && line != "\r\n"
          key, value = line.split(":", 2)
          headers[key.strip.downcase] = value.strip
        end
        content_length = headers["content-length"].to_i
        captured_bodies << JSON.parse(client.read(content_length))
        client.write(response_bytes)
        client.close
      end
      server.close
    end

    ["http://127.0.0.1:#{port}", thread]
  end

  def reply_with_prompt_tokens(prompt_tokens)
    http_response({
      "choices" => [{"message" => {"role" => "assistant", "content" => "ok"}}],
      "usage" => {"prompt_tokens" => prompt_tokens, "completion_tokens" => 1, "total_tokens" => prompt_tokens + 1}
    }.to_json)
  end

  # The flagship composition: usage stamped by round N gates the wire of
  # round N+1. Also pins the documented lag — the report describes the
  # request as sent, so once the abridged prompt comes back under budget
  # the gate turns itself off again the round after.
  def test_over_budget_gates_the_next_round_on_the_usage_this_round_stamped
    captured = []
    base_url, thread = start_fake_server_sequence(captured, [
      reply_with_prompt_tokens(500), # over budget: next round abridges
      reply_with_prompt_tokens(50),  # abridged prompt fits: next round doesn't
      reply_with_prompt_tokens(500)
    ])

    long_result = "a very long tool result, " + ("filler " * 40)
    convo = Lyman::Conversation.new(system_prompt: "be terse")
      .with_assistant_message({
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [{"id" => "call_1", "type" => "function", "function" => {"name" => "current_time", "arguments" => "{}"}}]
      })
      .with_tool_result("call_1", long_result)
      .with_assistant_message({"role" => "assistant", "content" => "done"})

    abridgement = Lyman::Abridgement.over_budget(100, Lyman::Abridgement::StubToolResults.new(keep_rounds: 1))
    worker = Lyman::Workers.chat_completion(base_url: base_url, model: "test-model", abridgement: abridgement)
    rounds = []
    pipeline = source_worker { rounds.shift } | worker

    3.times do |turn|
      rounds << convo.with_user_message("question #{turn}")
      convo = pipeline.shift
    end
    thread.join(5)

    tool_contents = captured.map { |body| body["messages"].find { |m| m["role"] == "tool" }["content"] }
    assert_equal long_result, tool_contents[0] # no usage yet: gate can't fire
    assert_match(/\A\[abridged: current_time result/, tool_contents[1])
    assert_equal long_result, tool_contents[2] # last report was under budget
    assert_operator JSON.generate(captured[1]).bytesize, :<, JSON.generate(captured[0]).bytesize

    assert_equal 500, convo.prompt_tokens
    assert_equal long_result, convo.element(4).content["text"] # series untouched throughout
  end

  def test_a_plain_lambda_works_as_an_abridgement_policy
    captured = []
    base_url, thread = start_fake_server(captured, http_response(non_streaming_response_json))

    convo = Lyman::Conversation.new(system_prompt: "be terse").with_user_message("hi")
    drop_nothing = ->(c) { c }

    worker = Lyman::Workers.chat_completion(base_url: base_url, model: "test-model", abridgement: drop_nothing)
    pipeline = source_worker([convo]) | worker
    pipeline.shift
    thread.join(5)

    assert_equal convo.wire_messages, captured.first["messages"]
  end

  # ── Transport failure (issue #33) ─────────────────────────────────────────
  # Every way the wire can fail comes back as one named class, on one line:
  # a shell catches Lyman::Workers::TransportError and a user can grep for it.

  def one_turn(base_url, **options)
    convo = Lyman::Conversation.new(system_prompt: "be terse").with_user_message("hi")
    worker = Lyman::Workers.chat_completion(base_url: base_url, model: "test-model", **options)
    (source_worker([convo]) | worker).shift
  end

  def assert_transport_error(message = nil)
    error = assert_raises(Lyman::Workers::TransportError) { yield }
    assert_equal 1, error.message.lines.size, "one line, not a trace: #{error.message}"
    assert_includes error.message, message if message
    error
  end

  def test_an_unreachable_endpoint_raises_transport_error_naming_the_endpoint
    error = assert_transport_error { one_turn("http://127.0.0.1:1") }

    assert_includes error.message, "can't reach http://127.0.0.1:1"
    assert_includes error.message, "is your server running?"
  end

  def test_a_missing_model_raises_transport_error_with_the_servers_own_reason
    body = {"error" => {"message" => "model 'doesnotexist:1b' not found"}}.to_json
    captured = []
    base_url, thread = start_fake_server(captured, http_response(body, status: "404 Not Found"))

    error = assert_transport_error("chat completion failed (404)") { one_turn(base_url) }
    thread.join(5)

    assert_includes error.message, "model 'doesnotexist:1b' not found"
    assert_includes error.message, "is the model pulled?"
  end

  # Streaming is the repl's path, so the streaming branch has to fail the
  # same way the blocking one does.
  def test_a_streaming_request_reports_a_non_2xx_as_transport_error_too
    body = {"error" => {"message" => "model not found"}}.to_json
    captured = []
    base_url, thread = start_fake_server(captured, http_response(body, status: "500 Internal Server Error"))

    error = assert_transport_error("chat completion failed (500)") { one_turn(base_url, on_delta: ->(_text) {}) }
    thread.join(5)

    assert_includes error.message, "model not found"
  end

  # A server error page is a wall of HTML; the message stays one line.
  def test_a_multiline_error_body_is_collapsed_onto_the_one_line
    captured = []
    base_url, thread = start_fake_server(captured, http_response("<html>\n  <body>boom</body>\n</html>",
      content_type: "text/html", status: "502 Bad Gateway"))

    error = assert_transport_error("chat completion failed (502)") { one_turn(base_url) }
    thread.join(5)

    assert_includes error.message, "<html> <body>boom</body> </html>"
  end

  # "200 OK with nothing usable in it" is a different bug than a dead
  # socket, but it's still the transport failing to produce a reply — and a
  # shell that catches one class should catch it too.
  def test_a_reply_with_no_message_is_a_transport_error_too
    captured = []
    base_url, thread = start_fake_server(captured, http_response({"choices" => []}.to_json))

    assert_transport_error("no message") { one_turn(base_url) }
    thread.join(5)
  end

  # A server that accepts the connection and then never answers: the
  # message has to name the knob that would fix it, and its value.
  def start_silent_server
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      client = server.accept
      sleep 2 # hold the connection open, say nothing
      client.close
      server.close
    rescue IOError, Errno::EBADF
      nil
    end
    [server, thread, "http://127.0.0.1:#{server.addr[1]}"]
  end

  def test_a_read_timeout_raises_transport_error_naming_read_timeout_and_its_value
    server, thread, base_url = start_silent_server

    error = assert_transport_error { one_turn(base_url, read_timeout: 1) }

    assert_includes error.message, "can't reach #{base_url}"
    assert_includes error.message, "read_timeout: 1"
  ensure
    server&.close
    thread&.join(5)
  end
end
