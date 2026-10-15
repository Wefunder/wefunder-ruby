# frozen_string_literal: true

# wf.member_links + wf.referral_codes (Wefunder-Version 2026-10-15): paths, bodies, headers, envelopes.
require "uri"

RSpec.describe "member links and referral codes" do
  Call = Struct.new(:verb, :path, :params, :headers, :body)
  LINK = { id: "il_1", type: "member_link", attributes: { reference: "member_8812", state: "created" } }.freeze
  CODE = { id: "ref_1", type: "referral_code", attributes: { label: "October", active: true, link_parameter: "wfr=ref_1" } }.freeze

  def recorder
    seen = []
    handler = lambda do |env|
      seen << Call.new(env.method, env.url.path, URI.decode_www_form(env.url.query.to_s).to_h, env.request_headers.to_h, env.body.to_s)
      case [env.method, env.url.path]
      when [:post, "/offerings/ofr_1/member_links"] then SpecSupport.json_response(201, { data: LINK })
      when [:get, "/offerings/ofr_1/member_links"]
        if seen.last.params.key?("cursor")
          SpecSupport.json_response(200, { data: [LINK.merge(id: "il_2")], meta: { has_more: false, next_cursor: nil } })
        else
          SpecSupport.json_response(200, { data: [LINK], meta: { has_more: true, next_cursor: 7 } })
        end
      when [:post, "/member_links/il_1/cancel"]
        SpecSupport.json_response(200, { data: LINK.merge(attributes: LINK[:attributes].merge(state: "canceled")) })
      when [:get, "/referral_codes"]
        SpecSupport.json_response(200, { data: [CODE], meta: { has_more: false, next_cursor: nil, active_limit: 50 } })
      when [:get, "/referral_codes/ref_1/stats"]
        SpecSupport.json_response(200, { data: { id: "ref_1", type: "referral_code_stats", attributes: { label: "October", companies: [{ company: "co_1", level: "anonymized", weeks: [] }] } }, meta: { has_more: false, next_cursor: nil } })
      when [:post, "/referral_codes"] then SpecSupport.json_response(201, { data: CODE })
      else SpecSupport.json_response(200, { data: env.url.path.start_with?("/referral") ? CODE : LINK })
      end
    end
    [seen, SpecSupport.faraday_for(handler)]
  end

  it "sends Wefunder-Version 2026-10-15 by default" do
    seen, faraday = recorder
    Wefunder::Client.new(access_token: "at_live_x", faraday: faraday).member_links.get("il_1")
    expect(Wefunder::DEFAULT_API_VERSION).to eq("2026-10-15")
    expect(seen.first.headers["Wefunder-Version"]).to eq("2026-10-15")
  end

  it "member_links: all pages, create sends the body and Idempotency-Key (or neither), get/cancel hit their paths" do
    seen, faraday = recorder
    wf = Wefunder::Client.new(access_token: "at_live_x", faraday: faraday)
    expect(wf.member_links.all("ofr_1").map(&:id)).to eq(%w[il_1 il_2])
    expect(wf.member_links.create("ofr_1", reference: "member_8812", idempotency_key: "k1").id).to eq("il_1")
    expect(wf.member_links.get("il_1").id).to eq("il_1")
    expect(wf.member_links.cancel("il_1").attributes.state).to eq("canceled")
    wf.member_links.create("ofr_1")
    expect(seen.map { |c| "#{c.verb.to_s.upcase} #{c.path}" }).to eq([
                                                                       "GET /offerings/ofr_1/member_links", "GET /offerings/ofr_1/member_links",
                                                                       "POST /offerings/ofr_1/member_links", "GET /member_links/il_1",
                                                                       "POST /member_links/il_1/cancel", "POST /offerings/ofr_1/member_links"
                                                                     ])
    expect(JSON.parse(seen[2].body)).to eq("member_link" => { "reference" => "member_8812" })
    # Faraday canonicalizes header names ("Idempotency-key"); HTTP headers are case-insensitive.
    header = ->(call, name) { call.headers.find { |k, _| k.casecmp?(name) }&.last }
    expect(header.call(seen[2], "Idempotency-Key")).to eq("k1")
    expect(seen[5].body).to eq("")
    expect(header.call(seen[5], "Idempotency-Key")).to be_nil
  end

  it "referral_codes: list forwards filters, create/update send bodies, get/stats hit their paths and stats keeps the envelope" do
    seen, faraday = recorder
    wf = Wefunder::Client.new(access_token: "at_live_x", faraday: faraday)
    expect(wf.referral_codes.list(active: true, per_page: 10).data.first.id).to eq("ref_1")
    expect(seen.first.params["active"]).to eq("true")
    expect(wf.referral_codes.create(label: "October", company_id: "co_1", utm: { source: "newsletter" }).attributes.link_parameter).to eq("wfr=ref_1")
    wf.referral_codes.get("ref_1")
    wf.referral_codes.update("ref_1", active: false)
    stats = wf.referral_codes.stats("ref_1", company_id: "co_1")
    expect(stats.data.attributes.companies.first.company).to eq("co_1")
    expect(stats.meta.has_more).to be(false)
    expect(seen.map { |c| "#{c.verb.to_s.upcase} #{c.path}" }).to eq([
                                                                       "GET /referral_codes", "POST /referral_codes", "GET /referral_codes/ref_1",
                                                                       "PATCH /referral_codes/ref_1", "GET /referral_codes/ref_1/stats"
                                                                     ])
    expect(JSON.parse(seen[1].body)).to eq("label" => "October", "company_id" => "co_1", "utm" => { "source" => "newsletter" })
    expect(JSON.parse(seen[3].body)).to eq("active" => false)
    expect(seen[4].params["company_id"]).to eq("co_1")
  end
end
