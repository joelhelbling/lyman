require_relative "../test_helper"

class ManifestTest < Minitest::Test
  def test_round_trips
    in_tmpdir do
      manifest = Lyman::CLI::Manifest.load(Dir.pwd)
      manifest.set_artifact("conversation", {"status" => "managed", "planted_at" => "0.1.0", "hash" => "abc"})
      manifest.save

      reloaded = Lyman::CLI::Manifest.load(Dir.pwd)
      assert_equal Lyman::CLI::VERSION, reloaded.lyman_version
      assert_equal({"status" => "managed", "planted_at" => "0.1.0", "hash" => "abc"}, reloaded.artifact("conversation"))
    end
  end

  def test_discovery_walks_up_from_a_subdirectory
    in_tmpdir do
      project = scaffold_project
      nested = File.join(project, "lib", "lyman", "workers")

      found = Lyman::CLI::Manifest.find(nested)

      assert_equal File.expand_path(project), found
    end
  end

  def test_commands_outside_a_project_fail_with_a_clear_message
    in_tmpdir do
      result = run_cli("add", "conversation")

      refute_equal 0, result.status
      assert_includes result.err, "lyman new"
    end
  end
end
