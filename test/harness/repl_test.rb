require_relative "../test_helper"
require_relative "archetype_helper"

# Drives harness/repl.rb the way a terminal does — a child process, piped
# stdin, its own exit status — to pin what a first-time evaluator sees when
# the model server isn't there (issue #33): one actionable line, and a
# session that survives to the next prompt.
class ReplTest < Minitest::Test
  include ArchetypeHelper

  def test_a_dead_endpoint_costs_one_turn_not_the_session
    out, err, status = run_harness("harness/repl.rb",
      env: {"LYMAN_BASE_URL" => UNREACHABLE_BASE_URL},
      stdin_data: "first\nsecond\n\n")

    assert status.success?, out + err
    # One prompt per input line, blank line included: the loop kept going.
    assert_equal 3, out.scan("you>").size
    assert_equal 2, out.scan("can't reach #{UNREACHABLE_BASE_URL}").size
    assert_includes out, "is your server running?"
    refute_match TRACE_PATTERN, out + err
  end

  def test_a_missing_model_prints_the_servers_own_reason_and_keeps_the_session
    server, thread, base_url, _bodies =
      start_model_server([error_reply("404 Not Found", "model 'doesnotexist:1b' not found")])

    out, err, status = run_harness("harness/repl.rb",
      env: {"LYMAN_BASE_URL" => base_url, "LYMAN_MODEL" => "doesnotexist:1b"},
      stdin_data: "first\nsecond\n\n")

    assert status.success?, out + err
    assert_equal 3, out.scan("you>").size
    assert_equal 2, out.scan("chat completion failed (404)").size
    assert_includes out, "model 'doesnotexist:1b' not found"
    assert_includes out, "is the model pulled?"
    refute_match TRACE_PATTERN, out + err
  ensure
    stop_server(server, thread)
  end

  # The circuit is rebuilt per turn, so prove the turns still work: two
  # answers, and the second request carrying the first exchange.
  def test_turns_still_run_and_still_accrete
    server, thread, base_url, bodies = start_model_server([assistant_reply("the answer")])

    out, err, status = run_harness("harness/repl.rb",
      env: {"LYMAN_BASE_URL" => base_url},
      stdin_data: "one\ntwo\n\n")

    assert status.success?, out + err
    assert_equal 2, out.scan("the answer").size
    assert_equal 2, bodies.size
    assert_equal "one", bodies.first["messages"].last["content"]
    sent = bodies.last["messages"].map { |m| m["content"] }
    assert_includes sent, "the answer"
    assert_includes sent, "two"
  ensure
    stop_server(server, thread)
  end

  # A turn that fails mid-session doesn't corrupt the one after it: the
  # conversation stays the last good one, and the next good turn still
  # carries it.
  def test_a_good_turn_after_a_bad_one_still_carries_the_last_good_turn
    server, thread, base_url, bodies = start_model_server([
      assistant_reply("my name is Joel"),
      error_reply("503 Service Unavailable", "server is busy"),
      assistant_reply("Joel")
    ])

    out, err, status = run_harness("harness/repl.rb",
      env: {"LYMAN_BASE_URL" => base_url},
      stdin_data: "remember my name\nlost turn\nwhat is my name\n\n")

    assert status.success?, out + err
    assert_includes out, "chat completion failed (503)"
    assert_equal 3, bodies.size
    assert_equal "my name is Joel", bodies.last["messages"].find { |m| m["role"] == "assistant" }["content"]
    refute_includes bodies.last["messages"].to_s, "lost turn"
  ensure
    stop_server(server, thread)
  end
end
