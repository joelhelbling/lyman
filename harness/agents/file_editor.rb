#
# The file editor agent: a tool the main model calls to change files
# instead of patching them itself — the write-side twin of
# harness/agents/file_reader.rb. Like the reader, it's the SCRIPT
# archetype (see docs/design/harness-archetypes.md) run *inside a tool
# handler*: the tool-call args play ARGV, the return value plays stdout.
# See docs/design/tools-and-agents.md ("Patching", "The file editor").
#
# The point is the reader's, in both directions now: the SUB-agent spends
# its context finding the code, reading it, and writing exact patches, so
# raw file text never crosses into the caller's context — neither going
# in (the caller describes a change, it doesn't quote the lines) nor
# coming back (the reply says what changed, not how). And one point the
# reader doesn't have: small local models are bad at reproducing exact
# context lines, so turning an imprecise intent ("in #bar, make the loop
# a map") into a patch that actually applies is work worth delegating.
#
# Tests are deliberately out of its reach. The sub-agent may fix its own
# patch and check failures (the round counter bounds that loop), but it
# must never "fix" a failing test by bending the code — or the test — to
# pass. That's enforced structurally, not by prompt: its circuit has no
# tool that runs tests, and the tests run in a plain worker AFTER the
# circuit finishes, so their outcome can't reach the model at all. The
# test output goes to the caller, whose call it is what to do next.
#
# This file is yours: the sub-agent's prompt (FILE_EDITOR_INSTRUCTIONS),
# its tools, its model, and its patch format are the editing *strategy* —
# a different strategy is a different version of this file, not a mode.
# To have it write unified diffs instead of search/replace blocks, change
# the one line in FileEditor.delegate that builds the patch tool to
# Lyman::Tools.apply_diff.
#
# Wiring it into a root harness (e.g. harness/repl.rb):
#
#   require_relative "agents/file_editor"
#
#   TOOLS = [
#     file_editor(root: Dir.pwd, check: CHECK_COMMAND, test: TEST_COMMAND,
#       default_model: MODEL, default_base_url: BASE_URL)
#   ]
#
# Pass `trace:` to observe the sub-agent's inner rounds, the same way as
# file_reader's.

# require_relative, not the load path: these are files planted beside this
# script, not the lyman gem.
require_relative "../../lib/lyman"
require "open3"
require "shellwords"

# This is a top-level wiring script by design; mixing the DSL into main
# is the point, not an accident.
include Shifty::DSL # standard:disable Style/MixinUsage

# What the sub-agent is told on every call. It never sees the caller's
# conversation, so this is the whole of its context beyond the request —
# kept tight since local small models read it every call.
FILE_EDITOR_INSTRUCTIONS = <<~TEXT
  You change files on behalf of another assistant. Your reply is the ONLY
  thing that assistant sees — everything else (your searches, your reads,
  your patches) is discarded.

  Locate the code with search_files, read it with read_file using a line
  range, then patch it with search_replace, copying the search text
  exactly from what you read.

  Make exactly the change asked for — nothing more. No unrelated
  refactoring, renaming, or reformatting.

  A reply starting "Patched" or "Created" means the edit landed, even if
  a check failure follows — never send the same patch again. Fix only
  what your change caused: if the findings don't name a line you changed,
  or give no detail at all, treat them as pre-existing — stop patching,
  finish, and say the check still fails. If a patch is refused, re-read
  those lines and retry with the exact text.

  You cannot run tests and must not try to; someone else runs them after
  you finish.

  When done, reply in one or two plain sentences saying what you changed,
  naming the files. No code, no markdown fences. If the change can't be
  made, say why in one line.
TEXT

# root: confines the sub-agent's tools to one directory, the same way the
# harness's own file tools are confined. check: is handed on to the patch
# tool (see lib/lyman/tools/patch.rb for its forms); test: is a command
# String/Array run from root, a callable returning nil (pass) or a failure
# string, or nil for no tests. Both are fixed here, at wiring time — the
# model never supplies any part of them. model:/base_url: resolve like
# file_reader's: explicit argument, then an env override, then the
# harness's own default, which the harness hands in.
def file_editor(default_model:, default_base_url:, root: Dir.pwd, check: "bundle exec standardrb",
  test: "bundle exec rake test", model: nil, base_url: nil, max_rounds: 12, trace: nil)
  model ||= ENV["LYMAN_FILE_EDITOR_MODEL"] || default_model
  base_url ||= ENV["LYMAN_FILE_EDITOR_BASE_URL"] || default_base_url
  confined_root = File.realpath(root)
  # Normalized now so a bad check:/test: fails at wiring time, not on the
  # model's first call.
  checker = Lyman::Tools::Patch.checker(check, root: confined_root)
  tester = FileEditor.test_runner(test, root: confined_root)
  # Named in the schema only when set, and only when they're commands a
  # model can recognize — a callable has no useful name to show.
  check_note = " (running `#{Array(check).join(" ")}` on each changed file)" if check.is_a?(String) || check.is_a?(Array)
  test_note =
    if test.is_a?(String) || test.is_a?(Array)
      ", since the tests (`#{Array(test).join(" ")}`) run after each call"
    elsif tester
      ", since the tests run after each call"
    end

  {
    schema: {
      "type" => "function",
      "function" => {
        "name" => "file_editor",
        "description" => "Change files instead of patching them yourself. Pass `request` describing " \
          "the change — a sub-agent with its own tools finds the code, writes exact edits, and applies " \
          "them#{check_note}, so file text never enters your context. Prefer one small, coherent change " \
          "per call#{test_note}.#{" It will not fix failing tests — what to do about them is your call." if tester} " \
          "The reply lists the changed files and any check failures that remain" \
          "#{", plus test output if the tests failed" if tester}.",
        "parameters" => {
          "type" => "object",
          "properties" => {
            "request" => {
              "type" => "string",
              "description" => "The change to make: where (path, method, section) when you know it, " \
                "and what should be different."
            }
          },
          "required" => ["request"]
        }
      }
    },
    handler: ->(args) {
      FileEditor.handle(args, root: confined_root, checker: checker, tester: tester,
        model: model, base_url: base_url, max_rounds: max_rounds, trace: trace)
    }
  }
end

module FileEditor
  MAX_TEST_OUTPUT = 4_000

  # What the trailing stages hand on once the circuit has finished: the
  # finished conversation plus what happened to the files. A Data value,
  # since shifty deep-freezes every handoff anyway. tests_run: false means
  # the tests were skipped (nothing changed, or no runner), not that they
  # passed.
  Outcome = Data.define(:conversation, :changed, :check_failures, :tests_run, :test_failure)

  def self.handle(args, root:, checker:, tester:, model:, base_url:, max_rounds:, trace:)
    request = args["request"].to_s.strip
    return "Pass a request describing the change to make." if request.empty?

    delegate(request, root: root, checker: checker, tester: tester, model: model, base_url: base_url,
      max_rounds: max_rounds, trace: trace)
  end

  # The script archetype, built fresh per call: a fresh Conversation, a
  # fresh rounds queue, a fresh change list, a fresh pipeline. An error
  # raised inside a shifty pipeline ends it for good, and each call must
  # forget the last — a memory is a splice, not a default.
  def self.delegate(request, root:, checker:, tester:, model:, base_url:, max_rounds:, trace:)
    changed = [] # closure state: mutable here, only handed-off values freeze

    patch_tool = Lyman::Tools.search_replace(root: root, check: checker)
    tools = [
      Lyman::Tools.search_files(root: root),
      Lyman::Tools.read_file(root: root),
      tracking(patch_tool, changed, root: root)
    ]
    schemas = tools.map { |tool| tool[:schema] }
    handlers = tools.to_h { |tool| [tool[:schema].dig("function", "name"), tool[:handler]] }

    conversation = Lyman::Conversation.new(system_prompt: FILE_EDITOR_INSTRUCTIONS, max_rounds: max_rounds)
    rounds = [] # the circuit's queue — visible right here, not smuggled

    # The model⇄tool circuit is everything up to the filter; the two
    # stages after it run once, on the finished conversation, outside the
    # loop. That placement IS the guarantee that the sub-agent never sees
    # test results: nothing downstream of the filter feeds back into
    # `rounds`, so no model request can ever carry them.
    pipeline =
      source_worker { rounds.shift } |
      Lyman::Workers.chat_completion(base_url: base_url, model: model, tools: schemas) |
      relay_worker { |c| (c.pending_tool_calls.empty? || c.runaway?) ? c.finish : c } |
      Lyman::Workers.tool_execution(handlers) |
      side_worker { |c| trace&.call(c) } |
      side_worker { |c| rounds << c unless c.finished? } |
      filter_worker { |c| c.finished? } |
      # The agent may have given up on a check failure; re-check what it
      # touched so the caller hears about any that remain.
      relay_worker { |c|
        Outcome.new(conversation: c, changed: changed.dup, check_failures: recheck(changed, checker, root: root),
          tests_run: false, test_failure: nil)
      } |
      relay_worker { |outcome|
        next outcome if outcome.changed.empty? || tester.nil?
        outcome.with(tests_run: true, test_failure: run_tests(tester))
      }

    # Enqueue before shifting — never pull the source while the queue is
    # empty (the nil footgun: a nil from a source ends the stream
    # permanently).
    rounds << conversation.with_user_message(request)
    report(pipeline.shift, max_rounds: max_rounds)
  end

  # Wraps the patch tool's handler to record which files it actually
  # changed, by comparing the file before and after — not by parsing the
  # tool's reply, whose wording is the patch tool's business. A path that
  # doesn't resolve inside root is left to the patch handler to refuse.
  def self.tracking(tool, changed, root:)
    patch = tool[:handler]
    handler = ->(args) {
      abs = Lyman::Tools::Patch.resolve_under_root(args["path"].to_s, root: root) unless args["path"].to_s.strip.empty?
      before = snapshot(abs)
      result = patch.call(args)
      if abs && snapshot(abs) != before
        rel = abs.delete_prefix("#{root}#{File::SEPARATOR}")
        changed << rel unless changed.include?(rel)
      end
      result
    }
    tool.merge(handler: handler)
  end

  def self.snapshot(abs)
    return nil unless abs && File.file?(abs)
    File.binread(abs)
  rescue SystemCallError
    nil
  end

  # [[path, findings], ...] for changed files that still fail the check.
  def self.recheck(changed, checker, root:)
    return [] unless checker
    changed.filter_map do |rel|
      abs = File.join(root, rel)
      next unless File.file?(abs)
      findings = begin
        checker.call(abs).to_s.strip
      rescue => e
        "the check raised #{e.class}: #{e.message}"
      end
      next if findings.empty?
      max = Lyman::Tools::Patch::MAX_CHECK_OUTPUT
      findings = "#{findings[0, max]}\n[check output truncated]" if findings.length > max
      [rel, findings]
    end
  end

  # Normalizes test: once, at factory time, into nil or a callable taking
  # no arguments and returning nil (pass) or a failure string. Commands
  # run as an argv from root, never through a shell.
  def self.test_runner(test, root:)
    case test
    when nil then nil
    when String, Array
      argv = test.is_a?(String) ? Shellwords.split(test) : test.map(&:to_s)
      raise ArgumentError, "test: command is empty" if argv.empty?
      -> { run_command(argv, root: root) }
    else
      raise ArgumentError, "test: must be a command String/Array, a callable, or nil" unless test.respond_to?(:call)
      test
    end
  end

  def self.run_command(argv, root:)
    output, status = Open3.capture2e(*argv, chdir: root)
    status.success? ? nil : "exit #{status.exitstatus}\n#{output.strip}"
  rescue SystemCallError => e
    "could not run `#{argv.join(" ")}`: #{e.message}"
  end

  # Keeps the tail: test runners print their failure summary last.
  def self.run_tests(tester)
    output = begin
      tester.call.to_s.strip
    rescue => e
      "the test run raised #{e.class}: #{e.message}"
    end
    return nil if output.empty?
    return output if output.length <= MAX_TEST_OUTPUT
    "[test output truncated]\n#{output[-MAX_TEST_OUTPUT..]}"
  end

  # No news is good news: what changed and anything still failing; test
  # output only when the tests failed.
  def self.report(outcome, max_rounds:)
    c = outcome.conversation
    lines = []
    # Tool calls still pending means the round counter cut the circuit off
    # mid-work — and unlike the reader, files may already have changed,
    # so the rest of the report still follows.
    if c.pending_tool_calls.any?
      lines << "file_editor stopped after #{max_rounds} rounds before finishing — the change may be partial."
    else
      reply = c.last_assistant_content.to_s.strip
      lines << (reply.empty? ? "file_editor finished without a summary." : reply)
    end

    lines << (outcome.changed.empty? ? "No files were changed." : "Changed: #{outcome.changed.join(", ")}")
    unless outcome.check_failures.empty?
      lines << "Check still failing —"
      outcome.check_failures.each { |path, findings| lines << "#{path}:\n#{findings}" }
    end
    if outcome.tests_run
      lines << (outcome.test_failure ? "Tests: failed —\n#{outcome.test_failure}" : "Tests: passed.")
    end
    lines.join("\n")
  end
end

if __FILE__ == $PROGRAM_NAME
  # ruby harness/agents/file_editor.rb "REQUEST"
  #
  # Standalone run: tune the sub-agent (its prompt, its model, its tools)
  # and watch it work without going through the main model at all —
  # stdout is just the report, and a trace of inner tool activity goes to
  # stderr. It edits files under the current directory for real, and runs
  # the factory's default check and test commands there.
  request = ARGV.join(" ")
  abort "usage: #{$PROGRAM_NAME} REQUEST" if request.strip.empty?

  default_model = ENV.fetch("LYMAN_MODEL", "gemma4:latest")
  default_base_url = ENV.fetch("LYMAN_BASE_URL", "http://localhost:11434/v1")
  # trace: fires after tool_execution, so this round's calls are already
  # answered — list the tool_call elements since the last assistant reply.
  trace = ->(c) {
    reply_start = c.elements.rindex { |e| e.type == "assistant" }
    c.elements[(reply_start + 1)..].each do |e|
      next unless e.type == "tool_call"
      warn "  ⚙ #{e.content.dig("function", "name")} #{e.content.dig("function", "arguments")}"
    end
  }

  tool = file_editor(root: Dir.pwd, default_model: default_model, default_base_url: default_base_url, trace: trace)
  puts tool[:handler].call({"request" => request})
end
