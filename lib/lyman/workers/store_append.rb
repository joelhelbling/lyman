require "shifty"

module Lyman
  module Workers
    extend Shifty::DSL

    # Side worker: persists the conversation on its way through the
    # circuit. Takes anything duck-typed to respond to #append(conversation)
    # — it never references sqlite (or any store internals) directly, so a
    # fake store, a different backend, or Lyman::Store all work the same
    # way here. See docs/design/context-control.md ("Store and recall").
    #
    # Durability is an optional splice, not a built-in assumption: a
    # harness that doesn't want one never wires this worker in.
    #
    # Splice it after tool_execution and before any "finished?" filter, so
    # it sees every round including the one that finishes the turn. A user
    # message appended by the shell (outside the circuit) is picked up on
    # the pipeline's next pass, once it flows back through as part of a
    # conversation.
    def self.store_append(store)
      side_worker { |conversation| store.append(conversation) }
    end
  end
end
