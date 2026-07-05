#!/usr/bin/env ruby
#
# lyman doctor's pipeline smoke test, run as a subprocess inside the client
# project (see lib/lyman/cli/commands/doctor.rb for why it must be a
# subprocess: the client's Lyman:: constants must not collide with this CLI
# process's own, and it's the client's bundle — not the CLI's — that needs
# to resolve shifty).
#
# Wires the same circuit shape as harness/chat.rb (docs/design/
# circuit-pattern.md): a queue-backed source, the model⇄tool round, the
# finish/requeue plumbing. The only substitution is the transport: a stub
# stands in at the chat_completion seam. That's legitimate, not a mock
# reaching inside — the model transport is itself a swappable worker (see
# docs/design/deployment.md, "Ruby without a type checker"), so a stub here
# is an alternate implementation of the seam, and every other stage (tool
# execution, requeue, the finished-turn filter) still runs for real.

require "./lib/lyman"

include Shifty::DSL # standard:disable Style/MixinUsage

conversation = Lyman::Conversation.new(system_prompt: "doctor")
conversation.add_user_message("ping the tool once, then answer")
rounds = [] # the circuit's queue, shell scope — mirrors harness/chat.rb

# Stands in for Lyman::Workers.chat_completion: round 1 calls the "ping"
# tool, round 2 answers plainly. A real transport wouldn't know the round
# count in advance, but the seam only cares that something plays by the
# wire's rules — append an assistant message, bump the round counter.
call_count = 0
stub_transport = relay_worker do |c|
  call_count += 1
  message =
    if call_count == 1
      {
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          {
            "id" => "call_1",
            "type" => "function",
            "function" => {"name" => "ping", "arguments" => "{}"}
          }
        ]
      }
    else
      {"role" => "assistant", "content" => "done"}
    end
  c.add_assistant_message(message)
  c.rounds += 1
  c
end

pipeline =
  source_worker { rounds.shift } |
  stub_transport |
  relay_worker { |c|
    c.finish! if c.pending_tool_calls.empty? || c.runaway?
    c
  } |
  Lyman::Workers.tool_execution({"ping" => ->(_) { "pong" }}) |
  side_worker { |c| rounds << c unless c.finished? } |
  filter_worker { |c| c.finished? }

# Never pull while the queue is empty (the nil footgun, CLAUDE.md) — enqueue
# the seed conversation before the first shift.
rounds << conversation
result = pipeline.shift

failures = []
failures << "conversation never finished" unless result.finished?

unless result.messages.all? { |m| m.keys.all? { |k| k.is_a?(String) } }
  failures << "a message used non-string keys"
end

valid_roles = %w[system user assistant tool]
unless result.messages.all? { |m| valid_roles.include?(m["role"]) }
  failures << "a message had a role outside system|user|assistant|tool"
end

tool_message = result.messages.find { |m| m["role"] == "tool" }
if tool_message.nil?
  failures << "no tool result message found"
elsif tool_message["tool_call_id"] != "call_1"
  failures << "tool result did not answer the expected tool call id"
elsif tool_message["content"] != "pong"
  failures << "tool result content was #{tool_message["content"].inspect}, expected \"pong\""
end

if failures.empty?
  puts "✓ pipeline smoke test passed (#{result.messages.size} messages, tool round-trip ok)"
  exit 0
else
  puts "✗ pipeline smoke test failed: #{failures.join("; ")}"
  exit 1
end
