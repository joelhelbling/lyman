require "cli/ui"

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
