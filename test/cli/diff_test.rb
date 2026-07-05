require_relative "../test_helper"

class DiffTest < Minitest::Test
  def test_pristine_artifact_shows_none_in_both_sections
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        result = run_cli("diff", "conversation")

        assert_equal 0, result.status
        assert_includes result.out, "(none)"
      end
    end
  end

  def test_local_edit_shows_in_your_changes_section
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        File.write("lib/lyman/conversation.rb", "# hand-edited\n", mode: "a")

        result = run_cli("diff", "conversation")

        assert_equal 0, result.status
        your_changes, upstream = split_sections(result.out)
        assert_includes your_changes, "hand-edited"
        assert_includes upstream, "(none)"
      end
    end
  end

  def test_upstream_change_shows_in_upstream_section
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        with_upstream_change("conversation") do
          result = run_cli("diff", "conversation")

          assert_equal 0, result.status
          your_changes, upstream = split_sections(result.out)
          assert_includes your_changes, "(none)"
          assert_includes upstream, "upstream marker: conversation changed"
        end
      end
    end
  end

  private

  def split_sections(output)
    upstream_marker = "--- upstream changes"
    idx = output.index(upstream_marker)
    [output[0...idx], output[idx..]]
  end
end
