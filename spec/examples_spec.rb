# frozen_string_literal: true

# Gates that keep doc examples honest: COVERAGE — every public operationId has an example or is
# explicitly curl-only; FRESHNESS — the committed manifest matches the builder; SHAPE — lang is
# a docs tab label; LOAD — every example file parses and loads.
require_relative "../script/build_examples_manifest"

RSpec.describe "examples" do
  root = SpecSupport::ROOT
  spec_ops = File.read(File.join(root, "openapi/openapi.yaml")).scan(/^\s*operationId:\s*(\w+)/).flatten
  manifest = JSON.parse(File.read(File.join(root, "examples_manifest.json")))
  allow = JSON.parse(File.read(File.join(root, "examples/coverage-allowlist.json")))["curlOnly"]
  keys = manifest["samples"].keys

  it "every public operationId has an example or is explicitly curl-only" do
    expect(spec_ops.reject { |o| keys.include?(o) || allow.include?(o) }).to eq([])
  end

  it("no operationId is both exampled and allowlisted") { expect(allow & keys).to eq([]) }
  it("the allowlist has no stale ids") { expect(allow - spec_ops).to eq([]) }

  it "the committed manifest is fresh (ruby script/build_examples_manifest.rb)" do
    expect(ExamplesManifest.serialize(ExamplesManifest.build)).to eq(File.read(File.join(root, "examples_manifest.json")))
  end

  it("declares a lang the docs can merge onto a tab") { expect(manifest["lang"]).to(satisfy { |l| %w[JavaScript Python Ruby].include?(l) }) }

  Dir[File.join(root, "examples/*.rb")].each do |file|
    it "#{File.basename(file)} loads" do
      expect { load file }.not_to raise_error
    end
  end
end
