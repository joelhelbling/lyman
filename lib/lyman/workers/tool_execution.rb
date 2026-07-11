require "shifty"
require "json"

module Lyman
  module Workers
    extend Shifty::DSL

    # Relay worker: executes any tool calls pending on the conversation and
    # hands off a new conversation with their results appended. Acts only
    # when the turn isn't already finished and the model has asked for
    # tools; otherwise passes through.
    #
    # +handlers+ is a hash of tool name => callable taking a Hash of
    # arguments and returning something stringable.
    def self.tool_execution(handlers)
      relay_worker do |conversation|
        # Fold results onto the accumulator while iterating the *original*
        # conversation's pending calls: each with_tool_result appends a
        # tool message, which empties pending_tool_calls on the new value.
        conversation.pending_tool_calls.reduce(conversation) do |convo, tool_call|
          break convo if convo.finished?

          name = tool_call.dig("function", "name")
          args = parse_arguments(tool_call.dig("function", "arguments"))
          handler = handlers[name]

          result =
            if handler
              begin
                handler.call(args).to_s
              rescue => e
                "Tool #{name} raised #{e.class}: #{e.message}"
              end
            else
              "Unknown tool: #{name}"
            end

          convo.with_tool_result(tool_call["id"], result)
        end
      end
    end

    def self.parse_arguments(raw)
      return raw if raw.is_a?(Hash)
      JSON.parse(raw.to_s)
    rescue JSON::ParserError
      {}
    end
  end
end
