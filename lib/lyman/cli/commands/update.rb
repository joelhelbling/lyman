module Lyman
  module CLI
    module Commands
      # `lyman update` — walks the manifest (never the filesystem) and
      # reconciles every managed artifact against the current lyman release.
      # Three tiers per docs/design/deployment.md: managed artifacts either
      # replace silently (pristine) or halt with a structured message
      # (modified/missing); owned artifacts are the user's and are skipped;
      # ejected artifacts get a one-time advisory. Artifacts not in the
      # manifest are never even looked at.
      class Update
        def initialize(thor, source_root:)
          @thor = thor
          @source_root = source_root
        end

        def call
          project_root = Manifest.find!
          manifest = Manifest.load(project_root)

          updated = []
          up_to_date = []
          halted = []
          advisories = []

          manifest.artifacts.each_key.to_a.each do |name|
            spec = Registry::ARTIFACTS[name]
            next unless spec # unknown-to-this-release entries are left alone

            entry = manifest.artifact(name)
            case entry["status"]
            when "managed"
              reconcile_managed(manifest, project_root, name, spec, entry, updated, up_to_date, halted)
            when "owned"
              next # the user's file; update never touches it
            when "ejected"
              reconcile_ejected(manifest, name, spec, entry, advisories)
            end
          end

          manifest.save
          summarize(updated, up_to_date, halted, advisories)
          exit 1 unless halted.empty?
        end

        private

        # The manifest's recorded path — not the registry's dest — says where
        # this project's copy lives; the registry only says where the current
        # release would plant a fresh one. When the two disagree (someone
        # moved the file, or upstream relocated the artifact), that's a halt:
        # update can't know which references would break by moving it.
        def reconcile_managed(manifest, project_root, name, spec, entry, updated, up_to_date, halted)
          path = entry["path"]
          dest = File.join(project_root, path)

          if spec[:dest] != path
            halted << {name: name, reason: :relocated, path: path, upstream_dest: spec[:dest]}
            return
          end

          unless File.exist?(dest)
            halted << {name: name, reason: :missing, planted_at: entry["planted_at"], path: path}
            return
          end

          current_bytes = File.read(dest)
          current_hash = Planter.hash(current_bytes)

          if current_hash != entry["hash"]
            halted << {name: name, reason: :modified, planted_at: entry["planted_at"], path: path}
            return
          end

          rendered = Planter.render(name, spec, source_root: @source_root)
          new_hash = Planter.hash(rendered)

          if new_hash == current_hash
            up_to_date << name
            return
          end

          from_version = entry["planted_at"]
          Planter.plant(name, spec, project_root: project_root, source_root: @source_root)
          manifest.write_pristine(path, rendered)
          manifest.set_artifact(name, entry.merge(
            "hash" => new_hash,
            "planted_at" => Lyman::CLI::VERSION
          ))
          updated << {name: name, from: from_version, to: Lyman::CLI::VERSION}
        end

        # Ejected artifacts are never touched — the manifest just tracks
        # whether upstream has moved since the fork point, and fires the
        # advisory at most once per upstream version so a long-lived fork
        # doesn't nag forever.
        def reconcile_ejected(manifest, name, spec, entry, advisories)
          rendered = Planter.render(name, spec, source_root: @source_root)
          current_hash = Planter.hash(rendered)

          return if current_hash == entry["pristine_hash"]
          return if entry["notified"] == Lyman::CLI::VERSION

          advisories << {name: name, ejected_at: entry["ejected_at"], upstream: Lyman::CLI::VERSION}
          manifest.set_artifact(name, entry.merge("notified" => Lyman::CLI::VERSION))
        end

        def summarize(updated, up_to_date, halted, advisories)
          updated.each do |u|
            @thor.say "updated #{u[:name]} (#{u[:from]} → #{u[:to]})"
          end

          up_to_date.each do |name|
            @thor.say "#{name} up to date"
          end

          halted.each do |h|
            @thor.say(halt_message(h), :red)
          end

          advisories.each do |a|
            @thor.say "#{a[:name]} (ejected at #{a[:ejected_at]}) has upstream changes in " \
              "#{a[:upstream]}; run `lyman diff #{a[:name]}` to compare.", :yellow
          end

          @thor.say [
            "#{updated.size} updated",
            "#{up_to_date.size} up to date",
            "#{halted.size} halted",
            "#{advisories.size} advisories"
          ].join(", ")
        end

        def halt_message(halted)
          case halted[:reason]
          when :missing
            "#{halted[:name]} (planted at #{halted[:planted_at]}) is missing its planted file " \
              "(#{halted[:path]}); run `lyman add #{halted[:name]} --force` to replant it."
          when :modified
            "#{halted[:name]} (planted at #{halted[:planted_at]}) has been modified since planting; " \
              "pristine copy at .lyman/pristine/#{halted[:path]}. " \
              "Run `lyman diff #{halted[:name]}` to see changes, or " \
              "`lyman eject #{halted[:name]}` to take ownership."
          when :relocated
            "#{halted[:name]} lives at #{halted[:path]} in this project, but this lyman release " \
              "plants it at #{halted[:upstream_dest]}. Move the file (and any references to it), " \
              "set its `path:` in .lyman/manifest.yml to match, and rerun `lyman update` — or " \
              "run `lyman eject #{halted[:name]}` to keep it where it is, as yours."
          end
        end
      end
    end
  end
end
