require "cli/ui"
require_relative "think_filter"
require_relative "wait_spinner"

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
