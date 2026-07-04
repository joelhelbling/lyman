#!/usr/bin/env ruby
#
# The shell: state + a process. Deliberately boring.
#
# This file is the one legible wiring script — the circuit pattern from
# docs/design/circuit-pattern.md, wired filter-in: one `pipeline.shift`
# per turn, with all model⇄tool rounds happening inside the call.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "lyman"

include Shifty::DSL

BASE_URL = ENV.fetch("LYMAN_BASE_URL", "http://localhost:11434/v1")
MODEL    = ENV.fetch("LYMAN_MODEL", "qwen3.5:2b")

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

schemas  = TOOLS.values.map { |tool| tool[:schema] }
handlers = TOOLS.transform_values { |tool| tool[:handler] }

# Local thinking models may prefix replies with <think>...</think>.
def display(content)
  content.to_s.sub(/\A<think>.*?<\/think>\s*/m, "").strip
end

# ── Shell state ─────────────────────────────────────────────────────────────
conversation = Lyman::Conversation.new(
  system_prompt: "You are a helpful assistant. Keep replies brief."
)
rounds = [] # the circuit's queue — visible right here, not smuggled

# ── The circuit ─────────────────────────────────────────────────────────────
pipeline =
  source_worker { rounds.shift }                                             |
  Lyman::Workers.chat_completion(
    base_url: BASE_URL, model: MODEL, tools: schemas
  )                                                                          |
  relay_worker { |c| c.finish! if c.pending_tool_calls.empty? || c.runaway?; c } |
  side_worker do |c|
    c.pending_tool_calls.each do |tc|
      puts "  ⚙ #{tc.dig("function", "name")} #{tc.dig("function", "arguments")}"
    end unless c.finished?
  end                                                                        |
  Lyman::Workers.tool_execution(handlers)                                    |
  side_worker { |c| rounds << c unless c.finished? }                         |
  filter_worker { |c| c.finished? }

# ── Shell process ───────────────────────────────────────────────────────────
puts "lyman ⇢ #{MODEL} @ #{BASE_URL}  (blank line or ctrl-d exits)"

loop do
  print "\nyou> "
  input = $stdin.gets&.strip
  break if input.nil? || input.empty?

  rounds << conversation.add_user_message(input)
  turn = pipeline.shift
  puts "\n#{MODEL}> #{display(turn.last_assistant_content)}"
end
