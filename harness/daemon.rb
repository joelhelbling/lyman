#!/usr/bin/env ruby
#
# The daemon archetype: launch once, then loop on an inbound stream of
# events, indefinitely. No human in the loop — each arriving event is a
# work item, processed to completion and answered. One of three archetype
# shells — repl, daemon, script — around the same circuit; see
# docs/design/harness-archetypes.md.
#
# The shell: state + a process. The process is `loop { accept an event,
# enqueue, shift, answer }` — the same enqueue-then-shift rhythm as the
# repl, with a socket where the human used to be.
#
# The event supplier here is a line-per-event TCP listener, chosen because
# it's stdlib and legible — try it with:
#
#   echo "what time is it?" | nc localhost 1216
#
# The supplier is this archetype's variable: swap the TCPServer for a
# webhook server, a queue consumer, an IMAP poller — the circuit below
# doesn't change, because the circuit never knows where events come from.
# Only the source_worker's queue does.

# require_relative, not the load path: these are files planted beside this
# script, not the lyman gem.
require_relative "../lib/lyman"
require "socket"

# This is a top-level wiring script by design; mixing the DSL into main
# is the point, not an accident.
include Shifty::DSL # standard:disable Style/MixinUsage

$stdout.sync = true

BASE_URL = ENV.fetch("LYMAN_BASE_URL", "http://localhost:11434/v1")
MODEL = ENV.fetch("LYMAN_MODEL", "gemma4:latest")
PORT = Integer(ENV.fetch("LYMAN_PORT", "1216")) # Lyman-alpha: 1216 Å

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
rounds = [] # the circuit's queue — visible right here, not smuggled

# ── The circuit ─────────────────────────────────────────────────────────────
# Identical to the script archetype's circuit, plus one logging side_worker —
# with no human watching, observability is spliced in, not bolted on.
pipeline =
  source_worker { rounds.shift } |
  Lyman::Workers.chat_completion(base_url: BASE_URL, model: MODEL, tools: schemas) |
  relay_worker { |c|
    (c.pending_tool_calls.empty? || c.runaway?) ? c.finish : c
  } |
  side_worker { |c|
    c.pending_tool_calls.each do |call|
      puts "  ⚙ #{call.dig("function", "name")} #{call.dig("function", "arguments")}"
    end
  } |
  Lyman::Workers.tool_execution(handlers) |
  side_worker { |c| rounds << c unless c.finished? } |
  filter_worker { |c| c.finished? }

# ── Shell process ───────────────────────────────────────────────────────────
server = TCPServer.new(PORT)
puts "lyman daemon ⇢ #{MODEL} @ #{BASE_URL}, listening on port #{PORT}"

loop do
  client = server.accept
  event = begin
    client.gets&.strip
  rescue IOError, SystemCallError
    nil # a client that hung up mid-line is not our problem
  end

  if event.nil? || event.empty?
    client.close
    next
  end

  puts "[#{Time.now.strftime("%H:%M:%S")}] event: #{event}"

  # Each event is an independent work item, so it gets a fresh conversation —
  # a daemon accretes no context across events unless you decide it should.
  conversation = Lyman::Conversation.new(
    system_prompt: "You are an event handler. Handle the incoming event and " \
      "reply with the result only — plain text, no markdown, no commentary."
  )

  # Enqueue before shifting — never pull the source while the queue is empty
  # (the nil footgun: a nil from a source ends the stream permanently).
  # Conversation is an immutable value (shifty 0.6 freezes every handoff):
  # with_user_message returns a new conversation, and the finished turn
  # comes back from the pipeline.
  rounds << conversation.with_user_message(event)
  result = pipeline.shift

  reply = result.last_assistant_content.to_s
  puts "[#{Time.now.strftime("%H:%M:%S")}] reply: #{reply}"
  client.puts reply
  client.close
rescue Interrupt
  puts "\nshutting down"
  server.close
  break
end
