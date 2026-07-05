require "yaml"
require "fileutils"

module Lyman
  module CLI
    # Reads and writes <project_root>/.lyman/manifest.yml — the record that
    # makes `update` cheap (hash comparison instead of guessing) and `eject`
    # meaningful (a tombstone, not a deletion). See docs/design/deployment.md.
    class Manifest
      RELATIVE_PATH = File.join(".lyman", "manifest.yml")
      PRISTINE_DIR = File.join(".lyman", "pristine")

      attr_reader :project_root

      # Walks up from +start_dir+ looking for .lyman/manifest.yml, the same
      # way git walks up looking for .git. Returns the project root or nil.
      def self.find(start_dir = Dir.pwd)
        dir = File.expand_path(start_dir)
        loop do
          return dir if File.exist?(File.join(dir, RELATIVE_PATH))
          parent = File.dirname(dir)
          break if parent == dir
          dir = parent
        end
        nil
      end

      # Every command except `new` needs a project to act on; this is the one
      # place that error is raised, worded for an agent to act on directly.
      def self.find!(start_dir = Dir.pwd)
        find(start_dir) || raise(Thor::Error, <<~MSG.strip)
          Not inside a lyman project (no .lyman/manifest.yml found walking up
          from #{start_dir}). Run `lyman new NAME` to create one.
        MSG
      end

      def self.load(project_root)
        new(project_root)
      end

      def initialize(project_root)
        @project_root = project_root
        @data = read
      end

      def path
        File.join(project_root, RELATIVE_PATH)
      end

      def lyman_version
        @data["lyman"]
      end

      def artifacts
        @data["artifacts"] ||= {}
      end

      def artifact(name)
        artifacts[name]
      end

      def set_artifact(name, attrs)
        artifacts[name] = attrs
      end

      def delete_artifact(name)
        artifacts.delete(name)
      end

      def save
        @data["lyman"] = Lyman::CLI::VERSION
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, dump)
        self
      end

      def pristine_path(name)
        File.join(project_root, PRISTINE_DIR, name)
      end

      def write_pristine(name, bytes)
        FileUtils.mkdir_p(File.join(project_root, PRISTINE_DIR))
        File.write(pristine_path(name), bytes)
      end

      def read_pristine(name)
        File.read(pristine_path(name))
      end

      def pristine?(name)
        File.exist?(pristine_path(name))
      end

      private

      # Stable key order (lyman, then artifacts sorted by name) so the
      # manifest's own diffs stay calm across runs.
      def dump
        ordered = {"lyman" => @data["lyman"] || Lyman::CLI::VERSION}
        ordered["artifacts"] = artifacts.sort.to_h
        YAML.dump(ordered)
      end

      def read
        return {"lyman" => Lyman::CLI::VERSION, "artifacts" => {}} unless File.exist?(path)
        YAML.safe_load_file(path) || {}
      end
    end
  end
end
