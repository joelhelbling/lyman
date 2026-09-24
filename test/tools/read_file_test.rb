require_relative "../test_helper"
require "shifty"
require "lyman"

class ReadFileTest < Minitest::Test
  include Shifty::DSL

  def test_schema_is_a_function_schema_named_read_file_requiring_path
    tool = Lyman::Tools.read_file(root: Dir.mktmpdir)

    assert_equal "function", tool[:schema]["type"]
    function = tool[:schema]["function"]
    assert_equal "read_file", function["name"]
    assert_equal ["path"], function["parameters"]["required"]
    assert_includes function["parameters"]["properties"].keys, "start_line"
    assert_includes function["parameters"]["properties"].keys, "end_line"
  end

  def test_reads_whole_file_with_line_numbers
    with_tree("a.txt" => "one\ntwo\nthree\n") do |root|
      tool = Lyman::Tools.read_file(root: root)

      result = tool[:handler].call({"path" => "a.txt"})

      assert_includes result, "1| one"
      assert_includes result, "2| two"
      assert_includes result, "3| three"
    end
  end

  def test_reads_a_line_range
    with_tree("a.txt" => "one\ntwo\nthree\nfour\n") do |root|
      tool = Lyman::Tools.read_file(root: root)

      result = tool[:handler].call({"path" => "a.txt", "start_line" => 2, "end_line" => 3})

      refute_includes result, "one"
      assert_includes result, "2| two"
      assert_includes result, "3| three"
      refute_includes result, "four"
    end
  end

  def test_accepts_string_line_numbers
    with_tree("a.txt" => "one\ntwo\nthree\n") do |root|
      tool = Lyman::Tools.read_file(root: root)

      result = tool[:handler].call({"path" => "a.txt", "start_line" => "2", "end_line" => "2"})

      assert_includes result, "2| two"
      refute_includes result, "one"
    end
  end

  def test_clamps_out_of_bounds_line_numbers_to_the_file
    with_tree("a.txt" => "one\ntwo\n") do |root|
      tool = Lyman::Tools.read_file(root: root)

      result = tool[:handler].call({"path" => "a.txt", "start_line" => 0, "end_line" => 500})

      assert_includes result, "1| one"
      assert_includes result, "2| two"
    end
  end

  def test_start_line_past_eof_says_so_with_line_count
    with_tree("a.txt" => "one\ntwo\n") do |root|
      tool = Lyman::Tools.read_file(root: root)

      result = tool[:handler].call({"path" => "a.txt", "start_line" => 10})

      assert_includes result, "2 lines"
      assert_includes result, "past the end"
    end
  end

  def test_start_after_end_says_so
    with_tree("a.txt" => "one\ntwo\nthree\n") do |root|
      tool = Lyman::Tools.read_file(root: root)

      result = tool[:handler].call({"path" => "a.txt", "start_line" => 3, "end_line" => 1})

      assert_includes result, "start_line"
      assert_includes result, "end_line"
    end
  end

  def test_truncates_at_max_chars_on_a_line_boundary_with_a_continue_hint
    lines = (1..100).map { |n| "line #{n}" }.join("\n")
    with_tree("a.txt" => lines) do |root|
      tool = Lyman::Tools.read_file(root: root, max_chars: 60)

      result = tool[:handler].call({"path" => "a.txt"})

      assert_includes result, "truncated at line"
      assert_includes result, "of 100"
      refute_includes result, "line 100"

      match = result.match(/pass start_line: (\d+) to continue/)
      refute_nil match
      next_start = match[1]

      continued = tool[:handler].call({"path" => "a.txt", "start_line" => next_start})
      assert_includes continued, "#{next_start}| line #{next_start}"
    end
  end

  def test_missing_file_returns_a_clear_message
    with_tree({}) do |root|
      tool = Lyman::Tools.read_file(root: root)

      result = tool[:handler].call({"path" => "nope.txt"})

      assert_includes result, "No such file"
    end
  end

  def test_directory_returns_a_clear_message
    with_tree("sub/.keep" => "") do |root|
      tool = Lyman::Tools.read_file(root: root)

      result = tool[:handler].call({"path" => "sub"})

      assert_includes result, "directory"
    end
  end

  def test_dotdot_escape_is_refused
    with_tree("a.txt" => "hi\n") do |root|
      tool = Lyman::Tools.read_file(root: root)

      result = tool[:handler].call({"path" => "../etc/passwd"})

      assert_includes result, "escapes the root"
    end
  end

  def test_symlink_escape_is_refused
    Dir.mktmpdir do |outside|
      File.write(File.join(outside, "secret.txt"), "sekrit\n")
      with_tree({}) do |root|
        File.symlink(File.join(outside, "secret.txt"), File.join(root, "link.txt"))
        tool = Lyman::Tools.read_file(root: root)

        result = tool[:handler].call({"path" => "link.txt"})

        assert_includes result, "escapes the root"
      end
    end
  end

  def test_binary_file_is_refused_with_a_clear_message
    with_tree({}) do |root|
      File.binwrite(File.join(root, "blob.bin"), "abc\x00def")
      tool = Lyman::Tools.read_file(root: root)

      result = tool[:handler].call({"path" => "blob.bin"})

      assert_includes result, "binary"
    end
  end

  def test_empty_file_says_so
    with_tree("empty.txt" => "") do |root|
      tool = Lyman::Tools.read_file(root: root)

      result = tool[:handler].call({"path" => "empty.txt"})

      assert_includes result, "empty"
    end
  end

  def test_blank_params_are_treated_as_absent
    with_tree("a.txt" => "one\ntwo\n") do |root|
      tool = Lyman::Tools.read_file(root: root)

      result = tool[:handler].call({"path" => "a.txt", "start_line" => "", "end_line" => " "})

      assert_includes result, "1| one"
      assert_includes result, "2| two"
    end
  end

  def test_works_end_to_end_through_tool_execution
    with_tree("a.txt" => "hello\n") do |root|
      tools = [Lyman::Tools.read_file(root: root)]
      handlers = tools.to_h { |tool| [tool[:schema].dig("function", "name"), tool[:handler]] }

      convo = Lyman::Conversation.new.with_assistant_message({
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          {"id" => "call_1", "type" => "function", "function" => {"name" => "read_file", "arguments" => JSON.generate({"path" => "a.txt"})}}
        ]
      })

      pipeline = source_worker([convo]) | Lyman::Workers.tool_execution(handlers)
      result = pipeline.shift

      tool_result = result.elements.last
      assert_equal "tool_result", tool_result.type
      assert_includes tool_result.content["text"], "1| hello"
    end
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
end
