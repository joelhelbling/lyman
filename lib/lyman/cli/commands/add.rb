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

        def call(artifact, force: false)
          project_root = Manifest.find!
          manifest = Manifest.load(project_root)
          name = Registry.resolve(artifact, manifest: manifest)
          spec = Registry.fetch(name)
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
              message = "#{dest} already exists and isn't tracked by lyman. " \
                "Move it aside, or run `lyman add #{name} --force` to overwrite it."
              if (alt = spec[:alternative])
                message += " Or plant `lyman add #{alt}` instead, " \
                  "which leaves #{spec[:dest]} untouched."
              end
              raise Thor::Error, message
            end
          end

          plant(manifest, name, spec, project_root)
          manifest.save
          @thor.say "Planted #{name} (#{spec[:role]}) at #{spec[:dest]}."
          advise_on_gems(name, spec, project_root)
          advise_on_wiring(name, spec, project_root)
          advise_on_needs(name, spec, manifest)
          @thor.say spec[:advice] if spec[:advice]
        end

        private

        # The client Gemfile is owned, so lyman advises rather than edits it —
        # planting a file that `require`s a gem the project never declared
        # would fail confusingly at runtime instead of here, up front.
        def advise_on_gems(name, spec, project_root)
          (spec[:gems] || []).each do |gem_name|
            next if gemfile_mentions?(project_root, gem_name)
            @thor.say "#{name} needs the #{gem_name} gem: add gem \"#{gem_name}\" to your Gemfile and run bundle install. " \
              "Until then lib/lyman.rb won't load (it requires every planted module), so neither will your harness or `lyman doctor`."
          end
        end

        def gemfile_mentions?(project_root, gem_name)
          gemfile = File.join(project_root, "Gemfile")
          return false unless File.exist?(gemfile)
          /gem\s+["']#{Regexp.escape(gem_name)}["']/.match?(File.read(gemfile)) || false
        end

        # Harnesses are owned files, so lyman advises rather than edits them —
        # a planted tool the model never hears about (because no TOOLS list
        # mentions it) would otherwise fail silently rather than loudly.
        def advise_on_wiring(name, spec, project_root)
          wire = spec[:wire]
          return unless wire
          return if any_harness_mentions?(project_root, wire)
          @thor.say "#{name} is planted but not wired: add #{wire} to a harness's TOOLS array " \
            "to hand it to the model (harnesses are yours, so lyman doesn't edit them)."
        end

        # A heuristic, since the advice is only a reminder: match the factory
        # call by name, ignoring its arguments (a harness may pass its own
        # variable where `wire:` says `store: store`), and stop at a word
        # boundary so current_time_range doesn't count as current_time.
        def any_harness_mentions?(project_root, wire)
          call = /#{Regexp.escape(wire.sub(/\(.*\z/m, ""))}\b/
          Dir.glob(File.join(project_root, "harness", "**", "*.rb")).any? do |path|
            call.match?(File.read(path))
          end
        end

        # A `needs:` dependency (e.g. recall_tool needing a store) is
        # duck-typed, so lyman can't just plant it for you — you might be
        # wiring in your own object. It only advises, the same
        # don't-edit-what-you-don't-own posture as the Gemfile and wiring
        # advice above. An ejected artifact counts as present: eject leaves
        # the file in place, so the dependency is still satisfied at runtime,
        # and re-adding it would offer to replace the user's fork.
        def advise_on_needs(name, spec, manifest)
          (spec[:needs] || []).each do |needed|
            status = manifest.artifact(needed)&.fetch("status", nil)
            next if %w[managed owned ejected].include?(status)
            @thor.say "#{name} expects #{needed}: run `lyman add #{needed}` " \
              "(or wire in your own object with the same interface)."
          end
        end

        def plant(manifest, name, spec, project_root)
          bytes = Planter.plant(name, spec, project_root: project_root, source_root: @source_root)
          manifest.write_pristine(spec[:dest], bytes)

          attrs = {
            "status" => spec[:role].to_s,
            "planted_at" => Lyman::CLI::VERSION,
            "path" => spec[:dest]
          }
          attrs["hash"] = Planter.hash(bytes) if spec[:role] == :managed
          manifest.set_artifact(name, attrs)
        end
      end
    end
  end
end
