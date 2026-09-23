require_relative "../test_helper"
require "shifty"
require "lyman"

class ToolExecutionTest < Minitest::Test
  include Shifty::DSL

  def test_executes_pending_tool_calls_and_appends_results
    handlers = {"add" => ->(args) { args["a"] + args["b"] }}

    convo = Lyman::Conversation.new.with_assistant_message({
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        {"id" => "call_1", "type" => "function", "function" => {"name" => "add", "arguments" => '{"a":1,"b":2}'}}
      ]
    })

    pipeline = source_worker([convo]) | Lyman::Workers.tool_execution(handlers)
    result = pipeline.shift

    tool_result = result.elements.last
    assert_equal "tool_result", tool_result.type
    assert_equal "call_1", tool_result.content["tool_call_id"]
    assert_equal "3", tool_result.content["text"]
  end

  def test_unknown_tool_produces_documented_string
    convo = Lyman::Conversation.new.with_assistant_message({
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        {"id" => "call_1", "type" => "function", "function" => {"name" => "missing", "arguments" => "{}"}}
      ]
    })

    pipeline = source_worker([convo]) | Lyman::Workers.tool_execution({})
    result = pipeline.shift

    assert_equal "Unknown tool: missing", result.elements.last.content["text"]
  end

  def test_raising_handler_produces_documented_string
    handlers = {"boom" => ->(_args) { raise ArgumentError, "nope" }}
    convo = Lyman::Conversation.new.with_assistant_message({
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        {"id" => "call_1", "type" => "function", "function" => {"name" => "boom", "arguments" => "{}"}}
      ]
    })

    pipeline = source_worker([convo]) | Lyman::Workers.tool_execution(handlers)
    result = pipeline.shift

    assert_equal "Tool boom raised ArgumentError: nope", result.elements.last.content["text"]
  end

  def test_passes_through_when_no_pending_tool_calls
    convo = Lyman::Conversation.new.with_assistant_message({"role" => "assistant", "content" => "hi"})

    pipeline = source_worker([convo]) | Lyman::Workers.tool_execution({})
    result = pipeline.shift

    assert_equal convo, result
  end

  def test_handles_multiple_pending_tool_calls_in_order
    handlers = {
      "first" => ->(_args) { "one" },
      "second" => ->(_args) { "two" }
    }
    convo = Lyman::Conversation.new.with_assistant_message({
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        {"id" => "call_1", "type" => "function", "function" => {"name" => "first", "arguments" => "{}"}},
        {"id" => "call_2", "type" => "function", "function" => {"name" => "second", "arguments" => "{}"}}
      ]
    })

    pipeline = source_worker([convo]) | Lyman::Workers.tool_execution(handlers)
    result = pipeline.shift

    results = result.elements.select { |e| e.type == "tool_result" }
    assert_equal [["call_1", "one"], ["call_2", "two"]],
      results.map { |e| [e.content["tool_call_id"], e.content["text"]] }
    assert_equal [], result.pending_tool_calls
  end
end
