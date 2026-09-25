require "cli/ui"
require_relative "style"

# Prints tool activity around the execution stage: the calls the model
# requested on the way in, a ✓-and-result line on the way out. Results are
# summarized to one line here — the full text is on the conversation, where
# the model (and any logging side-worker) sees it.
class ToolPrinter
  RESULT_WIDTH = 60

  def calls(conversation, indent: 0)
    pad = " " * indent
    conversation.pending_tool_calls.each do |tool_call|
      puts gray("#{pad}  ⚙ #{tool_call.dig("function", "name")} #{tool_call.dig("function", "arguments")}")
    end
  end

  def results(conversation, indent: 0)
    pad = " " * indent
    elements = conversation.elements
    reply_start = elements.rindex { |e| e.type == "assistant" }
    return unless reply_start

    reply = elements[(reply_start + 1)..]
    names = reply.select { |e| e.type == "tool_call" }
      .to_h { |e| [e.content["id"], e.content.dig("function", "name")] }

    reply.each do |element|
      next unless element.type == "tool_result"
      summary = gray("#{names[element.content["tool_call_id"]]} → #{summarize(element.content["text"])}")
      puts "#{pad}  #{CLI::UI.fmt("{{v}}")} #{summary}"
    end
  end

  private

  def summarize(text)
    line = text.to_s.gsub(/\s+/, " ").strip
    (line.length > RESULT_WIDTH) ? "#{line[0, RESULT_WIDTH - 1]}…" : line
  end
end
