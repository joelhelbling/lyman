require_relative "../test_helper"
require "lyman"
require_relative "../../harness/repl/context_meter"

class ContextMeterTest < Minitest::Test
  # A provider whose window can change between readings, the way a
  # server's does when it loads or unloads the model.
  FakeProvider = Struct.new(:window) do
    def context_window(_model) = window
  end

  def fresh = Lyman::Conversation.new(system_prompt: "hi")

  def replied(usage)
    fresh.with_user_message("hello")
      .with_assistant_message({"role" => "assistant", "content" => "hi there"})
      .with_usage(usage)
  end

  def reading(conversation, window:)
    ContextMeter.new(FakeProvider.new(window), "m").line(conversation)
  end

  def test_shows_tokens_in_use_over_the_context_window
    assert_equal "ctx: 2.4k/131k",
      reading(replied({"prompt_tokens" => 2_300, "completion_tokens" => 100, "total_tokens" => 2_400}), window: 131_072)
  end

  def test_sums_prompt_and_completion_when_total_is_missing
    assert_equal "ctx: 850/4.1k", reading(replied({"prompt_tokens" => 800, "completion_tokens" => 50}), window: 4_096)
  end

  def test_a_conversation_with_no_replies_yet_reads_as_empty
    assert_equal "ctx: 0/131k", reading(fresh, window: 131_072)
  end

  def test_unknowns_read_as_question_marks
    assert_equal "ctx: ?/?", reading(replied(nil), window: nil)
  end

  def test_keeps_the_last_known_window_when_the_model_is_unloaded
    provider = FakeProvider.new(131_072)
    meter = ContextMeter.new(provider, "m")
    meter.line(fresh)
    provider.window = nil # the server unloaded the model while idle

    assert_equal "ctx: 0/131k", meter.line(fresh)
  end

  def test_large_windows_abbreviate_to_millions
    assert_equal "ctx: 262k/1.0M", reading(replied({"total_tokens" => 262_144}), window: 1_048_576)
  end
end
