# frozen_string_literal: true

require "json"
require "wefunder"

# A Faraday adapter driven by a callable: handler.call(env) -> [status, headers, body] or raises.
class ScriptedAdapter < Faraday::Adapter
  def initialize(app, handler)
    super(app)
    @handler = handler
  end

  def call(env)
    super
    status, headers, body = @handler.call(env)
    save_response(env, status, body.to_s, headers || {})
    @app.call(env)
  end
end

module SpecSupport
  ROOT = File.expand_path("..", __dir__)

  def self.vector(name) = JSON.parse(File.read(File.join(ROOT, "conformance", name)))

  # +expected+ keys must match +actual+ (Hash or object); nil in expected means absent-or-nil.
  def self.expect_subset(actual, expected, path = "")
    expected.each do |key, value|
      got = actual.is_a?(Hash) ? (actual[key] || actual[key.to_sym]) : actual.public_send(key)
      where = path.empty? ? key : "#{path}.#{key}"
      if value.nil?
        raise "#{where}: expected nil, got #{got.inspect}" unless got.nil?
      elsif value.is_a?(Hash) && got.is_a?(Hash)
        expect_subset(got, value, where)
      else
        raise "#{where}: expected #{value.inspect}, got #{got.inspect}" unless got == value
      end
    end
  end

  # Build a faraday configurer that routes everything to +handler+.
  def self.faraday_for(handler) = ->(conn) { conn.adapter ScriptedAdapter, handler }

  def self.json_response(status, body, headers = {})
    [status, { "content-type" => "application/json" }.merge(headers), body.is_a?(String) ? body : JSON.generate(body)]
  end
end

RSpec.configure do |config|
  # Live sandbox examples are tagged :e2e and opt-in: `WEFUNDER_E2E=1 bundle exec rspec spec/e2e`.
  # A plain `bundle exec rspec` stays offline even when sandbox credentials happen to be exported.
  config.filter_run_excluding e2e: true unless ENV["WEFUNDER_E2E"] == "1"
  config.disable_monkey_patching!
  config.order = :random
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
