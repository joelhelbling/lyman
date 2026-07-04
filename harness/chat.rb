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

include Shifty::DSL

$stdout.sync = true

BASE_URL = ENV.fetch("LYMAN_BASE_URL", "http://localhost:11434/v1")
MODEL    = ENV.fetch("LYMAN_MODEL", "gemma4:latest")

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

schemas  = TOOLS.values.map { |tool| tool[:schema] }
handlers = TOOLS.transform_values { |tool| tool[:handler] }

# ── Display: fitting this harness to its models ─────────────────────────────

# Thinking models prefix replies with <think>...</think> (the worker
# normalizes separate-reasoning-field servers to the same convention). When
# the reply arrives one fragment at a time we can't regex the whole thing, so
# this streams a short preview of the thinking — the first few lines — then
# elides the rest, closing with "...</think>" once the model stops thinking.
class ThinkFilter
  OPEN = "<think>"
  CLOSE = "</think>"
  SNIPPET_LINES = 3
  SNIPPET_CHARS = 240 # think blocks are often one long unwrapped paragraph

  def initialize
    @state = :start
    @buffer = +""
    @lines = 0
    @chars = 0
    @truncated = false
  end

  # Returns the printable portion of this fragment.
  def filter(fragment)
    @buffer << fragment
    case @state
    when :start then filter_start
    when :thinking then filter_thinking
    when :after_think then filter_after_think
    when :passing then take_buffer
    end
  end

  # Call when the message is complete: releases anything still held back
  # (e.g. a reply that was nothing but "<thin"), and closes a think block
  # the model never closed itself.
  def flush
    case @state
    when :start then take_buffer
    when :thinking then (@truncated ? "..." : "") + CLOSE
    else ""
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
      OPEN + filter_thinking
    elsif OPEN.start_with?(@buffer)
      "" # could still become <think>; wait for more
    else
      @state = :passing
      take_buffer
    end
  end

  def filter_thinking
    if (idx = @buffer.index(CLOSE))
      thought = @buffer[0...idx]
      @buffer = @buffer[(idx + CLOSE.length)..]
      @state = :after_think
      snippet(thought) + (@truncated ? "..." : "") + CLOSE + "\n\n" + filter_after_think
    else
      # Keep any tail that could be the start of CLOSE split across
      # fragments; preview the rest.
      keep = partial_close_suffix
      thought = @buffer[0, @buffer.length - keep.length]
      @buffer = keep
      snippet(thought)
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

  # We print "</think>\n\n" ourselves, so swallow the model's own
  # whitespace between the close tag and the reply.
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

# Streams one round's content to the terminal, printing the model label
# before the first visible text so silent rounds (pure tool calls) don't
# leave an empty prompt behind.
class RoundPrinter
  def initialize(label)
    @label = label
  end

  def start_round
    @filter = ThinkFilter.new
    @printed = false
  end

  def delta(text)
    emit(@filter.filter(text))
  end

  def finish_round
    emit(@filter.flush)
    puts if @printed
  end

  private

  def emit(text)
    return if text.empty?
    print "\n#{@label}> " unless @printed
    @printed = true
    print text
  end
end

# ── Shell state ─────────────────────────────────────────────────────────────
conversation = Lyman::Conversation.new(
  system_prompt: "You are a helpful assistant. Keep replies brief."
)
rounds = [] # the circuit's queue — visible right here, not smuggled
printer = RoundPrinter.new(MODEL)

# ── The circuit ─────────────────────────────────────────────────────────────
pipeline =
  source_worker { rounds.shift }                                             |
  side_worker { |_c| printer.start_round }                                   |
  Lyman::Workers.chat_completion(
    base_url: BASE_URL, model: MODEL, tools: schemas,
    on_delta: printer.method(:delta)
  )                                                                          |
  side_worker { |_c| printer.finish_round }                                  |
  relay_worker { |c| c.finish! if c.pending_tool_calls.empty? || c.runaway?; c } |
  side_worker do |c|
    c.pending_tool_calls.each do |tc|
      puts "  ⚙ #{tc.dig("function", "name")} #{tc.dig("function", "arguments")}"
    end unless c.finished?
  end                                                                        |
  Lyman::Workers.tool_execution(handlers)                                    |
  side_worker { |c| rounds << c unless c.finished? }                         |
  filter_worker { |c| c.finished? }

# ── Shell process ───────────────────────────────────────────────────────────
puts <<~PREAMBLE
  lyman ⇢ #{MODEL} @ #{BASE_URL}

    exit:      blank line or ctrl-d
    model:     LYMAN_MODEL=qwen3.5:2b #{$PROGRAM_NAME}
    endpoint:  LYMAN_BASE_URL=http://localhost:1234/v1 #{$PROGRAM_NAME}
    tools:     #{TOOLS.keys.join(", ")} — a ⚙ line appears when the model calls one

PREAMBLE

loop do
  print "\nyou> "
  input = $stdin.gets&.strip
  break if input.nil? || input.empty?

  rounds << conversation.add_user_message(input)
  pipeline.shift
end
