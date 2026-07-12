require_relative "style"

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
