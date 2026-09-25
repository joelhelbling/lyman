require_relative "../test_helper"

class AddTest < Minitest::Test
  def test_unknown_artifact_lists_valid_names
    in_tmpdir do
      project = scaffold_project

      result = Dir.chdir(project) { run_cli("add", "nonexistent_artifact") }

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

  def test_add_plants_optional_claude_skill
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        result = run_cli("add", "claude_skill")

        assert_equal 0, result.status
        skill = File.read(".claude/skills/lyman/SKILL.md")
        assert_includes skill, "name: lyman"
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        assert_equal "owned", manifest.artifact("claude_skill")["status"]
        assert_equal ".claude/skills/lyman/SKILL.md", manifest.artifact("claude_skill")["path"]
      end
    end
  end

  def test_existing_claude_md_refusal_suggests_skill_variant
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        manifest.delete_artifact("claude_md")
        manifest.save
        # CLAUDE.md is on disk but untracked — the "project already had one"
        # situation the skill variant exists for.
        assert File.exist?("CLAUDE.md")

        result = run_cli("add", "claude_md")

        refute_equal 0, result.status
        assert_includes result.err, "lyman add claude_skill"
      end
    end
  end

  def test_add_plants_optional_archetype_harnesses
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        # A fresh scaffold gets only the repl archetype.
        assert File.exist?("harness/repl.rb")
        refute File.exist?("harness/daemon.rb")
        refute File.exist?("harness/script.rb")

        %w[daemon_harness script_harness].each do |name|
          result = run_cli("add", name)

          assert_equal 0, result.status
          manifest = Lyman::CLI::Manifest.load(Dir.pwd)
          assert_equal "owned", manifest.artifact(name)["status"]
        end

        %w[harness/daemon.rb harness/script.rb].each do |dest|
          source = File.read(dest)
          assert RubyVM::InstructionSequence.compile(source), "expected #{dest} to parse"
          refute_includes source, "Managed by lyman", "expected no banner in #{dest}"
        end
      end
    end
  end

  def test_add_store_plants_it_and_advises_the_missing_gem
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        refute_includes File.read("Gemfile"), "sqlite3"

        result = run_cli("add", "store")

        assert_equal 0, result.status
        assert File.exist?("lib/lyman/store.rb")
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        assert_equal "managed", manifest.artifact("store")["status"]
        assert_includes result.out, "store needs the sqlite3 gem"
        assert_includes result.out, "gem \"sqlite3\""
      end
    end
  end

  def test_add_store_gives_no_advice_when_gemfile_already_has_the_gem
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        File.open("Gemfile", "a") { |f| f.puts 'gem "sqlite3"' }

        result = run_cli("add", "store")

        assert_equal 0, result.status
        refute_includes result.out, "needs the sqlite3 gem"
      end
    end
  end

  def test_add_compactor_plants_the_sidecar_shell_and_points_at_its_wiring
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        result = run_cli("add", "compactor")

        assert_equal 0, result.status
        assert File.exist?("harness/compactor.rb")
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        assert_equal "owned", manifest.artifact("compactor")["status"]
        assert_includes result.out, "see the comment at the top of harness/compactor.rb"
        refute_includes result.out, "expects", "compaction and compaction_feed are planted by `new`"
      end
    end
  end

  def test_add_store_append_plants_the_worker
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        result = run_cli("add", "store_append")

        assert_equal 0, result.status
        assert File.exist?("lib/lyman/workers/store_append.rb")
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        assert_equal "managed", manifest.artifact("store_append")["status"]
      end
    end
  end

  def test_add_current_time_tool_advises_wiring_when_no_harness_mentions_it
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        manifest.delete_artifact("current_time_tool")
        manifest.save
        FileUtils.rm_f("lib/lyman/tools/current_time.rb")
        # The repl no longer mentions the tool, so `add` should notice it's
        # unwired rather than assume the harness already hands it to the model.
        contents = File.read("harness/repl.rb").gsub("Lyman::Tools.current_time", "# removed for this test")
        File.write("harness/repl.rb", contents)

        result = run_cli("add", "current_time_tool")

        assert_equal 0, result.status
        assert File.exist?("lib/lyman/tools/current_time.rb")
        assert_includes result.out, "not wired"
        assert_includes result.out, "Lyman::Tools.current_time"
      end
    end
  end

  def test_add_current_time_tool_gives_no_wiring_advice_when_a_harness_mentions_it
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        manifest.delete_artifact("current_time_tool")
        manifest.save
        FileUtils.rm_f("lib/lyman/tools/current_time.rb")
        # harness/repl.rb (planted by `new`) already lists Lyman::Tools.current_time.
        assert_includes File.read("harness/repl.rb"), "Lyman::Tools.current_time"

        result = run_cli("add", "current_time_tool")

        assert_equal 0, result.status
        refute_includes result.out, "not wired"
      end
    end
  end

  # A longer tool name sharing the prefix is a different tool, not a mention.
  def test_add_current_time_tool_advises_wiring_when_a_harness_only_mentions_a_longer_name
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        manifest.delete_artifact("current_time_tool")
        manifest.save
        FileUtils.rm_f("lib/lyman/tools/current_time.rb")
        contents = File.read("harness/repl.rb").gsub("Lyman::Tools.current_time", "Lyman::Tools.current_time_range")
        File.write("harness/repl.rb", contents)

        result = run_cli("add", "current_time_tool")

        assert_equal 0, result.status
        assert_includes result.out, "not wired"
      end
    end
  end

  # search_files and read_file are wired inside harness/agents/file_reader.rb
  # (the file reader agent's own tools), not directly in harness/repl.rb, so
  # these tests exercise that file rather than the root harness.
  def test_add_search_files_tool_gives_no_wiring_advice_when_a_harness_mentions_it
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        manifest.delete_artifact("search_files_tool")
        manifest.save
        FileUtils.rm_f("lib/lyman/tools/search_files.rb")
        # harness/agents/file_reader.rb (planted by `new`) already calls Lyman::Tools.search_files.
        assert_includes File.read("harness/agents/file_reader.rb"), "Lyman::Tools.search_files"

        result = run_cli("add", "search_files_tool")

        assert_equal 0, result.status
        refute_includes result.out, "not wired"
      end
    end
  end

  def test_add_search_files_tool_advises_wiring_when_no_harness_mentions_it
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        manifest.delete_artifact("search_files_tool")
        manifest.save
        FileUtils.rm_f("lib/lyman/tools/search_files.rb")
        contents = File.read("harness/agents/file_reader.rb").gsub("Lyman::Tools.search_files", "# removed for this test")
        File.write("harness/agents/file_reader.rb", contents)

        result = run_cli("add", "search_files_tool")

        assert_equal 0, result.status
        assert File.exist?("lib/lyman/tools/search_files.rb")
        assert_includes result.out, "not wired"
        assert_includes result.out, "Lyman::Tools.search_files"
      end
    end
  end

  # Nothing wires the patch tool yet (the file editor agent will), so
  # re-adding it advises the wiring line — and names both formats, since
  # wiring it means choosing one.
  def test_add_patch_tool_advises_wiring_and_names_both_formats
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        manifest.delete_artifact("patch_tool")
        manifest.save
        FileUtils.rm_f("lib/lyman/tools/patch.rb")

        result = run_cli("add", "patch_tool")

        assert_equal 0, result.status
        assert File.exist?("lib/lyman/tools/patch.rb")
        assert_includes result.out, "not wired"
        assert_includes result.out, "Lyman::Tools.search_replace"
        assert_includes result.out, "Lyman::Tools.apply_diff"
      end
    end
  end

  def test_add_read_file_tool_gives_no_wiring_advice_when_a_harness_mentions_it
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        manifest.delete_artifact("read_file_tool")
        manifest.save
        FileUtils.rm_f("lib/lyman/tools/read_file.rb")
        assert_includes File.read("harness/agents/file_reader.rb"), "Lyman::Tools.read_file"

        result = run_cli("add", "read_file_tool")

        assert_equal 0, result.status
        refute_includes result.out, "not wired"
      end
    end
  end

  def test_add_read_file_tool_advises_wiring_when_no_harness_mentions_it
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        manifest.delete_artifact("read_file_tool")
        manifest.save
        FileUtils.rm_f("lib/lyman/tools/read_file.rb")
        contents = File.read("harness/agents/file_reader.rb").gsub("Lyman::Tools.read_file", "# removed for this test")
        File.write("harness/agents/file_reader.rb", contents)

        result = run_cli("add", "read_file_tool")

        assert_equal 0, result.status
        assert File.exist?("lib/lyman/tools/read_file.rb")
        assert_includes result.out, "not wired"
        assert_includes result.out, "Lyman::Tools.read_file"
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

  def test_new_does_not_plant_recall_tool
    in_tmpdir do
      project = scaffold_project

      refute File.exist?(File.join(project, "lib/lyman/tools/recall.rb"))
      manifest = Lyman::CLI::Manifest.load(project)
      assert_nil manifest.artifact("recall_tool")
    end
  end

  def test_add_recall_tool_plants_it_wiring_advice_and_needs_advice_when_store_missing
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        result = run_cli("add", "recall_tool")

        assert_equal 0, result.status
        assert File.exist?("lib/lyman/tools/recall.rb")
        manifest = Lyman::CLI::Manifest.load(Dir.pwd)
        assert_equal "managed", manifest.artifact("recall_tool")["status"]
        assert_includes result.out, "not wired"
        assert_includes result.out, "Lyman::Tools.recall(store: store)"
        assert_includes result.out, "recall_tool expects store"
        assert_includes result.out, "lyman add store"
      end
    end
  end

  def test_add_recall_tool_gives_no_needs_advice_when_store_already_planted
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        run_cli("add", "store")

        result = run_cli("add", "recall_tool")

        assert_equal 0, result.status
        refute_includes result.out, "expects store"
      end
    end
  end

  # Eject leaves store.rb in place, so recall's dependency is still met at
  # runtime; advising `lyman add store` would lead to a fork-replacement prompt.
  def test_add_recall_tool_gives_no_needs_advice_when_store_ejected
    in_tmpdir do
      scaffold_project("demo")
      Dir.chdir("demo") do
        run_cli("add", "store")
        run_cli("eject", "store")

        result = run_cli("add", "recall_tool")

        assert_equal 0, result.status
        refute_includes result.out, "expects store"
      end
    end
  end
end
