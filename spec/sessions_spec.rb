# frozen_string_literal: true

# wf.join_sessions + wf.investment_sessions (beta since wefunder #24129): paths, bodies, headers, envelopes.
require "uri"

RSpec.describe "join sessions and investment sessions" do
  SessionCall = Struct.new(:verb, :path, :params, :headers, :body)
  JS = { id: "js_1", type: "join_session", attributes: { status: "pending", email: "m@example.com", url: "https://wefunder.com/join/session/js_1" } }.freeze
  IS = { id: "is_1", type: "investment_session", attributes: { status: "pending", url: "https://wefunder.com/invest/session/is_1" } }.freeze

  def recorder
    seen = []
    handler = lambda do |env|
      seen << SessionCall.new(env.method, env.url.path, URI.decode_www_form(env.url.query.to_s).to_h, env.request_headers.to_h, env.body.to_s)
      path = env.url.path
      if env.method == :post && path.end_with?("/join_sessions") then SpecSupport.json_response(201, { data: JS })
      elsif path == "/syndicates/syn_1/join_sessions"
        if seen.last.params.key?("cursor")
          SpecSupport.json_response(200, { data: [JS.merge(id: "js_2")], meta: { has_more: false } })
        else
          SpecSupport.json_response(200, { data: [JS], meta: { has_more: true, next_cursor: "c2" } })
        end
      elsif path.start_with?("/syndicates/syn_1/join_sessions/") then SpecSupport.json_response(200, { data: JS })
      elsif env.method == :post then SpecSupport.json_response(201, { data: IS })
      elsif env.method == :delete then SpecSupport.json_response(200, { data: IS.merge(attributes: IS[:attributes].merge(status: "canceled")) })
      elsif path == "/investment_sessions" then SpecSupport.json_response(200, { data: [IS], meta: { has_more: false } })
      elsif path == "/offerings/ofr_1/investment_sessions"
        if seen.last.params.key?("cursor")
          SpecSupport.json_response(200, { data: [IS.merge(id: "is_2")], meta: { has_more: false } })
        else
          SpecSupport.json_response(200, { data: [IS], meta: { has_more: true, next_cursor: 9 } })
        end
      else
        SpecSupport.json_response(200, { data: IS })
      end
    end
    [seen, SpecSupport.faraday_for(handler)]
  end

  it "join_sessions: untyped responses unwrap to Hashes, all pages, create wraps the body, get hits the nested path" do
    seen, faraday = recorder
    wf = Wefunder::Client.new(access_token: "at_live_x", faraday: faraday)
    expect(wf.join_sessions.all("syn_1", per_page: 1).map { |s| s["id"] }).to eq(%w[js_1 js_2])
    created = wf.join_sessions.create("syn_1", email: "m@example.com", require_approval: true)
    expect(created.dig("attributes", "url")).to start_with("https://wefunder.com/join/session/")
    expect(wf.join_sessions.get("syn_1", "js_1")["id"]).to eq("js_1")
    expect(seen.map { |c| "#{c.verb.to_s.upcase} #{c.path}" }).to eq([
                                                                       "GET /syndicates/syn_1/join_sessions", "GET /syndicates/syn_1/join_sessions",
                                                                       "POST /syndicates/syn_1/join_sessions", "GET /syndicates/syn_1/join_sessions/js_1"
                                                                     ])
    expect(seen.first.params["per_page"]).to eq("1")
    expect(JSON.parse(seen[2].body)).to eq("join_session" => { "email" => "m@example.com", "mode" => "hosted", "require_approval" => true })
  end

  it "investment_sessions: filters, offering paging, body + Idempotency-Key on create, get/cancel paths" do
    seen, faraday = recorder
    wf = Wefunder::Client.new(access_token: "at_live_x", faraday: faraday)
    expect(wf.investment_sessions.list(status: "in_progress", spv_id: "spv_1").data.first.id).to eq("is_1")
    expect(seen.first.params["status"]).to eq("in_progress")
    expect(wf.investment_sessions.all_for_offering("ofr_1", status: "completed").map(&:id)).to eq(%w[is_1 is_2])
    expect(seen[1].params["status"]).to eq("completed")
    created = wf.investment_sessions.create("ofr_1", email: "i@example.com", allocation_cents: 250_000, idempotency_key: "k1")
    expect(created.id).to eq("is_1")
    expect(wf.investment_sessions.get("is_1").id).to eq("is_1")
    expect(wf.investment_sessions.cancel("is_1").attributes.status).to eq("canceled")
    expect(seen.drop(3).map { |c| "#{c.verb.to_s.upcase} #{c.path}" })
      .to eq(["POST /offerings/ofr_1/investment_sessions", "GET /investment_sessions/is_1", "DELETE /investment_sessions/is_1"])
    expect(JSON.parse(seen[3].body)).to eq("investment_session" => { "email" => "i@example.com", "allocation_cents" => 250_000 })
    expect(seen[3].headers.find { |k, _| k.casecmp?("Idempotency-Key") }&.last).to eq("k1")
  end
end
