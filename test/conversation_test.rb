require_relative "test_helper"
require "shifty"
require "lyman"

class ConversationTest < Minitest::Test
  include Shifty::DSL

  def test_id_is_auto_assigned_and_distinct
    a = Lyman::Conversation.new
    b = Lyman::Conversation.new

    refute_nil a.id
    refute_equal a.id, b.id
  end

  def test_parent_id_defaults_to_nil
    assert_nil Lyman::Conversation.new.parent_id
  end

  def test_parent_id_is_settable_and_survives_with_calls
    convo = Lyman::Conversation.new(parent_id: "parent-1")
    updated = convo.with_user_message("hello")

    assert_equal "parent-1", convo.parent_id
    assert_equal "parent-1", updated.parent_id
  end

  def test_id_is_preserved_across_with_calls
    convo = Lyman::Conversation.new(system_prompt: "hi")
    updated = convo.with_user_message("hello")

    assert_equal convo.id, updated.id
  end

  def test_elements_carry_the_conversation_id
    convo = Lyman::Conversation.new(system_prompt: "hi").with_user_message("hello")

    convo.elements.each do |element|
      assert_equal convo.id, element.conversation_id
    end
  end

  def test_seq_is_one_based_and_contiguous
    convo = Lyman::Conversation.new(system_prompt: "hi").with_user_message("hello")

    assert_equal [1, 2], convo.elements.map(&:seq)
  end

  def test_address_format
    convo = Lyman::Conversation.new(system_prompt: "hi").with_user_message("hello")

    assert_equal "conv:#{convo.id}#2", convo.element(2).address
  end

  def test_append_only_leaves_receiver_untouched
    convo = Lyman::Conversation.new(system_prompt: "hi")
    updated = convo.with_user_message("hello")

    assert_equal 1, convo.elements.size
    assert_equal 2, updated.elements.size
  end

  def test_earlier_elements_are_identical_objects_in_the_new_value
    convo = Lyman::Conversation.new(system_prompt: "hi")
    updated = convo.with_user_message("hello")

    assert_same convo.elements[0], updated.elements[0]
  end

  def test_unknown_element_type_raises
    assert_raises(ArgumentError) do
      Lyman::Element.new(conversation_id: "x", seq: 1, type: "bogus", content: {})
    end
  end

  def test_decomposes_reasoning_content_and_tool_calls_in_order
    convo = Lyman::Conversation.new
    message = {
      "role" => "assistant",
      "reasoning" => "let me think",
      "content" => "here you go",
      "tool_calls" => [
        {"id" => "call_1", "type" => "function", "function" => {"name" => "a", "arguments" => "{}"}},
        {"id" => "call_2", "type" => "function", "function" => {"name" => "b", "arguments" => "{}"}}
      ]
    }

    convo = convo.with_assistant_message(message)

    assert_equal %w[reasoning assistant tool_call tool_call], convo.elements.map(&:type)
    assert_equal "let me think", convo.element(1).content["text"]
    assert_equal "here you go", convo.element(2).content["text"]
    assert_equal "call_1", convo.element(3).content["id"]
    assert_equal "call_2", convo.element(4).content["id"]
  end

  def test_reasoning_content_key_also_recognized
    convo = Lyman::Conversation.new.with_assistant_message(
      {"role" => "assistant", "reasoning_content" => "thinking", "content" => "done"}
    )

    assert_equal %w[reasoning assistant], convo.elements.map(&:type)
  end

  def test_empty_reasoning_is_ignored
    convo = Lyman::Conversation.new.with_assistant_message(
      {"role" => "assistant", "reasoning" => "", "content" => "done"}
    )

    assert_equal %w[assistant], convo.elements.map(&:type)
  end

  def test_nil_content_with_tool_calls_still_yields_assistant_element
    convo = Lyman::Conversation.new.with_assistant_message(
      {
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [{"id" => "call_1", "type" => "function", "function" => {"name" => "a", "arguments" => "{}"}}]
      }
    )

    assert_equal %w[assistant tool_call], convo.elements.map(&:type)
    assert_nil convo.element(1).content["text"]
  end

  def test_projection_round_trip
    convo = Lyman::Conversation.new(system_prompt: "system prompt")
    convo = convo.with_user_message("what time is it?")
    convo = convo.with_assistant_message({
      "role" => "assistant",
      "reasoning" => "should call the tool",
      "content" => nil,
      "tool_calls" => [
        {"id" => "call_1", "type" => "function", "function" => {"name" => "current_time", "arguments" => "{}"}}
      ]
    })
    convo = convo.with_tool_result("call_1", "3:00pm")
    convo = convo.with_assistant_message({"role" => "assistant", "content" => "it's 3:00pm"})

    expected_with_reasoning = [
      {"role" => "system", "content" => "system prompt"},
      {"role" => "user", "content" => "what time is it?"},
      {
        "role" => "assistant",
        "content" => nil,
        "reasoning" => "should call the tool",
        "tool_calls" => [
          {"id" => "call_1", "type" => "function", "function" => {"name" => "current_time", "arguments" => "{}"}}
        ]
      },
      {"role" => "tool", "tool_call_id" => "call_1", "content" => "3:00pm"},
      {"role" => "assistant", "content" => "it's 3:00pm"}
    ]

    assert_equal expected_with_reasoning, convo.messages

    expected_wire = expected_with_reasoning.map { |m| m.except("reasoning") }
    assert_equal expected_wire, convo.wire_messages
    convo.wire_messages.each { |m| refute m.key?("reasoning") }
  end

  def test_pending_tool_calls_before_and_after_results
    convo = Lyman::Conversation.new.with_assistant_message({
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        {"id" => "call_1", "type" => "function", "function" => {"name" => "a", "arguments" => "{}"}},
        {"id" => "call_2", "type" => "function", "function" => {"name" => "b", "arguments" => "{}"}}
      ]
    })

    assert_equal 2, convo.pending_tool_calls.size

    convo = convo.with_tool_result("call_1", "result 1")
    assert_equal [], convo.pending_tool_calls

    convo = convo.with_tool_result("call_2", "result 2")
    assert_equal [], convo.pending_tool_calls
  end

  def test_last_assistant_content
    convo = Lyman::Conversation.new
      .with_assistant_message({"role" => "assistant", "content" => "first"})
      .with_user_message("more")
      .with_assistant_message({"role" => "assistant", "content" => "second"})

    assert_equal "second", convo.last_assistant_content
  end

  def test_last_assistant_content_nil_when_no_assistant_yet
    assert_nil Lyman::Conversation.new.last_assistant_content
  end

  def test_rounds_increment_and_reset
    convo = Lyman::Conversation.new
    assert_equal 0, convo.rounds

    convo = convo.with_assistant_message({"role" => "assistant", "content" => "hi"})
    assert_equal 1, convo.rounds

    convo = convo.with_assistant_message({"role" => "assistant", "content" => "hi again"})
    assert_equal 2, convo.rounds

    convo = convo.with_user_message("ok")
    assert_equal 0, convo.rounds
  end

  def test_runaway_and_finish
    convo = Lyman::Conversation.new(max_rounds: 2)
    refute convo.runaway?

    convo = convo
      .with_assistant_message({"role" => "assistant", "content" => "1"})
      .with_assistant_message({"role" => "assistant", "content" => "2"})

    assert convo.runaway?
    refute convo.finished?

    convo = convo.finish
    assert convo.finished?
  end

  def test_element_and_elements_in
    convo = Lyman::Conversation.new(system_prompt: "sp")
      .with_user_message("u1")
      .with_assistant_message({"role" => "assistant", "content" => "a1"})

    assert_equal "user", convo.element(2).type
    assert_nil convo.element(99)

    assert_equal %w[user assistant], convo.elements_in(2..3).map(&:type)
  end

  def test_usage_defaults_to_nil
    assert_nil Lyman::Conversation.new.usage
  end

  def test_with_usage_sets_usage
    convo = Lyman::Conversation.new.with_usage({"prompt_tokens" => 42})

    assert_equal({"prompt_tokens" => 42}, convo.usage)
  end

  def test_prompt_tokens_reads_from_usage
    convo = Lyman::Conversation.new.with_usage({"prompt_tokens" => 42, "total_tokens" => 60})

    assert_equal 42, convo.prompt_tokens
  end

  def test_prompt_tokens_nil_when_usage_unreported
    assert_nil Lyman::Conversation.new.prompt_tokens
  end

  def test_with_user_message_keeps_usage
    convo = Lyman::Conversation.new.with_usage({"prompt_tokens" => 42})
    updated = convo.with_user_message("hello")

    assert_equal({"prompt_tokens" => 42}, updated.usage)
  end

  def test_wire_messages_strips_reasoning_by_default
    convo = Lyman::Conversation.new
      .with_assistant_message({"role" => "assistant", "reasoning" => "thinking", "content" => "reply"})

    convo.wire_messages.each { |m| refute m.key?("reasoning") }
  end

  def test_wire_messages_reasoning_true_includes_reasoning
    convo = Lyman::Conversation.new
      .with_assistant_message({"role" => "assistant", "reasoning" => "thinking", "content" => "reply"})

    message = convo.wire_messages(reasoning: true).find { |m| m["role"] == "assistant" }
    assert_equal "thinking", message["reasoning"]
  end

  def test_frozen_handoffs_survive_a_shifty_pipeline
    handlers = {
      "known" => ->(args) { "handled #{args["x"]}" },
      "raising" => ->(_args) { raise "boom" }
    }

    convo = Lyman::Conversation.new.with_assistant_message({
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        {"id" => "call_1", "type" => "function", "function" => {"name" => "known", "arguments" => '{"x":1}'}},
        {"id" => "call_2", "type" => "function", "function" => {"name" => "unknown", "arguments" => "{}"}},
        {"id" => "call_3", "type" => "function", "function" => {"name" => "raising", "arguments" => "{}"}}
      ]
    })

    pipeline = source_worker([convo]) | Lyman::Workers.tool_execution(handlers)
    result = pipeline.shift

    tool_results = result.elements.select { |e| e.type == "tool_result" }
    by_id = tool_results.to_h { |e| [e.content["tool_call_id"], e.content["text"]] }

    assert_equal "handled 1", by_id["call_1"]
    assert_equal "Unknown tool: unknown", by_id["call_2"]
    assert_equal "Tool raising raised RuntimeError: boom", by_id["call_3"]
    assert_equal [], result.pending_tool_calls
  end
end
