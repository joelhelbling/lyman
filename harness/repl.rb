#!/usr/bin/env ruby
#
# The REPL archetype: a human drives the loop and decides when it ends.
# One of three archetype shells — repl, daemon, script — around the same
# circuit; see docs/design/harness-archetypes.md.
#
# The shell: state + a process. Deliberately boring.
#
# This file is the one legible wiring script — the circuit pattern from
# docs/design/circuit-pattern.md, wired filter-in: one `pipeline.shift`
# per turn, with all model⇄tool rounds happening inside the call.
#
# Everything the model does streams to the terminal as it happens —
# pre-tool narration, tool calls, the final answer. Fitting the display
# to the model (like hiding a <think> block) is this shell's job, not
# the library's — the harness/repl/ files are that display layer. Their
# dependencies (cli-ui for color and glyphs, reline for prompt
# line-editing and history) stay out of the circuit; restyle or delete
# them freely.

# require_relative, not the load path: these are files planted beside this
# script, not the lyman gem.
require_relative "../lib/lyman"
require_relative "repl/style"
require_relative "repl/round_printer"
require_relative "repl/tool_printer"
require "cli/ui"
require "reline"

# This is a top-level wiring script by design; mixing the DSL into main
# is the point, not an accident.
include Shifty::DSL # standard:disable Style/MixinUsage

$stdout.sync = true

BASE_URL = ENV.fetch("LYMAN_BASE_URL", "http://localhost:11434/v1")
MODEL = ENV.fetch("LYMAN_MODEL", "gemma4:latest")

# ── Tools: schema and handler side by side, guts on the outside ────────────
TOOLS = {
  "current_time" => {
    schema: {
      "type" => "function",
      "function" => {
        "name" => "current_time",
        "description" => "Returns the current local date and time",
        "parameters" => {"type" => "object", "properties" => {}, "required" => []}
      }
    },
    handler: ->(_args) { Time.now.strftime("%Y-%m-%d %H:%M:%S %Z") }
  }
}

schemas = TOOLS.values.map { |tool| tool[:schema] }
handlers = TOOLS.transform_values { |tool| tool[:handler] }

# ── Shell state ─────────────────────────────────────────────────────────────
conversation = Lyman::Conversation.new(
  system_prompt: "You are a helpful assistant. Keep replies brief. " \
    "Your replies are printed verbatim in a plain-text terminal: write prose, " \
    "and avoid markdown and LaTeX markup."
)
rounds = [] # the circuit's queue — visible right here, not smuggled
printer = RoundPrinter.new(MODEL)
tool_printer = ToolPrinter.new

# ── The circuit ─────────────────────────────────────────────────────────────
pipeline =
  source_worker { rounds.shift } |
  side_worker { |_c| printer.start_round } |
  Lyman::Workers.chat_completion(
    base_url: BASE_URL, model: MODEL, tools: schemas,
    on_delta: printer.method(:delta)
  ) |
  side_worker { |_c| printer.finish_round } |
  relay_worker { |c|
    (c.pending_tool_calls.empty? || c.runaway?) ? c.finish : c
  } |
  side_worker { |c| tool_printer.calls(c) unless c.finished? } |
  Lyman::Workers.tool_execution(handlers) |
  side_worker { |c| tool_printer.results(c) unless c.finished? } |
  side_worker { |c| rounds << c unless c.finished? } |
  filter_worker { |c| c.finished? }

# ── Shell process ───────────────────────────────────────────────────────────
puts CLI::UI.fmt("{{bold:lyman}} ⇢ {{magenta:#{MODEL}}} @ {{blue:#{BASE_URL}}}")
puts
puts gray(<<~HINTS.gsub(/^/, "  "))
  exit:                 blank line, ctrl-c, or ctrl-d
  change the model:     LYMAN_MODEL=qwen3.5:2b #{$PROGRAM_NAME}
  change the endpoint:  LYMAN_BASE_URL=http://localhost:1234/v1 #{$PROGRAM_NAME}
  available tools:      #{TOOLS.keys.join(", ")} — a ⚙ line appears when the model calls one
HINTS

loop do
  puts
  # Reline gives the prompt line editing and history, but emits screen-
  # redraw escapes even when input is piped — so scripted runs get gets.
  input = begin
    if $stdin.tty?
      Reline.readline(CLI::UI.fmt("{{cyan:you}}> "), true)&.strip
    else
      print "you> "
      $stdin.gets&.strip
    end
  rescue Interrupt
    nil # ctrl-c leaves like ctrl-d, not with a stack trace
  end
  break if input.nil? || input.empty?

  # Conversation is an immutable value (shifty 0.6 freezes every handoff),
  # so state flows in the open: enqueue a new conversation carrying the
  # user's message, and rebind to the finished turn the circuit hands back.
  rounds << conversation.with_user_message(input)
  conversation = pipeline.shift
end
