require "shifty"
require "net/http"
require "json"
require "uri"

module Lyman
  module Workers
    extend Shifty::DSL

    # Relay worker: sends the conversation to an OpenAI-compatible chat
    # completions endpoint and appends the assistant's reply (which may
    # include tool calls). Increments the conversation's round counter.
    #
    # Pass an on_delta callable to stream: it receives each content
    # fragment as it arrives. The worker still returns the conversation
    # with the fully-assembled message appended, so the circuit sees no
    # difference between streamed and unstreamed rounds.
    #
    # This is the only part of lyman that knows HTTP exists.
    def self.chat_completion(base_url:, model:, tools: nil, read_timeout: 300, on_delta: nil)
      uri = URI("#{base_url.chomp("/")}/chat/completions")

      relay_worker do |conversation|
        payload = {"model" => model, "messages" => conversation.messages}
        payload["tools"] = tools if tools && !tools.empty?
        payload["stream"] = true if on_delta

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.read_timeout = read_timeout

        message =
          if on_delta
            stream_message(http, uri, payload, on_delta)
          else
            fetch_message(http, uri, payload)
          end

        conversation.add_assistant_message(message)
        conversation.rounds += 1
        conversation
      end
    end

    def self.fetch_message(http, uri, payload)
      response = http.post(
        uri.path,
        JSON.generate(payload),
        "Content-Type" => "application/json"
      )

      unless response.is_a?(Net::HTTPSuccess)
        raise "chat completion failed (#{response.code}): #{response.body}"
      end

      message = JSON.parse(response.body).dig("choices", 0, "message")
      raise "chat completion response had no message: #{response.body}" unless message
      message
    end

    def self.stream_message(http, uri, payload, on_delta)
      request = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
      request.body = JSON.generate(payload)

      message = {"role" => "assistant", "content" => nil}
      tool_calls = {}
      buffer = +""

      http.request(request) do |response|
        unless response.is_a?(Net::HTTPSuccess)
          raise "chat completion failed (#{response.code}): #{response.read_body}"
        end

        response.read_body do |chunk|
          buffer << chunk
          # SSE events arrive as "data: {json}" lines, but chunks don't
          # align with line boundaries.
          while (newline = buffer.index("\n"))
            line = buffer.slice!(0..newline).strip
            next unless line.start_with?("data:")

            data = line.delete_prefix("data:").strip
            next if data == "[DONE]"

            delta = JSON.parse(data).dig("choices", 0, "delta")
            apply_delta(message, tool_calls, delta, on_delta) if delta
          end
        end
      end

      unless tool_calls.empty?
        message["tool_calls"] = tool_calls.keys.sort.map { |index| tool_calls[index] }
      end
      message
    end

    # Content deltas concatenate; tool-call deltas arrive as fragments
    # keyed by index, with the arguments string dribbling in over many
    # chunks.
    def self.apply_delta(message, tool_calls, delta, on_delta)
      if (text = delta["content"])
        message["content"] = (message["content"] || +"") + text
        on_delta.call(text)
      end

      (delta["tool_calls"] || []).each do |fragment|
        entry = tool_calls[fragment["index"]] ||= {
          "id" => nil,
          "type" => "function",
          "function" => {"name" => +"", "arguments" => +""}
        }
        entry["id"] = fragment["id"] if fragment["id"]
        entry["type"] = fragment["type"] if fragment["type"]

        function = fragment["function"] || {}
        entry["function"]["name"] << function["name"] if function["name"]
        entry["function"]["arguments"] << function["arguments"] if function["arguments"]
      end
    end
  end
end
