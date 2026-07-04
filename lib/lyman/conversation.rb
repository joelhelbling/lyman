module Lyman
  # The item that flows through the spine and the circuit: the whole
  # conversation so far, plus the control data workers consult to decide
  # *whether* to act (never *which of several things* to do).
  #
  # Messages use string keys throughout, for clean round-tripping with
  # OpenAI-compatible wire formats.
  class Conversation
    attr_reader :messages
    attr_accessor :rounds, :max_rounds

    def initialize(system_prompt: nil, max_rounds: 10)
      @messages = []
      @messages << {"role" => "system", "content" => system_prompt} if system_prompt
      @rounds = 0
      @max_rounds = max_rounds
      @finished = false
    end

    def add_user_message(text)
      @messages << {"role" => "user", "content" => text}
      @finished = false
      @rounds = 0
      self
    end

    def add_assistant_message(message)
      @messages << message
      self
    end

    def add_tool_result(tool_call_id, content)
      @messages << {
        "role" => "tool",
        "tool_call_id" => tool_call_id,
        "content" => content
      }
      self
    end

    def pending_tool_calls
      last = @messages.last
      return [] unless last && last["role"] == "assistant"
      last["tool_calls"] || []
    end

    def last_assistant_content
      message = @messages.reverse.find { |m| m["role"] == "assistant" }
      message && message["content"]
    end

    def finish!
      @finished = true
      self
    end

    def finished?
      @finished
    end

    def runaway?
      @rounds >= @max_rounds
    end
  end
end
