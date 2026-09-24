require "json"
require "securerandom"

module Lyman
  # Compaction: the model-backed half of "two kinds of reduction, kept
  # apart" (docs/design/context-control.md). Where Abridgement shapes a
  # disposable wire view, compaction produces a *new conversation* — a
  # ledger of what mattered plus a short verbatim tail — whose parent_id
  # names the conversation it compacted, so nothing is destroyed: every
  # ledger entry carries the addresses of the elements it summarizes, and
  # a store plus the recall tool can re-expand any of them.
  #
  # This file is the stdlib-only vocabulary the sidecar is built from; the
  # sidecar itself is a wiring script (harness/compactor.rb), because a
  # compaction strategy is a choice of wiring, not a mode of a component.
  #
  # The client's lib/lyman.rb loads planted files alphabetically, so this
  # one loads before conversation.rb: refer to Conversation and Element
  # only inside method bodies, never at load time.
  module Compaction
    # How a root shell asks the sidecar for a compacted conversation: the
    # conversation to compact, and a queue to hand the result back on.
    # Requests ride the same inbox as the fed elements, so by the time the
    # sidecar reads one, every element fed before it has been read too —
    # ordering does the draining, no locks or flags needed.
    Request = Data.define(:conversation, :reply)

    # Enqueues a compaction request and waits for the compacted
    # conversation. Falls back to the conversation as given if the sidecar
    # doesn't answer within +timeout+ seconds (a dead or wedged compactor
    # thread must cost a missed compaction, never a hung root shell) — and
    # says so, so a stall reads as "compaction is broken" rather than "the
    # app is slow".
    def self.request(inbox, conversation, timeout: 120)
      reply = Thread::Queue.new
      inbox << Request.new(conversation: conversation, reply: reply)
      compacted = reply.pop(timeout: timeout)
      return compacted if compacted

      warn "compaction: no answer from the sidecar within #{timeout}s; continuing uncompacted"
      conversation
    end

    # The running summary a compactor keeps: entries, each a string-keyed
    # hash {"kind" => ..., "text" => ..., "sources" => [element addresses]},
    # plus how far into each conversation it has already accounted for.
    #
    # An immutable value, like Conversation: absorbing a batch or covering a
    # conversation returns a new Ledger. Entries are only ever appended — a
    # ledger extended step by step stays stable, rather than being
    # re-summarized (and re-worded, and re-lost) wholesale each time.
    #
    # Kinds: "fact" (established), "decision" (taken), "open" (still to
    # do or unresolved), and "gap" — elements the model failed to
    # summarize, kept as bare backlinks so they are never silently lost.
    class Ledger < Data.define(:entries, :covered)
      KINDS = %w[fact decision open].freeze

      SECTIONS = {
        "fact" => "Facts established",
        "decision" => "Decisions taken",
        "open" => "Open items",
        "gap" => "Not summarized (recall these to see them)"
      }.freeze

      # The ledger's heading in a compacted conversation's system prompt —
      # also how compact() finds and replaces an earlier ledger rather than
      # stacking one on top of the other when compacting a compaction.
      HEADING = "## Earlier in this conversation (compacted)"

      # Long tool output would make the digest model's prompt as large as
      # the context it's trying to shrink; the backlink keeps the rest.
      MAX_ELEMENT_CHARS = 1500

      # covered: conversation id => highest seq accounted for.
      def initialize(entries: [], covered: {})
        super
      end

      # The conversation handed to the digest model for one batch of fed
      # elements, or nil when the batch holds nothing worth summarizing
      # (system prompts travel verbatim; reasoning is scratch work; and a
      # compacted conversation's own opening is already the ledger).
      #
      # Elements are numbered locally ([1], [2], ...) rather than shown by
      # address: a small model copying back "3" is far more reliable than
      # one copying back a 36-character UUID.
      def prompt(batch, instructions:)
        items = summarizable(batch)
        return nil if items.empty?

        listing = items.each_with_index.map { |element, index|
          "[#{index + 1}] #{element.type}: #{excerpt(element)}"
        }.join("\n")
        current = entries.empty? ? "(empty)" : entries.map { |e| "- (#{e["kind"]}) #{e["text"]}" }.join("\n")

        Conversation.new(system_prompt: instructions)
          .with_user_message("Current ledger:\n#{current}\n\nNew elements:\n#{listing}")
      end

      # Folds the digest model's reply for +batch+ into a new Ledger. The
      # reply should be a JSON array of {"kind", "text", "sources"} with
      # sources as the local [n] numbers from prompt(); anything
      # unparseable (or no reply at all — the model call failed) becomes a
      # single "gap" entry pointing at the whole batch, so a bad digest
      # loses a summary but never a backlink.
      def absorb(batch, reply)
        items = summarizable(batch)
        new_entries = items.empty? ? [] : (parse(reply, items) || [gap_entry(items)])

        with(entries: entries + new_entries, covered: covered_through(batch))
      end

      # Marks every element of +conversation+ as accounted for. The sidecar
      # calls this on each conversation it hands back from compact(): that
      # conversation opens with the ledger and a tail already summarized,
      # which must not be fed back through the digest model as news.
      def cover(conversation)
        with(covered: covered_through(conversation.elements))
      end

      # A new conversation: the original system prompt with this ledger
      # appended, then a verbatim tail — the most recent turn, from its
      # user message on — since the model usually needs the immediate
      # exchange intact. parent_id points at the conversation compacted,
      # so a store can walk back to everything the ledger summarizes.
      def compact(conversation)
        id = SecureRandom.uuid
        compacted = []

        system_text = [base_system_prompt(conversation), render].reject(&:empty?).join("\n\n")
        compacted << Element.new(conversation_id: id, seq: 1, type: "system", content: {"text" => system_text}) unless system_text.empty?

        tail_start = conversation.elements.rindex { |e| e.type == "user" } || conversation.elements.size
        conversation.elements[tail_start..].each do |element|
          next if element.type == "reasoning" # a finished turn's scratch work, as in SuppressPriorReasoning
          compacted << Element.new(conversation_id: id, seq: compacted.size + 1, type: element.type, content: element.content)
        end

        Conversation.new(id: id, parent_id: conversation.id, elements: compacted, max_rounds: conversation.max_rounds)
      end

      # The ledger as it reads in a compacted system prompt; "" when empty.
      # Sources are compressed into ranges (conv:abc#3-7) — the same address
      # syntax Store#fetch and the recall tool accept.
      def render
        return "" if entries.empty?

        sections = SECTIONS.filter_map { |kind, label|
          kept = entries.select { |e| e["kind"] == kind }
          next if kept.empty?
          lines = kept.map { |e| "- #{e["text"]} [#{compress(e["sources"]).join(", ")}]" }
          "#{label}:\n#{lines.join("\n")}"
        }

        "#{HEADING}\nThe conversation so far was compacted into this ledger. Bracketed addresses " \
          "name the original elements; pass one to the recall tool, if you have it, to see them " \
          "in full.\n\n#{sections.join("\n\n")}"
      end

      private

      def summarizable(batch)
        batch.reject { |e| e.seq <= covered.fetch(e.conversation_id, 0) || %w[system reasoning].include?(e.type) }
      end

      def covered_through(elements)
        elements.each_with_object(covered.dup) do |element, marks|
          marks[element.conversation_id] = [marks.fetch(element.conversation_id, 0), element.seq].max
        end
      end

      # Only the part of the system prompt above any earlier ledger:
      # compacting a compacted conversation replaces the ledger (this one
      # already carries every earlier entry) instead of stacking a second.
      def base_system_prompt(conversation)
        system = conversation.elements.find { |e| e.type == "system" }
        text = system ? system.content["text"].to_s : ""
        text.split(HEADING, 2).first.to_s.rstrip
      end

      def excerpt(element)
        text =
          case element.type
          when "tool_call"
            function = element.content["function"] || {}
            arguments = function["arguments"]
            arguments = JSON.generate(arguments) if arguments.is_a?(Hash)
            "#{function["name"]}(#{arguments})"
          else
            element.content["text"].to_s
          end
        (text.length > MAX_ELEMENT_CHARS) ? "#{text[0, MAX_ELEMENT_CHARS]}… [truncated]" : text
      end

      # Small models wrap JSON in prose, code fences, or <think> blocks;
      # take the outermost [...] and let JSON decide. nil means "couldn't
      # read a digest here" (absorb records a gap); [] is a legitimate
      # "nothing new worth keeping".
      def parse(reply, items)
        return nil unless reply.is_a?(String)
        json = reply.gsub(%r{<think>.*?</think>}m, "")[/\[.*\]/m]
        return nil unless json

        data = JSON.parse(json)
        return nil unless data.is_a?(Array)

        parsed = data.filter_map { |raw| entry(raw, items) }
        (parsed.empty? && !data.empty?) ? nil : parsed
      rescue JSON::ParserError
        nil
      end

      def entry(raw, items)
        return nil unless raw.is_a?(Hash)
        text = raw["text"].to_s.strip
        return nil if text.empty?

        kind = raw["kind"].to_s.downcase.strip.delete_suffix("s")
        kind = "fact" unless KINDS.include?(kind)

        # Accept 3, "3", "[3]", "#3" — whatever a small model makes of the
        # numbering. Out-of-range numbers are dropped; an entry left citing
        # nothing cites the whole batch, since it came from somewhere in it.
        sources = Array(raw["sources"]).filter_map { |n|
          index = n.to_s[/\d+/]&.to_i
          items[index - 1] if index&.between?(1, items.size)
        }
        sources = items if sources.empty?

        {"kind" => kind, "text" => text, "sources" => sources.map(&:address).uniq}
      end

      def gap_entry(items)
        {"kind" => "gap", "text" => "#{items.size} element(s) not summarized", "sources" => items.map(&:address)}
      end

      # ["conv:a#3", "conv:a#4", "conv:a#5", "conv:a#9"] -> ["conv:a#3-5", "conv:a#9"]
      def compress(addresses)
        parsed = addresses.map { |address| address.match(/\Aconv:(.+)#(\d+)\z/) }
        return addresses unless parsed.all?

        parsed.group_by { |m| m[1] }.flat_map { |id, matches|
          seqs = matches.map { |m| m[2].to_i }.uniq.sort
          seqs.slice_when { |a, b| b != a + 1 }.map { |run|
            (run.size == 1) ? "conv:#{id}##{run.first}" : "conv:#{id}##{run.first}-#{run.last}"
          }
        }
      end
    end
  end
end
