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

  # standard -> rubocop-performance -> parallel, and every parallel 2.x
  # requires Ruby >= 3.3. The lockfile has to resolve at the declared floor
  # or CI's 3.2 job cannot install the bundle at all (issue #37).
  gem "parallel", "< 2"
end

# Not a gemspec dependency either — the store is optional plantable
# inventory (lib/lyman/store.rb), but this repo needs it to run and test
# that artifact against real SQLite.
gem "sqlite3"
