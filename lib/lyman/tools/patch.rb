require "open3"
require "shellwords"
require "fileutils"

module Lyman
  module Tools
    # The patch tool (docs/design/tools-and-agents.md, "Patching"): apply
    # one patch to one file, then run a configured check on the touched
    # file and report. Two formats, as two factories rather than a
    # `format:` switch — the format changes the schema the model sees, not
    # just the handler — so choosing a format is choosing which one to list
    # in TOOLS. Both live in this one file because they share the check
    # step and root confinement, and a tool file stays self-contained.
    #
    # check: is the seam where linting (and, later, an LSP client) plugs in:
    #   - a String or Array command, e.g. "bundle exec standardrb" — the
    #     touched path (relative to root) is appended and it runs as an
    #     argv from root, never through a shell; exit 0 is a pass;
    #   - a callable given the touched file's absolute path, returning
    #     nil/"" for a pass or the findings as a string;
    #   - nil (the default): no check.
    # The model never supplies any part of it — it's fixed at wiring time.
    # Prefer a check that only reports: a `--fix` style command rewrites
    # the file out from under the model's picture of it.

    # Search-and-replace blocks: robust against models that can't
    # reproduce exact context lines and line numbers — the default format.
    def self.search_replace(root: Dir.pwd, check: nil)
      confined_root = File.realpath(root)
      checker = Patch.checker(check, root: confined_root)

      {
        schema: {
          "type" => "function",
          "function" => {
            "name" => "search_replace",
            "description" => "Edit one file under the project root by replacing an exact block of " \
              "text. `search` must match the file exactly (including indentation) and exactly once — " \
              "copy it from the file, with enough surrounding lines to be unique. To create a new " \
              "file, pass an empty `search` and the whole content as `replace`." \
              "#{" After editing, a check runs on the file and its findings are returned." if checker}",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "path" => {
                  "type" => "string",
                  "description" => "Path to the file, relative to root (or absolute, if inside root)."
                },
                "search" => {
                  "type" => "string",
                  "description" => "The exact existing text to replace. Empty to create a new file."
                },
                "replace" => {
                  "type" => "string",
                  "description" => "The text to put in its place (empty to delete the block)."
                }
              },
              "required" => ["path", "search", "replace"]
            }
          }
        },
        handler: ->(args) { Patch::SearchReplace.handle(args, root: confined_root, checker: checker) }
      }
    end

    # Unified diff, one file per call: for models that can write one.
    # Hunks are placed by their context and removed lines, using the
    # header's line numbers only to choose among equal matches — models
    # get the numbers wrong far more often than the text.
    def self.apply_diff(root: Dir.pwd, check: nil)
      confined_root = File.realpath(root)
      checker = Patch.checker(check, root: confined_root)

      {
        schema: {
          "type" => "function",
          "function" => {
            "name" => "apply_diff",
            "description" => "Edit one file under the project root by applying a unified diff " \
              "(hunks starting with @@, lines prefixed by space, - or +). Context and - lines must " \
              "match the file; line numbers in @@ headers may be approximate. All hunks apply or none " \
              "do. To create a new file, send hunks with only + lines." \
              "#{" After editing, a check runs on the file and its findings are returned." if checker}",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "path" => {
                  "type" => "string",
                  "description" => "Path to the file, relative to root (or absolute, if inside root). " \
                    "This decides the file, not the diff's ---/+++ headers."
                },
                "diff" => {
                  "type" => "string",
                  "description" => "The unified diff for this one file."
                }
              },
              "required" => ["path", "diff"]
            }
          }
        },
        handler: ->(args) { Patch::UnifiedDiff.handle(args, root: confined_root, checker: checker) }
      }
    end

    # Nested so these helpers can't collide with other tools' (every tool
    # shares the Tools module). Nothing here raises on bad model input:
    # every failure comes back as a message the model can read and act on.
    module Patch
      BINARY_SNIFF_BYTES = 8192
      MAX_CHECK_OUTPUT = 4_000

      # Normalizes check: once, at factory time, into nil or a callable
      # taking the absolute path and returning nil (pass) or findings.
      def self.checker(check, root:)
        case check
        when nil then nil
        when String, Array
          argv = check.is_a?(String) ? Shellwords.split(check) : check.map(&:to_s)
          raise ArgumentError, "check: command is empty" if argv.empty?
          ->(abs_path) { run_command(argv, abs_path, root: root) }
        else
          raise ArgumentError, "check: must be a command String/Array, a callable, or nil" unless check.respond_to?(:call)
          check
        end
      end

      def self.run_command(argv, abs_path, root:)
        rel = abs_path.delete_prefix("#{root}#{File::SEPARATOR}")
        output, status = Open3.capture2e(*argv, rel, chdir: root)
        return nil if status.success?
        "exit #{status.exitstatus}\n#{output.strip}"
      rescue SystemCallError => e
        "could not run `#{argv.join(" ")}`: #{e.message}"
      end

      # What the model reads after a successful patch: what changed, then
      # the check — one word when it passes, the findings when it doesn't.
      def self.report(summary, abs_path, checker:)
        return summary unless checker
        findings = begin
          checker.call(abs_path)
        rescue => e
          "the check raised #{e.class}: #{e.message}"
        end
        findings = findings.to_s.strip
        return "#{summary}\nCheck: passed." if findings.empty?
        if findings.length > MAX_CHECK_OUTPUT
          findings = "#{findings[0, MAX_CHECK_OUTPUT]}\n[check output truncated]"
        end
        "#{summary}\nCheck: failed —\n#{findings}"
      end

      # Resolves a model-supplied path to an absolute path inside root, or
      # nil. The file may not exist yet (creation), so the nearest existing
      # ancestor is realpath'd — a symlinked directory leading outside root
      # is caught either way.
      def self.resolve_under_root(rel_or_abs, root:)
        candidate = File.expand_path(rel_or_abs, root)
        existing = candidate
        existing = File.dirname(existing) until File.exist?(existing) || existing == File.dirname(existing)
        real = File.realpath(existing) + candidate.delete_prefix(existing)
        real = File.realpath(real) if File.exist?(real) # the leaf itself may be a symlink
        real if in_root?(real, root: root) && real != root
      rescue SystemCallError
        nil
      end

      def self.in_root?(real, root:)
        real == root || real.start_with?("#{root}#{File::SEPARATOR}")
      end

      # Reads a file as text for patching: [text with "\n" endings, crlf?],
      # or a message String when it can't be patched as text. CRLF files
      # are matched as LF (models send LF) and written back as CRLF.
      def self.read_text(abs_path, path)
        return "#{path} is a directory, not a file." if File.directory?(abs_path)
        bytes = File.binread(abs_path)
        return "#{path} looks like a binary file — refusing to patch it." if bytes[0, BINARY_SNIFF_BYTES].include?("\x00".b)
        text = bytes.force_encoding(Encoding::UTF_8)
        return "#{path} isn't valid UTF-8 text — refusing to patch it." unless text.valid_encoding?
        crlf = text.include?("\r\n")
        [crlf ? text.gsub("\r\n", "\n") : text, crlf]
      rescue SystemCallError => e
        "could not read #{path}: #{e.message}"
      end

      def self.write_text(abs_path, text, crlf:)
        FileUtils.mkdir_p(File.dirname(abs_path))
        File.write(abs_path, crlf ? text.gsub("\n", "\r\n") : text)
        nil
      rescue SystemCallError => e
        "could not write #{abs_path}: #{e.message}"
      end

      def self.presence(value)
        string = value.to_s.strip
        string.empty? ? nil : string
      end

      def self.line_range(first, count)
        (count <= 1) ? "line #{first}" : "lines #{first}-#{first + count - 1}"
      end

      module SearchReplace
        def self.handle(args, root:, checker:)
          path = Patch.presence(args["path"])
          return "Pass a path to patch." unless path
          search = args["search"].to_s
          replace = args["replace"].to_s

          abs = Patch.resolve_under_root(path, root: root)
          return "path escapes the root (#{root}): #{path}" unless abs

          return create(path, abs, replace, checker: checker) if search.strip.empty?
          return "No such file: #{path} (to create a file, pass an empty search)." unless File.exist?(abs)

          read = Patch.read_text(abs, path)
          return read if read.is_a?(String)
          text, crlf = read
          search = search.gsub("\r\n", "\n")
          replace = replace.gsub("\r\n", "\n")

          offsets = occurrences(text, search)
          return not_found(text, search, path) if offsets.empty?
          if offsets.size > 1
            lines = offsets.map { |i| line_of(text, i) }.join(", ")
            return "search matches #{offsets.size} places in #{path} (starting at lines #{lines}); " \
              "nothing was changed. Include more surrounding lines so it matches exactly one."
          end

          at = offsets.first
          patched = text[0, at] + replace + text[(at + search.length)..]
          failure = Patch.write_text(abs, patched, crlf: crlf)
          return failure if failure

          first = line_of(text, at)
          summary = "Patched #{path}: replaced #{Patch.line_range(first, search.lines.size)} " \
            "with #{replace.lines.size} line#{"s" unless replace.lines.size == 1}."
          Patch.report(summary, abs, checker: checker)
        end

        def self.create(path, abs, content, checker:)
          return "#{path} already exists; pass the exact text to replace as search." if File.exist?(abs)
          failure = Patch.write_text(abs, content, crlf: false)
          return failure if failure
          Patch.report("Created #{path} (#{content.lines.size} lines).", abs, checker: checker)
        end

        def self.occurrences(text, search)
          found = []
          from = 0
          while (i = text.index(search, from))
            found << i
            from = i + search.length
          end
          found
        end

        def self.line_of(text, offset)
          text[0, offset].count("\n") + 1
        end

        # The common failure is right text, wrong whitespace. Rather than
        # guess which indentation the model meant, show it the exact lines
        # so its next attempt can match.
        def self.not_found(text, search, path)
          wanted = search.lines.map(&:strip)
          wanted.shift while wanted.first&.empty?
          wanted.pop while wanted.last&.empty?
          lines = text.lines
          if wanted.any?
            starts = (0..(lines.size - wanted.size)).select do |i|
              lines[i, wanted.size].map(&:strip) == wanted
            end
            if starts.size == 1
              exact = lines[starts.first, wanted.size].join
              return "search not found in #{path} exactly, but #{Patch.line_range(starts.first + 1, wanted.size)} " \
                "match it apart from whitespace; nothing was changed. Resend with search copied exactly:\n#{exact}"
            end
          end
          "search not found in #{path}; nothing was changed. Read the file and copy the text exactly, " \
            "including indentation."
        end
      end

      module UnifiedDiff
        HUNK_HEADER = /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/
        # no_newline: a "\ No newline at end of file" marker followed this
        # hunk's new side — only consulted when the diff creates a file.
        Hunk = Struct.new(:old_start, :lines, :no_newline) do
          def old_lines = lines.filter_map { |kind, text| text unless kind == "+" }
          def new_lines = lines.filter_map { |kind, text| text unless kind == "-" }
        end

        def self.handle(args, root:, checker:)
          path = Patch.presence(args["path"])
          return "Pass a path to patch." unless path
          diff = args["diff"].to_s.gsub("\r\n", "\n")

          abs = Patch.resolve_under_root(path, root: root)
          return "path escapes the root (#{root}): #{path}" unless abs

          hunks = parse(diff)
          return hunks if hunks.is_a?(String)
          return "No hunks found — a diff needs at least one @@ hunk; nothing was changed." if hunks.empty?

          return create(path, abs, hunks, checker: checker) unless File.exist?(abs)

          read = Patch.read_text(abs, path)
          return read if read.is_a?(String)
          text, crlf = read

          lines = text.split("\n", -1)
          trailing_newline = lines.last == ""
          lines.pop if trailing_newline

          placed = []
          offset = 0 # how far earlier hunks have shifted line numbers
          floor = 0  # hunks apply in order, never overlapping a previous one
          hunks.each_with_index do |hunk, n|
            at = locate(lines, hunk, expected: hunk.old_start && (hunk.old_start - 1 + offset), floor: floor)
            return failed_hunk(n, hunks.size, hunk, path, at) unless at.is_a?(Integer)
            lines[at, hunk.old_lines.size] = replacement(hunk, lines[at, hunk.old_lines.size])
            placed << Patch.line_range(at + 1, [hunk.new_lines.size, 1].max)
            offset += hunk.new_lines.size - hunk.old_lines.size
            floor = at + hunk.new_lines.size
          end

          patched = lines.join("\n")
          patched += "\n" if trailing_newline
          failure = Patch.write_text(abs, patched, crlf: crlf)
          return failure if failure

          summary = "Patched #{path}: #{hunks.size} hunk#{"s" unless hunks.size == 1} applied (now at #{placed.join(", ")})."
          Patch.report(summary, abs, checker: checker)
        end

        # The hunk's new side, but with context lines taken from the file
        # rather than the diff — a match that tolerated trailing whitespace
        # must not quietly rewrite the lines it only used as an anchor.
        def self.replacement(hunk, matched)
          old = matched.each
          hunk.lines.filter_map do |kind, text|
            case kind
            when " " then old.next
            when "-" then old.next && nil
            else text
            end
          end
        end

        # File headers (---/+++, diff, index) are ignored: `path` decides
        # the file. A second file header after the first hunk means the
        # model sent a multi-file diff, which this tool refuses. A ---/+++
        # pair only counts as a header when a hunk follows it, so a removed
        # "-- x" line next to an added "++ y" line stays content.
        def self.parse(diff)
          hunks = []
          rows = diff.split("\n", -1)
          rows.pop if rows.last == ""
          multi_file = "This diff touches more than one file; send one file per call. Nothing was changed."
          rows.each_with_index do |row, i|
            if row.start_with?("diff --git ")
              return multi_file if hunks.any?
              next
            end
            if row.start_with?("--- ") && rows[i + 1]&.start_with?("+++ ") && rows[i + 2]&.start_with?("@@")
              return multi_file if hunks.any?
              next
            end
            if row.start_with?("@@")
              start = row[HUNK_HEADER, 1]&.to_i
              hunks << Hunk.new(start, [])
              next
            end
            next unless hunks.any?
            case row[0]
            when " ", "-", "+" then hunks.last.lines << [row[0], row[1..]]
            when nil then hunks.last.lines << [" ", ""] # a blank context line whose space was trimmed
            when "\\" # "\ No newline at end of file" — after a - line it's about the old side
              hunks.last.no_newline = true unless hunks.last.lines.last&.first == "-"
            else
              return "Unrecognized line in hunk #{hunks.size}: #{row.inspect} — hunk lines start with " \
                "space, - or +. Nothing was changed."
            end
          end
          hunks
        end

        # Where the hunk's old side sits: exact matches first, then ignoring
        # trailing whitespace; among several, the one nearest the header's
        # line number. A pure insertion has only the header to go on.
        def self.locate(lines, hunk, expected:, floor:)
          old = hunk.old_lines
          if old.empty?
            return :no_anchor unless hunk.old_start
            # "-N,0" means "insert after line N", i.e. at index N (shifted).
            return (expected + 1).clamp(floor, lines.size)
          end

          [->(l) { l }, ->(l) { l.rstrip }].each do |norm|
            want = old.map(&norm)
            starts = (floor..(lines.size - old.size)).select { |i| lines[i, old.size].map(&norm) == want }
            next if starts.empty?
            return starts.first if starts.size == 1
            return :ambiguous unless expected
            return starts.min_by { |i| (i - expected).abs }
          end
          # Present, but above a hunk already applied: the model sent its
          # hunks out of file order, which is worth saying precisely.
          want = old.map(&:rstrip)
          behind = (0...[floor, lines.size - old.size + 1].min).any? { |i| lines[i, old.size].map(&:rstrip) == want }
          behind ? :out_of_order : :not_found
        end

        def self.failed_hunk(n, total, hunk, path, why)
          reason = case why
          when :no_anchor then "it only adds lines and has no @@ line number to place them by"
          when :ambiguous then "its context matches several places and its @@ header has no line number"
          when :out_of_order then "its lines are above an earlier hunk — hunks must appear in file order"
          else "its context and - lines were not found in #{path}"
          end
          "Hunk #{n + 1} of #{total} did not apply: #{reason}. Nothing was changed. " \
            "It expected these lines:\n#{hunk.old_lines.join("\n")}"
        end

        def self.create(path, abs, hunks, checker:)
          if hunks.any? { |h| h.old_lines.any? }
            return "No such file: #{path} (to create a file, send hunks with only + lines)."
          end
          content = hunks.flat_map(&:new_lines).join("\n")
          content += "\n" unless hunks.last.no_newline
          failure = Patch.write_text(abs, content, crlf: false)
          return failure if failure
          Patch.report("Created #{path} (#{content.lines.size} lines).", abs, checker: checker)
        end
      end
    end
  end
end
