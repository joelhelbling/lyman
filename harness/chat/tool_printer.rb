require "cli/ui"
require_relative "style"

# Prints tool activity around the execution stage: the calls the model
# requested on the way in, a ✓-and-result line on the way out. Results are
# summarized to one line here — the full text is on the conversation, where
# the model (and any logging side-worker) sees it.
class ToolPrinter
  RESULT_WIDTH = 60

  def calls(conversation)
    conversation.pending_tool_calls.each do |tool_call|
      puts gray("  ⚙ #{tool_call.dig("function", "name")} #{tool_call.dig("function", "arguments")}")
    end
  end

  def results(conversation)
    messages = conversation.messages
    request = messages.rindex { |m| m["role"] == "assistant" }
    return unless request
    names = (messages[request]["tool_calls"] || [])
      .to_h { |tc| [tc["id"], tc.dig("function", "name")] }
    messages[(request + 1)..].each do |message|
      next unless message["role"] == "tool"
      summary = gray("#{names[message["tool_call_id"]]} → #{summarize(message["content"])}")
      puts "  #{CLI::UI.fmt("{{v}}")} #{summary}"
    end
  end

  private

  def summarize(text)
    line = text.to_s.gsub(/\s+/, " ").strip
    (line.length > RESULT_WIDTH) ? "#{line[0, RESULT_WIDTH - 1]}…" : line
  end
end
