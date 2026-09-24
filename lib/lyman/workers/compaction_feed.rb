require "shifty"

module Lyman
  module Workers
    extend Shifty::DSL

    # Side worker: pushes each element the circuit hasn't fed yet onto
    # +inbox+ (a Thread::Queue) for a compaction sidecar to digest. This is
    # the sidecar's entire footprint in the root circuit — see
    # docs/design/context-control.md ("The compactor is a sidecar shell").
    #
    # A conversation passes through once per round, carrying every element
    # so far, so the worker remembers how far into each conversation it
    # has fed and pushes only what's past that. That memory is closure
    # state, which stays freely mutable; the elements themselves were
    # deep-frozen at the worker boundary (shifty 0.6's frozen handoffs),
    # which is what makes handing them to another thread safe without
    # locks.
    #
    # Splice it after tool_execution and before any "finished?" filter, so
    # it sees every round including the one that finishes the turn — the
    # same place as store_append.
    def self.compaction_feed(inbox)
      fed = {} # conversation id => highest seq already pushed

      side_worker do |conversation|
        conversation.elements.each do |element|
          inbox << element if element.seq > fed.fetch(conversation.id, 0)
        end
        fed[conversation.id] = conversation.elements.last&.seq || 0
      end
    end
  end
end
