require_relative "lib/lyman/cli/version"

Gem::Specification.new do |spec|
  spec.name = "lyman"
  spec.version = Lyman::CLI::VERSION
  spec.authors = ["Joel Helbling"]
  spec.email = ["joel.helbling@gmail.com"]

  spec.summary = "A composable agentic harness, delivered as code you own — " \
    "a pure generator in the shadcn/ui mold, built on shifty"
  spec.homepage = "https://github.com/joelhelbling/lyman"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage

  # lyman is a pure generator (see docs/design/deployment.md): the gem plants
  # legible source into client projects rather than being required by them
  # forever. Everything shipped here is either CLI machinery or plantable
  # inventory — the registry (lib/lyman/cli/registry.rb) says which is which.
  spec.files = Dir[
    "lib/**/*", "harness/**/*", "templates/**/*", "exe/*",
    "LICENSE", "README.md", "docs/**/*"
  ].select { |f| File.file?(f) }

  spec.bindir = "exe"
  spec.executables = ["lyman"]
  spec.require_paths = ["lib"]

  # 0.6 is shifty's handoff-immutability release — values are deeply frozen
  # at worker boundaries — and the planted Conversation and workers are
  # written for that world.
  spec.add_dependency "shifty", "~> 0.6"
  spec.add_dependency "ostruct" # shifty dependency; no longer a default gem in ruby 4
  spec.add_dependency "thor"
end
