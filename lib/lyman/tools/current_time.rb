module Lyman
  module Tools
    # The demo tool the harnesses start with: proves the schema/handler
    # shape end-to-end without needing any dependency of its own. A factory,
    # not a constant, so every tool follows the same shape as
    # Lyman::Workers.* — and so a tool with dependencies (e.g. the recall
    # tool's `store:`) has somewhere to take keyword arguments.
    def self.current_time
      {
        schema: {
          "type" => "function",
          "function" => {
            "name" => "current_time",
            "description" => "Returns the current local date and time",
            "parameters" => {"type" => "object", "properties" => {}, "required" => []}
          }
        },
        handler: ->(_args) { Time.now.strftime("%Y-%m-%d %H:%M:%S %Z") }
      }
    end
  end
end
