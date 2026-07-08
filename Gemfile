source "https://rubygems.org"

gemspec

# Not a dependency of the lyman gem itself — the shipped harness's display
# layer uses it, so this repo needs it to run harness/chat.rb.
gem "cli-ui"
gem "reline"

group :development, :test do
  gem "standard", require: false
  gem "rake"
  gem "minitest"
end
