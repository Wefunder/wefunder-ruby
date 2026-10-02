#!/usr/bin/env ruby
# frozen_string_literal: true

# Build examples_manifest.json — the verified-JSON artifact the docs site consumes. Same
# contract as wefunder-node/scripts/build-examples-manifest.mjs: a `# region <key>` …
# `# endregion` block per snippet, keyed by operationId or `guides/<name>`; `lang` MUST equal
# the docs tab label ("Ruby"). See examples/README.md.
require "json"

module ExamplesManifest
  ROOT = File.expand_path("..", __dir__)
  EXAMPLES = File.join(ROOT, "examples")
  OUT = File.join(ROOT, "examples_manifest.json")
  REGION = /\A\s*#\s*region\s+(\S+)\s*\z/
  ENDREGION = /\A\s*#\s*endregion\b/

  module_function

  def dedent(lines)
    body = lines.dup
    body.shift while body.any? && body.first.strip.empty?
    body.pop while body.any? && body.last.strip.empty?
    indents = body.reject { |l| l.strip.empty? }.map { |l| l[/\A\s*/].length }
    cut = indents.min || 0
    body.map { |l| l[cut..] || "" }.join("\n")
  end

  def extract_regions(text)
    out = {}
    key = nil
    buf = []
    text.each_line(chomp: true) do |line|
      if (m = REGION.match(line))
        raise "nested region #{m[1]} inside #{key}" if key

        key = m[1]
        buf = []
        next
      end
      if ENDREGION.match?(line)
        raise "endregion without region" unless key
        raise "duplicate region key: #{key}" if out.key?(key)

        out[key] = dedent(buf)
        key = nil
        next
      end
      buf << line if key
    end
    raise "unterminated region: #{key}" if key

    out
  end

  def version
    File.read(File.join(ROOT, "lib/wefunder/version.rb"))[/VERSION = "([^"]+)"/, 1]
  end

  def api_version
    File.read(File.join(ROOT, "lib/wefunder/client.rb"))[/DEFAULT_API_VERSION = "([^"]+)"/, 1]
  end

  def build
    samples = {}
    skipped = []
    Dir[File.join(EXAMPLES, "*.rb")].each do |path|
      next if File.basename(path).start_with?("_")

      regions = extract_regions(File.read(path))
      if regions.empty?
        skipped << File.basename(path)
        next
      end
      regions.each do |k, src|
        raise "duplicate sample key across files: #{k} (in #{File.basename(path)})" if samples.key?(k)

        samples[k] = src
      end
    end
    warn "build_examples_manifest: no region in #{skipped.join(", ")} — not in manifest" if skipped.any?
    {
      "manifestVersion" => 1,
      "lang" => "Ruby", # MUST equal the docs tab label, or the merge no-ops.
      "label" => "wefunder",
      "sdkVersion" => version,
      "apiVersion" => api_version,
      "generatedBy" => "script/build_examples_manifest.rb",
      "samples" => samples.sort.to_h
    }
  end

  def serialize(manifest)
    "#{JSON.pretty_generate(manifest)}\n"
  end
end

if $PROGRAM_NAME == __FILE__
  File.write(ExamplesManifest::OUT, ExamplesManifest.serialize(ExamplesManifest.build))
  puts "wrote #{ExamplesManifest::OUT}"
end
