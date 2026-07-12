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
        # The three harness archetypes (docs/design/harness-archetypes.md):
        # same circuit, different shells. `new` plants the repl — the
        # archetype you can talk to on day one; the other two are opt-in
        # (`lyman add daemon_harness` / `lyman add script_harness`) because a
        # narrow, purpose-built agent wants one shell shape, not three.
        "repl_harness" => {
          source: "harness/repl.rb",
          dest: "harness/repl.rb",
          role: :owned,
          description: "The REPL archetype: a human drives the loop — yours from day one; lyman never updates it"
        },
        "daemon_harness" => {
          source: "harness/daemon.rb",
          dest: "harness/daemon.rb",
          role: :owned,
          optional: true,
          description: "The daemon archetype: launch once, loop on an inbound event stream indefinitely"
        },
        "script_harness" => {
          source: "harness/script.rb",
          dest: "harness/script.rb",
          role: :owned,
          optional: true,
          description: "The script archetype: take one work item at launch, process it, halt"
        },
        # The repl's display layer, one artifact per widget so ownership —
        # and any drift `lyman diff` reports — stays per-file, not per-blob.
        "repl_style" => {
          source: "harness/repl/style.rb",
          dest: "harness/repl/style.rb",
          role: :owned,
          description: "Terminal styling codes and the gray() helper shared by the repl display"
        },
        "think_filter" => {
          source: "harness/repl/think_filter.rb",
          dest: "harness/repl/think_filter.rb",
          role: :owned,
          description: "Streams a dim preview of <think> blocks, then elides the rest"
        },
        "wait_spinner" => {
          source: "harness/repl/wait_spinner.rb",
          dest: "harness/repl/wait_spinner.rb",
          role: :owned,
          description: "Background spinner for the silence before the first streamed token"
        },
        "round_printer" => {
          source: "harness/repl/round_printer.rb",
          dest: "harness/repl/round_printer.rb",
          role: :owned,
          description: "Streams one round to the terminal: spinner, model label, think preview, reply"
        },
        "tool_printer" => {
          source: "harness/repl/tool_printer.rb",
          dest: "harness/repl/tool_printer.rb",
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

      # What `new` plants: everything except opt-in artifacts — alternates a
      # fresh scaffold shouldn't presume (the daemon and script archetypes,
      # the skill variant of CLAUDE.md). Reach them with `lyman add`.
      def self.default
        ARTIFACTS.reject { |_, spec| spec[:optional] }
      end

      def self.source_path(spec, source_root: GEM_ROOT)
        File.join(source_root, spec[:source])
      end
    end
  end
end
