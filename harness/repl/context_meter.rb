# A one-line reading of how full the model's context is — "ctx: 2.4k/131k"
# — printed above each prompt.
#
# The numerator is the last reply's usage report (prompt + completion):
# what the next request will carry before the new user message. It
# counts the wire view, so abridgement's savings show up here. The
# denominator comes from the provider (lib/lyman/providers.rb), asked
# each time, since servers load and unload models on their own schedule;
# when an idle server has unloaded the model, the last known window
# stands in (it reloads at the same size on the next request). Before
# any reply the context is read as empty — 0 — and either side reads "?"
# when unknown (e.g. a resumed conversation, or a server that doesn't
# report usage).
class ContextMeter
  def initialize(provider, model)
    @provider = provider
    @model = model
  end

  def line(conversation)
    @window = @provider.context_window(@model) || @window
    "ctx: #{abbreviate(used(conversation))}/#{abbreviate(@window)}"
  end

  private

  def used(conversation)
    return 0 if conversation.elements.none? { |e| e.type == "assistant" }
    usage = conversation.usage or return nil
    usage["total_tokens"] || usage.values_at("prompt_tokens", "completion_tokens").compact.sum
  end

  def abbreviate(tokens)
    if tokens.nil? then "?"
    elsif tokens < 1_000 then tokens.to_s
    elsif tokens < 9_950 then format("%.1fk", tokens / 1_000.0)
    elsif tokens < 999_500 then "#{(tokens / 1_000.0).round}k"
    else format("%.1fM", tokens / 1_000_000.0)
    end
  end
end
