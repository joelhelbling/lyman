require_relative "test_helper"
require "lyman"
require "socket"
require "json"

class ProvidersTest < Minitest::Test
  # A stdlib HTTP server answering from +routes+ ("/path" or "POST /path"
  # => JSON-able body, or a callable producing one); any other request
  # gets a 404, the way each real server answers the other's native
  # endpoints. Every request lands in +log+ as [method, path, parsed
  # body]. Yields the OpenAI-style base_url.
  def with_fake_server(routes, log = [])
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        client = server.accept
        method, path = client.gets.to_s.split
        length = 0
        while (line = client.gets) && line != "\r\n"
          key, value = line.split(":", 2)
          length = value.to_i if key.casecmp?("content-length")
        end
        log << [method, path, (length > 0) ? JSON.parse(client.read(length)) : nil]
        route = routes[(method == "GET") ? path : "#{method} #{path}"]
        route = route.call if route.respond_to?(:call)
        body = route ? JSON.generate(route) : "not found"
        status = route ? "200 OK" : "404 Not Found"
        client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
          "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      end
    rescue IOError
      # server closed: done
    end
    yield "http://127.0.0.1:#{server.addr[1]}/v1"
  ensure
    server&.close
    thread&.join
  end

  OLLAMA = {
    "/api/version" => {"version" => "0.34.4"},
    "/api/ps" => {"models" => [{"name" => "gemma4:latest", "model" => "gemma4:latest", "context_length" => 131_072}]}
  }.freeze

  LMSTUDIO = {
    "/api/v0/models" => {"data" => [
      {"id" => "qwen/qwen3.8-27b", "state" => "loaded", "max_context_length" => 262_144, "loaded_context_length" => 32_768},
      {"id" => "idle-model", "state" => "not-loaded", "max_context_length" => 262_144}
    ]}
  }.freeze

  def test_detects_ollama_and_reports_the_loaded_context_window
    with_fake_server(OLLAMA) do |base_url|
      provider = Lyman::Providers.detect(base_url)
      assert_equal "ollama", provider.name
      assert_equal 131_072, provider.context_window("gemma4:latest")
      assert_equal 131_072, provider.context_window("gemma4"), "an untagged name means :latest"
      assert_nil provider.context_window("mistral:latest"), "a model that isn't loaded has no window yet"
    end
  end

  def test_detects_lmstudio_and_reports_the_loaded_not_maximum_context_window
    with_fake_server(LMSTUDIO) do |base_url|
      provider = Lyman::Providers.detect(base_url)
      assert_equal "lmstudio", provider.name
      assert_equal 32_768, provider.context_window("qwen/qwen3.8-27b")
      assert_nil provider.context_window("idle-model")
    end
  end

  def test_falls_back_to_a_generic_provider_that_knows_no_window
    with_fake_server({}) do |base_url|
      provider = Lyman::Providers.detect(base_url)
      assert_equal "openai-compatible", provider.name
      assert_nil provider.context_window("anything")
    end
  end

  def test_an_unreachable_server_reads_as_unknown_rather_than_raising
    port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] } # bound, then released
    base_url = "http://127.0.0.1:#{port}/v1"

    assert_equal "openai-compatible", Lyman::Providers.detect(base_url).name
    assert_nil Lyman::Providers::Ollama.new(base_url: base_url).context_window("gemma4")
    assert_nil Lyman::Providers::LMStudio.new(base_url: base_url).context_window("gemma4")
    assert_nil Lyman::Providers::Ollama.new(base_url: base_url).preload("gemma4")
  end

  def test_ollama_preload_loads_the_model_so_its_window_is_known_before_any_prompt
    loaded = false
    routes = {
      "POST /api/generate" => -> {
        loaded = true
        {"done" => true, "done_reason" => "load"}
      },
      "/api/ps" => -> { {"models" => loaded ? OLLAMA["/api/ps"]["models"] : []} }
    }
    log = []
    with_fake_server(routes, log) do |base_url|
      provider = Lyman::Providers::Ollama.new(base_url: base_url)
      assert_nil provider.context_window("gemma4")

      provider.preload("gemma4")

      assert_includes log, ["POST", "/api/generate", {"model" => "gemma4"}], "an empty-prompt generate, which only loads"
      assert_equal 131_072, provider.context_window("gemma4")
    end
  end

  def test_lmstudio_preload_loads_only_a_model_that_isnt_loaded
    log = []
    routes = LMSTUDIO.merge("POST /api/v1/models/load" => {"status" => "loaded"})
    with_fake_server(routes, log) do |base_url|
      provider = Lyman::Providers::LMStudio.new(base_url: base_url)
      provider.preload("qwen/qwen3.8-27b") # already loaded: a second load would start a second instance
      provider.preload("idle-model")
    end

    loads = log.select { |method, _, _| method == "POST" }
    assert_equal [["POST", "/api/v1/models/load", {"model" => "idle-model"}]], loads
  end

  def test_the_generic_provider_preload_does_nothing
    log = []
    with_fake_server({}, log) do |base_url|
      Lyman::Providers::OpenAICompatible.new(base_url: base_url).preload("m")
    end
    assert_empty log
  end
end
