require_relative "../test_helper"

class NewTest < Minitest::Test
  def test_plants_every_default_registry_artifact
    in_tmpdir do
      project = scaffold_project

      Lyman::CLI::Registry.default.each_value do |spec|
        assert File.exist?(File.join(project, spec[:dest])), "expected #{spec[:dest]} to be planted"
      end
    end
  end

  # Element and Conversation upgrade together, so they ship as one planted
  # file: a project that updates conversation.rb must never be left
  # requiring a sibling its manifest doesn't know about.
  def test_planted_conversation_is_self_contained
    in_tmpdir do
      project = scaffold_project
      script = 'require "./lib/lyman/conversation"; ' \
        'c = Lyman::Conversation.new(system_prompt: "hi"); print c.elements.first.class'
      out = IO.popen([RbConfig.ruby, "-e", script], chdir: project, &:read)

      assert_equal "Lyman::Element", out
    end
  end

  # Each tool file is self-contained (no requires of sibling lyman files),
  # so it can be planted/updated/ejected alone — this proves current_time.rb
  # doesn't quietly depend on something the manifest doesn't track.
  def test_planted_current_time_tool_is_self_contained
    in_tmpdir do
      project = scaffold_project
      script = 'require "./lib/lyman/tools/current_time"; ' \
        'print Lyman::Tools.current_time[:schema].dig("function", "name")'
      out = IO.popen([RbConfig.ruby, "-e", script], chdir: project, &:read)

      assert_equal "current_time", out
    end
  end

  # search_files and read_file are file primitives (docs/design/tools-and-
  # agents.md), stdlib-only and planted by default — same self-containment
  # guarantee as current_time.rb.
  def test_planted_search_files_tool_is_self_contained
    in_tmpdir do
      project = scaffold_project
      script = 'require "./lib/lyman/tools/search_files"; ' \
        'print Lyman::Tools.search_files[:schema].dig("function", "name")'
      out = IO.popen([RbConfig.ruby, "-e", script], chdir: project, &:read)

      assert_equal "search_files", out
    end
  end

  def test_planted_read_file_tool_is_self_contained
    in_tmpdir do
      project = scaffold_project
      script = 'require "./lib/lyman/tools/read_file"; ' \
        'print Lyman::Tools.read_file[:schema].dig("function", "name")'
      out = IO.popen([RbConfig.ruby, "-e", script], chdir: project, &:read)

      assert_equal "read_file", out
    end
  end

  # The patch tool is stdlib-only and planted by default; one file, two
  # factories (one per patch format), both loadable standalone.
  def test_planted_patch_tool_is_self_contained
    in_tmpdir do
      project = scaffold_project
      script = 'require "./lib/lyman/tools/patch"; ' \
        'print [Lyman::Tools.search_replace, Lyman::Tools.apply_diff].map { |t| t[:schema].dig("function", "name") }.join(",")'
      out = IO.popen([RbConfig.ruby, "-e", script], chdir: project, &:read)

      assert_equal "search_replace,apply_diff", out
    end
  end

  # recall_tool is optional (it needs a store), so it isn't planted by
  # `new` — plant it with `add` to prove it's self-contained too: no
  # requires of sibling lyman files, so it can be planted/updated/ejected
  # alone, same guarantee as current_time.rb above.
  def test_planted_recall_tool_is_self_contained
    in_tmpdir do
      project = scaffold_project
      Dir.chdir(project) { run_cli("add", "recall_tool") }
      script = 'require "./lib/lyman/tools/recall"; ' \
        "fake_store = Object.new; " \
        'print Lyman::Tools.recall(store: fake_store)[:schema].dig("function", "name")'
      out = IO.popen([RbConfig.ruby, "-e", script], chdir: project, &:read)

      assert_equal "recall", out
    end
  end

  # The file reader agent (docs/design/tools-and-agents.md) is owned and
  # non-optional — harness/repl.rb requires it, so a fresh scaffold must
  # have it and it must load standalone, the same self-containment
  # guarantee the tool files get above (mirrors test_planted_read_file_
  # tool_is_self_contained), though this file isn't stdlib-only: it
  # requires lib/lyman (planted alongside it).
  def test_planted_file_reader_agent_loads_and_exposes_its_schema
    in_tmpdir do
      project = scaffold_project
      script = 'require "./harness/agents/file_reader"; ' \
        'tool = file_reader(root: Dir.pwd, default_model: "m", default_base_url: "http://example.invalid"); ' \
        'print tool[:schema].dig("function", "name")'
      out = IO.popen([RbConfig.ruby, "-e", script], chdir: project, &:read)

      assert_equal "file_reader", out
    end
  end

  # Same guarantee for its write-side twin, which the repl also requires.
  def test_planted_file_editor_agent_loads_and_exposes_its_schema
    in_tmpdir do
      project = scaffold_project
      script = 'require "./harness/agents/file_editor"; ' \
        'tool = file_editor(root: Dir.pwd, default_model: "m", default_base_url: "http://example.invalid"); ' \
        'print tool[:schema].dig("function", "name")'
      out = IO.popen([RbConfig.ruby, "-e", script], chdir: project, &:read)

      assert_equal "file_editor", out
    end
  end

  # Guards against a harness referencing a tool `new` never plants: every
  # Lyman::Tools.<x> this repo's own harnesses list must have a matching
  # registry artifact (by `wire:`) that isn't optional.
  def test_every_harness_tool_reference_has_a_default_registry_artifact
    # Compared as barewords (dropping any "(...)" args), the same way
    # add.rb's any_harness_mentions? matches a wire: against a harness —
    # a harness may pass its own variables where wire: shows the default
    # keyword arguments (e.g. root: Dir.pwd).
    tools_wired = Lyman::CLI::Registry::ARTIFACTS.values.filter_map { |spec| spec[:wire]&.sub(/\(.*\z/m, "") }
    default_wired = Lyman::CLI::Registry.default.values.filter_map { |spec| spec[:wire]&.sub(/\(.*\z/m, "") }

    Dir.glob(File.join(Lyman::CLI::Registry::GEM_ROOT, "harness", "*.rb")).each do |path|
      referenced = File.read(path).scan(/Lyman::Tools\.\w+/).uniq
      referenced.each do |wire|
        assert_includes tools_wired, wire, "expected #{wire} (referenced in #{path}) to be a registry artifact's wire:"
        assert_includes default_wired, wire, "expected #{wire} (referenced in #{path}) to be planted by default"
      end
    end
  end

  def test_skips_optional_artifacts
    in_tmpdir do
      project = scaffold_project
      manifest = Lyman::CLI::Manifest.load(project)

      optional = Lyman::CLI::Registry::ARTIFACTS.select { |_, spec| spec[:optional] }
      refute_empty optional, "expected at least one optional artifact in the registry"
      optional.each do |name, spec|
        refute File.exist?(File.join(project, spec[:dest])), "expected #{spec[:dest]} not to be planted"
        assert_nil manifest.artifact(name)
      end
    end
  end

  def test_manifest_lists_every_artifact_with_correct_status
    in_tmpdir do
      project = scaffold_project
      manifest = Lyman::CLI::Manifest.load(project)

      Lyman::CLI::Registry.default.each do |name, spec|
        entry = manifest.artifact(name)
        refute_nil entry, "expected manifest entry for #{name}"
        assert_equal spec[:role].to_s, entry["status"]
        assert_equal spec[:dest], entry["path"]
      end
    end
  end

  def test_managed_file_hashes_match_manifest
    in_tmpdir do
      project = scaffold_project
      manifest = Lyman::CLI::Manifest.load(project)

      Lyman::CLI::Registry.default.select { |_, spec| spec[:role] == :managed }.each do |name, spec|
        bytes = File.read(File.join(project, spec[:dest]))
        assert_equal Lyman::CLI::Planter.hash(bytes), manifest.artifact(name)["hash"]
      end
    end
  end

  def test_banner_present_on_managed_ruby_files_only
    in_tmpdir do
      project = scaffold_project

      Lyman::CLI::Registry.default.select { |_, spec| spec[:role] == :managed }.each_value do |spec|
        content = File.read(File.join(project, spec[:dest]))
        assert_includes content, "Managed by lyman", "expected banner in #{spec[:dest]}"
      end

      %w[harness/repl.rb CLAUDE.md].each do |owned_dest|
        content = File.read(File.join(project, owned_dest))
        refute_includes content, "Managed by lyman", "expected no banner in #{owned_dest}"
      end
    end
  end

  def test_planted_ruby_files_are_valid_syntax
    in_tmpdir do
      project = scaffold_project

      Lyman::CLI::Registry.default.each_value do |spec|
        next unless spec[:dest].end_with?(".rb")
        path = File.join(project, spec[:dest])
        assert RubyVM::InstructionSequence.compile(File.read(path)), "expected #{spec[:dest]} to parse"
      end
    end
  end

  def test_pristine_copies_mirror_planted_paths
    in_tmpdir do
      project = scaffold_project
      manifest = Lyman::CLI::Manifest.load(project)

      Lyman::CLI::Registry.default.each do |name, spec|
        assert manifest.pristine?(spec[:dest]), "expected pristine copy for #{name} at #{spec[:dest]}"
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
