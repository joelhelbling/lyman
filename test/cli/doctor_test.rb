require_relative "../test_helper"

class DoctorTest < Minitest::Test
  def test_passes_on_a_fresh_scaffold
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        result = run_cli("doctor")

        assert_equal 0, result.status
        assert_includes result.out, "manifest parses"
        assert_includes result.out, "pipeline smoke test passed"
        refute_includes result.out, "✗"
      end
    end
  end

  def test_reports_modified_managed_files_as_notes_without_failing
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        File.write("lib/lyman/conversation.rb", "# hand-edited\n", mode: "a")

        result = run_cli("doctor")

        assert_equal 0, result.status
        assert_includes result.out, "conversation: file present (modified)"
      end
    end
  end

  def test_exits_1_when_a_managed_file_is_deleted
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        File.delete("lib/lyman/conversation.rb")

        result = run_cli("doctor")

        refute_equal 0, result.status
        assert_includes result.out, "conversation: planted file missing"
      end
    end
  end
end
