module Lyman
  module Tools
    # A plain handler, no model (docs/design/tools-and-agents.md, "File
    # access"): read a file, optionally by 1-based inclusive line range,
    # with line numbers so a model can cite what it read and ask for more.
    # Root-confined the same way search_files is.
    def self.read_file(root: Dir.pwd, max_chars: 20_000)
      confined_root = ReadFile.realpath(root)

      {
        schema: {
          "type" => "function",
          "function" => {
            "name" => "read_file",
            "description" => "Read a file under the project root, with line numbers. Pass " \
              "`start_line`/`end_line` (1-based, inclusive) to read part of a file; omit both to " \
              "read from the start (long files are truncated with a hint for the next range).",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "path" => {
                  "type" => "string",
                  "description" => "Path to the file, relative to root (or absolute, if inside root)."
                },
                "start_line" => {
                  "type" => "integer",
                  "description" => "First line to return (1-based, inclusive). Default 1."
                },
                "end_line" => {
                  "type" => "integer",
                  "description" => "Last line to return (1-based, inclusive). Default: end of file."
                }
              },
              "required" => ["path"]
            }
          }
        },
        handler: ->(args) { ReadFile.handle(args, root: confined_root, max_chars: max_chars) }
      }
    end

    # Nested so its helpers can't collide with SearchFiles's (both tools
    # share the Tools module) without resorting to a shared name prefix.
    module ReadFile
      def self.handle(args, root:, max_chars:)
        path = presence(args["path"])
        return "Pass a path to read." unless path

        resolved = resolve_under_root(path, root: root)
        return "path escapes the root (#{root}): #{path}" unless resolved
        return "No such file: #{path}" unless File.exist?(resolved)
        return "#{path} is a directory, not a file." if File.directory?(resolved)

        text = read_text(resolved)
        return "#{path} looks like a binary file — refusing to read it as text." unless text

        return "#{path} is empty." if text.empty?

        lines = text.each_line.to_a
        render(lines, args: args, path: path, max_chars: max_chars)
      end
      # Not private: called from Lyman::Tools.read_file with an explicit
      # ReadFile receiver, which a private class method would refuse.

      def self.render(lines, args:, path:, max_chars:)
        total = lines.size
        start_line = line_number(args["start_line"]) || 1
        end_line = line_number(args["end_line"]) || total

        # Check "past EOF" against the raw requested start_line, before
        # clamping folds it back inside the file and hides the mistake.
        return "#{path} has #{total} line#{"s" if total != 1}; start_line #{start_line} is past the end." if start_line > total

        start_line = start_line.clamp(1, [total, 1].max)
        end_line = end_line.clamp(1, total)

        return "start_line (#{start_line}) is after end_line (#{end_line}); #{path} has #{total} lines." if start_line > end_line

        width = end_line.to_s.length
        numbered = (start_line..end_line).map { |n| "#{n.to_s.rjust(width)}| #{lines[n - 1].chomp}" }

        truncate(numbered, start_line: start_line, end_line: end_line, total: total, max_chars: max_chars)
      end
      private_class_method :render

      # Truncates on a line boundary (never mid-line) and names the next
      # start_line to request, so a small model can page through a large
      # file without re-reading what it already saw.
      def self.truncate(numbered, start_line:, end_line:, total:, max_chars:)
        full = numbered.join("\n")
        return full if full.length <= max_chars

        kept = []
        length = 0
        numbered.each do |line|
          added = kept.empty? ? line.length : line.length + 1
          break if length + added > max_chars
          kept << line
          length += added
        end
        kept = numbered.first(1) if kept.empty? # always show at least one line, even if it alone exceeds max_chars

        last_line_no = start_line + kept.size - 1
        text = kept.join("\n")
        "#{text}\n\n[truncated at line #{last_line_no} of #{total} — pass start_line: #{last_line_no + 1} to continue]"
      end
      private_class_method :truncate

      # Accepts integer-ish strings ("12") the way small models send them,
      # without raising on nonsense ("twelve" comes back nil, not an error).
      def self.line_number(value)
        return nil if value.nil? || presence(value.to_s).nil?
        Integer(value, exception: false)
      end
      private_class_method :line_number

      def self.presence(value)
        string = value.to_s.strip
        string.empty? ? nil : string
      end
      private_class_method :presence

      BINARY_SNIFF_BYTES = 8192

      def self.read_text(path)
        chunk = File.open(path, "rb") { |f| f.read(BINARY_SNIFF_BYTES) }
        return nil if chunk&.include?("\x00".b)
        File.read(path, encoding: "UTF-8").scrub
      rescue SystemCallError, IOError
        nil
      end
      private_class_method :read_text

      def self.realpath(root)
        File.realpath(root)
      end

      # Confines a model-supplied relative or absolute path to root, or
      # returns nil. An existing path is realpath'd, so a symlink that
      # leads outside root is caught; a missing one can only be checked
      # lexically — which is enough, since nothing will be read from it.
      def self.resolve_under_root(rel_or_abs, root:)
        candidate = File.expand_path(rel_or_abs, root)
        candidate = File.realpath(candidate) if File.exist?(candidate)
        candidate if in_root?(candidate, root: root)
      rescue SystemCallError
        nil
      end
      private_class_method :resolve_under_root

      def self.in_root?(real, root:)
        real == root || real.start_with?("#{root}#{File::SEPARATOR}")
      end
      private_class_method :in_root?
    end
  end
end
