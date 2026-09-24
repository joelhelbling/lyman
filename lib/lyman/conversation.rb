require "securerandom"

module Lyman
  # One typed, addressable unit in a Conversation's series. Today's
  # conversation bundles a whole assistant turn (text, reasoning, every
  # tool call) into one wire-shaped message hash — too coarse to store,
  # abridge, or recall selectively. Splitting each turn into elements
  # gives every piece its own identity (conversation_id + seq), which is
  # the address a store, an abridgement policy, a compaction ledger entry,
  # or a recall tool needs to point at exactly one thing. See
  # docs/design/context-control.md ("Elements, not messages").
  #
  # It lives in this file, not its own, because it can't be upgraded
  # independently of Conversation: the unit of upgrade is the unit of
  # extraction (docs/design/deployment.md).
  #
  # content is a string-keyed Hash, shaped per type:
  #   system/user/reasoning/assistant -> {"text" => String or nil}
  #   tool_call                       -> the tool call hash as received
  #   tool_result                     -> {"tool_call_id" => ..., "text" => ...}
  class Element < Data.define(:conversation_id, :seq, :type, :content)
    TYPES = %w[system user reasoning assistant tool_call tool_result].freeze

    def initialize(conversation_id:, seq:, type:, content:)
      unless TYPES.include?(type)
        raise ArgumentError, "unknown element type #{type.inspect} (expected one of #{TYPES.join(", ")})"
      end
      super
    end

    def address
      "conv:#{conversation_id}##{seq}"
    end
  end

  # The item that flows through the spine and the circuit: the whole
  # conversation so far, plus the control data workers consult to decide
  # *whether* to act (never *which of several things* to do).
  #
  # A conversation is a flat, append-only series of typed Elements (above)
  # rather than a list of wire-shaped message hashes. One assistant turn
  # used to bundle its text, reasoning, and every tool call into one
  # hash — too coarse to address, store, or abridge selectively.
  # Each element carries this conversation's id and its own 1-based
  # sequence position, so any piece can be named (`conv:abc#17`), looked
  # up, or later stored and recalled. See
  # docs/design/context-control.md ("Elements, not messages").
  #
  # The OpenAI-compatible message list is a *projection* of the series
  # (`messages` / `wire_messages`), not the storage form: elements are
  # regrouped back into wire messages on demand, reasoning stripped from
  # the wire by default but always kept in the series for observability.
  #
  # An immutable value. Shifty 0.6 deep-freezes every value at a worker
  # boundary (the :frozen handoff policy), so change is expressed as new
  # values: each with_* method returns a new Conversation and leaves the
  # receiver untouched, appending elements rather than revising or
  # reordering them. Data#with structurally shares the unchanged
  # members — safe precisely because handed-off values are frozen.
  #
  # Messages and element content use string keys throughout, for clean
  # round-tripping with OpenAI-compatible wire formats.
  class Conversation < Data.define(:id, :parent_id, :elements, :rounds, :max_rounds, :finished, :usage)
    # parent_id is the compaction lineage pointer: a compacted conversation
    # names the conversation it compacted, so a store can walk the ancestor
    # chain to recall what an over-aggressive compaction dropped. nil for an
    # ordinary conversation with no ancestor. See docs/design/context-control.md
    # ("Two kinds of reduction, kept apart").
    #
    # usage is the transport's raw usage hash from the most recent model
    # reply (string keys, e.g. {"prompt_tokens"=>..., "completion_tokens"=>...,
    # "total_tokens"=>...}), or nil when unreported. It's control data, not
    # series — a store persists the elements, never this — so a conversation
    # loaded back from storage starts with usage nil, same as rounds/finished.
    def initialize(system_prompt: nil, id: nil, parent_id: nil, elements: nil, rounds: 0, max_rounds: 10, finished: false, usage: nil)
      id ||= SecureRandom.uuid
      elements ||= system_prompt ? [Element.new(conversation_id: id, seq: 1, type: "system", content: {"text" => system_prompt})] : []
      super(id: id, parent_id: parent_id, elements: elements, rounds: rounds, max_rounds: max_rounds, finished: finished, usage: usage)
    end

    def with_user_message(text)
      with(
        elements: elements + [next_element("user", {"text" => text})],
        rounds: 0,
        finished: false
      )
    end

    # A round *is* one model reply, so the counter lives here rather than
    # in the transport worker — swap the transport and the runaway guard
    # still can't be forgotten.
    #
    # Decomposes the OpenAI-style assistant message into elements, in
    # order: reasoning (if present and non-empty), then always exactly one
    # assistant element (content may be nil when the model only called
    # tools), then one tool_call element per requested call.
    def with_assistant_message(message)
      new_elements = elements.dup

      reasoning = message["reasoning"] || message["reasoning_content"]
      if reasoning.is_a?(String) && !reasoning.empty?
        new_elements << next_element("reasoning", {"text" => reasoning}, new_elements)
      end

      new_elements << next_element("assistant", {"text" => message["content"]}, new_elements)

      (message["tool_calls"] || []).each do |tool_call|
        new_elements << next_element("tool_call", tool_call, new_elements)
      end

      with(elements: new_elements, rounds: rounds + 1)
    end

    def with_tool_result(tool_call_id, content)
      with(elements: elements + [next_element("tool_result", {"tool_call_id" => tool_call_id, "text" => content})])
    end

    # Stamps the transport's usage report from the reply that just landed.
    # chat_completion calls this after with_assistant_message on every
    # round, streamed or not, so "over budget?" always has the freshest
    # figure to consult (see Abridgement.over_budget).
    def with_usage(usage)
      with(usage: usage)
    end

    # The transport's prompt token count from the most recent reply, or
    # nil when usage was never reported. This lags one request behind —
    # it describes the request that just returned, not the one about to
    # be sent — so it's an approximation a whether-to-act stage consults,
    # not a hard guarantee.
    def prompt_tokens
      usage && usage["prompt_tokens"]
    end

    # The projection back to OpenAI-style message hashes, reasoning kept
    # (it's useful to observability): a reasoning element immediately
    # preceding an assistant element becomes that message's "reasoning"
    # key, and tool_call elements following an assistant element are
    # gathered back onto that same message's "tool_calls" array.
    def messages
      result = []
      pending_reasoning = nil

      elements.each do |element|
        case element.type
        when "system", "user"
          result << {"role" => element.type, "content" => element.content["text"]}
          pending_reasoning = nil
        when "reasoning"
          pending_reasoning = element.content["text"]
        when "assistant"
          message = {"role" => "assistant", "content" => element.content["text"]}
          message["reasoning"] = pending_reasoning if pending_reasoning
          result << message
          pending_reasoning = nil
        when "tool_call"
          (result.last["tool_calls"] ||= []) << element.content
        when "tool_result"
          result << {
            "role" => "tool",
            "tool_call_id" => element.content["tool_call_id"],
            "content" => element.content["text"]
          }
          pending_reasoning = nil
        end
      end

      result
    end

    # The conversation keeps each element's reasoning (it's useful to
    # observability), but by default it never rides back to the model:
    # providers either ignore it, reject it outright (DeepSeek), or would
    # burn context re-reading thoughts the model already finished thinking.
    #
    # reasoning: true is the opt-in for interleaved-thinking models (e.g.
    # gpt-oss, qwen3) that want the current turn's chain of thought back
    # between tool calls — pair it with Abridgement::SuppressPriorReasoning
    # so only the current turn's reasoning survives to ride along.
    def wire_messages(reasoning: false)
      reasoning ? messages : messages.map { |message| message.except("reasoning") }
    end

    def element(seq)
      elements.find { |e| e.seq == seq }
    end

    def elements_in(range)
      elements.select { |e| range.cover?(e.seq) }
    end

    # Tool calls from the latest reply, if and only if nothing has been
    # appended after that reply's elements yet. tool_execution relies on
    # this emptying out after the first with_tool_result is appended, so
    # folding results one at a time naturally terminates.
    def pending_tool_calls
      last = elements.last
      return [] unless last && %w[assistant tool_call].include?(last.type)

      reply_start = elements.rindex { |e| e.type == "assistant" }
      return [] unless reply_start

      elements[(reply_start + 1)..].select { |e| e.type == "tool_call" }.map(&:content)
    end

    def last_assistant_content
      element = elements.rfind { |e| e.type == "assistant" }
      element && element.content["text"]
    end

    def finish
      with(finished: true)
    end

    def finished?
      finished
    end

    def runaway?
      rounds >= max_rounds
    end

    private

    # Builds the next element in sequence, addressed at this conversation.
    # +from+ lets with_assistant_message compute seq against the
    # in-progress local array it's still appending to, rather than the
    # frozen receiver's elements.
    def next_element(type, content, from = elements)
      Element.new(conversation_id: id, seq: from.size + 1, type: type, content: content)
    end
  end
end
