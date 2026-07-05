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
        "claude_md" => {
          source: "templates/CLAUDE.md",
          dest: "CLAUDE.md",
          role: :owned,
          description: "Guidance for coding agents working in this project"
        },
        "gemfile" => {
          source: "templates/Gemfile",
          dest: "Gemfile",
          role: :owned,
          description: "Client dependencies: shifty (and ostruct for ruby >= 4)"
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

      def self.managed
        ARTIFACTS.select { |_, spec| spec[:role] == :managed }
      end

      def self.source_path(spec, source_root: GEM_ROOT)
        File.join(source_root, spec[:source])
      end
    end
  end
end
