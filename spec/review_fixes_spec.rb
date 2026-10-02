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

    # Build a manager whose persistence runs through the store OR the callback (both are persistence paths).
    def manager_with(path, oauth, tokens, &persist)
      if path == :store
        store = Object.new
        store.define_singleton_method(:save, &persist)
        Wefunder::TokenManager.new(tokens, client_id: "c", faraday: oauth, store: store)
      else
        Wefunder::TokenManager.new(tokens, client_id: "c", faraday: oauth, on_token_refresh: persist)
      end
    end

    it "the store sees the OLD token still current while saving" do
      observed = []
      manager = nil
      manager = manager_with(:store, oauth, tokens) { |set| observed << [set.access_token, manager.current.access_token] }
      manager.refresh
      expect(observed).to eq([%w[at_live_NEW at_live_OLD]])
      expect(manager.current.access_token).to eq("at_live_NEW")
    end

    %i[store callback].each do |path|
      it "barrier (#{path}): a reader behind an in-flight #{path} save never sees the undurable token" do
        entered = Queue.new
        release = Queue.new
        manager = manager_with(path, oauth, tokens) do |_set|
          entered << true
          release.pop
        end
        refresher = Thread.new { manager.refresh }
        entered.pop
        reader = Thread.new { manager.access_token }
        sleep 0.05
        expect(reader.alive?).to be(true)
        expect(manager.current.access_token).to eq("at_live_OLD")
        release << true
        expect(refresher.value.access_token).to eq("at_live_NEW")
        expect(reader.value).to eq("at_live_NEW")
      end

      it "failure (#{path}): a failing #{path} keeps the set pending, never uses it, and the next call retries" do
        attempts = 0
        manager = manager_with(path, oauth, tokens) do |_set|
          attempts += 1
          raise IOError, "disk full" if attempts == 1
        end
        expect { manager.refresh }.to raise_error(Wefunder::TokenPersistenceError) { |e|
          expect(e.tokens.refresh_token).to eq("r2")
          expect(e.message).to include("disk full")
        }
        expect(manager.current.access_token).to eq("at_live_OLD")
        expect(manager.pending_tokens.access_token).to eq("at_live_NEW")
        expect(manager.access_token).to eq("at_live_NEW")
        expect(attempts).to eq(2)
        expect(manager.pending_tokens).to be_nil
      end
    end

    it "on_token_refresh runs before publication, after store.save" do
      order = []
      manager = nil
      store = Object.new
      store.define_singleton_method(:save) { |_set| order << "save current=#{manager.current.access_token}" }
      manager = Wefunder::TokenManager.new(tokens, client_id: "c", faraday: oauth, store: store,
                                                   on_token_refresh: ->(_set) { order << "callback current=#{manager.current.access_token}" })
      manager.refresh
      expect(order).to eq(["save current=at_live_OLD", "callback current=at_live_OLD"])
    end

    it "mark_persisted! is bound to the exact set that was saved: a stale r2 ack cannot publish r3" do
      mint = 0
      rotating = SpecSupport.faraday_for(lambda do |_e|
        mint += 1
        SpecSupport.json_response(200, { access_token: "at_live_#{mint + 1}", refresh_token: "r#{mint + 1}" })
      end)
      fail_next = true
      store = Object.new
      store.define_singleton_method(:save) do |_set|
        return unless fail_next

        fail_next = false
        raise IOError, "down"
      end
      manager = Wefunder::TokenManager.new(tokens, client_id: "c", faraday: rotating, store: store)
      err_a = nil
      begin
        manager.refresh # r1 -> r2, save fails; caller A holds err.tokens (r2) for an out-of-band save
      rescue Wefunder::TokenPersistenceError => e
        err_a = e
      end
      expect(err_a.tokens.refresh_token).to eq("r2")
      expect(manager.access_token).to eq("at_live_2") # B retries persistence successfully (publishes r2)
      fail_next = true
      err_b = nil
      begin
        manager.refresh # r2 -> r3, save fails
      rescue Wefunder::TokenPersistenceError => e
        err_b = e
      end
      expect(err_b.tokens.refresh_token).to eq("r3")
      expect(manager.mark_persisted!(err_a.tokens)).to be(false) # A's stale r2 ack must NOT publish r3
      expect(manager.pending_tokens.refresh_token).to eq("r3")
      expect(manager.current.refresh_token).to eq("r2")
      expect(manager.mark_persisted!(err_b.tokens)).to be(true)
      expect(manager.current.refresh_token).to eq("r3")
      expect(manager.pending_tokens).to be_nil
    end
  end

  describe "the default rspec command is hermetic (wefunder-ruby#5)" do
    it "rake e2e sets WEFUNDER_E2E before RSpec runs (prerequisite, not a trailing action)" do
      require "rake"
      previous = ENV.fetch("WEFUNDER_E2E", nil)
      ENV.delete("WEFUNDER_E2E")
      captured = :not_run
      app = Rake::Application.new
      Rake.application = app
      Rake.load_rakefile(File.join(SpecSupport::ROOT, "Rakefile"))
      RSpec::Core::RakeTask.class_eval do
        alias_method :__real_run_task, :run_task
        define_method(:run_task) { |_verbose| captured = ENV.fetch("WEFUNDER_E2E", nil) } # no child process
      end
      begin
        app["e2e"].invoke
      ensure
        RSpec::Core::RakeTask.class_eval do
          alias_method :run_task, :__real_run_task
          remove_method :__real_run_task
        end
        previous ? ENV["WEFUNDER_E2E"] = previous : ENV.delete("WEFUNDER_E2E")
      end
      expect(captured).to eq("1")
    end

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
