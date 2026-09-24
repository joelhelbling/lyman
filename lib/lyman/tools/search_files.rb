module Lyman
  module Tools
    # A plain handler, no model (docs/design/tools-and-agents.md, "File
    # access"): search a tree by file-content substring, by file name/glob,
    # or both. Root-confined so a model can't be talked into reading outside
    # the project it was pointed at.
    def self.search_files(root: Dir.pwd, max_hits: 100)
      confined_root = SearchFiles.realpath(root)

      {
        schema: {
          "type" => "function",
          "function" => {
            "name" => "search_files",
            "description" => "Search files under the project root. Pass `pattern` to search file " \
              "contents (a literal, case-insensitive substring — not a regex), `glob` to restrict by " \
              "file name (e.g. \"**/*.rb\" or a bare \"store.rb\" to match at any depth), and/or `path` " \
              "to search under a subdirectory. Without `pattern`, lists matching file paths instead.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "pattern" => {
                  "type" => "string",
                  "description" => "Literal, case-insensitive text to find in file contents. Omit to " \
                    "list file paths instead of content hits."
                },
                "glob" => {
                  "type" => "string",
                  "description" => "File name glob relative to root, e.g. \"**/*.rb\" or " \
                    "\"lib/**/conversation.rb\". A bare name like \"*.rb\" matches at any depth. Default \"**/*\"."
                },
                "path" => {
                  "type" => "string",
                  "description" => "Optional subdirectory of root to search under."
                }
              },
              "required" => []
            }
          }
        },
        handler: ->(args) { SearchFiles.handle(args, root: confined_root, max_hits: max_hits) }
      }
    end

    # Nested so its helpers can't collide with ReadFile's (both tools share
    # the Tools module) without resorting to a shared name prefix.
    module SearchFiles
      MAX_LINE_LEN = 200
      BINARY_SNIFF_BYTES = 8192

      def self.handle(args, root:, max_hits:)
        pattern = presence(args["pattern"])
        glob = presence(args["glob"]) || "**/*"
        path = presence(args["path"])

        search_root = root
        if path
          search_root = resolve_under_root(path, root: root)
          return "No such directory under the search root: #{path}" if search_root == :missing
          return "path escapes the search root (#{root}): #{path}" unless search_root
        end

        full_glob = bareword?(glob) ? "**/#{glob}" : glob
        return "glob escapes the search root (#{root}): #{glob}" if escapes_root?(full_glob)

        paths = Dir.glob(full_glob, base: search_root)
          .map { |rel| File.join(search_root, rel) }
          .select { |abs| regular_file_in_root?(abs, root: root) }
          .sort

        pattern ? search_contents(paths, pattern: pattern, root: root, max_hits: max_hits)
          : list_paths(paths, root: root, max_hits: max_hits)
      end
      # Not private: called from Lyman::Tools.search_files with an explicit
      # SearchFiles receiver, which a private class method would refuse.

      # A model means "match anywhere" by a bare name with no slash and no
      # "**" — "*.rb" or "store.rb" — so treat it as "**/<glob>".
      def self.bareword?(glob)
        !glob.include?("/") && !glob.include?("**")
      end
      private_class_method :bareword?

      def self.search_contents(paths, pattern:, root:, max_hits:)
        hits = []
        needle = pattern.downcase

        paths.each do |abs|
          next if binary?(abs)
          text = read_text(abs)
          next unless text

          text.each_line.with_index(1) do |line, lineno|
            next unless line.downcase.include?(needle)
            hits << "#{relative(abs, root: root)}:#{lineno}: #{truncate_line(line.strip)}"
            break if hits.size >= max_hits
          end
          break if hits.size >= max_hits
        end

        return no_results_message(pattern: pattern) if hits.empty?

        result = hits.join("\n")
        result += "\n\n[truncated at #{max_hits} hits — narrow with a more specific glob, path, or pattern]" if hits.size >= max_hits
        result
      end
      private_class_method :search_contents

      def self.list_paths(paths, root:, max_hits:)
        return "No files matched." if paths.empty?

        capped = paths.first(max_hits)
        result = capped.map { |abs| relative(abs, root: root) }.join("\n")
        result += "\n\n[truncated at #{max_hits} paths — narrow with a more specific glob or path]" if paths.size > max_hits
        result
      end
      private_class_method :list_paths

      def self.no_results_message(pattern:)
        "No hits for #{pattern.inspect}. Try a shorter or different substring, or loosen the glob/path."
      end
      private_class_method :no_results_message

      def self.truncate_line(line)
        (line.length > MAX_LINE_LEN) ? "#{line[0, MAX_LINE_LEN]}…" : line
      end
      private_class_method :truncate_line

      # A NUL byte in the first chunk is the classic cheap binary sniff —
      # good enough to skip images/executables without a gem dependency.
      def self.binary?(path)
        chunk = File.open(path, "rb") { |f| f.read(BINARY_SNIFF_BYTES) }
        chunk.nil? || chunk.include?("\x00".b)
      rescue SystemCallError
        true
      end
      private_class_method :binary?

      # Scrub rather than raise: a file that isn't valid UTF-8 (or that
      # vanishes/becomes unreadable between glob and read, e.g. a race)
      # is skipped, not a crash the model has to explain.
      def self.read_text(path)
        File.read(path, encoding: "UTF-8").scrub
      rescue SystemCallError, IOError
        nil
      end
      private_class_method :read_text

      def self.presence(value)
        string = value.to_s.strip
        string.empty? ? nil : string
      end
      private_class_method :presence

      def self.relative(abs, root:)
        abs.delete_prefix("#{root}#{File::SEPARATOR}")
      end
      private_class_method :relative

      # A glob can spell "..", e.g. "../etc/*", or be absolute ("/etc/*",
      # which Dir.glob resolves ignoring base:) — refuse both up front
      # rather than let per-file confinement quietly return nothing.
      def self.escapes_root?(glob)
        glob.start_with?("/", "~") || glob.split("/").any? { |segment| segment == ".." }
      end
      private_class_method :escapes_root?

      # Resolves root once, the same way ReadFile does — kept as a separate
      # copy on purpose (docs/design/tools-and-agents.md: each tool file is
      # self-contained, no requires of sibling lyman files).
      def self.realpath(root)
        File.realpath(root)
      end

      # Confines a model-supplied relative or absolute subdirectory to
      # root, resolving symlinks so a link that escapes is caught too.
      # Returns the realpath, :missing, or nil for an escape.
      def self.resolve_under_root(rel_or_abs, root:)
        candidate = File.expand_path(rel_or_abs, root)
        return in_root?(candidate, root: root) ? :missing : nil unless File.directory?(candidate)
        real = File.realpath(candidate)
        real if in_root?(real, root: root)
      rescue SystemCallError
        nil
      end
      private_class_method :resolve_under_root

      def self.in_root?(real, root:)
        real == root || real.start_with?("#{root}#{File::SEPARATOR}")
      end
      private_class_method :in_root?

      # Confines each globbed hit individually — a symlink inside the tree
      # may still point outside root, so this is checked per file, not just
      # once for the search root. Skipped silently (not refused): a stray
      # symlink shouldn't halt an otherwise-good search.
      def self.regular_file_in_root?(abs, root:)
        real = File.realpath(abs)
        return false unless in_root?(real, root: root)
        File.file?(real)
      rescue SystemCallError
        false
      end
      private_class_method :regular_file_in_root?
    end
  end
end
