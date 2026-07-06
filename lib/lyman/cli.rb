require "thor"

require_relative "cli/version"
require_relative "cli/registry"
require_relative "cli/manifest"
require_relative "cli/planter"
require_relative "cli/commands/new"
require_relative "cli/commands/add"
require_relative "cli/commands/update"
require_relative "cli/commands/eject"
require_relative "cli/commands/diff"
require_relative "cli/commands/doctor"

module Lyman
  module CLI
    # The legible table of contents for every lyman command. Root wires
    # Thor's argument parsing to a plain object per command
    # (lib/lyman/cli/commands/*.rb) and nothing else — no command grows its
    # body here.
    #
    # Command contract: every command class is built as
    # `Commands::X.new(thor, source_root:).call(*args)`.
    #   - `thor` is this Root instance, passed through so a command can use
    #     Thor's UI helpers (`thor.yes?`, `thor.say`) without inheriting from
    #     Thor itself — commands are plain objects, not Thor subclasses.
    #   - `source_root:` is where artifacts are read from (the gem tree by
    #     default; overridable via LYMAN_SOURCE_ROOT so tests can point it at
    #     a fixture that simulates a newer lyman release).
    #   - `#call`'s positional args are whatever the command needs (an
    #     artifact/project name, or nothing). Project-root discovery
    #     (Manifest.find!) happens inside each command that needs it — `new`
    #     is the one command that doesn't have a project root yet.
    class Root < Thor
      def self.exit_on_failure?
        true
      end

      desc "new NAME", "Scaffold a new lyman project at NAME"
      def new(name)
        Commands::New.new(self, source_root: source_root).call(name)
      end

      desc "add ARTIFACT", "Plant an artifact (by name or path) this project doesn't have yet"
      method_option :force, type: :boolean, default: false,
        desc: "Skip the confirmation prompt when re-adding an ejected artifact, " \
          "or overwrite an untracked file at the destination"
      def add(artifact)
        Commands::Add.new(self, source_root: source_root).call(artifact, force: options[:force])
      end

      desc "update", "Refresh managed artifacts from the current lyman release"
      def update
        Commands::Update.new(self, source_root: source_root).call
      end

      desc "eject ARTIFACT", "Take ownership of a managed artifact (by name or path)"
      def eject(artifact)
        Commands::Eject.new(self, source_root: source_root).call(artifact)
      end

      desc "diff ARTIFACT", "Show local and upstream changes for an artifact (by name or path)"
      def diff(artifact)
        Commands::Diff.new(self, source_root: source_root).call(artifact)
      end

      desc "doctor", "Smoke-test that the planted pipeline still runs"
      def doctor
        Commands::Doctor.new(self, source_root: source_root).call
      end

      desc "list", "List every artifact lyman knows how to install"
      def list
        manifest_root = Manifest.find
        manifest = Manifest.load(manifest_root) if manifest_root

        Registry::ARTIFACTS.each do |name, spec|
          status =
            if manifest
              entry = manifest.artifact(name)
              entry ? entry["status"] : "not planted"
            end

          line = "#{name} (#{spec[:role]}) #{spec[:dest]}#{" — #{status}" if status} — #{spec[:description]}"
          say line
        end
      end

      desc "version", "Print the lyman gem version"
      def version
        say VERSION
      end

      private

      def source_root
        ENV.fetch("LYMAN_SOURCE_ROOT", Registry::GEM_ROOT)
      end
    end
  end
end
