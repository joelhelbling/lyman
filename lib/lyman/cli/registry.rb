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
          description: "The item that flows through pipelines: an append-only series of elements"
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
        "abridgement" => {
          source: "lib/lyman/abridgement.rb",
          dest: "lib/lyman/abridgement.rb",
          role: :managed,
          description: "Wire-time abridgement policies: deterministic context reduction, no model needed"
        },
        # The compaction vocabulary and its feed: stdlib only, so planted
        # unconditionally, like abridgement. The sidecar that uses them
        # (compactor, below) is the opt-in part.
        "compaction" => {
          source: "lib/lyman/compaction.rb",
          dest: "lib/lyman/compaction.rb",
          role: :managed,
          description: "Compaction ledger and request protocol: model-built, lineage-linked context reduction"
        },
        "compaction_feed" => {
          source: "lib/lyman/workers/compaction_feed.rb",
          dest: "lib/lyman/workers/compaction_feed.rb",
          role: :managed,
          description: "Side worker: feeds each new element to a compaction sidecar's inbox"
        },
        # Tools (docs/design/tools-and-agents.md): one file per tool under
        # lib/lyman/tools/, named `<tool>_tool` here. `wire:` is the
        # expression a harness lists in its TOOLS to hand the tool to the
        # model — harnesses are owned, so `add` advises the line rather
        # than editing it in. `needs:` names other artifacts a tool expects
        # to be planted alongside it (a keyword dependency its factory
        # can't do without); `add` only *advises* planting them, never
        # plants them itself — the dependency is duck-typed, so a user may
        # wire in their own object instead of the registry's artifact.
        "current_time_tool" => {
          source: "lib/lyman/tools/current_time.rb",
          dest: "lib/lyman/tools/current_time.rb",
          role: :managed,
          wire: "Lyman::Tools.current_time",
          description: "Tool: the current local date and time — the demo tool the harnesses start with"
        },
        # Plain handlers, no model (docs/design/tools-and-agents.md, "File
        # access") — stdlib only, so planted by default like current_time.
        "search_files_tool" => {
          source: "lib/lyman/tools/search_files.rb",
          dest: "lib/lyman/tools/search_files.rb",
          role: :managed,
          wire: "Lyman::Tools.search_files(root: Dir.pwd)",
          description: "Tool: search a tree by file content and/or name/glob, root-confined"
        },
        "read_file_tool" => {
          source: "lib/lyman/tools/read_file.rb",
          dest: "lib/lyman/tools/read_file.rb",
          role: :managed,
          wire: "Lyman::Tools.read_file(root: Dir.pwd)",
          description: "Tool: read a file (optionally by line range) with line numbers, root-confined"
        },
        # optional: true because it needs a store, which a fresh scaffold
        # doesn't have — reach it with `lyman add recall_tool` once `store`
        # is planted (or wire it to a hand-rolled duck-typed store).
        "recall_tool" => {
          source: "lib/lyman/tools/recall.rb",
          dest: "lib/lyman/tools/recall.rb",
          role: :managed,
          optional: true,
          needs: ["store"],
          wire: "Lyman::Tools.recall(store: store)",
          description: "Tool: re-expands abridged or compacted context by address or search (docs/design/context-control.md)"
        },
        # `optional:` keeps `new` from planting these — a SQLite
        # native-extension dependency shouldn't be presumed on a fresh
        # scaffold; reach it with `lyman add store`. `gems:` names gem
        # dependencies the client Gemfile (an owned file) needs but that
        # planting doesn't add for them; `add` advises rather than edits it.
        "store" => {
          source: "lib/lyman/store.rb",
          dest: "lib/lyman/store.rb",
          role: :managed,
          optional: true,
          gems: ["sqlite3"],
          description: "SQLite conversation store: lineage and full-text recall (docs/design/context-control.md)"
        },
        "store_append" => {
          source: "lib/lyman/workers/store_append.rb",
          dest: "lib/lyman/workers/store_append.rb",
          role: :managed,
          optional: true,
          description: "Side worker: persists conversations to any duck-typed store as they flow through the circuit"
        },
        # The three harness archetypes (docs/design/harness-archetypes.md):
        # same circuit, different shells. `new` plants the repl — the
        # archetype you can talk to on day one; the other two are opt-in
        # (`lyman add daemon_harness` / `lyman add script_harness`) because a
        # narrow, purpose-built agent wants one shell shape, not three.
        # Agent-as-tool (docs/design/tools-and-agents.md): a script-archetype
        # shell run inside a tool handler rather than a fourth harness
        # archetype — same posture as compactor below. Owned, not optional:
        # its prompt, tools, and model *are* the reading strategy, and
        # harness/repl.rb (which `new` plants) requires it, so a fresh
        # scaffold needs it on day one. `needs:` names the file primitives
        # its inner circuit calls directly (not duck-typed the way
        # recall_tool's store is), but they're managed and non-optional
        # too, so `advise_on_needs` never has anything to say here.
        "file_reader_agent" => {
          source: "harness/agents/file_reader.rb",
          dest: "harness/agents/file_reader.rb",
          role: :owned,
          needs: ["search_files_tool", "read_file_tool"],
          wire: "file_reader(root: Dir.pwd, default_model: MODEL, default_base_url: BASE_URL)",
          advice: "Wire it into a harness: require_relative \"agents/file_reader\", then list " \
            "file_reader(root: Dir.pwd, default_model: MODEL, default_base_url: BASE_URL) in TOOLS.",
          description: "Agent-as-tool: a sub-agent that reads files so raw file text never enters the main context"
        },
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
        # Not a fourth archetype but a daemon-archetype shell that runs in a
        # thread beside a root harness (docs/design/context-control.md). It
        # has no `wire:` — splicing it in touches the circuit and the shell
        # loop, not a TOOLS array — so `advice:` points at its own header.
        # Owned: its digest instructions and model *are* the compaction
        # strategy, and a different strategy is a different copy of it.
        "compactor" => {
          source: "harness/compactor.rb",
          dest: "harness/compactor.rb",
          role: :owned,
          optional: true,
          needs: ["compaction", "compaction_feed"],
          advice: "Wire it into a harness: see the comment at the top of harness/compactor.rb " \
            "(a thread, one side worker in the circuit, one conditional in the shell loop).",
          description: "Compaction sidecar: a threaded daemon shell keeping a ledger, so compaction is a handoff, not a stall"
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
