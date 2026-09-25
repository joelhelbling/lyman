require_relative "../test_helper"
require "shifty"
require "lyman"
require "socket"
require "json"
require "fileutils"
require "open3"
require_relative "../../harness/agents/file_editor"

# Drives the file editor agent the way a root harness's TOOLS array does:
# a real handler call, with a fake OpenAI-compatible endpoint standing in
# for the sub-agent's model — same fake-server pattern as file_reader_test.rb.
# check:/test: are nil, callables, or cheap ruby argv commands, never the
# factory defaults, so these stay fast and hermetic.
class FileEditorTest < Minitest::Test
  include Shifty::DSL

  # Answers chat completion requests in order from +script+ (an array of
  # OpenAI-style "message" hashes); the last entry repeats once the script
  # is exhausted, so a runaway loop keeps getting a tool call forever.
  # Records each request body into +bodies+.
  def start_model_server(script, bodies)
    server = TCPServer.new("127.0.0.1", 0)
    index = 0
    thread = Thread.new do
      loop do
        client = server.accept
        headers = {}
        client.gets
        while (line = client.gets) && line != "\r\n"
          key, value = line.split(":", 2)
          headers[key.strip.downcase] = value.strip
        end
        bodies << JSON.parse(client.read(headers["content-length"].to_i))

        message = script[[index, script.size - 1].min]
        index += 1
        body = {"choices" => [{"message" => message}]}.to_json
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
          "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      rescue IOError, Errno::EBADF
        break
      end
    end
    [server, thread, "http://127.0.0.1:#{server.addr[1]}"]
  end

  def tool_call_message(name, arguments, id: "call_1")
    {
      "role" => "assistant", "content" => nil,
      "tool_calls" => [{"id" => id, "type" => "function", "function" => {"name" => name, "arguments" => arguments.to_json}}]
    }
  end

  def final_message(text)
    {"role" => "assistant", "content" => text}
  end

  def with_server(script)
    bodies = []
    server, thread, base_url = start_model_server(script, bodies)
    yield base_url, bodies
  ensure
    server&.close
    thread&.join(5)
  end

  def with_tree(files)
    Dir.mktmpdir do |dir|
      files.each do |rel, contents|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, contents)
      end
      yield File.realpath(dir)
    end
  end

  # A port nothing listens on: if the handler ever tries to connect, the
  # test fails with a connection error rather than silently passing.
  UNREACHABLE_BASE_URL = "http://127.0.0.1:1"

  GREET = "def greet(name)\n  \"hello \#{name}\"\nend\n"

  # The common script: read the file, patch it, then summarize.
  def edit_script(summary = "Made greet upcase the name in greet.rb.")
    [
      tool_call_message("read_file", {"path" => "greet.rb"}),
      tool_call_message("search_replace", {
        "path" => "greet.rb", "search" => "  \"hello \#{name}\"\n", "replace" => "  \"hello \#{name.upcase}\"\n"
      }, id: "call_2"),
      final_message(summary)
    ]
  end

  def editor(root:, base_url:, **opts)
    file_editor(root: root, default_model: "m", default_base_url: base_url, check: nil, test: nil, **opts)
  end

  def test_schema_is_named_file_editor_with_request_required
    tool = editor(root: Dir.mktmpdir, base_url: UNREACHABLE_BASE_URL)

    function = tool[:schema]["function"]
    assert_equal "file_editor", function["name"]
    assert_equal ["request"], function["parameters"]["required"]
  end

  def test_schema_names_the_check_and_test_commands_only_when_set
    root = Dir.mktmpdir
    with = file_editor(root: root, default_model: "m", default_base_url: UNREACHABLE_BASE_URL,
      check: "lint-it", test: "test-it")[:schema].dig("function", "description")
    without = editor(root: root, base_url: UNREACHABLE_BASE_URL)[:schema].dig("function", "description")

    assert_includes with, "lint-it"
    assert_includes with, "test-it"
    refute_includes without, "running"
    refute_includes without, "tests run"
  end

  def test_blank_request_is_refused_without_contacting_a_model
    tool = editor(root: Dir.mktmpdir, base_url: UNREACHABLE_BASE_URL)

    assert_equal "Pass a request describing the change to make.", tool[:handler].call({"request" => "  "})
    assert_equal "Pass a request describing the change to make.", tool[:handler].call({})
  end

  def test_end_to_end_patches_the_file_and_reports_the_summary_and_changed_path
    with_tree("greet.rb" => GREET) do |root|
      with_server(edit_script) do |base_url, bodies|
        tool = editor(root: root, base_url: base_url)

        result = tool[:handler].call({"request" => "in greet.rb, make greet upcase the name"})

        assert_includes File.read(File.join(root, "greet.rb")), "name.upcase"
        assert_equal "Made greet upcase the name in greet.rb.\nChanged: greet.rb", result
        assert_equal 3, bodies.size
      end
    end
  end

  def test_no_change_reports_so_and_does_not_run_tests
    with_tree("greet.rb" => GREET) do |root|
      with_server([final_message("greet already does that.")]) do |base_url, _bodies|
        test_calls = 0
        tool = editor(root: root, base_url: base_url, test: -> {
          test_calls += 1
          nil
        })

        result = tool[:handler].call({"request" => "make greet greet"})

        assert_equal "greet already does that.\nNo files were changed.", result
        assert_equal 0, test_calls
      end
    end
  end

  # A refused patch (search not found) leaves the file alone, so it
  # mustn't count as a change — tracking compares the file, not the reply.
  def test_a_refused_patch_is_not_counted_as_a_change
    with_tree("greet.rb" => GREET) do |root|
      script = [
        tool_call_message("search_replace", {"path" => "greet.rb", "search" => "nope", "replace" => "x"}),
        final_message("Could not find it.")
      ]
      with_server(script) do |base_url, _bodies|
        result = editor(root: root, base_url: base_url)[:handler].call({"request" => "r"})

        assert_includes result, "No files were changed."
      end
    end
  end

  def test_tests_run_exactly_once_after_the_last_model_request_and_pass_is_one_line
    with_tree("greet.rb" => GREET) do |root|
      with_server(edit_script) do |base_url, bodies|
        requests_seen_at_test_time = []
        tool = editor(root: root, base_url: base_url, test: -> {
          requests_seen_at_test_time << bodies.size
          nil
        })

        result = tool[:handler].call({"request" => "upcase the name"})

        assert_equal [bodies.size], requests_seen_at_test_time
        assert result.end_with?("Changed: greet.rb\nTests: passed."), result
      end
    end
  end

  # The structural guarantee: tests run after the circuit, so their output
  # reaches the caller and never the sub-agent's model.
  def test_failing_test_output_reaches_the_caller_but_never_the_model
    with_tree("greet.rb" => GREET) do |root|
      with_server(edit_script) do |base_url, bodies|
        tool = editor(root: root, base_url: base_url, test: [RbConfig.ruby, "-e", "puts 'MARKER_TEST_FAILURE'; exit 3"])

        result = tool[:handler].call({"request" => "upcase the name"})

        assert_includes result, "Tests: failed —\nexit 3\nMARKER_TEST_FAILURE"
        bodies.each { |body| refute_includes body.to_json, "MARKER_TEST_FAILURE" }
      end
    end
  end

  def test_test_commands_run_from_root
    with_tree("greet.rb" => GREET) do |root|
      with_server(edit_script) do |base_url, _bodies|
        tool = editor(root: root, base_url: base_url, test: [RbConfig.ruby, "-e", "puts Dir.pwd; exit 1"])

        result = tool[:handler].call({"request" => "upcase the name"})

        assert_includes result, root
      end
    end
  end

  def test_a_test_command_that_cannot_run_says_so
    with_tree("greet.rb" => GREET) do |root|
      with_server(edit_script) do |base_url, _bodies|
        tool = editor(root: root, base_url: base_url, test: "definitely-not-a-real-command-xyz")

        result = tool[:handler].call({"request" => "upcase the name"})

        assert_includes result, "Tests: failed —\ncould not run `definitely-not-a-real-command-xyz`"
      end
    end
  end

  def test_long_test_output_keeps_the_tail
    with_tree("greet.rb" => GREET) do |root|
      with_server(edit_script) do |base_url, _bodies|
        output = "HEAD_OF_OUTPUT\n" + ("x" * 10_000) + "\nSUMMARY_AT_THE_END"
        tool = editor(root: root, base_url: base_url, test: -> { output })

        result = tool[:handler].call({"request" => "upcase the name"})

        assert_includes result, "Tests: failed —\n[test output truncated]\n"
        assert_includes result, "SUMMARY_AT_THE_END"
        refute_includes result, "HEAD_OF_OUTPUT"
      end
    end
  end

  # The agent may give up with a check still failing; the final sweep
  # re-checks what it changed so the caller hears about it.
  def test_a_remaining_check_failure_is_reported
    with_tree("greet.rb" => GREET) do |root|
      with_server(edit_script("Done, though the check complains.")) do |base_url, _bodies|
        check = ->(abs) { "#{File.basename(abs)}:2 upcase is frowned upon" if File.read(abs).include?("upcase") }
        tool = editor(root: root, base_url: base_url, check: check)

        result = tool[:handler].call({"request" => "upcase the name"})

        assert_includes result, "Changed: greet.rb\nCheck still failing —\ngreet.rb:\ngreet.rb:2 upcase is frowned upon"
      end
    end
  end

  def test_a_passing_check_adds_nothing_to_the_report
    with_tree("greet.rb" => GREET) do |root|
      with_server(edit_script) do |base_url, _bodies|
        tool = editor(root: root, base_url: base_url, check: [RbConfig.ruby, "-wc"])

        result = tool[:handler].call({"request" => "upcase the name"})

        assert_equal "Made greet upcase the name in greet.rb.\nChanged: greet.rb", result
      end
    end
  end

  def test_runaway_still_reports_changed_files_and_runs_tests
    with_tree("greet.rb" => GREET) do |root|
      # Patch, then a read that repeats forever: max_rounds: 3 is the only
      # thing that ends it, after the file has already changed.
      script = edit_script[1..1] + [tool_call_message("read_file", {"path" => "greet.rb"})]
      with_server(script) do |base_url, _bodies|
        test_calls = 0
        tool = editor(root: root, base_url: base_url, max_rounds: 3, test: -> {
          test_calls += 1
          nil
        })

        result = tool[:handler].call({"request" => "upcase the name"})

        assert_match(/\Afile_editor stopped after 3 rounds before finishing/, result)
        assert_includes result, "Changed: greet.rb"
        assert_includes result, "Tests: passed."
        assert_equal 1, test_calls
      end
    end
  end

  def test_an_empty_final_reply_says_so
    with_tree("greet.rb" => GREET) do |root|
      with_server([final_message("")]) do |base_url, _bodies|
        result = editor(root: root, base_url: base_url)[:handler].call({"request" => "r"})

        assert_equal "file_editor finished without a summary.\nNo files were changed.", result
      end
    end
  end

  def test_created_files_count_as_changed_once_each_in_order
    with_tree("greet.rb" => GREET) do |root|
      script = [
        tool_call_message("search_replace", {"path" => "new.rb", "search" => "", "replace" => "x = 1\n"}),
        tool_call_message("search_replace", {"path" => "./greet.rb", "search" => "hello", "replace" => "hi"}, id: "c2"),
        tool_call_message("search_replace", {"path" => "greet.rb", "search" => "hi", "replace" => "hey"}, id: "c3"),
        final_message("Done.")
      ]
      with_server(script) do |base_url, _bodies|
        result = editor(root: root, base_url: base_url)[:handler].call({"request" => "r"})

        assert_includes result, "Changed: new.rb, greet.rb"
      end
    end
  end

  def test_the_sub_agent_has_no_test_tool
    with_tree("greet.rb" => GREET) do |root|
      with_server([final_message("ok")]) do |base_url, bodies|
        editor(root: root, base_url: base_url, test: -> {})[:handler].call({"request" => "r"})

        names = bodies.first["tools"].map { |t| t.dig("function", "name") }
        assert_equal %w[search_files read_file search_replace], names
      end
    end
  end

  def test_each_call_gets_a_fresh_conversation
    with_tree("greet.rb" => GREET) do |root|
      with_server([final_message("one"), final_message("two")]) do |base_url, bodies|
        tool = editor(root: root, base_url: base_url)

        tool[:handler].call({"request" => "first request"})
        tool[:handler].call({"request" => "second request"})

        assert_includes bodies[0]["messages"].to_s, "first request"
        refute_includes bodies[1]["messages"].to_s, "first request"
        assert_includes bodies[1]["messages"].to_s, "second request"
      end
    end
  end

  def test_explicit_model_wins_over_env_and_default
    with_tree("greet.rb" => GREET) do |root|
      with_server([final_message("ok")]) do |base_url, bodies|
        with_env("LYMAN_FILE_EDITOR_MODEL" => "env-model") do
          editor(root: root, base_url: base_url, model: "explicit")[:handler].call({"request" => "r"})
        end

        assert_equal "explicit", bodies.last["model"]
      end
    end
  end

  def test_env_model_wins_over_default_when_no_explicit_model
    with_tree("greet.rb" => GREET) do |root|
      with_server([final_message("ok")]) do |base_url, bodies|
        with_env("LYMAN_FILE_EDITOR_MODEL" => "env-model") do
          editor(root: root, base_url: base_url)[:handler].call({"request" => "r"})
        end

        assert_equal "env-model", bodies.last["model"]
      end
    end
  end

  def test_default_model_used_when_no_explicit_model_or_env
    with_tree("greet.rb" => GREET) do |root|
      with_server([final_message("ok")]) do |base_url, bodies|
        with_env("LYMAN_FILE_EDITOR_MODEL" => nil) do
          editor(root: root, base_url: base_url)[:handler].call({"request" => "r"})
        end

        assert_equal "m", bodies.last["model"]
      end
    end
  end

  def test_bad_test_and_check_types_raise_at_wiring_time
    assert_raises(ArgumentError) { editor(root: Dir.mktmpdir, base_url: UNREACHABLE_BASE_URL, test: 42) }
    assert_raises(ArgumentError) { editor(root: Dir.mktmpdir, base_url: UNREACHABLE_BASE_URL, test: "") }
    assert_raises(ArgumentError) { editor(root: Dir.mktmpdir, base_url: UNREACHABLE_BASE_URL, check: 42) }
  end

  def test_standalone_run_without_args_exits_nonzero_with_usage
    script = File.expand_path("../../harness/agents/file_editor.rb", __dir__)
    _out, err, status = Open3.capture3(RbConfig.ruby, script)

    refute status.success?
    assert_match(/usage:/, err)
  end

  private

  def with_env(vars)
    originals = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    originals.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
