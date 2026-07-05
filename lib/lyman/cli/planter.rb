require "digest"
require "fileutils"

module Lyman
  module CLI
    # Turns a registry entry into planted bytes and writes them. Rendering
    # and hashing are kept together deliberately: the hash must always be a
    # hash of what actually landed on disk (banner included), never of the
    # bare source file, or `update` would flag every managed artifact as
    # locally modified on first run.
    module Planter
      BANNER = <<~RUBY
        # Managed by lyman — extend, don't modify. `lyman eject %<name>s` takes
        # ownership; see .lyman/manifest.yml.

      RUBY

      def self.render(name, spec, source_root: Registry::GEM_ROOT)
        source = File.read(Registry.source_path(spec, source_root: source_root))
        if spec[:role] == :managed && spec[:dest].end_with?(".rb")
          format(BANNER, name: name) + source
        else
          source
        end
      end

      def self.plant(name, spec, project_root:, source_root: Registry::GEM_ROOT)
        bytes = render(name, spec, source_root: source_root)
        dest = File.join(project_root, spec[:dest])
        FileUtils.mkdir_p(File.dirname(dest))
        File.write(dest, bytes)
        bytes
      end

      def self.hash(bytes)
        Digest::SHA256.hexdigest(bytes)
      end
    end
  end
end
