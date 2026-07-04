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
    # This is the only part of lyman that knows HTTP exists.
    def self.chat_completion(base_url:, model:, tools: nil, read_timeout: 300)
      uri = URI("#{base_url.chomp("/")}/chat/completions")

      relay_worker do |conversation|
        payload = {"model" => model, "messages" => conversation.messages}
        payload["tools"] = tools if tools && !tools.empty?

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.read_timeout = read_timeout

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

        conversation.add_assistant_message(message)
        conversation.rounds += 1
        conversation
      end
    end
  end
end
