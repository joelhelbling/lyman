#!/usr/bin/env ruby
#
# The script archetype: launched by something out of scope — cron, a
# Makefile, a hand on a keyboard — with its work item in hand. It
# processes that one item (however many model⇄tool rounds it takes) and
# halts. One of three archetype shells — repl, daemon, script — around
# the same circuit; see docs/design/harness-archetypes.md.
#
# The shell: state + a process. Here the process needs no loop at all —
# the circuit still runs as many rounds as the model asks for, because
# repetition lives in the pipeline (docs/design/circuit-pattern.md), not
# in the shell. One enqueue, one shift, done.
#
# No display layer: output is the final answer on stdout, which is what
# a cron job or a calling script wants to capture. Everything between —
# the tool calls, the intermediate rounds — stays on the conversation,
# where a logging side_worker can be spliced in if you want to see it.

# require_relative, not the load path: these are files planted beside this
# script, not the lyman gem.
require_relative "../lib/lyman"

# This is a top-level wiring script by design; mixing the DSL into main
# is the point, not an accident.
include Shifty::DSL # standard:disable Style/MixinUsage

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

# ── The work item ───────────────────────────────────────────────────────────
# It arrives at launch: arguments if given, stdin otherwise — the two
# channels a cron line or a calling script naturally speaks.
task = ARGV.empty? ? $stdin.read.to_s.strip : ARGV.join(" ")
abort "usage: #{$PROGRAM_NAME} TASK...   (or pipe the task on stdin)" if task.empty?

# ── Shell state ─────────────────────────────────────────────────────────────
conversation = Lyman::Conversation.new(
  system_prompt: "You are a task runner. Complete the given task and reply " \
    "with the result only — plain text, no markdown, no commentary."
)
rounds = [] # the circuit's queue — visible right here, not smuggled

# ── The circuit ─────────────────────────────────────────────────────────────
pipeline =
  source_worker { rounds.shift } |
  Lyman::Workers.chat_completion(base_url: BASE_URL, model: MODEL, tools: schemas) |
  relay_worker { |c|
    (c.pending_tool_calls.empty? || c.runaway?) ? c.finish : c
  } |
  Lyman::Workers.tool_execution(handlers) |
  side_worker { |c| rounds << c unless c.finished? } |
  filter_worker { |c| c.finished? }

# ── Shell process ───────────────────────────────────────────────────────────
# Enqueue before shifting — never pull the source while the queue is empty
# (the nil footgun: a nil from a source ends the stream permanently).
# Conversation is an immutable value (shifty 0.6 freezes every handoff):
# with_user_message returns a new conversation, and the finished turn
# comes back from the pipeline.
rounds << conversation.with_user_message(task)
result = pipeline.shift

puts result.last_assistant_content
