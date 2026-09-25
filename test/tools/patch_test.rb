require_relative "../test_helper"
require "rbconfig"
require "shifty"
require "lyman"

class PatchTest < Minitest::Test
  # A check command that fails (printing a finding) when the file contains
  # "BAD" — an argv, so it runs without a shell, the same way a string
  # command like "bundle exec standardrb" does once split.
  BAD_CHECK = [RbConfig.ruby, "-e", 'if File.read(ARGV[0]).include?("BAD") then puts ARGV[0] + ": found BAD"; exit 1 end'].freeze

  # ── search_replace ──────────────────────────────────────────────────────

  def test_search_replace_schema_requires_path_search_and_replace
    tool = Lyman::Tools.search_replace(root: Dir.mktmpdir)

    function = tool[:schema]["function"]
    assert_equal "search_replace", function["name"]
    assert_equal %w[path search replace], function["parameters"]["required"]
  end

  def test_schema_mentions_the_check_only_when_one_is_configured
    root = Dir.mktmpdir
    unchecked = Lyman::Tools.search_replace(root: root)[:schema].dig("function", "description")
    checked = Lyman::Tools.search_replace(root: root, check: "true")[:schema].dig("function", "description")

    refute_includes unchecked, "check"
    assert_includes checked, "check"
  end

  def test_replaces_a_unique_block_and_says_where
    with_tree("a.rb" => "one\ntwo\nthree\n") do |root|
      result = search_replace(root, "path" => "a.rb", "search" => "two\n", "replace" => "TWO\n2\n")

      assert_equal "one\nTWO\n2\nthree\n", File.read(File.join(root, "a.rb"))
      assert_includes result, "Patched a.rb"
      assert_includes result, "line 2"
      refute_includes result, "Check"
    end
  end

  def test_empty_replace_deletes_the_block
    with_tree("a.rb" => "one\ntwo\nthree\n") do |root|
      search_replace(root, "path" => "a.rb", "search" => "two\n", "replace" => "")

      assert_equal "one\nthree\n", File.read(File.join(root, "a.rb"))
    end
  end

  def test_several_matches_are_refused_and_nothing_changes
    with_tree("a.rb" => "x = 1\ny = 2\nx = 1\n") do |root|
      result = search_replace(root, "path" => "a.rb", "search" => "x = 1", "replace" => "x = 9")

      assert_includes result, "matches 2 places"
      assert_includes result, "lines 1, 3"
      assert_equal "x = 1\ny = 2\nx = 1\n", File.read(File.join(root, "a.rb"))
    end
  end

  def test_whitespace_near_miss_shows_the_exact_lines_to_resend
    with_tree("a.rb" => "def foo\n    bar\nend\n") do |root|
      result = search_replace(root, "path" => "a.rb", "search" => "def foo\n  bar\n", "replace" => "x")

      assert_includes result, "apart from whitespace"
      assert_includes result, "lines 1-2"
      assert_includes result, "def foo\n    bar\n"
      assert_equal "def foo\n    bar\nend\n", File.read(File.join(root, "a.rb"))
    end
  end

  def test_plain_miss_says_nothing_changed
    with_tree("a.rb" => "one\n") do |root|
      result = search_replace(root, "path" => "a.rb", "search" => "zebra", "replace" => "x")

      assert_includes result, "not found"
      assert_includes result, "nothing was changed"
    end
  end

  def test_empty_search_creates_a_new_file_in_new_directories
    with_tree({}) do |root|
      result = search_replace(root, "path" => "lib/new/thing.rb", "search" => "", "replace" => "class Thing\nend\n")

      assert_equal "class Thing\nend\n", File.read(File.join(root, "lib/new/thing.rb"))
      assert_includes result, "Created lib/new/thing.rb"
    end
  end

  def test_empty_search_refuses_to_overwrite_an_existing_file
    with_tree("a.rb" => "keep\n") do |root|
      result = search_replace(root, "path" => "a.rb", "search" => "", "replace" => "clobber\n")

      assert_includes result, "already exists"
      assert_equal "keep\n", File.read(File.join(root, "a.rb"))
    end
  end

  def test_missing_file_with_a_search_points_at_creation
    with_tree({}) do |root|
      result = search_replace(root, "path" => "nope.rb", "search" => "x", "replace" => "y")

      assert_includes result, "No such file"
      assert_includes result, "empty search"
    end
  end

  def test_dotdot_escape_is_refused
    with_tree({}) do |root|
      result = search_replace(root, "path" => "../evil.rb", "search" => "", "replace" => "x")

      assert_includes result, "escapes the root"
      refute File.exist?(File.join(File.dirname(root), "evil.rb"))
    end
  end

  def test_symlinked_directory_escape_is_refused_even_for_a_new_file
    Dir.mktmpdir do |outside|
      with_tree({}) do |root|
        File.symlink(outside, File.join(root, "out"))

        result = search_replace(root, "path" => "out/evil.rb", "search" => "", "replace" => "x")

        assert_includes result, "escapes the root"
        refute File.exist?(File.join(outside, "evil.rb"))
      end
    end
  end

  def test_binary_file_is_refused
    with_tree({}) do |root|
      File.binwrite(File.join(root, "blob.bin"), "abc\x00def")

      result = search_replace(root, "path" => "blob.bin", "search" => "abc", "replace" => "x")

      assert_includes result, "binary"
    end
  end

  def test_crlf_files_match_lf_search_and_stay_crlf
    with_tree({}) do |root|
      File.binwrite(File.join(root, "a.txt"), "one\r\ntwo\r\n")

      search_replace(root, "path" => "a.txt", "search" => "one\ntwo\n", "replace" => "uno\ndos\n")

      assert_equal "uno\r\ndos\r\n", File.binread(File.join(root, "a.txt"))
    end
  end

  # ── the check seam ──────────────────────────────────────────────────────

  def test_passing_check_command_reports_one_word
    with_tree("a.rb" => "one\n") do |root|
      result = search_replace(root, {"path" => "a.rb", "search" => "one", "replace" => "fine"}, check: BAD_CHECK)

      assert_includes result, "Check: passed."
    end
  end

  def test_failing_check_command_reports_its_output_and_keeps_the_edit
    with_tree("a.rb" => "one\n") do |root|
      result = search_replace(root, {"path" => "a.rb", "search" => "one", "replace" => "BAD"}, check: BAD_CHECK)

      assert_includes result, "Check: failed"
      assert_includes result, "exit 1"
      assert_includes result, "a.rb: found BAD" # the path is appended, relative to root
      assert_equal "BAD\n", File.read(File.join(root, "a.rb"))
    end
  end

  def test_string_check_command_is_split_into_an_argv_not_run_through_a_shell
    with_tree("a.rb" => "one\n", "check.rb" => "exit 3 if ARGV == [\"--flag\", \"a.rb\"]\n") do |root|
      result = search_replace(root, {"path" => "a.rb", "search" => "one", "replace" => "two"},
        check: "#{RbConfig.ruby} check.rb --flag")

      assert_includes result, "exit 3"
    end
  end

  def test_check_command_that_cannot_run_says_so
    with_tree("a.rb" => "one\n") do |root|
      result = search_replace(root, {"path" => "a.rb", "search" => "one", "replace" => "two"},
        check: "no-such-checker-xyz")

      assert_includes result, "could not run `no-such-checker-xyz`"
    end
  end

  def test_callable_check_gets_the_absolute_path_and_its_findings_are_reported
    with_tree("a.rb" => "one\n") do |root|
      seen = nil
      check = ->(path) {
        seen = path
        "line 1: too short"
      }

      result = search_replace(root, {"path" => "a.rb", "search" => "one", "replace" => "two"}, check: check)

      assert_equal File.join(root, "a.rb"), seen
      assert_includes result, "Check: failed"
      assert_includes result, "line 1: too short"
    end
  end

  def test_callable_check_returning_nil_is_a_pass
    with_tree("a.rb" => "one\n") do |root|
      result = search_replace(root, {"path" => "a.rb", "search" => "one", "replace" => "two"}, check: ->(_) {})

      assert_includes result, "Check: passed."
    end
  end

  def test_check_runs_on_created_files_too
    with_tree({}) do |root|
      result = search_replace(root, {"path" => "b.rb", "search" => "", "replace" => "BAD\n"}, check: BAD_CHECK)

      assert_includes result, "Created b.rb"
      assert_includes result, "Check: failed"
    end
  end

  def test_a_nonsense_check_is_refused_at_wiring_time
    assert_raises(ArgumentError) { Lyman::Tools.search_replace(root: Dir.mktmpdir, check: 42) }
  end

  # ── apply_diff ──────────────────────────────────────────────────────────

  def test_apply_diff_schema_requires_path_and_diff
    function = Lyman::Tools.apply_diff(root: Dir.mktmpdir)[:schema]["function"]

    assert_equal "apply_diff", function["name"]
    assert_equal %w[path diff], function["parameters"]["required"]
  end

  def test_applies_a_hunk_even_when_its_line_numbers_are_wrong
    with_tree("a.rb" => "a\nb\nc\nd\ne\n") do |root|
      diff = <<~DIFF
        --- a/a.rb
        +++ b/a.rb
        @@ -40,3 +40,3 @@
         b
        -c
        +C
         d
      DIFF

      result = apply_diff(root, "path" => "a.rb", "diff" => diff)

      assert_equal "a\nb\nC\nd\ne\n", File.read(File.join(root, "a.rb"))
      assert_includes result, "1 hunk applied"
    end
  end

  def test_applies_several_hunks_in_order_tracking_the_shift
    with_tree("a.rb" => (1..10).map { |n| "line#{n}\n" }.join) do |root|
      diff = <<~DIFF
        @@ -2,1 +2,3 @@
        -line2
        +line2a
        +line2b
        +line2c
        @@ -9,1 +11,1 @@
        -line9
        +LINE9
      DIFF

      result = apply_diff(root, "path" => "a.rb", "diff" => diff)

      lines = File.read(File.join(root, "a.rb")).lines(chomp: true)
      assert_equal %w[line1 line2a line2b line2c line3], lines.first(5)
      assert_equal "LINE9", lines[10]
      assert_includes result, "2 hunks applied"
    end
  end

  def test_an_ambiguous_context_picks_the_match_nearest_the_header
    with_tree("a.rb" => "x\ny\nx\ny\n") do |root|
      diff = "@@ -3,2 +3,2 @@\n x\n-y\n+Y\n"

      apply_diff(root, "path" => "a.rb", "diff" => diff)

      assert_equal "x\ny\nx\nY\n", File.read(File.join(root, "a.rb"))
    end
  end

  def test_a_pure_insertion_is_placed_by_its_header
    with_tree("a.rb" => "one\ntwo\n") do |root|
      apply_diff(root, "path" => "a.rb", "diff" => "@@ -1,0 +2,1 @@\n+between\n")

      assert_equal "one\nbetween\ntwo\n", File.read(File.join(root, "a.rb"))
    end
  end

  def test_trailing_whitespace_differences_are_tolerated
    with_tree("a.rb" => "keep   \nold\n") do |root|
      apply_diff(root, "path" => "a.rb", "diff" => "@@ -1,2 +1,2 @@\n keep\n-old\n+new\n")

      assert_equal "keep   \nnew\n", File.read(File.join(root, "a.rb"))
    end
  end

  def test_a_blank_context_line_with_its_space_trimmed_still_matches
    with_tree("a.rb" => "a\n\nb\n") do |root|
      apply_diff(root, "path" => "a.rb", "diff" => "@@ -1,3 +1,3 @@\n a\n\n-b\n+B\n")

      assert_equal "a\n\nB\n", File.read(File.join(root, "a.rb"))
    end
  end

  def test_a_failing_hunk_writes_nothing_at_all
    with_tree("a.rb" => "a\nb\nc\n") do |root|
      diff = "@@ -1,1 +1,1 @@\n-a\n+A\n@@ -3,1 +3,1 @@\n-zebra\n+Z\n"

      result = apply_diff(root, "path" => "a.rb", "diff" => diff)

      assert_includes result, "Hunk 2 of 2 did not apply"
      assert_includes result, "zebra"
      assert_equal "a\nb\nc\n", File.read(File.join(root, "a.rb"))
    end
  end

  def test_creates_a_file_from_an_add_only_diff
    with_tree({}) do |root|
      diff = "--- /dev/null\n+++ b/new.rb\n@@ -0,0 +1,2 @@\n+class New\n+end\n"

      result = apply_diff(root, "path" => "new.rb", "diff" => diff)

      assert_equal "class New\nend\n", File.read(File.join(root, "new.rb"))
      assert_includes result, "Created new.rb"
    end
  end

  def test_a_multi_file_diff_is_refused
    with_tree("a.rb" => "a\n", "b.rb" => "b\n") do |root|
      diff = "--- a/a.rb\n+++ b/a.rb\n@@ -1 +1 @@\n-a\n+A\n--- a/b.rb\n+++ b/b.rb\n@@ -1 +1 @@\n-b\n+B\n"

      result = apply_diff(root, "path" => "a.rb", "diff" => diff)

      assert_includes result, "more than one file"
      assert_equal "a\n", File.read(File.join(root, "a.rb"))
    end
  end

  def test_a_diff_without_hunks_says_so
    with_tree("a.rb" => "a\n") do |root|
      assert_includes apply_diff(root, "path" => "a.rb", "diff" => "just some words"), "No hunks found"
    end
  end

  def test_apply_diff_runs_the_check
    with_tree("a.rb" => "a\n") do |root|
      result = apply_diff(root, {"path" => "a.rb", "diff" => "@@ -1 +1 @@\n-a\n+BAD\n"}, check: BAD_CHECK)

      assert_includes result, "Check: failed"
    end
  end

  private

  # A braceless string-keyed hash arrives as keywords (the helpers take
  # check:), so `inline` gathers it back up as the tool-call args.
  def search_replace(root, args = {}, check: nil, **inline)
    Lyman::Tools.search_replace(root: root, check: check)[:handler].call(args.merge(inline))
  end

  def apply_diff(root, args = {}, check: nil, **inline)
    Lyman::Tools.apply_diff(root: root, check: check)[:handler].call(args.merge(inline))
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
