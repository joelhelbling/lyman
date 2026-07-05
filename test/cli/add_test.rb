require_relative "../test_helper"

class AddTest < Minitest::Test
  def test_unknown_artifact_lists_valid_names
    in_tmpdir do
      scaffold_project

      result = run_cli("add", "nonexistent_artifact")

      refute_equal 0, result.status
      Lyman::CLI::Registry::ARTIFACTS.each_key do |name|
        assert_includes result.err, name
      end
    end
  end

  def test_already_managed_is_a_noop
    in_tmpdir do
      project = scaffold_project
      before = File.read(File.join(project, "lib/lyman/conversation.rb"))

      result = Dir.chdir(project) { run_cli("add", "conversation") }

      assert_equal 0, result.status
      assert_includes result.out, "already"
      assert_equal before, File.read(File.join(project, "lib/lyman/conversation.rb"))
    end
  end

  def test_untracked_existing_file_refused_without_force
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        Lyman::CLI::Manifest.load(Dir.pwd).tap do |manifest|
          manifest.delete_artifact("gitignore")
          manifest.save
        end
        # The file is still on disk but no longer tracked in the manifest.
        assert File.exist?(".gitignore")

        result = run_cli("add", "gitignore")

        refute_equal 0, result.status
        assert_includes result.err, "--force"
      end
    end
  end

  def test_untracked_existing_file_overwritten_with_force
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        manifest.delete_artifact("gitignore")
        manifest.save

        result = run_cli("add", "gitignore", "--force")

        assert_equal 0, result.status
        reloaded = Lyman::CLI::Manifest.load(Dir.pwd)
        assert_equal "owned", reloaded.artifact("gitignore")["status"]
      end
    end
  end

  def test_readd_over_tombstone_prompts_and_force_restores_managed_status
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        manifest.set_artifact("conversation", {
          "status" => "ejected",
          "ejected_at" => "0.0.1",
          "pristine_hash" => "deadbeef"
        })
        manifest.save

        result = run_cli("add", "conversation", "--force")

        assert_equal 0, result.status
        reloaded = Lyman::CLI::Manifest.load(Dir.pwd)
        assert_equal "managed", reloaded.artifact("conversation")["status"]
        refute_nil reloaded.artifact("conversation")["hash"]
      end
    end
  end
end
