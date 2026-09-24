require_relative "../test_helper"
require "shifty"
require "lyman"

class SearchFilesTest < Minitest::Test
  include Shifty::DSL

  def test_schema_is_a_function_schema_named_search_files_with_no_required_parameters
    tool = Lyman::Tools.search_files(root: Dir.mktmpdir)

    assert_equal "function", tool[:schema]["type"]
    function = tool[:schema]["function"]
    assert_equal "search_files", function["name"]
    assert_equal "object", function["parameters"]["type"]
    assert_equal [], function["parameters"]["required"]
    assert_includes function["parameters"]["properties"].keys, "pattern"
    assert_includes function["parameters"]["properties"].keys, "glob"
    assert_includes function["parameters"]["properties"].keys, "path"
  end

  def test_pattern_hits_are_formatted_as_path_colon_line_colon_text
    with_tree("lib/thing.rb" => "class Thing\n  def dig\n  end\nend\n") do |root|
      tool = Lyman::Tools.search_files(root: root)

      result = tool[:handler].call({"pattern" => "def dig"})

      assert_includes result, "lib/thing.rb:2: def dig"
    end
  end

  def test_pattern_search_is_case_insensitive
    with_tree("lib/thing.rb" => "Treasure Buried Here\n") do |root|
      tool = Lyman::Tools.search_files(root: root)

      result = tool[:handler].call({"pattern" => "treasure buried"})

      assert_includes result, "lib/thing.rb:1:"
    end
  end

  def test_glob_restricts_by_file_name
    with_tree("lib/thing.rb" => "match me\n", "lib/thing.txt" => "match me\n") do |root|
      tool = Lyman::Tools.search_files(root: root)

      result = tool[:handler].call({"pattern" => "match me", "glob" => "**/*.rb"})

      assert_includes result, "lib/thing.rb"
      refute_includes result, "lib/thing.txt"
    end
  end

  def test_bare_glob_matches_at_any_depth
    with_tree("lib/nested/deep/store.rb" => "hi\n", "lib/other.rb" => "hi\n") do |root|
      tool = Lyman::Tools.search_files(root: root)

      result = tool[:handler].call({"glob" => "store.rb"})

      assert_includes result, "lib/nested/deep/store.rb"
      refute_includes result, "lib/other.rb"
    end
  end

  def test_path_restricts_search_to_a_subdirectory
    with_tree("lib/a.rb" => "needle\n", "spec/b.rb" => "needle\n") do |root|
      tool = Lyman::Tools.search_files(root: root)

      result = tool[:handler].call({"pattern" => "needle", "path" => "lib"})

      assert_includes result, "lib/a.rb"
      refute_includes result, "spec/b.rb"
    end
  end

  def test_no_pattern_lists_matching_file_paths
    with_tree("lib/a.rb" => "x\n", "lib/b.rb" => "x\n") do |root|
      tool = Lyman::Tools.search_files(root: root)

      result = tool[:handler].call({"glob" => "**/*.rb"})

      assert_includes result, "lib/a.rb"
      assert_includes result, "lib/b.rb"
      refute_includes result, "x\n"
    end
  end

  def test_hits_are_capped_at_max_hits_with_a_truncation_note
    files = (1..5).to_h { |i| ["file#{i}.txt", "needle\n"] }
    with_tree(files) do |root|
      tool = Lyman::Tools.search_files(root: root, max_hits: 2)

      result = tool[:handler].call({"pattern" => "needle"})

      assert_includes result, "truncated"
      assert_equal 2, result.scan(":1: needle").size
    end
  end

  def test_no_results_returns_a_helpful_message
    with_tree("lib/a.rb" => "hello\n") do |root|
      tool = Lyman::Tools.search_files(root: root)

      result = tool[:handler].call({"pattern" => "nonexistent"})

      assert_includes result, "No hits"
      assert_includes result, "nonexistent"
    end
  end

  def test_binary_file_is_skipped
    with_tree("lib/a.rb" => "needle\n") do |root|
      File.binwrite(File.join(root, "blob.bin"), "needle\x00binary")
      tool = Lyman::Tools.search_files(root: root)

      result = tool[:handler].call({"pattern" => "needle"})

      assert_includes result, "lib/a.rb"
      refute_includes result, "blob.bin"
    end
  end

  def test_dotdir_is_skipped
    with_tree(".git/config" => "needle\n", "lib/a.rb" => "needle\n") do |root|
      tool = Lyman::Tools.search_files(root: root)

      result = tool[:handler].call({"pattern" => "needle"})

      assert_includes result, "lib/a.rb"
      refute_includes result, ".git"
    end
  end

  def test_dotdot_escape_is_refused
    with_tree("lib/a.rb" => "x\n") do |root|
      tool = Lyman::Tools.search_files(root: root)

      result = tool[:handler].call({"path" => "../etc"})

      assert_includes result, "escapes the search root"
    end
  end

  def test_missing_subdirectory_is_reported_as_missing_not_as_an_escape
    with_tree("lib/a.rb" => "x\n") do |root|
      tool = Lyman::Tools.search_files(root: root)

      result = tool[:handler].call({"path" => "nope"})

      assert_includes result, "No such directory"
    end
  end

  def test_absolute_glob_is_refused
    with_tree("lib/a.rb" => "x\n") do |root|
      tool = Lyman::Tools.search_files(root: root)

      result = tool[:handler].call({"glob" => "/etc/*"})

      assert_includes result, "escapes the search root"
    end
  end

  def test_symlink_out_of_root_is_skipped
    Dir.mktmpdir do |outside|
      File.write(File.join(outside, "secret.txt"), "needle\n")
      with_tree("lib/a.rb" => "needle\n") do |root|
        File.symlink(File.join(outside, "secret.txt"), File.join(root, "lib", "link.txt"))
        tool = Lyman::Tools.search_files(root: root)

        result = tool[:handler].call({"pattern" => "needle"})

        assert_includes result, "lib/a.rb"
        refute_includes result, "link.txt"
      end
    end
  end

  def test_absolute_path_inside_root_is_allowed
    with_tree("lib/a.rb" => "needle\n") do |root|
      tool = Lyman::Tools.search_files(root: root)

      result = tool[:handler].call({"pattern" => "needle", "path" => File.join(root, "lib")})

      assert_includes result, "lib/a.rb"
    end
  end

  def test_blank_params_are_treated_as_absent
    with_tree("lib/a.rb" => "needle\n") do |root|
      tool = Lyman::Tools.search_files(root: root)

      result = tool[:handler].call({"pattern" => "needle", "glob" => "", "path" => "  "})

      assert_includes result, "lib/a.rb"
    end
  end

  def test_works_end_to_end_through_tool_execution
    with_tree("lib/a.rb" => "needle\n") do |root|
      tools = [Lyman::Tools.search_files(root: root)]
      handlers = tools.to_h { |tool| [tool[:schema].dig("function", "name"), tool[:handler]] }

      convo = Lyman::Conversation.new.with_assistant_message({
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          {"id" => "call_1", "type" => "function", "function" => {"name" => "search_files", "arguments" => JSON.generate({"pattern" => "needle"})}}
        ]
      })

      pipeline = source_worker([convo]) | Lyman::Workers.tool_execution(handlers)
      result = pipeline.shift

      tool_result = result.elements.last
      assert_equal "tool_result", tool_result.type
      assert_includes tool_result.content["text"], "lib/a.rb"
    end
  end

  # Builds a temp directory tree from a relative-path => contents hash and
  # yields its realpath (matching what the tool factory resolves root to).
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
