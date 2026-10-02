# frozen_string_literal: true

# Live sandbox E2E — needs WEFUNDER_CLIENT_ID / WEFUNDER_CLIENT_SECRET (a pk_test_ app). Excluded
# from `rake spec`; run with `bundle exec rspec spec/e2e`. Asserts contract shape and paginator
# invariants, not data (a fresh realm may have no offerings).
RSpec.describe "live sandbox", if: ENV.fetch("WEFUNDER_CLIENT_ID", nil) && ENV.fetch("WEFUNDER_CLIENT_SECRET", nil) do
  let(:wf) do
    Wefunder::Client.from_client_credentials(client_id: ENV.fetch("WEFUNDER_CLIENT_ID"),
                                             client_secret: ENV.fetch("WEFUNDER_CLIENT_SECRET"), scopes: ["read:public"])
  end

  it "mints a test-mode token at the gateway" do
    expect(wf.mode).to eq("test")
    expect(wf.tokens.access_token).to start_with("at_test_")
  end

  it "offerings.list has the envelope shape and the paginator terminates without duplicates" do
    page = wf.offerings.list
    expect(page.data).to be_an(Array)
    expect(page.meta).not_to be_nil
    ids = wf.offerings.all.map(&:id)
    expect(ids.uniq.size).to eq(ids.size)
  end

  it "a scope error is typed and carries a request id" do
    expect { wf.users.me }.to raise_error(Wefunder::Error) { |e|
      expect(e.status).to eq(403)
      expect(e.request_id).not_to be_nil
    }
  end

  it "an unknown offering is a typed error" do
    expect { wf.offerings.get("ofr_doesnotexist000000") }.to raise_error(Wefunder::Error) { |e|
      expect(e.status).to satisfy { |s| [404, 400].include?(s) }
      expect(e.request_id).not_to be_nil
    }
  end
end
