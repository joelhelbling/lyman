# Demo for the lyman README: scaffold a project, run the repl harness,
# watch a model⇄tool round stream by. Requires vhs (brew install vhs),
# Ollama running locally with the default model pulled, and the lyman
# gem installed. Record from an empty scratch directory (`lyman new`
# plants a project where it runs), then copy the gif back here:
#
#   cd $(mktemp -d) && vhs path/to/demo/demo.tape && cp demo.gif path/to/demo/
Output demo.gif

Set Shell "bash"
Set FontSize 13
Set Width 1000
Set Height 600
Set Padding 16
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms

Type "lyman new time-teller"
Enter
Sleep 2.5s

Type "cd time-teller && bundle install"
Enter
Sleep 5s

Type "ruby harness/repl.rb"
Enter
Sleep 2s

Type "What time is it right now?"
Enter
Sleep 10s

Enter
Sleep 4s
