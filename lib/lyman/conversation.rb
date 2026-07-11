module Lyman
  # The item that flows through the spine and the circuit: the whole
  # conversation so far, plus the control data workers consult to decide
  # *whether* to act (never *which of several things* to do).
  #
  # An immutable value. Shifty 0.6 deep-freezes every value at a worker
  # boundary (the :frozen handoff policy), so change is expressed as new
  # values: each with_* method returns a new Conversation and leaves the
  # receiver untouched. Data#with structurally shares the unchanged
  # members — safe precisely because handed-off values are frozen.
  #
  # Messages use string keys throughout, for clean round-tripping with
  # OpenAI-compatible wire formats.
  class Conversation < Data.define(:messages, :rounds, :max_rounds, :finished)
    def initialize(system_prompt: nil, messages: nil, rounds: 0, max_rounds: 10, finished: false)
      messages ||= system_prompt ? [{"role" => "system", "content" => system_prompt}] : []
      super(messages: messages, rounds: rounds, max_rounds: max_rounds, finished: finished)
    end

    def with_user_message(text)
      with(
        messages: messages + [{"role" => "user", "content" => text}],
        rounds: 0,
        finished: false
      )
    end

    # A round *is* one model reply, so the counter lives here rather than
    # in the transport worker — swap the transport and the runaway guard
    # still can't be forgotten.
    def with_assistant_message(message)
      with(messages: messages + [message], rounds: rounds + 1)
    end

    def with_tool_result(tool_call_id, content)
      with(messages: messages + [{
        "role" => "tool",
        "tool_call_id" => tool_call_id,
        "content" => content
      }])
    end

    def pending_tool_calls
      last = messages.last
      return [] unless last && last["role"] == "assistant"
      last["tool_calls"] || []
    end

    def last_assistant_content
      message = messages.rfind { |m| m["role"] == "assistant" }
      message && message["content"]
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
  end
end
