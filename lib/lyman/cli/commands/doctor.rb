require "open3"

module Lyman
  module CLI
    module Commands
      # `lyman doctor` — smoke-tests a scaffolded project: manifest parses,
      # every listed file exists (managed files note pristine/modified), and
      # a subprocess runs the planted pipeline end to end against a stub
      # transport (lib/lyman/cli/doctor_check.rb). See docs/design/
      # deployment.md ("Ruby without a type checker").
      class Doctor
        # doctor_check.rb is CLI machinery, not a planted artifact — it always
        # ships from this gem's own tree, never from a fixture source_root
        # (source_root exists so other commands can point at "a newer lyman
        # release"; doctor has no such concept, it only checks what's here).
        CHECK_SCRIPT = File.join(Registry::GEM_ROOT, "lib", "lyman", "cli", "doctor_check.rb")

        def initialize(thor, source_root:)
          @thor = thor
          @source_root = source_root
        end

        def call
          project_root = Manifest.find!
          manifest = load_manifest(project_root)

          results = [!manifest.nil?]
          if manifest
            results << check_files(manifest, project_root)
            results << check_pipeline(project_root)
          end

          exit 1 unless results.all?
        end

        private

        # Check 1: the manifest itself parses. `Manifest.find!` already
        # confirmed the file exists; the read can still blow up on malformed
        # YAML, and that's worth its own ✓/✗ line rather than a raw backtrace.
        def load_manifest(project_root)
          manifest = Manifest.load(project_root)
          report(true, "manifest parses (#{manifest.path})")
          manifest
        rescue => e
          report(false, "manifest failed to parse: #{e.message}")
          nil
        end

        # Check 2: every manifest-listed file exists. Managed files also get
        # a pristine/modified note — modified is informational (that's
        # `update`'s job to flag as a halt), not a doctor failure.
        def check_files(manifest, project_root)
          ok = true

          manifest.artifacts.each do |name, entry|
            spec = Registry::ARTIFACTS[name]
            next unless spec # unknown-to-this-release entries: nothing to check against

            dest = File.join(project_root, spec[:dest])
            unless File.exist?(dest)
              report(false, "#{name}: planted file missing (#{dest})")
              ok = false
              next
            end

            if entry["status"] == "managed"
              current_hash = Planter.hash(File.read(dest))
              note = (current_hash == entry["hash"]) ? "pristine" : "modified"
              report(true, "#{name}: file present (#{note})")
            else
              report(true, "#{name}: file present")
            end
          end

          ok
        end

        # Check 3: run the planted pipeline against a stub transport, in a
        # subprocess. It must be a subprocess — the client project has its
        # own `Lyman::` constants (Conversation, Workers) that would collide
        # with this CLI process if we required them in-process, and the
        # client's bundle (not the CLI's) is what needs to resolve shifty.
        def check_pipeline(project_root)
          cmd = subprocess_command(project_root)
          out, status = Open3.capture2e(*cmd, chdir: project_root)

          # doctor_check.rb prints its own ✓/✗ verdict line; relay it
          # verbatim rather than re-deriving one, so the subprocess's
          # explanation of *why* it failed (if it did) reaches the user.
          out.each_line { |line| @thor.say line.chomp }
          status.success?
        end

        # A freshly scaffolded project has no Gemfile.lock until the user
        # runs `bundle install` — `lyman doctor` should still work at that
        # point, so it falls back to plain `ruby` with explicit `-I` load
        # paths for shifty/ostruct, borrowed from the CLI process's own
        # activated gems (Gem.loaded_specs — populated by Bundler when this
        # CLI itself was launched via `bundle exec`/the installed gem).
        # Once the client has a lock, `bundle exec` lets their own bundle
        # (which might pin a different shifty version) resolve instead.
        def subprocess_command(project_root)
          if File.exist?(File.join(project_root, "Gemfile.lock"))
            ["bundle", "exec", "ruby", CHECK_SCRIPT]
          else
            load_paths = %w[shifty ostruct].filter_map do |gem_name|
              spec = Gem.loaded_specs[gem_name]
              "#{spec.gem_dir}/lib" if spec
            end
            ["ruby", *load_paths.flat_map { |p| ["-I", p] }, CHECK_SCRIPT]
          end
        end

        def report(ok, message)
          @thor.say "#{ok ? "✓" : "✗"} #{message}"
        end
      end
    end
  end
end
