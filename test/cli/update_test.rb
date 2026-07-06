require_relative "../test_helper"

class UpdateTest < Minitest::Test
  def test_replaces_pristine_file_when_upstream_changed
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        with_upstream_change("conversation") do
          result = run_cli("update")

          assert_equal 0, result.status
          content = File.read("lib/lyman/conversation.rb")
          assert_includes content, "upstream marker: conversation changed"

          manifest = Lyman::CLI::Manifest.load(Dir.pwd)
          expected_hash = Lyman::CLI::Planter.hash(content)
          assert_equal expected_hash, manifest.artifact("conversation")["hash"]
          assert_equal expected_hash,
            Lyman::CLI::Planter.hash(manifest.read_pristine("lib/lyman/conversation.rb"))
        end
      end
    end
  end

  def test_reports_up_to_date_when_no_upstream_change
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        result = run_cli("update")

        assert_equal 0, result.status
        assert_includes result.out, "up to date"
      end
    end
  end

  def test_halts_on_locally_modified_file_and_leaves_it_untouched
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        File.write("lib/lyman/conversation.rb", "# hand-edited\n", mode: "a")
        modified = File.read("lib/lyman/conversation.rb")

        result = run_cli("update")

        refute_equal 0, result.status
        assert_includes result.out, "conversation"
        assert_includes result.out, ".lyman/pristine/lib/lyman/conversation.rb"
        assert_includes result.out, "lyman diff"
        assert_includes result.out, "lyman eject"
        assert_equal modified, File.read("lib/lyman/conversation.rb")
      end
    end
  end

  def test_owned_files_never_touched_even_when_template_changes
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        with_upstream_change("claude_md") do
          before = File.read("CLAUDE.md")

          result = run_cli("update")

          assert_equal 0, result.status
          assert_equal before, File.read("CLAUDE.md")
        end
      end
    end
  end

  def test_ejected_upstream_change_advises_once
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        run_cli("eject", "conversation")

        with_upstream_change("conversation") do
          first = run_cli("update")
          assert_includes first.out, "conversation"
          assert_includes first.out, "upstream changes"

          second = run_cli("update")
          refute_includes second.out, "upstream changes"
        end
      end
    end
  end

  def test_halts_when_manifest_path_disagrees_with_registry_dest
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        # Simulate a relocation: the file (and the manifest's record of it)
        # live somewhere this release's registry doesn't expect.
        FileUtils.mkdir_p("lib/elsewhere")
        FileUtils.mv("lib/lyman/conversation.rb", "lib/elsewhere/conversation.rb")
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        entry = manifest.artifact("conversation")
        manifest.set_artifact("conversation", entry.merge("path" => "lib/elsewhere/conversation.rb"))
        manifest.save

        result = run_cli("update")

        refute_equal 0, result.status
        assert_includes result.out, "lib/elsewhere/conversation.rb"
        assert_includes result.out, "lib/lyman/conversation.rb"
        assert File.exist?("lib/elsewhere/conversation.rb"), "expected relocated file untouched"
      end
    end
  end

  def test_unknown_files_on_disk_never_touched
    in_tmpdir do
      project = scaffold_project

      Dir.chdir(project) do
        File.write("scratch.txt", "leave me alone")

        result = run_cli("update")

        assert_equal 0, result.status
        assert_equal "leave me alone", File.read("scratch.txt")
      end
    end
  end
end
