#!/usr/bin/env ruby
# frozen_string_literal: true

# Vendor the cross-language conformance vectors from Wefunder/wefunder-node (conformance/*.json +
# manifest.json) at the ref in conformance/PIN (pass a tag/sha to repin), verifying each file's
# SHA-256 against the manifest. spec/conformance_spec.rb runs every case against this SDK.
require "digest"
require "json"
require "net/http"
require "uri"

root = File.expand_path("..", __dir__)
dest = File.join(root, "conformance")
pin_path = File.join(dest, "PIN")
pin = File.readlines(pin_path).grep_v(/^#/).to_h { |l| l.strip.split("=", 2) }
repo = pin.fetch("repo")
ref = ARGV[0] || pin.fetch("ref")

fetch = lambda do |path|
  res = Net::HTTP.get_response(URI("https://raw.githubusercontent.com/#{repo}/#{ref}/conformance/#{path}"))
  abort("error: #{path}: HTTP #{res.code}") unless res.is_a?(Net::HTTPSuccess)
  res.body
end

manifest_raw = fetch.call("manifest.json")
manifest = JSON.parse(manifest_raw)
manifest.fetch("files").each do |name, sha|
  data = fetch.call(name)
  actual = Digest::SHA256.hexdigest(data)
  abort("error: #{name} sha256 #{actual} != manifest #{sha}") unless actual == sha
  File.binwrite(File.join(dest, name), data)
end
File.binwrite(File.join(dest, "manifest.json"), manifest_raw)
File.write(pin_path, <<~PIN)
  # Source of the vendored vectors: Wefunder/wefunder-node, conformance/*.json at this ref.
  # Refresh with:  ruby script/sync_conformance.rb [ref]
  repo=#{repo}
  ref=#{ref}
PIN
puts "vendored #{manifest["files"].size} vector files from #{repo}@#{ref} (conformance_version #{manifest["conformance_version"]})"
