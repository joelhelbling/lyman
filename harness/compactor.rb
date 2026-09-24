#
# The compaction sidecar: a daemon-archetype shell that runs in its own
# thread beside a root harness, keeping a ledger of the root conversation
# up to date *as it happens* — so that when the root asks for compaction,
# the answer is a drain and a handoff, not a summarization pass at the
# worst possible moment. See docs/design/context-control.md ("The
# compactor is a sidecar shell").
#
# Same anatomy as every other harness (docs/design/harness-archetypes.md):
# state (the ledger), a circuit (one digest-model call per batch), and a
# process (loop on an inbound stream, forever). Its inbound stream is a
# Thread::Queue the root circuit feeds with Lyman::Workers.compaction_feed.
#
# This file is yours: the digest instructions, the model, and the tail the
# compacted conversation keeps are the compaction *strategy*, and a
# different strategy is a different version of this file — not a mode.
#
# Wiring it into a root harness (e.g. harness/repl.rb):
#
#   require_relative "compactor"
#
#   COMPACT_AT = 6000 # prompt tokens — leave headroom below the real window
#   compactor_inbox = Thread::Queue.new
#   compactor = Thread.new { run_compactor(compactor_inbox, base_url: BASE_URL, model: MODEL) }
#
#   # in the circuit, after tool_execution, before the finished filter:
#   Lyman::Workers.compaction_feed(compactor_inbox) |
#
#   # in the shell loop, after the turn comes back:
#   conversation = pipeline.shift
#   if conversation.prompt_tokens.to_i > COMPACT_AT
#     conversation = Lyman::Compaction.request(compactor_inbox, conversation)
#   end
#
# Splice Lyman::Workers.store_append in too, and hand the model the recall
# tool (`lyman add store`, `lyman add recall_tool`), and every ledger
# entry's backlinks become something the root model can re-expand.

# require_relative, not the load path: these are files planted beside this
# script, not the lyman gem.
require_relative "../lib/lyman"

# This is a top-level wiring script by design; mixing the DSL into main
# is the point, not an accident.
include Shifty::DSL # standard:disable Style/MixinUsage

# What the digest model is asked to do with each batch. The reply format
# is what Lyman::Compaction::Ledger#absorb reads: a JSON array of entries
# citing the batch's local [n] numbers.
COMPACTOR_INSTRUCTIONS = <<~TEXT
  You keep a ledger for an assistant that will soon lose its memory of a
  conversation. You are shown the current ledger and some new, numbered
  conversation elements. Record only what the assistant would need to carry
  on: facts established, decisions taken, and items still open. Skip
  pleasantries and anything already in the ledger.

  Reply with ONLY a JSON array, no prose. Each entry:
    {"kind": "fact" | "decision" | "open", "text": "<one terse sentence>", "sources": [<element numbers>]}
  Reply [] if nothing new is worth keeping.
TEXT

def run_compactor(inbox, base_url:, model:, instructions: COMPACTOR_INSTRUCTIONS)
  # ── Shell state ───────────────────────────────────────────────────────────
  ledger = Lyman::Compaction::Ledger.new

  # ── The circuit: one digest-model call per batch ──────────────────────────
  # Built per batch rather than once: an error raised inside a pipeline
  # ends it for good, and the sidecar must outlive a flaky model call.
  digest = ->(prompt) {
    (source_worker([prompt]) | Lyman::Workers.chat_completion(base_url: base_url, model: model)).shift
  }

  # ── Shell process ─────────────────────────────────────────────────────────
  # Block for one arrival, then take whatever else is already waiting:
  # elements queue up while a digest call is in flight, so batches size
  # themselves to how far behind the sidecar is. A compaction request
  # splits the batch — elements before it are digested first, which is
  # exactly the "drain, then hand off" the root is waiting on.
  while (first = inbox.pop) # nil once the inbox is closed
    arrivals = [first]
    while (more = inbox.pop(timeout: 0))
      arrivals << more
    end

    arrivals.slice_when { |a, b| [a, b].any?(Lyman::Compaction::Request) }.each do |run|
      if run.first.is_a?(Lyman::Compaction::Request)
        # Always answer: the root shell is blocked waiting on this reply,
        # so a failed compaction hands back the conversation as it was.
        request = run.first
        compacted = begin
          ledger.compact(request.conversation).tap { |child| ledger = ledger.cover(child) }
        rescue => e
          warn "compactor: compaction failed (#{e.class}: #{e.message}); handing back the conversation uncompacted"
          request.conversation
        end
        request.reply << compacted
      else
        reply = begin
          prompt = ledger.prompt(run, instructions: instructions)
          prompt && digest.call(prompt).last_assistant_content
        rescue => e
          warn "compactor: digest failed (#{e.class}: #{e.message}); recording a gap"
          nil
        end
        ledger = ledger.absorb(run, reply)
      end
    end
  end
rescue => e
  # Anything that escapes the loop has killed the sidecar. Say so loudly:
  # otherwise every later compaction request just waits out its timeout,
  # which looks like a slow app rather than a dead compactor.
  warn "compactor: sidecar stopped (#{e.class}: #{e.message}); compaction requests will time out"
  raise
end
