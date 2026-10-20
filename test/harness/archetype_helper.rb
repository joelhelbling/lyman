require "open3"
require "socket"
require "json"
require "timeout"

# Shared plumbing for driving the shipped archetype harnesses the way a
# terminal drives them: a real child process, real stdin/stdout/exit status,
# with a fake OpenAI-compatible endpoint standing in for the model. Tests
# assert on what a user would see — lines printed, prompts asked, status
# returned — never on the harness's internals.
module ArchetypeHelper
  REPO_ROOT = File.expand_path("../..", __dir__)

  # A port nothing listens on: the "server isn't running" first run.
  UNREACHABLE_BASE_URL = "http://127.0.0.1:1"

  # The signature of a Ruby backtrace ("file.rb:108:in 'Net::HTTP#request'").
  # A shell that handles a failure must not print one.
  TRACE_PATTERN = /\.rb:\d+:in/

  def run_harness(script, env: {}, args: [], stdin_data: "", timeout: 60)
    Timeout.timeout(timeout) do
      Open3.capture3(default_env.merge(env), RbConfig.ruby, File.join(REPO_ROOT, script), *args,
        stdin_data: stdin_data, chdir: REPO_ROOT)
    end
  end

  # Pin what the harnesses would otherwise inherit from whoever runs the
  # suite: a name for the model (the fake server answers any name) and an
  # endpoint no test means to use, so a test that forgets to pass one fails
  # loudly instead of reaching a real local server.
  def default_env
    {"LYMAN_MODEL" => "test-model", "LYMAN_BASE_URL" => UNREACHABLE_BASE_URL,
     "LYMAN_FILE_READER_MODEL" => "test-model"}
  end

  # Stands in for the model server. POSTs to .../chat/completions are
  # answered from +responses+ (an array of [status, body] pairs; the last
  # entry repeats), in order, and their request bodies recorded in +bodies+
  # so a test can see what each turn was actually sent. Everything else — a
  # provider probe — gets a 404, which is how Lyman::Providers.detect decides
  # the harness is talking to a generic OpenAI-compatible server.
  #
  # Returns [server, thread, base_url, bodies].
  def start_model_server(responses)
    server = TCPServer.new("127.0.0.1", 0)
    bodies = []
    index = 0

    thread = Thread.new do
      loop do
        client = server.accept
        method, path = client.gets.to_s.split(" ")
        headers = {}
        while (line = client.gets) && line != "\r\n"
          key, value = line.split(":", 2)
          headers[key.strip.downcase] = value.strip
        end
        request_body = (headers["content-length"].to_i > 0) ? client.read(headers["content-length"].to_i) : nil

        chat = method == "POST" && path.to_s.end_with?("/chat/completions")
        status, body = chat ? responses[[index, responses.size - 1].min] : ["404 Not Found", %({"error":"not found"})]
        content_type = "application/json"
        if chat
          index += 1
          bodies << JSON.parse(request_body)
          # The repl streams (chat_completion always passes on_delta), so a
          # canned chat-completion body has to arrive as SSE chunks instead.
          if JSON.parse(request_body)["stream"] && status.start_with?("2")
            body, content_type = sse_body(body), "text/event-stream"
          end
        end

        client.write("HTTP/1.1 #{status}\r\nContent-Type: #{content_type}\r\n" \
          "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      rescue IOError, Errno::EBADF
        break
      end
    end

    [server, thread, "http://127.0.0.1:#{server.addr[1]}", bodies]
  end

  # One delta chunk carrying the whole message, then the trailing usage
  # chunk a server honoring stream_options.include_usage sends.
  def sse_body(chat_completion_json)
    message = JSON.parse(chat_completion_json).dig("choices", 0, "message")
    return chat_completion_json unless message

    delta = {"role" => "assistant"}
    delta["content"] = message["content"] if message["content"]
    message["tool_calls"]&.each_with_index { |call, index| (delta["tool_calls"] ||= []) << call.merge("index" => index) }

    chunks = [{"choices" => [{"delta" => delta}]}]
    chunks << {"choices" => [], "usage" => {"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}}
    chunks.map { |chunk| "data: #{chunk.to_json}\n\n" }.join + "data: [DONE]\n\n"
  end

  def stop_server(server, thread)
    server&.close
    thread&.join(5)
  end

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  def assistant_reply(text)
    ["200 OK", {"choices" => [{"message" => {"role" => "assistant", "content" => text}}]}.to_json]
  end

  def error_reply(status, message)
    [status, {"error" => {"message" => message}}.to_json]
  end
end
