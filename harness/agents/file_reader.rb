#
# The file reader agent: a tool the main model calls instead of reading a
# file whole. Architecturally it's the SCRIPT archetype (see
# docs/design/harness-archetypes.md) run *inside a tool handler* rather
# than launched from a shell — the tool-call args play ARGV, the return
# value plays stdout. See docs/design/tools-and-agents.md ("An agent-as-
# tool is a script shell inside a handler"). It is not a fourth archetype,
# the same way harness/compactor.rb isn't: a daemon-archetype shell run in
# a thread there, a script-archetype shell run in a handler here.
#
# The point of an agent-as-tool is to spend the SUB-agent's context on the
# token-heavy work (searching, reading, re-reading) so the MAIN model's
# context only holds a concise question and a concise answer. Everything
# the sub-agent did — every search_files hit, every read_file page — is
# discarded once its circuit finishes; only the request (this tool's args)
# and the reply cross back into the caller's conversation.
#
# This file is yours: the sub-agent's prompt (FILE_READER_INSTRUCTIONS),
# its tools, and its model are the reading *strategy* — a different
# strategy is a different version of this file, not a mode.
#
# Wiring it into a root harness (e.g. harness/repl.rb):
#
#   require_relative "agents/file_reader"
#
#   TOOLS = [
#     file_reader(root: Dir.pwd, default_model: MODEL, default_base_url: BASE_URL)
#   ]
#
# Pass `trace:` to observe the sub-agent's inner rounds (e.g. to print
# nested tool activity the way harness/repl.rb does):
#
#   file_reader(root: Dir.pwd, default_model: MODEL, default_base_url: BASE_URL,
#     trace: ->(c) { tool_printer.results(c, indent: 2) })

# require_relative, not the load path: these are files planted beside this
# script, not the lyman gem.
require_relative "../../lib/lyman"

# This is a top-level wiring script by design; mixing the DSL into main
# is the point, not an accident.
include Shifty::DSL # standard:disable Style/MixinUsage

# What the sub-agent is told on every call. It never sees the caller's
# conversation, so this is the whole of its context beyond the task
# message — kept tight since local small models read it every call.
FILE_READER_INSTRUCTIONS = <<~TEXT
  You read files on behalf of another assistant. Your reply is the ONLY
  thing that assistant sees — everything else (your searches, your reads,
  your reasoning) is discarded. Be concise.

  Extract to exactly the shape you were asked for: nothing more.
  Always cite locations as path:start-end (e.g. lib/foo.rb:12-18). Quote
  only the lines that matter, not surrounding context.

  Use search_files to locate what's relevant, then read_file with a line
  range rather than reading a large file whole. If nothing relevant is
  found, say so in one line.

  Reply in plain text: no preamble, no markdown fences, no "Here is...".
TEXT

# root: confines both the routing bypass and the sub-agent's own tools to
# one directory, the same way the harness's own file tools are confined.
# model:/base_url: resolve at factory time, explicit argument first, then
# an env override, then the harness's own default — the agent can't see
# the harness's MODEL/BASE_URL constants, so the harness hands them in.
def file_reader(default_model:, default_base_url:, root: Dir.pwd, model: nil, base_url: nil, max_rounds: 8, trace: nil)
  model ||= ENV["LYMAN_FILE_READER_MODEL"] || default_model
  base_url ||= ENV["LYMAN_FILE_READER_BASE_URL"] || default_base_url
  confined_root = File.realpath(root)

  {
    schema: {
      "type" => "function",
      "function" => {
        "name" => "file_reader",
        "description" => "Look into files instead of reading them whole. Pass `path` (a file path " \
          "or glob relative to the project root) and, when you have one, `query` describing what you " \
          "need — a sub-agent with its own tools will find and extract just that, so raw file text " \
          "never enters your context. Without a query and a single file path, the file comes back " \
          "whole. `shape` controls the reply: \"excerpts\" (default) quotes relevant passages with " \
          "path:line ranges, \"outline\" lists symbols/sections with line numbers, \"answer\" gives a " \
          "short prose answer citing path:line.",
        "parameters" => {
          "type" => "object",
          "properties" => {
            "path" => {
              "type" => "string",
              "description" => "File path or glob, relative to the project root."
            },
            "query" => {
              "type" => "string",
              "description" => "What you want to know or find. Omit only when you want a single " \
                "whole file back."
            },
            "shape" => {
              "type" => "string",
              "enum" => %w[excerpts outline answer],
              "description" => "Result shape: excerpts (default), outline, or answer."
            }
          },
          "required" => ["path"]
        }
      }
    },
    handler: ->(args) {
      FileReader.handle(args, root: confined_root, model: model, base_url: base_url, max_rounds: max_rounds, trace: trace)
    }
  }
end

module FileReader
  def self.handle(args, root:, model:, base_url:, max_rounds:, trace:)
    path = presence(args["path"])
    return "Pass a path to read." unless path
    query = presence(args["query"])
    shape = presence(args["shape"])
    shape = "excerpts" unless %w[excerpts outline answer].include?(shape)

    bypass = whole_file_bypass(path, root: root) unless query
    return bypass if bypass

    delegate(path: path, query: query, shape: shape, root: root, model: model, base_url: base_url, max_rounds: max_rounds, trace: trace)
  end

  # No query, and the path/glob resolves to exactly one regular file:
  # there is nothing to extract *against*, so return it whole rather than
  # spend a model call. Confinement is read_file's job (it refuses
  # ../symlink escapes with a message); this only decides whether to
  # bypass delegation, not whether the read is safe.
  def self.whole_file_bypass(path, root:)
    matches = Dir.glob(path, base: root)
      .map { |match| File.expand_path(match, root) } # absolute globs come back absolute
      .select { |abs| File.file?(abs) }
    return nil unless matches.size == 1

    reader = Lyman::Tools.read_file(root: root, max_chars: Float::INFINITY)
    reader[:handler].call({"path" => path})
  end

  # The script archetype, built fresh per call: a fresh Conversation, a
  # fresh rounds queue, a fresh pipeline. An error raised inside a shifty
  # pipeline ends it for good, and each call must forget the last — a
  # memory is a splice, not a default.
  def self.delegate(path:, query:, shape:, root:, model:, base_url:, max_rounds:, trace:)
    tools = [
      Lyman::Tools.search_files(root: root),
      Lyman::Tools.read_file(root: root)
    ]
    schemas = tools.map { |tool| tool[:schema] }
    handlers = tools.to_h { |tool| [tool[:schema].dig("function", "name"), tool[:handler]] }

    conversation = Lyman::Conversation.new(system_prompt: FILE_READER_INSTRUCTIONS, max_rounds: max_rounds)
    task = "path: #{path}\n" \
      "query: #{query || "no specific question — give the requested shape for the whole match"}\n" \
      "shape: #{shape}"

    rounds = [] # the circuit's queue — visible right here, not smuggled

    pipeline =
      source_worker { rounds.shift } |
      Lyman::Workers.chat_completion(base_url: base_url, model: model, tools: schemas) |
      relay_worker { |c| (c.pending_tool_calls.empty? || c.runaway?) ? c.finish : c } |
      Lyman::Workers.tool_execution(handlers) |
      side_worker { |c| trace&.call(c) } |
      side_worker { |c| rounds << c unless c.finished? } |
      filter_worker { |c| c.finished? }

    # Enqueue before shifting — never pull the source while the queue is
    # empty (the nil footgun: a nil from a source ends the stream
    # permanently).
    rounds << conversation.with_user_message(task)
    result = pipeline.shift

    # Tool calls still pending means the round counter cut the circuit off
    # mid-work (runaway? alone can't tell — it's also true when the answer
    # arrived on the last allowed round).
    answer = result.last_assistant_content.to_s.strip
    if result.pending_tool_calls.any? || answer.empty?
      return "file_reader stopped after #{max_rounds} rounds without an answer — " \
        "try a narrower path or a more specific query."
    end
    answer
  end

  def self.presence(value)
    string = value.to_s.strip
    string.empty? ? nil : string
  end
end

if __FILE__ == $PROGRAM_NAME
  # ruby harness/agents/file_reader.rb PATH [QUERY] [SHAPE]
  #
  # Standalone run: the script framing pays off here. Tune the sub-agent
  # (its prompt, its model, its tools) and watch it work without going
  # through the main model at all — stdout is just the answer, and a
  # trace of inner tool activity goes to stderr.
  path = ARGV[0]
  abort "usage: #{$PROGRAM_NAME} PATH [QUERY] [SHAPE]" if path.to_s.strip.empty?
  query = ARGV[1]
  shape = ARGV[2]

  default_model = ENV.fetch("LYMAN_MODEL", "gemma4:latest")
  default_base_url = ENV.fetch("LYMAN_BASE_URL", "http://localhost:11434/v1")
  # trace: fires after tool_execution, so this round's calls are already
  # answered — list the tool_call elements since the last assistant reply.
  trace = ->(c) {
    reply_start = c.elements.rindex { |e| e.type == "assistant" }
    c.elements[(reply_start + 1)..].each do |e|
      next unless e.type == "tool_call"
      warn "  ⚙ #{e.content.dig("function", "name")} #{e.content.dig("function", "arguments")}"
    end
  }

  tool = file_reader(root: Dir.pwd, default_model: default_model, default_base_url: default_base_url, trace: trace)
  args = {"path" => path, "query" => query, "shape" => shape}.compact
  puts tool[:handler].call(args)
end
