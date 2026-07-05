require "shifty"

# Every planted module under lib/lyman/ loads here. `lyman add` drops new
# modules in place without this file ever needing an edit.
Dir[File.join(__dir__, "lyman", "**", "*.rb")].sort.each { |file| require file }

module Lyman
end
