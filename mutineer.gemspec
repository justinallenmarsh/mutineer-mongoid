# frozen_string_literal: true

require_relative "lib/mutineer/version"

Gem::Specification.new do |spec|
  spec.name          = "mutineer-mongoid"
  spec.version       = Mutineer::VERSION
  spec.authors       = ["David Teren", "Justin Allen Marsh"]
  spec.email         = ["48605824+justinallenmarsh@users.noreply.github.com"]
  spec.summary       = "Mutation testing with parallel Mongoid/RSpec support, based on Mutineer."
  spec.description   = "Mutineer mutates your source one change at a time and runs your Minitest or RSpec " \
                       "suite against each mutant to find tests that don't actually test anything. " \
                       "Prism-based, fork-isolated, zero runtime dependencies."
  spec.homepage      = "https://github.com/justinallenmarsh/mutineer-mongoid"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.4"

  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "documentation_uri" => "#{spec.homepage}#readme",
    "rubygems_mfa_required" => "true"
  }

  # bin/mutineer MUST be shipped, else the declared executable has no source file.
  spec.files       = Dir.glob("lib/**/*.rb") + Dir.glob("bin/*") + %w[README.md LICENSE CHANGELOG.md]
  spec.bindir      = "bin"
  spec.executables = ["mutineer"]
  spec.require_paths = ["lib"]

  # No runtime dependencies — Prism is bundled with Ruby >= 3.4.
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "yard", "~> 0.9"
end
