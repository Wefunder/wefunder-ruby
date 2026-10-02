# frozen_string_literal: true

require "yaml"

RSpec.describe Wefunder::Webhooks do
  it "EVENT_NAMES matches the spec's events enum (openapi/openapi.yaml)" do
    spec = YAML.safe_load_file(File.join(SpecSupport::ROOT, "openapi/openapi.yaml"), aliases: true)
    resolve = lambda do |node|
      node = spec.dig(*node["$ref"].delete_prefix("#/").split("/")) while node.is_a?(Hash) && node["$ref"]
      node
    end
    body = spec.dig("paths", "/webhook_endpoints", "post", "requestBody", "content", "application/json", "schema")
    events = resolve.call(resolve.call(body)["properties"]["events"])
    enum = resolve.call(events["items"])["enum"]
    expect(described_class::EVENT_NAMES.sort).to eq(enum.sort)
  end

  it "dispatch routes to the specific handler, then default, and never treats 'default' as specific" do
    make = lambda { |name|
      described_class::Event.new(id: "evt_#{name}", event: name, created_at: "x", mode: "live", data: {}, timestamp: 1)
    }
    ran = []
    expect(described_class.dispatch(make.call("offering.opened"), { "offering.opened" => ->(e) { ran << e.event } })).to be(true)
    expect(described_class.dispatch(make.call("brand.new"), { default: ->(e) { ran << "default:#{e.event}" } })).to be(true)
    expect(described_class.dispatch(make.call("offering.opened"), {})).to be(false)
    expect(described_class.dispatch(make.call("default"), { "default" => ->(e) { ran << "fallback:#{e.event}" } })).to be(true)
    expect(ran).to eq(["offering.opened", "default:brand.new", "fallback:default"])
  end

  it "accepts Rack-style HTTP_ header keys" do
    body = '{"id":"evt_1","event":"offering.opened","data":{}}'
    header = described_class.sign(body, "s", timestamp: 1_700_000_000)
    event = described_class.construct_event(body, { "HTTP_WEFUNDER_SIGNATURE" => header }, "s", now: -> { 1_700_000_000 })
    expect(event.id).to eq("evt_1")
  end
end
