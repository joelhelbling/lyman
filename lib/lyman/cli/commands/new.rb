require "fileutils"

module Lyman
  module CLI
    module Commands
      # `lyman new NAME` — the one command that doesn't need an existing
      # project: it creates one, planting every registry artifact and
      # writing the manifest that makes `update`/`eject`/`diff` possible
      # afterward.
      class New
        def initialize(thor, source_root:)
          @thor = thor
          @source_root = source_root
        end

        def call(name)
          project_root = File.expand_path(name)
          refuse_nonempty!(project_root, name)
          FileUtils.mkdir_p(project_root)

          manifest = Manifest.load(project_root)
          Registry.default.each do |artifact_name, spec|
            plant(manifest, artifact_name, spec, project_root)
          end
          manifest.save

          epilogue(name)
        end

        private

        def refuse_nonempty!(project_root, name)
          return unless Dir.exist?(project_root)
          return if Dir.empty?(project_root)

          raise Thor::Error, "#{name} already exists and is not empty; " \
            "choose a different name or clear the directory first."
        end

        # The manifest records where each artifact was planted, so every
        # entry stays self-describing even if a later lyman release renames
        # or drops the artifact — lifecycle commands read the path from
        # here, not from the registry.
        def plant(manifest, artifact_name, spec, project_root)
          bytes = Planter.plant(artifact_name, spec, project_root: project_root, source_root: @source_root)
          manifest.write_pristine(spec[:dest], bytes)

          attrs = {
            "status" => spec[:role].to_s,
            "planted_at" => Lyman::CLI::VERSION,
            "path" => spec[:dest]
          }
          attrs["hash"] = Planter.hash(bytes) if spec[:role] == :managed
          manifest.set_artifact(artifact_name, attrs)
        end

        def epilogue(name)
          @thor.say <<~EPILOGUE

            Planted a new lyman project in #{name}.

            Next steps:
              cd #{name}
              bundle install
              ruby harness/repl.rb   # defaults to Ollama at http://localhost:11434/v1
              lyman doctor           # smoke-test the pipeline

            The repl is one of three harness archetypes; the other two are a
            `lyman add` away (daemon_harness, script_harness).
          EPILOGUE
        end
      end
    end
  end
end
