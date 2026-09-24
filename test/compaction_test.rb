require_relative "test_helper"
require "lyman"

class CompactionTest < Minitest::Test
  INSTRUCTIONS = "Keep a ledger."

  def turn(conversation, user:, reply:)
    conversation.with_user_message(user).with_assistant_message({"role" => "assistant", "content" => reply})
  end

  def conversation
    @conversation ||= turn(
      Lyman::Conversation.new(id: "abc", system_prompt: "You are helpful."),
      user: "My name is Joel.", reply: "Nice to meet you, Joel."
    )
  end

  def ledger
    Lyman::Compaction::Ledger.new
  end

  # ── prompt ──────────────────────────────────────────────────────────────

  def test_prompt_numbers_summarizable_elements_and_shows_the_current_ledger
    prompt = ledger.prompt(conversation.elements, instructions: INSTRUCTIONS)

    assert_equal "system", prompt.elements.first.type
    assert_equal INSTRUCTIONS, prompt.elements.first.content["text"]
    text = prompt.elements.last.content["text"]
    assert_includes text, "Current ledger:\n(empty)"
    assert_includes text, "[1] user: My name is Joel."
    assert_includes text, "[2] assistant: Nice to meet you, Joel."
    refute_includes text, "You are helpful.", "the system prompt travels verbatim, it isn't digested"
  end

  def test_prompt_is_nil_when_nothing_is_worth_summarizing
    reasoning_only = Lyman::Conversation.new(id: "abc", system_prompt: "sys")
      .with_assistant_message({"role" => "assistant", "content" => nil, "reasoning" => "hmm"})
    batch = reasoning_only.elements.reject { |e| e.type == "assistant" }

    assert_nil ledger.prompt(batch, instructions: INSTRUCTIONS)
  end

  def test_prompt_renders_tool_calls_and_truncates_long_text
    convo = Lyman::Conversation.new(id: "abc")
      .with_user_message("time?")
      .with_assistant_message({"role" => "assistant", "content" => nil, "tool_calls" => [
        {"id" => "c1", "type" => "function", "function" => {"name" => "current_time", "arguments" => "{}"}}
      ]})
      .with_tool_result("c1", "x" * 5000)

    text = ledger.prompt(convo.elements, instructions: INSTRUCTIONS).elements.last.content["text"]

    assert_includes text, "tool_call: current_time({})"
    assert_includes text, "… [truncated]"
    assert_operator text.length, :<, 2500
  end

  # ── absorb ──────────────────────────────────────────────────────────────

  def test_absorb_maps_local_numbers_back_to_element_addresses
    reply = '[{"kind": "fact", "text": "The user is Joel.", "sources": [1, 2]}]'

    absorbed = ledger.absorb(conversation.elements, reply)

    assert_equal [{"kind" => "fact", "text" => "The user is Joel.", "sources" => ["conv:abc#2", "conv:abc#3"]}],
      absorbed.entries
  end

  def test_absorb_reads_json_wrapped_in_think_blocks_and_code_fences
    reply = "<think>[not this]</think>Here you go:\n```json\n" \
      '[{"kind": "decisions", "text": "Use SQLite.", "sources": ["[2]"]}]' + "\n```"

    entry = ledger.absorb(conversation.elements, reply).entries.first

    assert_equal "decision", entry["kind"]
    assert_equal ["conv:abc#3"], entry["sources"]
  end

  def test_absorb_cites_the_whole_batch_when_sources_are_missing_or_out_of_range
    reply = '[{"kind": "weird", "text": "Something.", "sources": [99]}]'

    entry = ledger.absorb(conversation.elements, reply).entries.first

    assert_equal "fact", entry["kind"]
    assert_equal ["conv:abc#2", "conv:abc#3"], entry["sources"]
  end

  def test_an_empty_array_means_nothing_new
    assert_empty ledger.absorb(conversation.elements, "[]").entries
  end

  def test_an_unreadable_or_missing_reply_records_a_gap_rather_than_losing_the_backlinks
    [nil, "I could not do that.", "[{not json}]", '["just a string"]'].each do |reply|
      entries = ledger.absorb(conversation.elements, reply).entries

      assert_equal 1, entries.size, "reply #{reply.inspect}"
      assert_equal "gap", entries.first["kind"]
      assert_equal ["conv:abc#2", "conv:abc#3"], entries.first["sources"]
    end
  end

  def test_absorbed_elements_are_not_digested_again
    absorbed = ledger.absorb(conversation.elements, "[]")

    assert_nil absorbed.prompt(conversation.elements, instructions: INSTRUCTIONS)
    grown = turn(conversation, user: "Bye.", reply: "Goodbye.")
    assert_includes absorbed.prompt(grown.elements, instructions: INSTRUCTIONS).elements.last.content["text"], "[1] user: Bye."
  end

  # ── compact ─────────────────────────────────────────────────────────────

  def test_compact_builds_a_child_conversation_of_ledger_plus_the_last_turn
    long = turn(conversation, user: "What's 2+2?", reply: "4")
      .with_usage({"prompt_tokens" => 9000})
    kept = ledger.absorb(long.elements, '[{"kind": "fact", "text": "The user is Joel.", "sources": [1, 2]}]')

    compacted = kept.compact(long)

    refute_equal long.id, compacted.id
    assert_equal long.id, compacted.parent_id
    assert_nil compacted.usage
    assert_equal long.max_rounds, compacted.max_rounds
    assert_equal %w[system user assistant], compacted.elements.map(&:type)
    assert_equal [1, 2, 3], compacted.elements.map(&:seq)
    assert(compacted.elements.all? { |e| e.conversation_id == compacted.id })

    system = compacted.elements.first.content["text"]
    assert system.start_with?("You are helpful.\n\n#{Lyman::Compaction::Ledger::HEADING}")
    assert_includes system, "Facts established:\n- The user is Joel. [conv:abc#2-3]"
    assert_equal ["What's 2+2?", "4"], compacted.elements.drop(1).map { |e| e.content["text"] }
  end

  def test_compact_keeps_the_tail_tool_exchange_but_drops_its_reasoning
    convo = conversation.with_user_message("time?")
      .with_assistant_message({"role" => "assistant", "content" => nil, "reasoning" => "hmm", "tool_calls" => [
        {"id" => "c1", "type" => "function", "function" => {"name" => "current_time", "arguments" => "{}"}}
      ]})
      .with_tool_result("c1", "noon")
      .with_assistant_message({"role" => "assistant", "content" => "It's noon."})

    compacted = ledger.compact(convo)

    assert_equal %w[system user assistant tool_call tool_result assistant], compacted.elements.map(&:type)
    assert_equal "You are helpful.", compacted.elements.first.content["text"], "an empty ledger adds nothing"
    assert_equal "tool", compacted.wire_messages[3]["role"]
  end

  def test_compacting_a_compaction_replaces_the_ledger_instead_of_stacking_it
    first = ledger.absorb(conversation.elements, '[{"text": "The user is Joel.", "sources": [1]}]')
    once = first.compact(conversation)
    first = first.cover(once)

    later = turn(once, user: "I like tea.", reply: "Noted.")
    second = first.absorb(later.elements, '[{"text": "The user likes tea.", "sources": [1]}]')
    twice = second.compact(later)

    system = twice.elements.first.content["text"]
    assert_equal 1, system.scan(Lyman::Compaction::Ledger::HEADING).size
    assert_includes system, "The user is Joel. [conv:abc#2]"
    assert_includes system, "The user likes tea. [conv:#{once.id}#4]"
    assert_equal once.id, twice.parent_id
  end

  def test_covering_a_compacted_conversation_keeps_its_opening_out_of_the_digest
    kept = ledger.absorb(conversation.elements, '[{"text": "The user is Joel.", "sources": [1]}]')
    compacted = kept.compact(conversation)
    kept = kept.cover(compacted)

    assert_nil kept.prompt(compacted.elements, instructions: INSTRUCTIONS)
    next_turn = compacted.with_user_message("Again?")
    assert_includes kept.prompt(next_turn.elements, instructions: INSTRUCTIONS).elements.last.content["text"], "[1] user: Again?"
  end

  def test_render_groups_by_kind_and_compresses_source_ranges
    kept = Lyman::Compaction::Ledger.new(entries: [
      {"kind" => "open", "text" => "Pick a name.", "sources" => ["conv:a#9"]},
      {"kind" => "fact", "text" => "It rains.", "sources" => ["conv:a#3", "conv:a#5", "conv:a#4", "conv:b#1"]}
    ])

    rendered = kept.render

    assert_operator rendered.index("Facts established"), :<, rendered.index("Open items")
    assert_includes rendered, "- It rains. [conv:a#3-5, conv:b#1]"
    assert_includes rendered, "- Pick a name. [conv:a#9]"
    assert_equal "", ledger.render
  end

  # ── request ─────────────────────────────────────────────────────────────

  def test_request_hands_the_conversation_over_and_returns_the_reply
    inbox = Thread::Queue.new
    compactor = Thread.new do
      request = inbox.pop
      request.reply << ledger.compact(request.conversation)
    end

    compacted = Lyman::Compaction.request(inbox, conversation)

    assert_equal conversation.id, compacted.parent_id
  ensure
    compactor&.join
  end

  def test_request_falls_back_to_the_original_when_the_sidecar_never_answers
    assert_same conversation, Lyman::Compaction.request(Thread::Queue.new, conversation, timeout: 0.05)
  end
end
