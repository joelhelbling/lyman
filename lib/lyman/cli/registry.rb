module Lyman
  module CLI
    # What lyman installs. Everything the generator plants into a client
    # project is declared here — this list, not directory layout, is the
    # boundary between what lyman *does* (lib/lyman/cli) and what lyman
    # *installs* (everything named below).
    module Registry
      GEM_ROOT = File.expand_path("../../..", __dir__)

      ARTIFACTS = {
        "lyman_entry" => {
          source: "templates/lib_lyman.rb",
          dest: "lib/lyman.rb",
          role: :managed,
          description: "Library entry point; requires shifty and every planted module"
        },
        "conversation" => {
          source: "lib/lyman/conversation.rb",
          dest: "lib/lyman/conversation.rb",
          role: :managed,
          description: "The item that flows through pipelines"
        },
        "chat_completion" => {
          source: "lib/lyman/workers/chat_completion.rb",
          dest: "lib/lyman/workers/chat_completion.rb",
          role: :managed,
          description: "Relay worker: OpenAI-compatible chat completions (streaming + blocking)"
        },
        "tool_execution" => {
          source: "lib/lyman/workers/tool_execution.rb",
          dest: "lib/lyman/workers/tool_execution.rb",
          role: :managed,
          description: "Relay worker: executes pending tool calls"
        },
        "harness" => {
          source: "harness/chat.rb",
          dest: "harness/chat.rb",
          role: :owned,
          description: "The wiring script — yours from day one; lyman never updates it"
        },
        # The harness's display layer, one artifact per widget so ownership —
        # and any drift `lyman diff` reports — stays per-file, not per-blob.
        "chat_style" => {
          source: "harness/chat/style.rb",
          dest: "harness/chat/style.rb",
          role: :owned,
          description: "Terminal styling codes and the gray() helper shared by the chat display"
        },
        "think_filter" => {
          source: "harness/chat/think_filter.rb",
          dest: "harness/chat/think_filter.rb",
          role: :owned,
          description: "Streams a dim preview of <think> blocks, then elides the rest"
        },
        "wait_spinner" => {
          source: "harness/chat/wait_spinner.rb",
          dest: "harness/chat/wait_spinner.rb",
          role: :owned,
          description: "Background spinner for the silence before the first streamed token"
        },
        "round_printer" => {
          source: "harness/chat/round_printer.rb",
          dest: "harness/chat/round_printer.rb",
          role: :owned,
          description: "Streams one round to the terminal: spinner, model label, think preview, reply"
        },
        "tool_printer" => {
          source: "harness/chat/tool_printer.rb",
          dest: "harness/chat/tool_printer.rb",
          role: :owned,
          description: "Prints tool calls on the way in, summarized results on the way out"
        },
        "claude_md" => {
          source: "templates/CLAUDE.md",
          dest: "CLAUDE.md",
          role: :owned,
          alternative: "claude_skill",
          description: "Guidance for coding agents working in this project"
        },
        # The same guidance as claude_md, packaged as a Claude Code skill —
        # for projects that already have a CLAUDE.md lyman shouldn't clobber.
        # `optional:` keeps `new` from planting it (a fresh scaffold gets
        # claude_md instead); `alternative:` on claude_md points here when
        # `add` refuses to overwrite an existing CLAUDE.md.
        "claude_skill" => {
          source: "templates/SKILL.md",
          dest: ".claude/skills/lyman/SKILL.md",
          role: :owned,
          optional: true,
          description: "Claude Code skill variant of the CLAUDE.md guidance — for projects with their own CLAUDE.md"
        },
        "gemfile" => {
          source: "templates/Gemfile",
          dest: "Gemfile",
          role: :owned,
          description: "Client dependencies: shifty (plus ostruct for ruby >= 4, cli-ui for the harness display)"
        },
        "gitignore" => {
          source: "templates/gitignore",
          dest: ".gitignore",
          role: :owned,
          description: "A minimal starter .gitignore (.lyman/ stays tracked on purpose)"
        }
      }.freeze

      def self.fetch(name)
        ARTIFACTS.fetch(name) do
          valid = ARTIFACTS.keys.join(", ")
          raise Thor::Error, "Unknown artifact #{name.inspect}. Valid artifacts: #{valid}"
        end
      end

      # Commands accept an artifact name or a project-relative path — you
      # shouldn't have to remember the token while looking at the file.
      # Resolution order: registry name, then the path recorded in this
      # project's manifest (authoritative for where the file actually is),
      # then the registry's dest (for artifacts not yet planted).
      def self.resolve(token, manifest: nil)
        return token if ARTIFACTS.key?(token)

        path = token.delete_prefix("./")
        if manifest
          name, _entry = manifest.artifacts.find { |_, entry| entry["path"] == path }
          return name if name
        end
        name, _spec = ARTIFACTS.find { |_, spec| spec[:dest] == path }
        return name if name

        valid = ARTIFACTS.keys.join(", ")
        raise Thor::Error, "Unknown artifact #{token.inspect}. " \
          "Give an artifact name (#{valid}) or a planted path (e.g. lib/lyman/conversation.rb)."
      end

      def self.managed
        ARTIFACTS.select { |_, spec| spec[:role] == :managed }
      end

      # What `new` plants: everything except opt-in artifacts (those exist
      # for situations a fresh scaffold can't be in, like a pre-existing
      # CLAUDE.md — reach them with `lyman add`).
      def self.default
        ARTIFACTS.reject { |_, spec| spec[:optional] }
      end

      def self.source_path(spec, source_root: GEM_ROOT)
        File.join(source_root, spec[:source])
      end
    end
  end
end
