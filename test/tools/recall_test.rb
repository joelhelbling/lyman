require_relative "../test_helper"
require "shifty"
require "lyman"

class RecallTest < Minitest::Test
  include Shifty::DSL

  def test_schema_is_a_function_schema_named_recall_with_no_required_parameters
    store = Lyman::Store.new(":memory:")
    tool = Lyman::Tools.recall(store: store)

    assert_equal "function", tool[:schema]["type"]
    function = tool[:schema]["function"]
    assert_equal "recall", function["name"]
    assert_equal "object", function["parameters"]["type"]
    assert_equal [], function["parameters"]["required"]
    assert_includes function["parameters"]["properties"].keys, "address"
    assert_includes function["parameters"]["properties"].keys, "query"
    assert_includes function["parameters"]["properties"].keys, "conversation_id"
    assert_includes function["parameters"]["properties"].keys, "limit"
  ensure
    store.close
  end

  def test_fetch_by_single_address_renders_type_and_text
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new.with_user_message("what's buried in the yard")
    store.append(convo)
    tool = Lyman::Tools.recall(store: store)

    result = tool[:handler].call({"address" => "conv:#{convo.id}#1"})

    assert_includes result, "conv:#{convo.id}#1 user"
    assert_includes result, "what's buried in the yard"
  ensure
    store.close
  end

  def test_fetch_by_range_renders_each_element_separated_by_blank_line
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new
      .with_user_message("dig here")
      .with_assistant_message({"role" => "assistant", "content" => "sure thing"})
    store.append(convo)
    tool = Lyman::Tools.recall(store: store)

    result = tool[:handler].call({"address" => "conv:#{convo.id}#1-2"})

    assert_includes result, "conv:#{convo.id}#1 user"
    assert_includes result, "conv:#{convo.id}#2 assistant"
    assert_includes result, "\n\n"
  ensure
    store.close
  end

  def test_fetch_whole_conversation_with_bare_address
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new(system_prompt: "sp").with_user_message("hi")
    store.append(convo)
    tool = Lyman::Tools.recall(store: store)

    result = tool[:handler].call({"address" => "conv:#{convo.id}"})

    assert_includes result, "conv:#{convo.id}#1 system"
    assert_includes result, "conv:#{convo.id}#2 user"
  ensure
    store.close
  end

  def test_renders_tool_call_as_name_with_arguments
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new.with_assistant_message({
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        {"id" => "call_1", "type" => "function", "function" => {"name" => "dig", "arguments" => '{"location":"backyard"}'}}
      ]
    })
    store.append(convo)
    tool = Lyman::Tools.recall(store: store)

    result = tool[:handler].call({"address" => "conv:#{convo.id}#2"})

    assert_includes result, "conv:#{convo.id}#2 tool_call"
    assert_includes result, 'dig({"location":"backyard"})'
  ensure
    store.close
  end

  def test_renders_tool_result_text
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new
      .with_assistant_message({
        "role" => "assistant", "content" => nil,
        "tool_calls" => [{"id" => "call_1", "type" => "function", "function" => {"name" => "dig", "arguments" => "{}"}}]
      })
      .with_tool_result("call_1", "found nothing")
    store.append(convo)
    tool = Lyman::Tools.recall(store: store)

    result = tool[:handler].call({"address" => "conv:#{convo.id}#3"})

    assert_includes result, "conv:#{convo.id}#3 tool_result"
    assert_includes result, "found nothing"
  ensure
    store.close
  end

  def test_query_finds_text_by_full_text_search
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new.with_user_message("where is the treasure buried")
    store.append(convo)
    tool = Lyman::Tools.recall(store: store)

    result = tool[:handler].call({"query" => "treasure"})

    assert_includes result, "treasure"
  ensure
    store.close
  end

  def test_query_scoped_by_conversation_id_reaches_an_ancestor_element
    store = Lyman::Store.new(":memory:")
    root = Lyman::Conversation.new.with_user_message("shared keyword apple")
    store.append(root)
    child = Lyman::Conversation.new(parent_id: root.id).with_user_message("child message")
    store.append(child)
    tool = Lyman::Tools.recall(store: store)

    result = tool[:handler].call({"query" => "apple", "conversation_id" => child.id})

    assert_includes result, "apple"
    assert_includes result, root.id
  ensure
    store.close
  end

  # Small models often send every parameter, blanking the unused ones and
  # stringifying numbers.
  def test_blank_address_is_ignored_and_string_limit_is_accepted
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new.with_user_message("the treasure is under the oak")
    store.append(convo)
    tool = Lyman::Tools.recall(store: store)

    result = tool[:handler].call({"address" => "", "query" => "treasure", "limit" => "5"})

    assert_includes result, "conv:#{convo.id}#1 user"
  ensure
    store.close
  end

  def test_neither_address_nor_query_returns_explanatory_string
    store = Lyman::Store.new(":memory:")
    tool = Lyman::Tools.recall(store: store)

    result = tool[:handler].call({})

    assert_kind_of String, result
    assert_includes result, "address"
    assert_includes result, "query"
  ensure
    store.close
  end

  def test_both_address_and_query_returns_explanatory_string
    store = Lyman::Store.new(":memory:")
    tool = Lyman::Tools.recall(store: store)

    result = tool[:handler].call({"address" => "conv:abc#1", "query" => "hello"})

    assert_kind_of String, result
    assert_includes result, "not both"
  ensure
    store.close
  end

  def test_malformed_address_returns_helpful_message_instead_of_raising
    store = Lyman::Store.new(":memory:")
    tool = Lyman::Tools.recall(store: store)

    result = tool[:handler].call({"address" => "not-an-address"})

    assert_kind_of String, result
    assert_includes result, "conv:ID"
  ensure
    store.close
  end

  def test_nothing_found_for_address_returns_a_plain_string
    store = Lyman::Store.new(":memory:")
    tool = Lyman::Tools.recall(store: store)

    result = tool[:handler].call({"address" => "conv:nonexistent#1"})

    assert_kind_of String, result
    assert_includes result, "Nothing found"
  ensure
    store.close
  end

  def test_truncation_note_appended_when_max_chars_is_small
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new
      .with_user_message("a" * 100)
      .with_assistant_message({"role" => "assistant", "content" => "b" * 100})
    store.append(convo)
    tool = Lyman::Tools.recall(store: store, max_chars: 50)

    result = tool[:handler].call({"address" => "conv:#{convo.id}#1-2"})

    assert_includes result, "recall truncated at 50 chars"
    assert_includes result, "narrow the range, e.g. conv:#{convo.id}#1-1"
  ensure
    store.close
  end

  # Echoing back the range that just overflowed would invite a small model
  # to repeat it; a single oversized element has nothing narrower to offer.
  def test_truncation_of_a_single_element_says_so_instead_of_suggesting_a_range
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new.with_user_message("a" * 100)
    store.append(convo)
    tool = Lyman::Tools.recall(store: store, max_chars: 50)

    result = tool[:handler].call({"address" => "conv:#{convo.id}#1"})

    assert_includes result, "this single element is longer than the cap"
    refute_includes result, "narrow the range"
  ensure
    store.close
  end

  def test_blank_conversation_id_is_ignored_rather_than_scoping_to_nothing
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new.with_user_message("the treasure is under the oak")
    store.append(convo)
    tool = Lyman::Tools.recall(store: store)

    result = tool[:handler].call({"query" => "treasure", "conversation_id" => " "})

    assert_includes result, "conv:#{convo.id}#1 user"
  end

  def test_limit_is_clamped_to_a_sane_range
    limits = []
    fake_store = Object.new
    fake_store.define_singleton_method(:search) do |_query, conversation_id:, limit:|
      limits << limit
      []
    end
    tool = Lyman::Tools.recall(store: fake_store)

    tool[:handler].call({"query" => "x", "limit" => "-5"})
    tool[:handler].call({"query" => "x", "limit" => 100_000})
    tool[:handler].call({"query" => "x", "limit" => "nonsense"})

    assert_equal [1, 50, 10], limits
  end

  def test_works_end_to_end_through_tool_execution
    store = Lyman::Store.new(":memory:")
    seed = Lyman::Conversation.new.with_user_message("find the treasure")
    store.append(seed)

    tools = [Lyman::Tools.recall(store: store)]
    handlers = tools.to_h { |tool| [tool[:schema].dig("function", "name"), tool[:handler]] }

    convo = Lyman::Conversation.new.with_assistant_message({
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        {"id" => "call_1", "type" => "function", "function" => {"name" => "recall", "arguments" => JSON.generate({"address" => "conv:#{seed.id}#1"})}}
      ]
    })

    pipeline = source_worker([convo]) | Lyman::Workers.tool_execution(handlers)
    result = pipeline.shift

    tool_result = result.elements.last
    assert_equal "tool_result", tool_result.type
    assert_includes tool_result.content["text"], "find the treasure"
  ensure
    store.close
  end

  # Proves the tool is duck-typed against Lyman::Store's interface rather
  # than depending on the class itself — a fake answering fetch/search
  # works exactly the same, and this file never requires sqlite3.
  def test_works_with_a_fake_duck_typed_store
    fake_store = Class.new do
      def fetch(address)
        [Lyman::Element.new(conversation_id: "fake", seq: 1, type: "user", content: {"text" => "hello from a fake store"})]
      end

      def search(query, conversation_id:, limit:)
        []
      end
    end.new

    tool = Lyman::Tools.recall(store: fake_store)

    result = tool[:handler].call({"address" => "conv:fake#1"})

    assert_includes result, "hello from a fake store"
  end
end
