module Lyman
  module CLI
    module Commands
      # `lyman add ARTIFACT` — plant one artifact into an already-scaffolded
      # project. Where `new` plants everything blind, `add` has to reconcile
      # against whatever the manifest and filesystem already say, so most of
      # this class is the branching the design doc calls out: managed/owned
      # no-op, ejected tombstone (ask first), untracked file (refuse first).
      class Add
        def initialize(thor, source_root:)
          @thor = thor
          @source_root = source_root
        end

        def call(name, force: false)
          spec = Registry.fetch(name)
          project_root = Manifest.find!
          manifest = Manifest.load(project_root)
          entry = manifest.artifact(name)
          dest = File.join(project_root, spec[:dest])

          case entry&.fetch("status", nil)
          when "managed", "owned"
            @thor.say "#{name} is already #{entry["status"]}; nothing to do."
            return
          when "ejected"
            unless force || @thor.yes?("#{name} was ejected at #{entry["ejected_at"]}; re-adding replaces your fork with the current upstream version. Continue? (y/N)")
              @thor.say "Left #{name} as-is."
              return
            end
          else
            if File.exist?(dest) && !force
              raise Thor::Error, "#{dest} already exists and isn't tracked by lyman. " \
                "Move it aside, or run `lyman add #{name} --force` to overwrite it."
            end
          end

          plant(manifest, name, spec, project_root)
          manifest.save
          @thor.say "Planted #{name} (#{spec[:role]}) at #{spec[:dest]}."
        end

        private

        def plant(manifest, name, spec, project_root)
          bytes = Planter.plant(name, spec, project_root: project_root, source_root: @source_root)
          manifest.write_pristine(name, bytes)

          attrs = {"status" => spec[:role].to_s, "planted_at" => Lyman::CLI::VERSION}
          attrs["hash"] = Planter.hash(bytes) if spec[:role] == :managed
          manifest.set_artifact(name, attrs)
        end
      end
    end
  end
end
