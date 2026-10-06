# frozen_string_literal: true

require_relative "lib/wefunder/version"

Gem::Specification.new do |spec|
  spec.name = "wefunder"
  spec.version = Wefunder::VERSION
  spec.authors = ["Wefunder"]
  spec.email = ["api@wefunder.com"]
  spec.summary = "Official Ruby SDK for the Wefunder API"
  spec.description = "Client for the Wefunder API: OAuth (PKCE + client credentials) with refresh rotation, " \
                     "retries, auto-pagination, typed errors, and webhook verification."
  spec.homepage = "https://github.com/Wefunder/wefunder-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "documentation_uri" => "https://docs.wefunder.com",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  # The generated layer (lib/wefunder_generated, openapi-generator's faraday library) needs these.
  spec.add_dependency "faraday", ">= 1.0.1", "< 3.0"
  spec.add_dependency "faraday-multipart", "~> 1.0"
  spec.add_dependency "marcel", "~> 1.0"
end
