require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "lyman/cli"

# The result of an in-process CLI invocation: what a real terminal session
# would have shown, plus the exit status Thor would have produced.
CliResult = Struct.new(:out, :err, :status)

module TestHelper
  # Runs the block with cwd set to a scratch directory that's cleaned up
  # afterward — every test that scaffolds a project needs this.
  def in_tmpdir
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) { yield dir }
    end
  end

  # Invokes the CLI in-process (no subprocess, so it's fast and the
  # coverage/loaded-code state stays shared with the test). Thor's
  # exit_on_failure? path raises SystemExit rather than propagating
  # Thor::Error, so we rescue it here rather than let it fail the test.
  def run_cli(*argv)
    original_stdout, original_stderr = $stdout, $stderr
    out, err = StringIO.new, StringIO.new
    status = 0
    $stdout, $stderr = out, err

    begin
      Lyman::CLI::Root.start(argv)
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout, $stderr = original_stdout, original_stderr
    end

    CliResult.new(out.string, err.string, status)
  end

  # Scaffolds a project named +name+ in the current directory (call this
  # inside in_tmpdir) and returns its absolute path.
  def scaffold_project(name = "demo")
    run_cli("new", name)
    File.expand_path(name)
  end

  # Simulates "a newer lyman release": copies the gem's plantable source
  # into a fixture tree, appends a marker comment to the named artifact's
  # source file, and points LYMAN_SOURCE_ROOT at the fixture for the
  # duration of the block. This is how update/diff/advisory tests get an
  # upstream change to react to without touching the real gem tree.
  def with_upstream_change(artifact)
    spec = Lyman::CLI::Registry.fetch(artifact)

    Dir.mktmpdir do |fixture|
      %w[lib harness templates].each do |dir|
        src = File.join(Lyman::CLI::Registry::GEM_ROOT, dir)
        FileUtils.cp_r(src, fixture) if Dir.exist?(src)
      end

      changed_source = File.join(fixture, spec[:source])
      File.open(changed_source, "a") { |f| f.puts("# upstream marker: #{artifact} changed") }

      original_source_root = ENV["LYMAN_SOURCE_ROOT"]
      ENV["LYMAN_SOURCE_ROOT"] = fixture
      begin
        yield fixture
      ensure
        if original_source_root
          ENV["LYMAN_SOURCE_ROOT"] = original_source_root
        else
          ENV.delete("LYMAN_SOURCE_ROOT")
        end
      end
    end
  end
end

Minitest::Test.include(TestHelper)
