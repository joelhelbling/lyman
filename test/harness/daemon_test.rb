require_relative "../test_helper"
require_relative "archetype_helper"

# Drives harness/daemon.rb the way its operator does — a child process on a
# TCP port, one line per event in, one line per event out — to pin that a
# failing event costs that event and not the daemon (issue #33).
class DaemonTest < Minitest::Test
  include ArchetypeHelper

  def start_daemon(env)
    port = free_port
    child_in, child_out, child_err, wait = Open3.popen3(default_env.merge(env).merge("LYMAN_PORT" => port.to_s),
      RbConfig.ruby, File.join(REPO_ROOT, "harness/daemon.rb"))
    child_in.close

    banner = Timeout.timeout(20) { child_out.gets }
    raise "daemon never started: #{banner.inspect} / #{child_err.read}" unless banner.to_s.include?("listening on port #{port}")

    [port, child_out, child_err, wait]
  end

  def send_event(port, text)
    TCPSocket.open("127.0.0.1", port) do |socket|
      socket.puts text
      socket.gets
    end
  end

  # ctrl-c is how a daemon is stopped; the shell's Interrupt path must be a
  # clean exit, not a trace.
  def stop_daemon(child_out, child_err, wait)
    Process.kill(:INT, wait.pid)
    status = Timeout.timeout(15) { wait.value }
    [status, child_out.read, child_err.read]
  end

  def test_a_dead_endpoint_answers_the_event_with_one_line_and_keeps_listening
    port, out, err, wait = start_daemon({"LYMAN_BASE_URL" => UNREACHABLE_BASE_URL})

    first = Timeout.timeout(20) { send_event(port, "what time is it?") }
    second = Timeout.timeout(20) { send_event(port, "and now?") }
    status, log, err = stop_daemon(out, err, wait)

    assert_includes first, "error: can't reach #{UNREACHABLE_BASE_URL}"
    assert_includes first, "is your server running?"
    assert_includes second, "error: can't reach #{UNREACHABLE_BASE_URL}"
    assert_equal 2, log.scan("reply: error: can't reach").size
    refute_match TRACE_PATTERN, log + err
    assert status.success?, log + err
  end

  # Good event, bad event, good event: the circuit is rebuilt per event, so
  # a mid-session failure neither kills the listener nor corrupts what comes
  # after it.
  def test_a_failing_event_is_followed_by_a_working_one
    server, thread, base_url, bodies = start_model_server([
      assistant_reply("12:34"),
      error_reply("503 Service Unavailable", "server is busy"),
      assistant_reply("12:35")
    ])
    port, out, err, wait = start_daemon({"LYMAN_BASE_URL" => base_url})

    first = Timeout.timeout(20) { send_event(port, "what time is it?") }
    second = Timeout.timeout(20) { send_event(port, "and now?") }
    third = Timeout.timeout(20) { send_event(port, "still there?") }
    status, log, err = stop_daemon(out, err, wait)

    assert_equal "12:34\n", first
    assert_includes second, "error: chat completion failed (503)"
    assert_includes second, "server is busy"
    assert_equal "12:35\n", third
    assert_equal 3, bodies.size
    assert_equal 1, log.scan("reply: error: chat completion failed").size
    refute_match TRACE_PATTERN, log + err
    assert status.success?, log + err
  ensure
    stop_server(server, thread)
  end
end
