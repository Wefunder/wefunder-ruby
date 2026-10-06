# frozen_string_literal: true

# wf.installations: paths, bodies, envelope handling, and the already-installed fallback
# (409 already_installed → mint for details.installation, same scopes).
require "uri"

RSpec.describe Wefunder::Client::Installations do
  InstallCall = Struct.new(:verb, :path, :params, :body)
  INSTALL = { id: "ins_1", type: "installation",
              attributes: { target: { type: "syndicate", id: "syn_1" }, status: "active", scopes: ["read:syndicates"] } }.freeze

  def recorder(&respond)
    seen = []
    handler = lambda do |env|
      seen << InstallCall.new(env.method, env.url.path, URI.decode_www_form(env.url.query.to_s).to_h, env.body.to_s)
      respond.call(seen.last)
    end
    [seen, SpecSupport.faraday_for(handler)]
  end

  def client(faraday) = Wefunder::Client.new(access_token: "at_live_x", faraday: faraday)

  def already_installed(req)
    case req.path
    when "/installations"
      SpecSupport.json_response(409, { error: { type: "already_installed", message: "already",
                                                details: { installation: "ins_existing" }, request_id: "r" } })
    when "/installations/ins_existing/tokens"
      SpecSupport.json_response(201, { data: INSTALL.merge(id: "ins_existing"), token: { access_token: "at_live_MINT" } })
    else raise "unexpected #{req.path}"
    end
  end

  it "eligible_targets forwards target_type and returns the rows (an investor's empty list is not an error)" do
    seen, faraday = recorder do |req|
      rows = req.params["target_type"] == "company" ? [{ type: "company", id: "co_1", name: "Acme", installed: false }] : []
      SpecSupport.json_response(200, { data: rows })
    end
    wf = client(faraday)
    expect(wf.installations.eligible_targets(target_type: "company").map(&:id)).to eq(["co_1"])
    expect(wf.installations.eligible_targets(target_type: "syndicate")).to eq([])
    expect(wf.installations.eligible_targets).to eq([])
    expect(seen.map(&:path).uniq).to eq(["/installations/eligible"])
    expect(seen.last.params).not_to have_key("target_type")
  end

  it "list returns the envelope (meta.count); get and revoke unwrap data from the right paths" do
    seen, faraday = recorder do |req|
      case [req.verb, req.path]
      when [:delete, "/installations/ins_1"]
        SpecSupport.json_response(200, { data: INSTALL.merge(attributes: INSTALL[:attributes].merge(status: "revoked")) })
      when [:get, "/installations"] then SpecSupport.json_response(200, { data: [INSTALL], meta: { count: 1 } })
      else SpecSupport.json_response(200, { data: INSTALL })
      end
    end
    wf = client(faraday)
    expect(wf.installations.list.meta.count).to eq(1)
    expect(wf.installations.get("ins_1").id).to eq("ins_1")
    expect(wf.installations.revoke("ins_1").attributes.status).to eq("revoked")
    expect(seen.map { |r| "#{r.verb.to_s.upcase} #{r.path}" })
      .to eq(["GET /installations", "GET /installations/ins_1", "DELETE /installations/ins_1"])
  end

  it "create POSTs the body and keeps the one-time token beside data" do
    seen, faraday = recorder do |_|
      SpecSupport.json_response(201, { data: INSTALL, token: { access_token: "at_live_INSTALL" } })
    end
    created = client(faraday).installations.create(target_type: "syndicate", target_id: "syn_1", scopes: ["read:syndicates"])
    expect(seen.first.verb).to eq(:post)
    expect(seen.first.path).to eq("/installations")
    expect(JSON.parse(seen.first.body)).to eq("target_type" => "syndicate", "target_id" => "syn_1", "scopes" => ["read:syndicates"])
    expect(created.data.id).to eq("ins_1")
    expect(created.token.access_token).to eq("at_live_INSTALL")
  end

  it "mint_token sends scopes when given and NO body when omitted (omit = the install's ceiling)" do
    seen, faraday = recorder do |_|
      SpecSupport.json_response(201, { data: INSTALL, token: { access_token: "at_live_MINT" } })
    end
    wf = client(faraday)
    wf.installations.mint_token("ins_1", ["read:investments"])
    wf.installations.mint_token("ins_1")
    wf.installations.mint_token("ins_1", []) # an explicit [] is a real body: it grants nothing
    expect(seen.map(&:path).uniq).to eq(["/installations/ins_1/tokens"])
    expect(JSON.parse(seen[0].body)).to eq("scopes" => ["read:investments"])
    expect(seen[1].body).to eq("")
    expect(JSON.parse(seen[2].body)).to eq("scopes" => [])
  end

  it "install_or_mint_token: 409 already_installed → mints for details.installation with the SAME scopes" do
    seen, faraday = recorder { |req| already_installed(req) }
    result = client(faraday).installations.install_or_mint_token(target_type: "syndicate", target_id: "syn_1",
                                                                 scopes: ["read:syndicates"])
    expect(result.token.access_token).to eq("at_live_MINT")
    expect(seen.map(&:path)).to eq(["/installations", "/installations/ins_existing/tokens"])
    expect(JSON.parse(seen[1].body)).to eq("scopes" => ["read:syndicates"])
  end

  it "install_or_mint_token: a fresh install returns the create response without a second call" do
    seen, faraday = recorder do |_|
      SpecSupport.json_response(201, { data: INSTALL, token: { access_token: "at_live_NEW" } })
    end
    result = client(faraday).installations.install_or_mint_token(target_type: "syndicate", target_id: "syn_1")
    expect(result.token.access_token).to eq("at_live_NEW")
    expect(seen.size).to eq(1)
  end

  it "install_or_mint_token: any other error (or a 409 with no details.installation) still raises" do
    _, revoked = recorder do |_|
      SpecSupport.json_response(409, { error: { type: "installation_revoked", message: "revoked", request_id: "r" } })
    end
    expect { client(revoked).installations.install_or_mint_token(target_type: "syndicate", target_id: "syn_1") }
      .to raise_error(Wefunder::Error) { |e| expect([e.status, e.type]).to eq([409, "installation_revoked"]) }

    seen, no_details = recorder do |_|
      SpecSupport.json_response(409, { error: { type: "already_installed", message: "already", request_id: "r" } })
    end
    expect { client(no_details).installations.install_or_mint_token(target_type: "syndicate", target_id: "syn_1") }
      .to raise_error(Wefunder::Error) { |e| expect(e.type).to eq("already_installed") }
    expect(seen.size).to eq(1)
  end
end
