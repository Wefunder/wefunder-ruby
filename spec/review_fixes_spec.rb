# frozen_string_literal: true

# Regression tests for the pre-release review findings on 0.1.0.beta1.
require "uri"

RSpec.describe "review fixes (0.1.0.beta2)" do
  Seen = Struct.new(:verb, :path, :params, :headers, :body, :timeout)

  def recorder(&respond)
    seen = []
    handler = lambda do |env|
      seen << Seen.new(env.method, env.url.path, URI.decode_www_form(env.url.query.to_s).to_h,
                       env.request_headers.to_h, env.body.to_s, env.request.timeout)
      respond.call(seen.last)
    end
    [seen, SpecSupport.faraday_for(handler)]
  end

  describe "Time / Date query params serialize as ISO 8601 (not Ruby Time#to_s)" do
    it "normalizes Time, DateTime and Date in namespace calls, pagination, and request()" do
      seen, faraday = recorder { |_| SpecSupport.json_response(200, { data: [], meta: { has_more: false } }) }
      wf = Wefunder::Client.new(access_token: "at_test_x", faraday: faraday)
      wf.investments.list(updated_since: Time.utc(2026, 9, 1, 12, 30))
      wf.investments.collect(updated_since: DateTime.new(2026, 9, 1, 12, 30, 0, "+02:00"))
      wf.offerings.list(closing_before: Date.new(2026, 12, 31))
      wf.request(:get, "/investments", query: { updated_since: Time.utc(2026, 9, 1) })
      expect(seen.map { |r| r.params["updated_since"] || r.params["closing_before"] }).to eq(
        ["2026-09-01T12:30:00Z", "2026-09-01T12:30:00+02:00", "2026-12-31", "2026-09-01T00:00:00Z"]
      )
    end
  end

  describe "rotated tokens are persisted BEFORE they become visible (wefunder-ruby#1)" do
    let(:oauth) { SpecSupport.faraday_for(->(_e) { SpecSupport.json_response(200, { access_token: "at_live_NEW", refresh_token: "r2" }) }) }
    let(:tokens) { Wefunder::TokenSet.new(access_token: "at_live_OLD", refresh_token: "r1") }

    it "the store sees the OLD token still current while saving" do
      observed = []
      store = Object.new
      manager = Wefunder::TokenManager.new(tokens, client_id: "c", faraday: oauth, store: store)
      store.define_singleton_method(:save) { |set| observed << [set.access_token, manager.current.access_token] }
      manager.refresh
      expect(observed).to eq([%w[at_live_NEW at_live_OLD]])
      expect(manager.current.access_token).to eq("at_live_NEW")
    end

    it "barrier: a concurrent reader blocked behind an in-flight save never sees the undurable token" do
      entered = Queue.new
      release = Queue.new
      store = Object.new
      store.define_singleton_method(:save) do |_set|
        entered << true
        release.pop # hold the save open until the test says so
      end
      manager = Wefunder::TokenManager.new(tokens, client_id: "c", faraday: oauth, store: store)
      refresher = Thread.new { manager.refresh }
      entered.pop # thread A is inside store.save
      reader = Thread.new { manager.access_token }
      sleep 0.05
      expect(reader.alive?).to be(true) # B waits on the lock instead of reading the pending set
      expect(manager.current.access_token).to eq("at_live_OLD")
      release << true
      expect(refresher.value.access_token).to eq("at_live_NEW")
      expect(reader.value).to eq("at_live_NEW") # B proceeds only after the save completed
    end

    it "a failing store keeps the rotated set pending, never uses it, and retries the save on the next call" do
      attempts = 0
      store = Object.new
      store.define_singleton_method(:save) do |_set|
        attempts += 1
        raise IOError, "disk full" if attempts == 1
      end
      manager = Wefunder::TokenManager.new(tokens, client_id: "c", faraday: oauth, store: store)
      expect { manager.refresh }.to raise_error(Wefunder::TokenPersistenceError) { |e|
        expect(e.tokens.refresh_token).to eq("r2")
        expect(e.message).to include("disk full")
      }
      expect(manager.current.access_token).to eq("at_live_OLD") # not published
      expect(manager.pending_tokens.access_token).to eq("at_live_NEW")
      # Next call retries the save (no second rotation — the old refresh token is consumed) and publishes.
      expect(manager.access_token).to eq("at_live_NEW")
      expect(attempts).to eq(2)
      expect(manager.pending_tokens).to be_nil
    end

    it "mark_persisted! publishes a pending set the caller saved out of band" do
      store = Object.new
      store.define_singleton_method(:save) { |_set| raise IOError, "disk full" }
      manager = Wefunder::TokenManager.new(tokens, client_id: "c", faraday: oauth, store: store)
      expect { manager.refresh }.to raise_error(Wefunder::TokenPersistenceError)
      manager.mark_persisted!
      expect(manager.current.access_token).to eq("at_live_NEW")
      expect(manager.pending_tokens).to be_nil
    end
  end

  describe "the default rspec command is hermetic (wefunder-ruby#5)" do
    it "filters the :e2e group out unless WEFUNDER_E2E=1, regardless of exported credentials" do
      out = Bundler.with_unbundled_env do
        env = { "WEFUNDER_CLIENT_ID" => "pk_test_dummy", "WEFUNDER_CLIENT_SECRET" => "sk_test_dummy", "WEFUNDER_E2E" => nil }
        IO.popen(env, ["bundle", "exec", "rspec", "spec/e2e", "--format", "progress"], chdir: SpecSupport::ROOT, &:read)
      end
      expect(out).to include("0 examples, 0 failures")
    end
  end

  describe "the client timeout covers every path" do
    it "applies to OAuth token requests (refresh / re-mint)" do
      seen, faraday = recorder { |_| SpecSupport.json_response(200, { access_token: "at_live_NEW", refresh_token: "r2" }) }
      manager = Wefunder::TokenManager.new(Wefunder::TokenSet.new(access_token: "a", refresh_token: "r1"),
                                           client_id: "c", faraday: faraday, timeout: 7)
      manager.refresh
      expect(seen.first.timeout).to eq(7)
      Wefunder.client_credentials_grant(client_id: "c", client_secret: "s", faraday: faraday, timeout: 3)
      expect(seen.last.timeout).to eq(3)
    end

    it "applies to request() and to the client-credentials mint" do
      seen, faraday = recorder do |r|
        next SpecSupport.json_response(200, { access_token: "at_test_x" }) if r.path.end_with?("/oauth/token")

        SpecSupport.json_response(200, { ok: true })
      end
      wf = Wefunder::Client.from_client_credentials(client_id: "c", client_secret: "s", faraday: faraday, timeout: 11)
      wf.request(:get, "/anything")
      expect(seen.map(&:timeout)).to eq([11, 11])
    end
  end

  describe "request() reports network failures like the generated calls" do
    it "raises Wefunder::Error(network_error) instead of a raw Faraday exception" do
      faraday = SpecSupport.faraday_for(->(_e) { raise Faraday::ConnectionFailed, "boom" })
      wf = Wefunder::Client.new(access_token: "at_test_x", faraday: faraday, retry_options: Wefunder::RetryOptions.new(
        max_retries: 0, base_delay_ms: 1, max_delay_ms: 1
      ))
      expect { wf.request(:get, "/x") }.to raise_error(Wefunder::Error) { |e| expect([e.status, e.type]).to eq([0, "network_error"]) }
      expect { wf.users.me }.to raise_error(Wefunder::Error) { |e| expect(e.type).to eq("network_error") }
    end
  end
end
