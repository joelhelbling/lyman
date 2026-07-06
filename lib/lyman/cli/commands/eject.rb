module Lyman
  module CLI
    module Commands
      # `lyman eject ARTIFACT` — rewrites a managed artifact's manifest
      # entry into a tombstone (status: ejected, ejected_at, pristine_hash),
      # transferring ownership without deleting history. See docs/design/
      # deployment.md ("Eject-to-own"). The pristine copy is left in place —
      # it becomes the fork point that makes a later `lyman diff` meaningful.
      class Eject
        def initialize(thor, source_root:)
          @thor = thor
          @source_root = source_root
        end

        def call(artifact)
          project_root = Manifest.find!
          manifest = Manifest.load(project_root)
          name = Registry.resolve(artifact, manifest: manifest)
          entry = manifest.artifact(name)

          case entry&.fetch("status", nil)
          when "managed"
            eject(manifest, name, entry)
          when "owned"
            @thor.say "#{name} is already yours; lyman never manages #{entry["path"]}."
          when "ejected"
            @thor.say "#{name} was already ejected at #{entry["ejected_at"]}; nothing to do."
          else
            raise Thor::Error, "#{name} isn't planted in this project; nothing to eject."
          end
        end

        private

        # The tombstone keeps the path: it's what lets `diff` and `doctor`
        # find the fork without consulting a registry that may no longer
        # know this artifact.
        def eject(manifest, name, entry)
          manifest.set_artifact(name, {
            "status" => "ejected",
            "ejected_at" => Lyman::CLI::VERSION,
            "path" => entry["path"],
            "pristine_hash" => entry["hash"]
          })
          manifest.save

          @thor.say "#{name} is yours now. lyman will note upstream changes to it " \
            "(run `lyman diff #{name}` to compare) but will never touch the file again."
        end
      end
    end
  end
end
