require "tempfile"
require "open3"

module Lyman
  module CLI
    module Commands
      # `lyman diff ARTIFACT` — shows "your changes" (pristine vs. working
      # file) and "upstream changes since your copy was planted" (pristine
      # vs. a freshly rendered copy), by shelling out to `diff -u`. The
      # pristine-as-planted copy is the fork point in both comparisons, so
      # the two sections never mix upstream's changes with the user's own.
      class Diff
        def initialize(thor, source_root:)
          @thor = thor
          @source_root = source_root
        end

        def call(artifact)
          project_root = Manifest.find!
          manifest = Manifest.load(project_root)
          name = Registry.resolve(artifact, manifest: manifest)
          spec = Registry.fetch(name)
          entry = manifest.artifact(name)
          path = entry && entry["path"]

          unless path && manifest.pristine?(path)
            raise Thor::Error, "#{name} has no pristine copy in this project; nothing to diff against."
          end

          pristine_path = manifest.pristine_path(path)
          dest = File.join(project_root, path)

          @thor.say "--- your changes (#{name}) ---"
          @thor.say section(pristine_path, dest, "pristine/#{path}", path)

          @thor.say ""
          @thor.say "--- upstream changes since planted (#{name}) ---"
          rendered = Planter.render(name, spec, source_root: @source_root)
          Tempfile.create(name) do |upstream|
            upstream.write(rendered)
            upstream.flush
            @thor.say section(pristine_path, upstream.path, "pristine/#{path}", "upstream/#{spec[:dest]}")
          end
        end

        private

        # `diff` exits 1 when the compared files differ — that's the
        # expected, successful case here, not a failure to raise on.
        def section(from, to, from_label, to_label)
          out, _status = Open3.capture2("diff", "-u", "-L", from_label, "-L", to_label, from, to)
          out.empty? ? "(none)" : out
        end
      end
    end
  end
end
