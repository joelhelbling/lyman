#!/usr/bin/env ruby
#
# The shell: state + a process. Deliberately boring.
#
# This file is the one legible wiring script — the circuit pattern from
# docs/design/circuit-pattern.md, wired filter-in: one `pipeline.shift`
# per turn, with all model⇄tool rounds happening inside the call.
#
# Everything the model does streams to the terminal as it happens —
# pre-tool narration, tool calls, the final answer. Fitting the display
# to the model (like hiding a <think> block) is this shell's job, not
# the library's.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "lyman"

# This is a top-level wiring script by design; mixing the DSL into main
# is the point, not an accident.
include Shifty::DSL # standard:disable Style/MixinUsage

$stdout.sync = true

BASE_URL = ENV.fetch("LYMAN_BASE_URL", "http://localhost:11434/v1")
MODEL = ENV.fetch("LYMAN_MODEL", "gemma4:latest")

# ── Tools: schema and handler side by side, guts on the outside ────────────
TOOLS = {
  "current_time" => {
    schema: {
      "type" => "function",
      "function" => {
        "name" => "current_time",
        "description" => "Returns the current local date and time",
        "parameters" => {"type" => "object", "properties" => {}, "required" => []}
      }
    },
    handler: ->(_args) { Time.now.strftime("%Y-%m-%d %H:%M:%S %Z") }
  }
}

schemas = TOOLS.values.map { |tool| tool[:schema] }
handlers = TOOLS.transform_values { |tool| tool[:handler] }

# ── Display: fitting this harness to its models ─────────────────────────────
# Everything from here to "Shell state" is presentation. Its dependencies —
# cli-ui for color and glyphs, reline (stdlib) for prompt line-editing and
# history — are confined to this section; restyle or delete freely without
# touching the circuit.
require "cli/ui"
require "reline"

# Styling codes used across streamed fragments, where CLI::UI.fmt can't help
# (fmt resets at the end of each call; a think preview arrives in pieces).
# Empty when piped, matching cli-ui's own no-tty behavior.
TTY = $stdout.tty?
GRAY = TTY ? CLI::UI.resolve_color(:gray).code : ""
DIM = TTY ? "\e[2;3m" : "" # faint italic, for think previews
RESET = TTY ? CLI::UI::Color::RESET.code : ""

# Paint without CLI::UI.fmt so text we don't control (tool arguments and
# results) can't be misread as {{markup}}.
def gray(text) = "#{GRAY}#{text}#{RESET}"

# Thinking models prefix replies with <think>...</think> (the worker
# normalizes separate-reasoning-field servers to the same convention). When
# the reply arrives one fragment at a time we can't regex the whole thing, so
# this streams a short preview of the thinking — the first few lines,
# rendered as a dim "✻ …" aside rather than the literal tags — then elides
# the rest once the model stops thinking.
#
# Emits [think_text, reply_text] pairs. Both stream straight to the terminal
# today, but the split is the seam for reply-side processing (a markdown
# renderer, say — mind that anything buffering the reply trades away its
# token-by-token streaming, which is why this harness doesn't ship one).
class ThinkFilter
  OPEN = "<think>"
  CLOSE = "</think>"
  MARK = "✻ "
  SNIPPET_LINES = 3
  SNIPPET_CHARS = 240 # think blocks are often one long unwrapped paragraph

  def initialize
    @state = :start
    @buffer = +""
    @lines = 0
    @chars = 0
    @truncated = false
  end

  # Returns the printable portion of this fragment as a
  # [think_text, reply_text] pair (either may be empty).
  def filter(fragment)
    @buffer << fragment
    case @state
    when :start then filter_start
    when :thinking then filter_thinking
    when :after_think then ["", filter_after_think]
    when :passing then ["", take_buffer]
    end
  end

  # Call when the message is complete: releases anything still held back
  # (e.g. a reply that was nothing but "<thin"), and closes out the styling
  # of a think block the model never closed itself.
  def flush
    case @state
    when :start then ["", take_buffer]
    when :thinking then [(@truncated ? "…" : "") + RESET, ""]
    else ["", ""]
    end
  end

  private

  def take_buffer
    out = @buffer
    @buffer = +""
    out
  end

  def filter_start
    if @buffer.start_with?(OPEN)
      @state = :thinking
      @buffer = @buffer[OPEN.length..]
      think, reply = filter_thinking
      [DIM + MARK + think, reply]
    elsif OPEN.start_with?(@buffer)
      ["", ""] # could still become <think>; wait for more
    else
      @state = :passing
      ["", take_buffer]
    end
  end

  def filter_thinking
    if (idx = @buffer.index(CLOSE))
      thought = @buffer[0...idx]
      @buffer = @buffer[(idx + CLOSE.length)..]
      @state = :after_think
      [snippet(thought) + (@truncated ? "…" : "") + RESET + "\n\n", filter_after_think]
    else
      # Keep any tail that could be the start of CLOSE split across
      # fragments; preview the rest.
      keep = partial_close_suffix
      thought = @buffer[0, @buffer.length - keep.length]
      @buffer = keep
      [snippet(thought), ""]
    end
  end

  # The leading portion of the thought that fits the preview budget.
  def snippet(text)
    return "" if @truncated
    out = +""
    text.each_char do |ch|
      if @chars >= SNIPPET_CHARS || (ch == "\n" && @lines >= SNIPPET_LINES - 1)
        @truncated = true
        break
      end
      out << ch
      @chars += 1
      @lines += 1 if ch == "\n"
    end
    out
  end

  # We end the think preview with "\n\n" ourselves, so swallow the model's
  # own whitespace between the close tag and the reply.
  def filter_after_think
    stripped = @buffer.lstrip
    if stripped.empty?
      @buffer = +""
      ""
    else
      @state = :passing
      @buffer = stripped
      take_buffer
    end
  end

  def partial_close_suffix
    (1...CLOSE.length).reverse_each do |len|
      tail = @buffer[-len, len]
      return tail if tail && CLOSE.start_with?(tail)
    end
    +""
  end
end

# The silence between sending a prompt and the first streamed token can be
# long on a local model (prefill). cli-ui's spinner owns the calling thread
# for the duration of a block, which can't express "spin until the first
# delta arrives" — so this is the one hand-rolled widget: a background
# spinner with a stop method. Quiet when output is piped.
class WaitSpinner
  FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏]

  def start(label)
    return unless TTY
    stop
    @thread = Thread.new do
      FRAMES.cycle do |frame|
        print "\r#{GRAY}#{frame} #{label}#{RESET}"
        sleep 0.08
      end
    end
  end

  def stop
    return unless @thread
    @thread.kill.join
    @thread = nil
    print "\r\e[K" # erase the spinner line
  end
end

# Streams one round's content to the terminal: a spinner while waiting on
# the model, then the model label before the first visible text — so silent
# rounds (pure tool calls) don't leave an empty prompt behind.
class RoundPrinter
  def initialize(label)
    @label = label
    @spinner = WaitSpinner.new
  end

  def start_round
    @think = ThinkFilter.new
    @printed = false
    @spinner.start("waiting for #{@label}…")
  end

  def delta(text)
    think, reply = @think.filter(text)
    emit(think)
    emit(reply)
  end

  def finish_round
    @spinner.stop
    think, reply = @think.flush
    emit(think)
    emit(reply)
    puts if @printed
  end

  private

  def emit(text)
    return if text.empty?
    @spinner.stop
    print CLI::UI.fmt("\n{{magenta:#{@label}}}> ") unless @printed
    @printed = true
    print text
  end
end

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

# ── Shell state ─────────────────────────────────────────────────────────────
conversation = Lyman::Conversation.new(
  system_prompt: "You are a helpful assistant. Keep replies brief. " \
    "Your replies are printed verbatim in a plain-text terminal: write prose, " \
    "and avoid markdown and LaTeX markup."
)
rounds = [] # the circuit's queue — visible right here, not smuggled
printer = RoundPrinter.new(MODEL)
tool_printer = ToolPrinter.new

# ── The circuit ─────────────────────────────────────────────────────────────
pipeline =
  source_worker { rounds.shift } |
  side_worker { |_c| printer.start_round } |
  Lyman::Workers.chat_completion(
    base_url: BASE_URL, model: MODEL, tools: schemas,
    on_delta: printer.method(:delta)
  ) |
  side_worker { |_c| printer.finish_round } |
  relay_worker { |c|
    c.finish! if c.pending_tool_calls.empty? || c.runaway?
    c
  } |
  side_worker { |c| tool_printer.calls(c) unless c.finished? } |
  Lyman::Workers.tool_execution(handlers) |
  side_worker { |c| tool_printer.results(c) unless c.finished? } |
  side_worker { |c| rounds << c unless c.finished? } |
  filter_worker { |c| c.finished? }

# ── Shell process ───────────────────────────────────────────────────────────
puts CLI::UI.fmt("{{bold:lyman}} ⇢ {{magenta:#{MODEL}}} @ {{blue:#{BASE_URL}}}")
puts
puts gray(<<~HINTS.gsub(/^/, "  "))
  exit:                 blank line, ctrl-c, or ctrl-d
  change the model:     LYMAN_MODEL=qwen3.5:2b #{$PROGRAM_NAME}
  change the endpoint:  LYMAN_BASE_URL=http://localhost:1234/v1 #{$PROGRAM_NAME}
  available tools:      #{TOOLS.keys.join(", ")} — a ⚙ line appears when the model calls one
HINTS

loop do
  puts
  # Reline gives the prompt line editing and history, but emits screen-
  # redraw escapes even when input is piped — so scripted runs get gets.
  input = begin
    if $stdin.tty?
      Reline.readline(CLI::UI.fmt("{{cyan:you}}> "), true)&.strip
    else
      print "you> "
      $stdin.gets&.strip
    end
  rescue Interrupt
    nil # ctrl-c leaves like ctrl-d, not with a stack trace
  end
  break if input.nil? || input.empty?

  rounds << conversation.add_user_message(input)
  pipeline.shift
end
