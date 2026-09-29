require "net/http"
require "json"
require "uri"

module Lyman
  # What a model server knows that the OpenAI-compatible surface doesn't
  # say. Chat completions go through the one shared wire format
  # (Workers.chat_completion); facts like the loaded context window live
  # only in each server's native API, and every server spells them
  # differently. A provider hides that difference behind one interface,
  # so a harness asks the same question whichever server it's talking to:
  #
  #   provider.name                  # => "ollama"
  #   provider.preload(model)        # load it now, not on the first request
  #   provider.context_window(model) # => 131072, or nil when unknown
  #
  # Servers settle a model's context window when they load it — not
  # always at its trained maximum — so the real figure exists only once
  # the model is resident. preload is how a harness gets it before the
  # first prompt; the load happens once either way, just sooner.
  #
  # Each provider takes the same base_url the harness hands chat_completion
  # (".../v1") and finds its native API beside it. Nothing here raises:
  # these facts feed displays and whether-to-act checks, and a server that
  # can't answer should read as "unknown", not crash a turn. A new server
  # is a new class with the same three methods — add it to DETECTION_ORDER
  # if it can be recognized by probing.
  module Providers
    # Any OpenAI-compatible server: chat works, nothing more is known.
    # Also the fallback when detection recognizes nothing.
    class OpenAICompatible
      OPEN_TIMEOUT = 1
      READ_TIMEOUT = 2
      # Loading a large model from disk can take a while.
      LOAD_TIMEOUT = 300

      attr_reader :base_url

      def initialize(base_url:)
        @base_url = base_url.chomp("/")
      end

      def name = "openai-compatible"

      # Nothing to ask the server to do; the first request loads the model.
      def preload(_model) = nil

      def context_window(_model) = nil

      # Whether a server at base_url answers this provider's native API.
      def self.recognizes?(_base_url) = true

      # The server root, where native APIs live beside the /v1 surface.
      def self.native_root(base_url) = base_url.chomp("/").delete_suffix("/v1")

      # GET (or, given a body, POST) a native endpoint; parsed JSON, or nil
      # for any failure.
      def self.request_json(url, body: nil, read_timeout: READ_TIMEOUT)
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = read_timeout
        response =
          if body
            http.post(uri.request_uri, JSON.generate(body), "Content-Type" => "application/json")
          else
            http.get(uri.request_uri)
          end
        response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body) : nil
      rescue
        nil
      end

      private

      def native(path, **) = self.class.request_json("#{self.class.native_root(base_url)}#{path}", **)
    end

    class Ollama < OpenAICompatible
      def name = "ollama"

      # An empty-prompt generate is Ollama's documented way to load a model
      # without running it; for a model already loaded, it just refreshes
      # the idle timer.
      def preload(model)
        native("/api/generate", body: {"model" => model}, read_timeout: LOAD_TIMEOUT)
        nil
      end

      # The answer comes from /api/ps (running models), not /api/show (the
      # model's trained maximum, which the runtime may not allot). Until
      # the model is loaded — before preload or the first request, or
      # after Ollama unloads it when idle — the window is unknown: nil.
      def context_window(model)
        wanted = tagged(model)
        running = native("/api/ps")&.fetch("models", nil) || []
        entry = running.find { |m| [m["name"], m["model"]].any? { |n| tagged(n) == wanted } }
        entry && entry["context_length"]
      end

      def self.recognizes?(base_url)
        request_json("#{native_root(base_url)}/api/version")&.key?("version") || false
      end

      private

      # "gemma4" and "gemma4:latest" name the same model.
      def tagged(model) = model.to_s.include?(":") ? model.to_s : "#{model}:latest"
    end

    class LMStudio < OpenAICompatible
      def name = "lmstudio"

      # Loading an already-loaded model would start a second instance of
      # it, so this loads only a model that isn't resident yet.
      def preload(model)
        entry = model_entry(model)
        return if entry.nil? || entry["state"] == "loaded"
        native("/api/v1/models/load", body: {"model" => model}, read_timeout: LOAD_TIMEOUT)
        nil
      end

      # LM Studio's REST API reports each model's loaded context length
      # alongside its maximum; only the loaded figure is the real window
      # (a model with a 64k maximum may load at 8k), so an unloaded model
      # reads as nil.
      def context_window(model)
        entry = model_entry(model)
        entry && entry["loaded_context_length"]
      end

      def self.recognizes?(base_url)
        request_json("#{native_root(base_url)}/api/v0/models")&.key?("data") || false
      end

      private

      # Listing all models (rather than GET /api/v0/models/{id}) sidesteps
      # ids containing slashes.
      def model_entry(model)
        models = native("/api/v0/models")&.fetch("data", nil) || []
        models.find { |m| m["id"] == model }
      end
    end

    # Probed in order; the first to recognize the server wins.
    DETECTION_ORDER = [Ollama, LMStudio].freeze

    # Probes base_url's native APIs to pick a provider, falling back to
    # OpenAICompatible. A convenience: when you know your server, name
    # its class directly and skip the probes.
    def self.detect(base_url)
      provider = DETECTION_ORDER.find { |klass| klass.recognizes?(base_url) } || OpenAICompatible
      provider.new(base_url: base_url)
    end
  end
end
