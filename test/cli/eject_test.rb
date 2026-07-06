require_relative "../test_helper"

class EjectTest < Minitest::Test
  def test_manifest_entry_becomes_tombstone
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        manifest_before = Lyman::CLI::Manifest.load(Dir.pwd)
        hash_before = manifest_before.artifact("conversation")["hash"]

        result = run_cli("eject", "conversation")

        assert_equal 0, result.status
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        entry = manifest.artifact("conversation")
        assert_equal "ejected", entry["status"]
        assert_equal Lyman::CLI::VERSION, entry["ejected_at"]
        assert_equal hash_before, entry["pristine_hash"]
        assert_equal "lib/lyman/conversation.rb", entry["path"]
      end
    end
  end

  def test_pristine_copy_survives_and_file_untouched
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        before = File.read("lib/lyman/conversation.rb")

        run_cli("eject", "conversation")

        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        assert manifest.pristine?("lib/lyman/conversation.rb")
        assert_equal before, File.read("lib/lyman/conversation.rb")
      end
    end
  end

  def test_subsequent_update_with_local_modifications_no_longer_halts
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        run_cli("eject", "conversation")
        File.write("lib/lyman/conversation.rb", "# hand-edited\n", mode: "a")

        result = run_cli("update")

        assert_equal 0, result.status
      end
    end
  end

  def test_owned_artifact_reports_already_yours
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        result = run_cli("eject", "harness")

        assert_equal 0, result.status
        assert_includes result.out, "already yours"
      end
    end
  end

  def test_already_ejected_is_a_noop
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        run_cli("eject", "conversation")
        result = run_cli("eject", "conversation")

        assert_equal 0, result.status
        assert_includes result.out, "already ejected"
      end
    end
  end

  def test_accepts_a_path_in_place_of_a_name
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        result = run_cli("eject", "lib/lyman/conversation.rb")

        assert_equal 0, result.status
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        assert_equal "ejected", manifest.artifact("conversation")["status"]
      end
    end
  end

  def test_unknown_artifact_raises_registry_error
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        result = run_cli("eject", "nonexistent_artifact")

        refute_equal 0, result.status
        assert_includes result.err, "nonexistent_artifact"
      end
    end
  end
end
