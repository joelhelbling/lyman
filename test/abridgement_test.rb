require_relative "test_helper"
require "lyman"

class AbridgementTest < Minitest::Test
  # ── SuppressPriorReasoning ────────────────────────────────────────────────

  def test_suppress_prior_reasoning_drops_prior_turn_reasoning
    convo = Lyman::Conversation.new
      .with_assistant_message({"role" => "assistant", "reasoning" => "old thought", "content" => "old reply"})
      .with_user_message("next question")
      .with_assistant_message({"role" => "assistant", "reasoning" => "new thought", "content" => "new reply"})

    view = Lyman::Abridgement::SuppressPriorReasoning.new.call(convo)

    assert_equal %w[assistant user reasoning assistant], view.elements.map(&:type)
  end

  def test_suppress_prior_reasoning_keeps_current_turn_reasoning
    convo = Lyman::Conversation.new
      .with_user_message("hi")
      .with_assistant_message({"role" => "assistant", "reasoning" => "current thought", "content" => "reply"})

    view = Lyman::Abridgement::SuppressPriorReasoning.new.call(convo)

    reasoning = view.elements.find { |e| e.type == "reasoning" }
    refute_nil reasoning
    assert_equal "current thought", reasoning.content["text"]
  end

  def test_suppress_prior_reasoning_leaves_original_conversation_untouched
    convo = Lyman::Conversation.new
      .with_assistant_message({"role" => "assistant", "reasoning" => "old thought", "content" => "old reply"})
      .with_user_message("next question")

    original_types = convo.elements.map(&:type)
    Lyman::Abridgement::SuppressPriorReasoning.new.call(convo)

    assert_equal original_types, convo.elements.map(&:type)
  end

  def test_suppress_prior_reasoning_with_no_user_element_drops_nothing
    convo = Lyman::Conversation.new
      .with_assistant_message({"role" => "assistant", "reasoning" => "only thought", "content" => "reply"})

    view = Lyman::Abridgement::SuppressPriorReasoning.new.call(convo)

    assert_equal %w[reasoning assistant], view.elements.map(&:type)
  end

  # ── StubToolResults ───────────────────────────────────────────────────────

  def long_tool_result_conversation
    Lyman::Conversation.new
      .with_assistant_message({
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [{"id" => "call_1", "type" => "function", "function" => {"name" => "current_time", "arguments" => "{}"}}]
      })
      .with_tool_result("call_1", "3:00pm exactly, with a good deal of extra padding text to make this longer than any stub")
      .with_assistant_message({"role" => "assistant", "content" => "round 1 done"})
      .with_assistant_message({"role" => "assistant", "content" => "round 2 done"})
      .with_assistant_message({"role" => "assistant", "content" => "round 3 done"})
  end

  def test_stub_tool_results_stubs_results_at_or_past_keep_rounds
    convo = long_tool_result_conversation # tool_result age is 3

    view = Lyman::Abridgement::StubToolResults.new(keep_rounds: 2).call(convo)

    stubbed = view.element(3)
    assert_match(/\[abridged: current_time result, \d+ chars/, stubbed.content["text"])
  end

  def test_stub_tool_results_leaves_results_younger_than_keep_rounds
    convo = long_tool_result_conversation # tool_result age is 3

    view = Lyman::Abridgement::StubToolResults.new(keep_rounds: 4).call(convo)

    original = convo.element(3)
    assert_equal original.content["text"], view.element(3).content["text"]
  end

  def test_stub_contains_tool_name_address_and_char_count
    convo = long_tool_result_conversation
    original_text = convo.element(3).content["text"]

    view = Lyman::Abridgement::StubToolResults.new(keep_rounds: 2).call(convo)
    stub = view.element(3).content["text"]

    assert_includes stub, "current_time"
    assert_includes stub, original_text.length.to_s
    assert_includes stub, convo.element(3).address
  end

  def test_stub_falls_back_to_tool_when_matching_tool_call_missing
    convo = Lyman::Conversation.new
      .with_tool_result("mystery_call", "a" * 200)
      .with_assistant_message({"role" => "assistant", "content" => "1"})
      .with_assistant_message({"role" => "assistant", "content" => "2"})

    view = Lyman::Abridgement::StubToolResults.new(keep_rounds: 2).call(convo)

    assert_includes view.element(1).content["text"], "[abridged: tool result"
  end

  def test_stub_keeps_seq_type_and_tool_call_id
    convo = long_tool_result_conversation
    original = convo.element(3)

    view = Lyman::Abridgement::StubToolResults.new(keep_rounds: 2).call(convo)
    stubbed = view.element(3)

    assert_equal original.seq, stubbed.seq
    assert_equal original.type, stubbed.type
    assert_equal original.content["tool_call_id"], stubbed.content["tool_call_id"]
  end

  def test_stub_never_lengthens_a_short_result
    convo = Lyman::Conversation.new
      .with_tool_result("call_1", "ok")
      .with_assistant_message({"role" => "assistant", "content" => "1"})
      .with_assistant_message({"role" => "assistant", "content" => "2"})

    view = Lyman::Abridgement::StubToolResults.new(keep_rounds: 2).call(convo)

    assert_equal "ok", view.element(1).content["text"]
  end

  def test_stub_keeps_nil_text_as_is
    convo = Lyman::Conversation.new
      .with_tool_result("call_1", nil)
      .with_assistant_message({"role" => "assistant", "content" => "1"})
      .with_assistant_message({"role" => "assistant", "content" => "2"})

    view = Lyman::Abridgement::StubToolResults.new(keep_rounds: 2).call(convo)

    assert_nil view.element(1).content["text"]
  end

  def test_stub_tool_results_leaves_original_conversation_untouched
    convo = long_tool_result_conversation
    original_text = convo.element(3).content["text"]

    Lyman::Abridgement::StubToolResults.new(keep_rounds: 2).call(convo)

    assert_equal original_text, convo.element(3).content["text"]
  end

  def test_wire_projection_of_view_still_pairs_tool_results_with_tool_call_id
    convo = long_tool_result_conversation

    view = Lyman::Abridgement::StubToolResults.new(keep_rounds: 2).call(convo)
    tool_message = view.wire_messages.find { |m| m["role"] == "tool" }

    assert_equal "call_1", tool_message["tool_call_id"]
    assert_match(/\[abridged: current_time result/, tool_message["content"])
  end

  # ── chain ─────────────────────────────────────────────────────────────────

  def test_chain_applies_policies_left_to_right
    calls = []
    a = ->(c) {
      calls << :a
      c
    }
    b = ->(c) {
      calls << :b
      c
    }

    Lyman::Abridgement.chain(a, b).call(Lyman::Conversation.new)

    assert_equal [:a, :b], calls
  end

  def test_chain_threads_the_view_from_one_policy_to_the_next
    convo = Lyman::Conversation.new
      .with_assistant_message({"role" => "assistant", "reasoning" => "old thought", "content" => "old reply"})
      .with_user_message("next")

    chained = Lyman::Abridgement.chain(
      Lyman::Abridgement::SuppressPriorReasoning.new,
      ->(c) { c.with(elements: c.elements + [Lyman::Element.new(conversation_id: c.id, seq: c.elements.size + 1, type: "user", content: {"text" => "marker"})]) }
    )

    view = chained.call(convo)

    refute_includes view.elements.map(&:type), "reasoning"
    assert_equal "marker", view.elements.last.content["text"]
  end

  # ── over_budget ───────────────────────────────────────────────────────────

  def test_over_budget_applies_policy_above_threshold
    convo = Lyman::Conversation.new.with_usage({"prompt_tokens" => 150})
    policy = ->(c) { c.with_user_message("shrunk") }

    result = Lyman::Abridgement.over_budget(100, policy).call(convo)

    assert_equal "shrunk", result.elements.last.content["text"]
  end

  def test_over_budget_does_nothing_below_threshold
    convo = Lyman::Conversation.new.with_usage({"prompt_tokens" => 50})
    policy = ->(c) { c.with_user_message("shrunk") }

    result = Lyman::Abridgement.over_budget(100, policy).call(convo)

    assert_same convo, result
  end

  def test_over_budget_does_nothing_when_usage_is_nil
    convo = Lyman::Conversation.new
    policy = ->(c) { c.with_user_message("shrunk") }

    result = Lyman::Abridgement.over_budget(100, policy).call(convo)

    assert_same convo, result
  end
end
