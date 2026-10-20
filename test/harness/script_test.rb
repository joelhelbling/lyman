require_relative "../test_helper"
require_relative "archetype_helper"

# Drives harness/script.rb the way cron or a Makefile does — one work item at
# launch, stdout as the answer, exit status as the verdict — to pin that a
# transport failure reads as one line and a non-zero status, never a trace
# (issue #33).
class ScriptTest < Minitest::Test
  include ArchetypeHelper

  def test_a_dead_endpoint_exits_nonzero_with_one_actionable_line
    out, err, status = run_harness("harness/script.rb",
      env: {"LYMAN_BASE_URL" => UNREACHABLE_BASE_URL},
      stdin_data: "summarize the notes")

    refute status.success?
    assert_equal 1, status.exitstatus
    assert_empty out
    assert_equal 1, err.lines.size
    assert_includes err, "can't reach #{UNREACHABLE_BASE_URL}"
    assert_includes err, "is your server running?"
    refute_match TRACE_PATTERN, err
  end

  def test_a_missing_model_reports_the_servers_own_reason
    server, thread, base_url, _bodies =
      start_model_server([error_reply("404 Not Found", "model 'doesnotexist:1b' not found")])

    out, err, status = run_harness("harness/script.rb",
      env: {"LYMAN_BASE_URL" => base_url, "LYMAN_MODEL" => "doesnotexist:1b"},
      args: ["summarize the notes"])

    refute status.success?
    assert_empty out
    assert_equal 1, err.lines.size
    assert_includes err, "chat completion failed (404)"
    assert_includes err, "model 'doesnotexist:1b' not found"
    refute_match TRACE_PATTERN, err
  ensure
    stop_server(server, thread)
  end

  # The rescue must not swallow the working path: the answer still lands on
  # stdout and the status is still zero.
  def test_a_working_model_still_answers_on_stdout_and_exits_zero
    server, thread, base_url, bodies = start_model_server([assistant_reply("three notes, one idea")])

    out, err, status = run_harness("harness/script.rb",
      env: {"LYMAN_BASE_URL" => base_url},
      args: ["summarize the notes"])

    assert status.success?, out + err
    assert_equal "three notes, one idea\n", out
    assert_empty err
    assert_equal "summarize the notes", bodies.first["messages"].last["content"]
  ensure
    stop_server(server, thread)
  end
end
