module Lyman
  # Wire-time projection policies: deterministic context reduction that
  # needs no model. A policy is any object responding to
  # `call(conversation) -> conversation`: it returns a *view* — the same
  # conversation with `elements` substituted (`conversation.with(elements:
  # ...)`), some elements dropped or replaced by same-seq stand-ins. Plain
  # lambdas qualify.
  #
  # The original conversation is never touched (it's immutable anyway) and
  # the view is never stored or handed on: chat_completion builds it,
  # projects it to wire messages, and discards it — the reply lands on the
  # ORIGINAL conversation. Stand-in elements keep their conversation_id,
  # seq, and type, so addresses stay meaningful even though the content
  # they point at has been shrunk for the wire.
  #
  # This is the cheap half of "two kinds of reduction, kept apart": no
  # model call, no new conversation, nothing persisted. See
  # docs/design/context-control.md ("Two kinds of reduction, kept apart").
  # The other half — compaction — is a model-backed, stored, lineage-
  # tracked operation and lives elsewhere.
  module Abridgement
    # Drops `reasoning` elements belonging to turns before the current
    # one. The current turn is "everything after the last `user`
    # element" — a model thinking through *this* turn's tool calls still
    # wants that chain of thought back (paired with
    # `send_reasoning: true` on chat_completion); earlier turns' thoughts
    # are dead weight once the turn that produced them is done. With no
    # user element at all, everything is the current turn and nothing is
    # dropped.
    class SuppressPriorReasoning
      def call(conversation)
        elements = conversation.elements
        current_turn_start = elements.rindex { |element| element.type == "user" }
        return conversation unless current_turn_start

        kept = elements.each_with_index.reject { |element, index|
          element.type == "reasoning" && index <= current_turn_start
        }.map(&:first)

        conversation.with(elements: kept)
      end
    end

    # Condenses `tool_result` elements older than `keep_rounds` model
    # replies to a one-line stub, so a long-running conversation doesn't
    # keep paying full price for tool output the model has already acted
    # on. Age is counted in rounds (one round = one `assistant` element),
    # not turns or wall-clock time, because that's what actually presses
    # on context size.
    #
    # The stub still carries the tool name, the original size, and the
    # original element's address, so a future recall tool (issue #12) can
    # re-expand exactly what was shrunk. Stubbing never makes a result
    # longer: a result already shorter than its own stub is left alone.
    #
    # keep_rounds must be at least 1: a result with no reply after it is
    # one the model hasn't seen yet, and stubbing it would have the model
    # act on "[abridged: ...]" with no way (until recall exists) to see
    # what it asked for.
    class StubToolResults
      def initialize(keep_rounds: 2)
        unless keep_rounds.is_a?(Integer) && keep_rounds >= 1
          raise ArgumentError, "keep_rounds must be an Integer >= 1 (got #{keep_rounds.inspect}): " \
            "a result the model hasn't replied to yet can't be abridged"
        end
        @keep_rounds = keep_rounds
      end

      def call(conversation)
        elements = conversation.elements

        # Age = assistant elements after this one. Elements arrive in
        # order, so a single reverse pass computes every result's age in
        # one go: assistant_after only ever grows as we walk backward.
        assistant_after = 0
        kept = elements.reverse_each.map { |element|
          replacement =
            if element.type == "tool_result" && assistant_after >= @keep_rounds
              stub_for(element, elements)
            else
              element
            end
          assistant_after += 1 if element.type == "assistant"
          replacement
        }.reverse

        conversation.with(elements: kept)
      end

      private

      def stub_for(element, elements)
        text = element.content["text"]
        return element if text.nil?

        tool_call_id = element.content["tool_call_id"]
        tool_call = elements.find { |e| e.type == "tool_call" && e.content["id"] == tool_call_id }
        tool_name = tool_call ? tool_call.content.dig("function", "name") : "tool"

        stub = "[abridged: #{tool_name} result, #{text.length} chars — #{element.address}]"
        return element if text.length <= stub.length

        Element.new(
          conversation_id: element.conversation_id,
          seq: element.seq,
          type: element.type,
          content: {"tool_call_id" => tool_call_id, "text" => stub}
        )
      end
    end

    # Composes policies left to right into a single policy — the
    # everyday way to run more than one (e.g. SuppressPriorReasoning then
    # StubToolResults), without inventing a second way to combine wire-
    # time projections.
    def self.chain(*policies)
      ->(conversation) { policies.reduce(conversation) { |view, policy| policy.call(view) } }
    end

    # Item-as-control: applies +policy+ only when the conversation is
    # over budget, otherwise passes the conversation through untouched.
    # "Over budget" means the transport's most recent usage report (see
    # Conversation#prompt_tokens) exceeds +max_prompt_tokens+; usage lags
    # one request behind (it's stamped from the *previous* reply), so
    # this is a same-request approximation, not a guarantee. When usage
    # is unreported (nil), there's nothing to compare, so the policy
    # never fires. The report describes the request as *sent* — already
    # abridged, if this gate fired last round — so a policy that pulls the
    # prompt back under budget turns itself off again next round. Leave
    # headroom below the real limit rather than gating right at it.
    def self.over_budget(max_prompt_tokens, policy)
      ->(conversation) {
        tokens = conversation.prompt_tokens
        (tokens && tokens > max_prompt_tokens) ? policy.call(conversation) : conversation
      }
    end
  end
end
