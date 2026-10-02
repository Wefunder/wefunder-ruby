# frozen_string_literal: true

# Hermetic client tests beyond the conformance vectors: namespace wiring to the generated APIs
# (paths, query forwarding, envelope unwrapping, typed errors) and the request escape hatch.
require "uri"

RSpec.describe Wefunder::Client do
  Recorded = Struct.new(:verb, :path, :params, :headers, :body)

  def recorder(&respond)
    seen = []
    handler = lambda do |env|
      seen << Recorded.new(env.method, env.url.path, URI.decode_www_form(env.url.query.to_s).to_h,
                           env.request_headers.to_h, env.body.to_s)
      respond.call(seen.last)
    end
    [seen, SpecSupport.faraday_for(handler)]
  end

  it "uses the single host, pins Wefunder-Version, attaches the bearer, and unwraps data" do
    seen, faraday = recorder do |_|
      SpecSupport.json_response(200, { data: { id: "usr_1", type: "user", attributes: { name: "A" } } })
    end
    wf = described_class.new(access_token: "at_test_x", faraday: faraday)
    me = wf.users.me
    expect(seen.first.path).to eq("/users/me")
    expect(seen.first.headers["Wefunder-Version"]).to eq("2025-01-15")
    expect(seen.first.headers["Authorization"]).to eq("Bearer at_test_x")
    expect(wf.mode).to eq("test")
    expect(me.id).to eq("usr_1")
    expect(me.attributes.name).to eq("A")
  end

  it "forwards query params and paginates with the cursor, preserving the query" do
    seen, faraday = recorder do |req|
      if req.params.key?("cursor")
        SpecSupport.json_response(200, { data: [{ id: "ofr_2", type: "offering" }], meta: { has_more: false, next_cursor: nil } })
      else
        SpecSupport.json_response(200, { data: [{ id: "ofr_1", type: "offering" }], meta: { has_more: true, next_cursor: 25 } })
      end
    end
    wf = described_class.new(access_token: "at_test_x", faraday: faraday)
    expect(wf.offerings.all(sort: "most_raised").map(&:id)).to eq(%w[ofr_1 ofr_2])
    expect(seen.map { |r| r.params["sort"] }).to eq(%w[most_raised most_raised])
    expect(seen.last.params["cursor"]).to eq("25")
    expect(seen.first.path).to eq("/explore")
  end

  it "raises a typed Wefunder::Error from the envelope, header request id first" do
    _, faraday = recorder do |_|
      SpecSupport.json_response(403, { error: { type: "insufficient_scope", message: "needs read:profile", request_id: "req_body" } },
                                "x-wf-request-id" => "req_header")
    end
    wf = described_class.new(access_token: "at_test_x", faraday: faraday)
    expect { wf.users.me }.to raise_error(Wefunder::Error) { |e|
      expect([e.status, e.type, e.request_id, e.message]).to eq([403, "insufficient_scope", "req_header", "needs read:profile"])
      expect(e.summary).to include("insufficient_scope", "req_header")
    }
  end

  it "wires every webhook_endpoints method to the right path and body" do
    seen, faraday = recorder do |req|
      case [req.verb, req.path]
      when [:delete, "/webhook_endpoints/whe_1"]
        SpecSupport.json_response(200, { data: { id: "whe_1", type: "webhook_endpoint", removed: true } })
      when [:get, "/webhook_endpoints"]
        SpecSupport.json_response(200, { data: [], meta: { count: 0, quota: 10 } })
      else
        status = req.verb == :post && req.path == "/webhook_endpoints" ? 201 : 200
        SpecSupport.json_response(status, { data: { id: "whe_1", type: "webhook_endpoint",
                                                    attributes: { url: "https://e.com/h", secret: "whsec_once" } } })
      end
    end
    wf = described_class.new(access_token: "at_live_x", faraday: faraday)
    created = wf.webhook_endpoints.create(url: "https://e.com/h", events: ["offering.opened"], mode: "live")
    expect(created.attributes.secret).to eq("whsec_once")
    expect(JSON.parse(seen.first.body)).to eq("url" => "https://e.com/h", "events" => ["offering.opened"], "mode" => "live")
    expect(wf.webhook_endpoints.list.meta.quota).to eq(10)
    wf.webhook_endpoints.get("whe_1")
    wf.webhook_endpoints.update("whe_1", events: ["investment.executed"])
    wf.webhook_endpoints.rotate_secret("whe_1")
    wf.webhook_endpoints.reenable("whe_1")
    wf.webhook_endpoints.test("whe_1", "offering.opened")
    wf.webhook_endpoints.test("whe_1")
    expect(wf.webhook_endpoints.remove("whe_1").removed).to be(true)
    expect(seen.drop(1).map { |r| "#{r.verb.to_s.upcase} #{r.path}" }).to eq([
                                                                               "GET /webhook_endpoints", "GET /webhook_endpoints/whe_1", "PATCH /webhook_endpoints/whe_1",
                                                                               "POST /webhook_endpoints/whe_1/rotate_secret", "POST /webhook_endpoints/whe_1/reenable",
                                                                               "POST /webhook_endpoints/whe_1/test", "POST /webhook_endpoints/whe_1/test", "DELETE /webhook_endpoints/whe_1"
                                                                             ])
    expect(JSON.parse(seen[3].body)).to eq("events" => ["investment.executed"])
    expect(JSON.parse(seen[6].body)).to eq("event" => "offering.opened")
    expect(seen[7].body).to eq("")
  end

  it "request escape hatch sends JSON with auth + version and returns parsed JSON" do
    seen, faraday = recorder do |req|
      SpecSupport.json_response(200, { echo: JSON.parse(req.body), path: req.path, q: req.params })
    end
    wf = described_class.new(access_token: "at_test_x", faraday: faraday)
    out = wf.request(:post, "/partner/spvs", query: { dry_run: "1", skip: nil }, body: { a: 1 },
                                             headers: { "Idempotency-Key" => "k1" })
    expect(out).to eq("echo" => { "a" => 1 }, "path" => "/partner/spvs", "q" => { "dry_run" => "1" })
    expect(seen.first.headers["Idempotency-Key"]).to eq("k1")
    expect(seen.first.headers["Authorization"]).to eq("Bearer at_test_x")
    expect(seen.first.headers["Wefunder-Version"]).to eq("2025-01-15")
  end

  it "request raises a typed error" do
    _, faraday = recorder do |_|
      SpecSupport.json_response(404, { error: { type: "not_found", message: "nope", request_id: "r" } })
    end
    wf = described_class.new(access_token: "at_test_x", faraday: faraday)
    expect { wf.request(:get, "/nothing") }.to raise_error(Wefunder::Error) { |e| expect(e.type).to eq("not_found") }
  end

  it "investments.collect stops on has_more=false even though next_cursor is always present" do
    seen, faraday = recorder do |req|
      if req.params.key?("cursor")
        SpecSupport.json_response(200, { data: [{ id: "inv_2", visible: false, observed_at: "2026-09-02T00:00:00Z" }],
                                         meta: { mode: "delta", has_more: false, next_cursor: "c2" } })
      else
        SpecSupport.json_response(200, { data: [{ id: "inv_1", visible: true, observed_at: "2026-09-01T00:00:00Z" }],
                                         meta: { mode: "delta", has_more: true, next_cursor: "c1" } })
      end
    end
    wf = described_class.new(access_token: "at_live_x", faraday: faraday)
    ids = wf.investments.collect(company_id: "co_1", updated_since: Time.utc(2026, 9, 1)).map(&:id)
    expect(ids).to eq(%w[inv_1 inv_2])
    expect(seen.size).to eq(2)
    expect(seen.last.params).to include("company_id" => "co_1", "cursor" => "c1")
  end

  it "requires a token" do
    expect { described_class.new }.to raise_error(ArgumentError)
  end
end
