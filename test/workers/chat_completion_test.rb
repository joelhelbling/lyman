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

  def http_response(body, content_type: "application/json")
    "HTTP/1.1 200 OK\r\nContent-Type: #{content_type}\r\nConnection: close\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
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
end
