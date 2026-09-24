require "json"

module Lyman
  module Tools
    # Re-expands what abridgement or compaction compressed away. Both
    # mechanisms are designed to be reversible rather than lossy (see
    # docs/design/context-control.md, "Store and recall"): a stubbed tool
    # result names the original element's address, and a compaction
    # ledger entry backlinks to the elements it summarized. This tool is
    # what turns those addresses into something the model can act on.
    #
    # `store:` is duck-typed, not `Lyman::Store` specifically — anything
    # responding to `fetch(address)` and `search(query, conversation_id:,
    # limit:)` works, so a fake stands in for tests and this file never
    # requires sqlite3 (dependency isolation: the sqlite3 dependency stays
    # confined to store.rb, same as Lyman::Workers.store_append).
    def self.recall(store:, max_chars: 8000)
      {
        schema: {
          "type" => "function",
          "function" => {
            "name" => "recall",
            "description" => "Re-expand context that was compacted or abridged away. " \
              "Abridged stubs (e.g. \"[abridged: current_time result, 1234 chars — conv:abc#12]\") " \
              "and compaction ledger entries carry addresses; pass one as `address` to see the " \
              "original element(s). Or search past conversations by plain-word `query` when you " \
              "don't have an address. Pass exactly one of address or query.",
            "parameters" => {
              "type" => "object",
              "properties" => {
                "address" => {
                  "type" => "string",
                  "description" => "An element address: \"conv:ID\" (a whole conversation), " \
                    "\"conv:ID#17\" (one element), or \"conv:ID#17-23\" (a range)."
                },
                "query" => {
                  "type" => "string",
                  "description" => "Plain words to search for (not FTS syntax)."
                },
                "conversation_id" => {
                  "type" => "string",
                  "description" => "Optional: scopes `query` to this conversation and its ancestors."
                },
                "limit" => {
                  "type" => "integer",
                  "description" => "Optional: max results for `query` (default 10)."
                }
              },
              "required" => []
            }
          }
        },
        handler: ->(args) { handle(args, store: store, max_chars: max_chars) }
      }
    end

    def self.handle(args, store:, max_chars:)
      # Small models often send every parameter, blanking the ones they
      # don't mean — treat an empty string as absent.
      address, query = args.values_at("address", "query").map { |v| v.to_s.strip.empty? ? nil : v }

      if address && query
        return "Pass exactly one of address or query, not both."
      elsif address
        elements = fetch(address, store: store)
        return elements if elements.is_a?(String)
      elsif query
        limit = Integer(args["limit"] || 10, exception: false) || 10
        elements = store.search(query, conversation_id: args["conversation_id"], limit: limit)
      else
        return "Pass either address (e.g. \"conv:abc#17-23\") or query (plain words) to recall."
      end

      return "Nothing found for #{address ? address.inspect : query.inspect}." if elements.empty?

      render(elements, max_chars: max_chars)
    end
    private_class_method :handle

    def self.fetch(address, store:)
      store.fetch(address)
    rescue ArgumentError
      "Malformed address #{address.inspect} — expected \"conv:ID\", \"conv:ID#17\", or \"conv:ID#17-23\"."
    end
    private_class_method :fetch

    def self.render(elements, max_chars:)
      blocks = elements.map { |element| render_element(element) }
      full = blocks.join("\n\n")
      return full if full.length <= max_chars

      # A recall of a whole (or wide) range must not blow the very context
      # the abridgement was protecting — truncate and tell the model how
      # to ask again more narrowly, rather than silently overflowing.
      truncated = full[0, max_chars]
      first, last = elements.first, elements.last
      example = "conv:#{first.conversation_id}##{first.seq}-#{[first.seq + 2, last.seq].min}"
      "#{truncated}\n\n[recall truncated at #{max_chars} chars — narrow the range, e.g. #{example}]"
    end
    private_class_method :render

    def self.render_element(element)
      "[#{element.address} #{element.type}]\n#{element_text(element)}"
    end
    private_class_method :render_element

    def self.element_text(element)
      case element.type
      when "system", "user", "reasoning", "assistant"
        element.content["text"].to_s
      when "tool_call"
        function = element.content["function"] || {}
        arguments = function["arguments"]
        arguments = JSON.generate(arguments) if arguments.is_a?(Hash)
        "#{function["name"]}(#{arguments})"
      when "tool_result"
        element.content["text"].to_s
      end
    end
    private_class_method :element_text
  end
end
