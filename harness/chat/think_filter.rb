require_relative "style"

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
