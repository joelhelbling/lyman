require_relative "../test_helper"
require "shifty"
require "lyman"
require "socket"
require "json"
require_relative "../../harness/compactor"

# Drives the compaction sidecar the way a root harness does: a real thread
# running run_compactor, fed by compaction_feed from a root circuit, asked
# for compaction through Lyman::Compaction.request — with a fake
# OpenAI-compatible endpoint standing in for the digest model.
class CompactorTest < Minitest::Test
  include Shifty::DSL

  # Answers every chat completion request with +content+ (or a 500 when
  # content is nil), recording each request body. Runs until closed.
  def start_digest_server(content, bodies)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        client = server.accept
        headers = {}
        client.gets
        while (line = client.gets) && line != "\r\n"
          key, value = line.split(":", 2)
          headers[key.strip.downcase] = value.strip
        end
        bodies << JSON.parse(client.read(headers["content-length"].to_i))

        body, status =
          if content
            [{"choices" => [{"message" => {"role" => "assistant", "content" => content}}]}.to_json, "200 OK"]
          else
            ["boom", "500 Internal Server Error"]
          end
        client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
          "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      rescue IOError, Errno::EBADF
        break
      end
    end
    [server, thread, "http://127.0.0.1:#{server.addr[1]}"]
  end

  def root_turn(conversation, user, reply)
    conversation.with_user_message(user).with_assistant_message({"role" => "assistant", "content" => reply})
  end

  def with_sidecar(content)
    bodies = Thread::Queue.new
    server, server_thread, base_url = start_digest_server(content, bodies)
    inbox = Thread::Queue.new
    compactor = Thread.new { run_compactor(inbox, base_url: base_url, model: "tiny") }

    yield inbox, bodies
  ensure
    # Server first: a join below that re-raises a dead sidecar's error
    # must not leave the server thread blocked in accept.
    server&.close
    server_thread&.join(5)
    inbox&.close
    compactor&.join(5)
  end

  def test_keeps_a_ledger_while_the_root_talks_then_hands_back_a_compacted_child
    digest = '[{"kind": "fact", "text": "The user is Joel.", "sources": [1]}]'

    with_sidecar(digest) do |inbox, bodies|
      root = Lyman::Conversation.new(system_prompt: "You are helpful.")
      first = root_turn(root, "My name is Joel.", "Hi Joel.")
      second = root_turn(first, "What's 2+2?", "4")

      feed = source_worker([first, second]) | Lyman::Workers.compaction_feed(inbox)
      2.times { feed.shift }

      compacted = Lyman::Compaction.request(inbox, second, timeout: 5)

      refute_same second, compacted, "the sidecar answered rather than timing out"
      assert_equal second.id, compacted.parent_id
      system = compacted.elements.first.content["text"]
      assert system.start_with?("You are helpful.")
      assert_includes system, "The user is Joel. [conv:#{second.id}#"
      assert_equal ["What's 2+2?", "4"], compacted.elements.drop(1).map { |e| e.content["text"] }

      request = bodies.pop(timeout: 1)
      assert_equal "tiny", request["model"]
      assert_includes request["messages"].first["content"], "keep a ledger"
    end
  end

  def test_a_failing_digest_model_leaves_a_gap_not_a_dead_sidecar
    with_sidecar(nil) do |inbox, _bodies|
      conversation = root_turn(Lyman::Conversation.new(system_prompt: "sys"), "hello", "hi")
      conversation.elements.each { |element| inbox << element }

      compacted = nil
      _out, err = capture_io { compacted = Lyman::Compaction.request(inbox, conversation, timeout: 5) }

      assert_includes err, "digest failed"
      system = compacted.elements.first.content["text"]
      assert_includes system, "Not summarized"
      assert_includes system, "conv:#{conversation.id}#2-3"
    end
  end
end
