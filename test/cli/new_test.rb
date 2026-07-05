require_relative "../test_helper"

class NewTest < Minitest::Test
  def test_plants_every_registry_artifact
    in_tmpdir do
      project = scaffold_project

      Lyman::CLI::Registry::ARTIFACTS.each_value do |spec|
        assert File.exist?(File.join(project, spec[:dest])), "expected #{spec[:dest]} to be planted"
      end
    end
  end

  def test_manifest_lists_every_artifact_with_correct_status
    in_tmpdir do
      project = scaffold_project
      manifest = Lyman::CLI::Manifest.load(project)

      Lyman::CLI::Registry::ARTIFACTS.each do |name, spec|
        entry = manifest.artifact(name)
        refute_nil entry, "expected manifest entry for #{name}"
        assert_equal spec[:role].to_s, entry["status"]
      end
    end
  end

  def test_managed_file_hashes_match_manifest
    in_tmpdir do
      project = scaffold_project
      manifest = Lyman::CLI::Manifest.load(project)

      Lyman::CLI::Registry.managed.each do |name, spec|
        bytes = File.read(File.join(project, spec[:dest]))
        assert_equal Lyman::CLI::Planter.hash(bytes), manifest.artifact(name)["hash"]
      end
    end
  end

  def test_banner_present_on_managed_ruby_files_only
    in_tmpdir do
      project = scaffold_project

      Lyman::CLI::Registry.managed.each_value do |spec|
        content = File.read(File.join(project, spec[:dest]))
        assert_includes content, "Managed by lyman", "expected banner in #{spec[:dest]}"
      end

      %w[harness/chat.rb CLAUDE.md].each do |owned_dest|
        content = File.read(File.join(project, owned_dest))
        refute_includes content, "Managed by lyman", "expected no banner in #{owned_dest}"
      end
    end
  end

  def test_planted_ruby_files_are_valid_syntax
    in_tmpdir do
      project = scaffold_project

      Lyman::CLI::Registry::ARTIFACTS.each_value do |spec|
        next unless spec[:dest].end_with?(".rb")
        path = File.join(project, spec[:dest])
        assert RubyVM::InstructionSequence.compile(File.read(path)), "expected #{spec[:dest]} to parse"
      end
    end
  end

  def test_pristine_copies_exist
    in_tmpdir do
      project = scaffold_project
      manifest = Lyman::CLI::Manifest.load(project)

      Lyman::CLI::Registry::ARTIFACTS.each_key do |name|
        assert manifest.pristine?(name), "expected pristine copy for #{name}"
      end
    end
  end

  def test_refuses_nonempty_target_directory
    in_tmpdir do
      FileUtils.mkdir_p("demo")
      File.write(File.join("demo", "keepme.txt"), "hi")

      result = run_cli("new", "demo")

      refute_equal 0, result.status
    end
  end
end
