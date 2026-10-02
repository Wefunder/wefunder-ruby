# frozen_string_literal: true

# The install-target guide must survive the API's "already installed" answer: create_installation
# returns 409 already_installed (details.installation = the existing id) and the example has to
# mint a token for THAT install and continue — not surface the 409.
require_relative "../examples/install_target"

RSpec.describe "examples/install_target.rb" do
  def api(create_response)
    seen = []
    handler = lambda do |env|
      seen << "#{env.method.to_s.upcase} #{env.url.path} #{env.request_headers["Authorization"]}"
      case env.url.path
      when "/installations/eligible"
        SpecSupport.json_response(200, { data: [{ type: "syndicate", id: "syn_1", name: "Ex", installed: true }] })
      when "/installations" then create_response
      when "/installations/ins_existing/tokens"
        SpecSupport.json_response(201, { data: { id: "ins_existing" }, token: { access_token: "at_live_INSTALL" } })
      when "/syndicates/syn_1/deals"
        SpecSupport.json_response(200, { data: [{ id: "deal_1" }], meta: {} })
      else raise "unexpected #{env.method} #{env.url.path}"
      end
    end
    [seen, SpecSupport.faraday_for(handler)]
  end

  it "already installed: 409 already_installed → mints for details.installation → deals request runs AS the install" do
    seen, faraday = api(SpecSupport.json_response(409, { error: { type: "already_installed", message: "already",
                                                                  details: { installation: "ins_existing" }, request_id: "r" } }))
    wf = Wefunder::Client.new(access_token: "at_live_USER", faraday: faraday)
    deals = InstallTargetExample.example(wf, "syn_1", client_options: { faraday: faraday })
    expect(deals.data.map(&:id)).to eq(["deal_1"])
    expect(seen).to eq([
                         "GET /installations/eligible Bearer at_live_USER",
                         "POST /installations Bearer at_live_USER",
                         "POST /installations/ins_existing/tokens Bearer at_live_USER",
                         "GET /syndicates/syn_1/deals Bearer at_live_INSTALL"
                       ])
  end

  it "any other 409 still raises" do
    _, faraday = api(SpecSupport.json_response(409,
                                               { error: { type: "installation_revoked", message: "revoked", request_id: "r" } }))
    wf = Wefunder::Client.new(access_token: "at_live_USER", faraday: faraday)
    expect { InstallTargetExample.example(wf, "syn_1", client_options: { faraday: faraday }) }
      .to raise_error(Wefunder::Error) { |e| expect([e.status, e.type]).to eq([409, "installation_revoked"]) }
  end
end
