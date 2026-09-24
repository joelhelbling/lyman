require_relative "../test_helper"
require "shifty"
require "lyman"
require "time"

class CurrentTimeTest < Minitest::Test
  include Shifty::DSL

  def test_schema_is_a_function_schema_named_current_time_with_object_parameters
    tool = Lyman::Tools.current_time

    assert_equal "function", tool[:schema]["type"]
    function = tool[:schema]["function"]
    assert_equal "current_time", function["name"]
    assert_equal "object", function["parameters"]["type"]
  end

  def test_handler_returns_a_string_close_to_now
    tool = Lyman::Tools.current_time

    result = tool[:handler].call({})

    assert_kind_of String, result
    parsed = Time.parse(result)
    assert_in_delta Time.now, parsed, 5
  end

  # Mirrors how a harness derives handlers from TOOLS: `TOOLS.to_h { |tool|
  # [tool[:schema].dig("function", "name"), tool[:handler]] }`.
  def test_works_end_to_end_through_tool_execution
    tools = [Lyman::Tools.current_time]
    handlers = tools.to_h { |tool| [tool[:schema].dig("function", "name"), tool[:handler]] }

    convo = Lyman::Conversation.new.with_assistant_message({
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        {"id" => "call_1", "type" => "function", "function" => {"name" => "current_time", "arguments" => "{}"}}
      ]
    })

    pipeline = source_worker([convo]) | Lyman::Workers.tool_execution(handlers)
    result = pipeline.shift

    tool_result = result.elements.last
    assert_equal "tool_result", tool_result.type
    parsed = Time.parse(tool_result.content["text"])
    assert_in_delta Time.now, parsed, 5
  end
end
