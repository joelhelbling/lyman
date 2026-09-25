require_relative "../test_helper"
require "shifty"
require "lyman"
require "socket"
require "json"
require "fileutils"
require "open3"
require_relative "../../harness/agents/file_reader"

# Drives the file reader agent the way a root harness's TOOLS array does:
# a real handler call, with a fake OpenAI-compatible endpoint standing in
# for the sub-agent's model — same fake-server pattern as compactor_test.rb.
class FileReaderTest < Minitest::Test
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

  def tool_call_message(name, arguments)
    {
      "role" => "assistant", "content" => nil,
      "tool_calls" => [{"id" => "call_1", "type" => "function", "function" => {"name" => name, "arguments" => arguments.to_json}}]
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

  def test_schema_is_named_file_reader_with_path_required_and_shape_enum
    tool = file_reader(root: Dir.mktmpdir, default_model: "m", default_base_url: UNREACHABLE_BASE_URL)

    function = tool[:schema]["function"]
    assert_equal "file_reader", function["name"]
    assert_equal ["path"], function["parameters"]["required"]
    assert_equal %w[excerpts outline answer], function["parameters"]["properties"]["shape"]["enum"]
  end

  def test_routing_bypasses_delegation_for_a_single_file_with_no_query
    with_tree("foo.txt" => "line one\nline two\n") do |root|
      tool = file_reader(root: root, default_model: "m", default_base_url: UNREACHABLE_BASE_URL)

      result = tool[:handler].call({"path" => "foo.txt"})

      assert_includes result, "line one"
      assert_includes result, "line two"
    end
  end

  def test_routing_bypass_resolves_a_glob_matching_exactly_one_file
    with_tree("a.txt" => "only file contents here\n", "b.rb" => "x\n") do |root|
      tool = file_reader(root: root, default_model: "m", default_base_url: UNREACHABLE_BASE_URL)

      result = tool[:handler].call({"path" => "*.txt"})

      assert_includes result, "only file contents here"
    end
  end

  def test_routing_bypass_returns_a_large_file_untruncated
    content = (1..2000).map { |i| "line #{i} #{"x" * 20}" }.join("\n")
    with_tree("big.txt" => content) do |root|
      tool = file_reader(root: root, default_model: "m", default_base_url: UNREACHABLE_BASE_URL)

      result = tool[:handler].call({"path" => "big.txt"})

      assert_operator content.length, :>, 20_000
      refute_includes result, "truncated"
      assert_includes result, "line 2000"
    end
  end

  def test_routing_delegates_when_a_query_is_present_even_for_a_small_file
    with_tree("foo.txt" => "hello world\n") do |root|
      with_server([final_message("nothing relevant")]) do |base_url, bodies|
        tool = file_reader(root: root, default_model: "m", default_base_url: base_url)

        tool[:handler].call({"path" => "foo.txt", "query" => "what does this say"})

        refute_empty bodies
      end
    end
  end

  def test_routing_delegates_when_no_query_but_the_glob_matches_several_files
    with_tree("a.txt" => "a", "b.txt" => "b") do |root|
      with_server([final_message("a summary")]) do |base_url, bodies|
        tool = file_reader(root: root, default_model: "m", default_base_url: base_url)

        tool[:handler].call({"path" => "*.txt"})

        refute_empty bodies
      end
    end
  end

  def test_delegation_end_to_end_runs_inner_tools_and_returns_only_the_stripped_answer
    with_tree("secret.txt" => "the vault code is 42\nsome other line that should not leak\n") do |root|
      script = [
        tool_call_message("read_file", {"path" => "secret.txt"}),
        final_message("  The vault code is 42 (secret.txt:1).  ")
      ]
      with_server(script) do |base_url, _bodies|
        tool = file_reader(root: root, default_model: "m", default_base_url: base_url)

        result = tool[:handler].call({"path" => "secret.txt", "query" => "what is the vault code"})

        assert_equal "The vault code is 42 (secret.txt:1).", result
        refute_includes result, "some other line that should not leak"
      end
    end
  end

  def test_trace_is_called_once_per_inner_round_with_a_conversation
    with_tree("f.txt" => "hi\n") do |root|
      script = [tool_call_message("read_file", {"path" => "f.txt"}), final_message("done")]
      with_server(script) do |base_url, _bodies|
        traced = []
        tool = file_reader(root: root, default_model: "m", default_base_url: base_url, trace: ->(c) { traced << c })

        tool[:handler].call({"path" => "f.txt", "query" => "q"})

        assert_equal 2, traced.size
        traced.each { |c| assert_kind_of Lyman::Conversation, c }
      end
    end
  end

  def test_each_call_gets_a_fresh_conversation
    with_tree("f.txt" => "hi\n") do |root|
      script = [final_message("answer one"), final_message("answer two")]
      with_server(script) do |base_url, bodies|
        tool = file_reader(root: root, default_model: "m", default_base_url: base_url)

        tool[:handler].call({"path" => "f.txt", "query" => "first question"})
        tool[:handler].call({"path" => "f.txt", "query" => "second question"})

        assert_includes bodies[0]["messages"].to_s, "first question"
        refute_includes bodies[1]["messages"].to_s, "first question"
        assert_includes bodies[1]["messages"].to_s, "second question"
      end
    end
  end

  def test_runaway_returns_a_short_stopped_message_instead_of_flooding_the_caller
    with_tree("f.txt" => "hi\n") do |root|
      # The script always hands back a tool call, so this never finishes on
      # its own — max_rounds: 2 is the only thing that ends it.
      with_server([tool_call_message("read_file", {"path" => "f.txt"})]) do |base_url, _bodies|
        tool = file_reader(root: root, default_model: "m", default_base_url: base_url, max_rounds: 2)

        result = tool[:handler].call({"path" => "f.txt", "query" => "q"})

        assert_match(/stopped after 2 rounds/, result)
      end
    end
  end

  # The round counter reaching max_rounds isn't itself failure: an answer
  # that arrives on the last allowed round is still the answer.
  def test_an_answer_on_the_last_allowed_round_is_kept
    with_tree("f.txt" => "hi\n") do |root|
      script = [tool_call_message("read_file", {"path" => "f.txt"}), final_message("f.txt:1-1: hi")]
      with_server(script) do |base_url, _bodies|
        tool = file_reader(root: root, default_model: "m", default_base_url: base_url, max_rounds: 2)

        result = tool[:handler].call({"path" => "f.txt", "query" => "q"})

        assert_equal "f.txt:1-1: hi", result
      end
    end
  end

  # An empty reply isn't a runaway, so it mustn't be reported as one.
  def test_an_empty_final_reply_says_so_without_claiming_a_runaway
    with_tree("f.txt" => "hi\n") do |root|
      with_server([final_message("")]) do |base_url, _bodies|
        tool = file_reader(root: root, default_model: "m", default_base_url: base_url)

        result = tool[:handler].call({"path" => "f.txt", "query" => "q"})

        assert_includes result, "finished without an answer"
        refute_match(/stopped after/, result)
      end
    end
  end

  def test_explicit_model_wins_over_env_and_default
    with_tree("f.txt" => "hi\n") do |root|
      with_server([final_message("ok")]) do |base_url, bodies|
        tool = file_reader(root: root, model: "explicit", default_model: "default", default_base_url: base_url)
        tool[:handler].call({"path" => "f.txt", "query" => "q"})

        assert_equal "explicit", bodies.last["model"]
      end
    end
  end

  def test_env_model_wins_over_default_when_no_explicit_model
    with_tree("f.txt" => "hi\n") do |root|
      with_server([final_message("ok")]) do |base_url, bodies|
        original = ENV["LYMAN_FILE_READER_MODEL"]
        ENV["LYMAN_FILE_READER_MODEL"] = "env-model"
        begin
          tool = file_reader(root: root, default_model: "default", default_base_url: base_url)
          tool[:handler].call({"path" => "f.txt", "query" => "q"})

          assert_equal "env-model", bodies.last["model"]
        ensure
          if original
            ENV["LYMAN_FILE_READER_MODEL"] = original
          else
            ENV.delete("LYMAN_FILE_READER_MODEL")
          end
        end
      end
    end
  end

  def test_default_model_used_when_no_explicit_model_or_env
    with_tree("f.txt" => "hi\n") do |root|
      with_server([final_message("ok")]) do |base_url, bodies|
        original = ENV.delete("LYMAN_FILE_READER_MODEL")
        begin
          tool = file_reader(root: root, default_model: "default-model", default_base_url: base_url)
          tool[:handler].call({"path" => "f.txt", "query" => "q"})

          assert_equal "default-model", bodies.last["model"]
        ensure
          ENV["LYMAN_FILE_READER_MODEL"] = original if original
        end
      end
    end
  end

  def test_escape_attempt_is_refused_without_delegating
    Dir.mktmpdir do |dir|
      project = File.join(dir, "project")
      FileUtils.mkdir_p(project)
      File.write(File.join(dir, "outside.txt"), "secret")

      tool = file_reader(root: project, default_model: "m", default_base_url: UNREACHABLE_BASE_URL)
      result = tool[:handler].call({"path" => "../outside.txt"})

      assert_includes result, "escapes the root"
    end
  end

  def test_absolute_path_outside_root_is_refused_without_delegating
    Dir.mktmpdir do |dir|
      project = File.join(dir, "project")
      FileUtils.mkdir_p(project)
      outside = File.join(dir, "outside.txt")
      File.write(outside, "secret")

      tool = file_reader(root: project, default_model: "m", default_base_url: UNREACHABLE_BASE_URL)
      result = tool[:handler].call({"path" => outside})

      assert_includes result, "escapes the root"
    end
  end

  def test_standalone_run_without_args_exits_nonzero_with_usage
    script = File.expand_path("../../harness/agents/file_reader.rb", __dir__)
    _out, err, status = Open3.capture3(RbConfig.ruby, script)

    refute status.success?
    assert_match(/usage:/, err)
  end

  def test_standalone_run_bypass_prints_the_whole_file_to_stdout
    with_tree("hi.txt" => "hello there\n") do |root|
      script = File.expand_path("../../harness/agents/file_reader.rb", __dir__)
      out, _err, status = Open3.capture3(
        {"LYMAN_BASE_URL" => UNREACHABLE_BASE_URL},
        RbConfig.ruby, script, "hi.txt",
        chdir: root
      )

      assert status.success?
      assert_includes out, "hello there"
    end
  end
end
