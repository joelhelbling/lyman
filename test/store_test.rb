require_relative "test_helper"
require "tmpdir"
require "lyman"

class StoreTest < Minitest::Test
  def test_append_persists_all_elements_with_correct_seq_type_content
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new(system_prompt: "sp").with_user_message("hi")

    store.append(convo)

    stored = store.elements(convo.id)
    assert_equal convo.elements.map(&:seq), stored.map(&:seq)
    assert_equal convo.elements.map(&:type), stored.map(&:type)
    assert_equal convo.elements.map(&:content), stored.map(&:content)
  ensure
    store.close
  end

  def test_append_is_idempotent
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new.with_user_message("hello there")

    store.append(convo)
    store.append(convo)

    assert_equal 1, store.elements(convo.id).size
    assert_equal 1, store.search("hello").size
  ensure
    store.close
  end

  def test_append_on_a_grown_conversation_adds_only_new_elements
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new.with_user_message("first")
    store.append(convo)

    grown = convo.with_assistant_message({"role" => "assistant", "content" => "second"})
    store.append(grown)

    assert_equal 2, store.elements(convo.id).size
    assert_equal %w[user assistant], store.elements(convo.id).map(&:type)
  ensure
    store.close
  end

  def test_persists_across_close_and_reopen
    Dir.mktmpdir do |dir|
      path = File.join(dir, "conversations.sqlite3")
      convo = Lyman::Conversation.new.with_user_message("persist me")

      store = Lyman::Store.new(path)
      store.append(convo)
      store.close

      reopened = Lyman::Store.new(path)
      begin
        stored = reopened.elements(convo.id)
        assert_equal 1, stored.size
        assert_equal "persist me", stored.first.content["text"]
      ensure
        reopened.close
      end
    end
  end

  def test_element_and_elements_with_range
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new(system_prompt: "sp")
      .with_user_message("u1")
      .with_assistant_message({"role" => "assistant", "content" => "a1"})
    store.append(convo)

    assert_equal "user", store.element(convo.id, 2).type
    assert_nil store.element(convo.id, 99)
    assert_equal %w[user assistant], store.elements(convo.id, 2..3).map(&:type)
    assert_equal %w[system user], store.elements(convo.id, 1...3).map(&:type)
    # Endless and beginless ranges agree with Conversation#elements_in.
    [2.., 2..., ..2, ...2].each do |range|
      assert_equal convo.elements_in(range).map(&:seq), store.elements(convo.id, range).map(&:seq), range.inspect
    end
  ensure
    store.close
  end

  def test_fetch_address_forms_round_trip_with_element_address
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new(system_prompt: "sp").with_user_message("u1")
    store.append(convo)

    all = store.fetch("conv:#{convo.id}")
    assert_equal 2, all.size

    one = store.fetch("conv:#{convo.id}#2")
    assert_equal [convo.element(2)], one
    assert_equal "conv:#{convo.id}#2", one.first.address

    range = store.fetch("conv:#{convo.id}#1-2")
    assert_equal 2, range.size

    assert_equal [], store.fetch("conv:#{convo.id}#99")
  ensure
    store.close
  end

  def test_fetch_malformed_address_raises_argument_error
    store = Lyman::Store.new(":memory:")

    assert_raises(ArgumentError) { store.fetch("not-an-address") }
    assert_raises(ArgumentError) { store.fetch("conv:abc#") }
  ensure
    store.close
  end

  def test_search_finds_text_across_element_types
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new
      .with_user_message("where is the treasure buried")
      .with_assistant_message({
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          {"id" => "call_1", "type" => "function", "function" => {"name" => "dig", "arguments" => '{"location":"backyard"}'}}
        ]
      })
      .with_tool_result("call_1", "found nothing in the backyard")
    store.append(convo)

    assert_equal 1, store.search("treasure").size
    assert_equal 1, store.search("dig").size
    # "backyard" appears in both the tool_call arguments and the tool_result.
    assert_equal 2, store.search("backyard").size
  ensure
    store.close
  end

  def test_search_with_punctuation_does_not_raise
    store = Lyman::Store.new(":memory:")
    convo = Lyman::Conversation.new.with_user_message("what's the time?")
    store.append(convo)

    assert_equal 1, store.search("what's the time?").size
  ensure
    store.close
  end

  def test_search_empty_query_returns_empty
    store = Lyman::Store.new(":memory:")
    assert_equal [], store.search("")
    assert_equal [], store.search("   ")
  ensure
    store.close
  end

  def test_search_restricted_by_conversation_id_includes_ancestors
    store = Lyman::Store.new(":memory:")

    root = Lyman::Conversation.new.with_user_message("shared keyword apple")
    store.append(root)

    child = Lyman::Conversation.new(parent_id: root.id).with_user_message("child message apple")
    store.append(child)

    unrelated = Lyman::Conversation.new.with_user_message("unrelated apple mention")
    store.append(unrelated)

    results = store.search("apple", conversation_id: child.id)
    ids = results.map(&:conversation_id)

    assert_includes ids, root.id
    assert_includes ids, child.id
    refute_includes ids, unrelated.id
  ensure
    store.close
  end

  def test_lineage_three_deep_chain_and_unknown_id
    store = Lyman::Store.new(":memory:")

    grandparent = Lyman::Conversation.new
    parent = Lyman::Conversation.new(parent_id: grandparent.id)
    child = Lyman::Conversation.new(parent_id: parent.id)

    store.append(grandparent)
    store.append(parent)
    store.append(child)

    assert_equal [child.id, parent.id, grandparent.id], store.lineage(child.id)
    assert_equal [], store.lineage("unknown-id")
  ensure
    store.close
  end

  def test_conversation_returns_parent_id
    store = Lyman::Store.new(":memory:")
    parent = Lyman::Conversation.new
    child = Lyman::Conversation.new(parent_id: parent.id)
    store.append(parent)
    store.append(child)

    assert_nil store.conversation(parent.id)["parent_id"]
    assert_equal parent.id, store.conversation(child.id)["parent_id"]
  ensure
    store.close
  end

  def test_load_round_trips_messages_ids_and_parent_id
    store = Lyman::Store.new(":memory:")
    original = Lyman::Conversation.new(system_prompt: "sp", parent_id: "parent-x")
      .with_user_message("hi")
      .with_assistant_message({"role" => "assistant", "content" => "hello"})
    store.append(original)

    loaded = store.load(original.id)

    assert_equal original.id, loaded.id
    assert_equal "parent-x", loaded.parent_id
    assert_equal original.messages, loaded.messages
  ensure
    store.close
  end

  def test_load_gives_fresh_control_state_including_nil_usage
    store = Lyman::Store.new(":memory:")
    original = Lyman::Conversation.new(system_prompt: "sp")
      .with_user_message("hi")
      .with_assistant_message({"role" => "assistant", "content" => "hello"})
      .with_usage({"prompt_tokens" => 42})
    store.append(original)

    loaded = store.load(original.id)

    assert_nil loaded.usage
  ensure
    store.close
  end

  def test_load_unknown_id_returns_nil
    store = Lyman::Store.new(":memory:")
    assert_nil store.load("unknown")
  ensure
    store.close
  end
end
