# frozen_string_literal: true

# Runs the cross-language conformance vectors (conformance/*.json, vendored from
# Wefunder/wefunder-node at conformance/PIN) against this SDK. Every Wefunder SDK must pass every
# case identically — do NOT "fix" a vector to match the shell.
require "digest"
require "uri"

V = SpecSupport
secs = ->(unix) { -> { unix.to_f } }

RSpec.describe "conformance/webhooks.json" do
  vectors = V.vector("webhooks.json")

  it("constants") { expect(vectors["header_name"].downcase).to eq("wefunder-signature") }

  vectors["verify"].each do |c|
    it "verify: #{c["name"]}" do
      opts = { now: secs.call(c["now"]), tolerance_seconds: c["tolerance_seconds"] }
      event = nil
      result =
        begin
          event = Wefunder.construct_event(c["payload"], c["headers"], c["secret"], **opts)
          "ok"
        rescue Wefunder::WebhookSignatureError => e
          e.reason
        end
      expect(result).to eq(c.dig("expect", "result"))
      V.expect_subset(event, c["expect"]["event"]) if c["expect"]["event"]
      header = c["headers"].find { |k, _| k.downcase == "wefunder-signature" }&.last
      if header && c["expect"]["result"] != "invalid_payload"
        failure = Wefunder.check_webhook_signature(c["payload"], header, c["secret"], **opts)
        expect(failure || "ok").to eq(c["expect"]["result"])
        expect(Wefunder.verify_webhook(c["payload"], c["secret"], header: header, **opts)).to eq(c["expect"]["result"] == "ok")
      end
    end
  end

  vectors["parse_header"].each do |c|
    it "parse_header: #{c["header"].inspect}" do
      parsed = Wefunder.parse_signature_header(c["header"])
      if c["expect"].nil?
        expect(parsed).to be_nil
      else
        expect(parsed.timestamp).to eq(c["expect"]["timestamp"])
        expect(parsed.signatures).to eq(c["expect"]["signatures"])
      end
    end
  end

  vectors["sign"].each do |c|
    it "sign: #{c["name"]}" do
      header = Wefunder.sign_webhook(c["payload"], c["secret"], timestamp: c["timestamp"],
                                                                additional_secrets: c["additional_secrets"] || [])
      expect(header).to eq(c["expect_header"])
    end
  end
end

RSpec.describe "conformance/legacy_webhooks.json" do
  vectors = V.vector("legacy_webhooks.json")

  vectors["verify"].each do |c|
    it "verify: #{c["name"]}" do
      opts = { tolerance_seconds: c["tolerance_seconds"] }
      opts[:now] = secs.call(c["now"]) if c.key?("now")
      valid = Wefunder.verify_webhook(c["payload"], c["secret"], signature: c["signature"], timestamp: c["timestamp"], **opts)
      expect(valid).to eq(c["expect_valid"])
    end
  end

  vectors["construct"].each do |c|
    it "construct: #{c["name"]}" do
      event = Wefunder.construct_event(c["payload"], c["headers"], c["secret"], now: secs.call(c["now"]))
      expect(c["expect"]["result"]).to eq("ok")
      V.expect_subset(event, c["expect"]["event"])
    rescue Wefunder::WebhookSignatureError => e
      expect(e.reason).to eq(c["expect"]["result"])
    end
  end
end

RSpec.describe "conformance/errors.json" do
  vectors = V.vector("errors.json")

  it("constants") { expect(Wefunder::REQUEST_ID_HEADER.downcase).to eq(vectors["request_id_header"].downcase) }

  vectors["cases"].each do |c|
    it c["name"] do
      err = Wefunder::Error.from_response(c["status"], c["headers"], c["body"])
      expected = c["expect"].dup
      message = expected.delete("message")
      V.expect_subset({ "status" => err.status, "type" => err.type, "request_id" => err.request_id,
                        "details" => err.details, "remediation" => err.remediation }, expected)
      if message.nil?
        expect(err.message).to be_a(String)
      else
        expect(err.message).to eq(message)
      end
    end
  end
end

RSpec.describe "conformance/pagination.json" do
  vectors = V.vector("pagination.json")
  same = ->(a, b) { a.instance_of?(b.class) && a == b }

  vectors["cases"].each do |c|
    it c["name"] do
      sent = []
      fetch = lambda do |cursor|
        sent << cursor
        page = c["pages"].find { |p| (p["cursor"].nil? && cursor.nil?) || same.call(p["cursor"], cursor) }
        raise "unexpected cursor #{cursor.inspect}" unless page

        page["response"]
      end
      expect(Wefunder.paginate(fetch).to_a).to eq(c["expect"]["items"])
      expect(sent).to eq(c["expect"]["cursors_sent"])
      sent.zip(c["expect"]["cursors_sent"]).each { |a, b| expect(same.call(a, b)).to be(true) }
    end
  end
end

RSpec.describe "conformance/retry.json" do
  vectors = V.vector("retry.json")

  vectors["rate_limit_wait_ms"]["cases"].each do |c|
    it "rate_limit_wait_ms: #{c["note"]}" do
      expect(Wefunder::Transport.rate_limit_wait_ms(c["header"], c["now_ms"], c["max_delay_ms"])).to eq(c["expect_ms"])
    end
  end

  vectors["cases"].each do |c|
    it c["name"] do
      responses = c["responses"].dup
      calls = 0
      bodies = []
      auths = []
      sleeps = []
      oauth_calls = 0
      handler = lambda do |env|
        calls += 1
        auths << env.request_headers["Authorization"]
        bodies << env.body.to_s
        nxt = responses.shift
        raise Faraday::ConnectionFailed, "network_error" if nxt["network_error"]

        [nxt["status"], nxt["headers"] || {}, nxt["body"] || ""]
      end
      tm = nil
      if (t = c["token_manager"])
        oauth = lambda do |_env|
          oauth_calls += 1
          V.json_response(200, t["oauth_response"])
        end
        tm = Wefunder::TokenManager.new(Wefunder::TokenSet.new(access_token: t["access_token"], refresh_token: t["refresh_token"]),
                                        client_id: t["client_id"], faraday: V.faraday_for(oauth))
      end
      retry_opts = c["retry"] && Wefunder::RetryOptions.new(max_retries: c["retry"]["max_retries"],
                                                            base_delay_ms: c["retry"]["base_delay_ms"],
                                                            max_delay_ms: c["retry"]["max_delay_ms"])
      conn = Faraday.new do |f|
        f.use Wefunder::Transport, token_manager: tm, retry_options: retry_opts, sleep: ->(ms) { sleeps << ms },
                                   now_ms: -> { c["now_ms"] || 0 }, random: -> { c["random"] || 0 }
        f.adapter ScriptedAdapter, handler
      end
      headers = t ? { "Authorization" => "Bearer #{t["access_token"]}" } : {}
      status = threw = nil
      begin
        status = conn.run_request(c["method"].downcase.to_sym, "https://api.test/x", c["body"], headers).status
      rescue Faraday::ConnectionFailed => e
        threw = e.message
      end
      e = c["expect"]
      if e["throws"]
        expect(threw).to eq(e["throws"])
      else
        expect(status).to eq(e["final_status"])
      end
      expect(calls).to eq(e["calls"])
      expect(sleeps).to eq(e["sleeps_ms"])
      expect(bodies).to eq(e["bodies_seen"]) if e.key?("bodies_seen")
      expect(auths).to eq(e["authorization_seen"]) if e.key?("authorization_seen")
      expect(oauth_calls).to eq(e["oauth_calls"]) if e.key?("oauth_calls")
    end
  end
end

RSpec.describe "conformance/token_recovery.json" do
  vectors = V.vector("token_recovery.json")

  vectors["token_set_conversion"]["cases"].each do |c|
    it "token_set_conversion: #{c["raw"]["access_token"]}" do
      tokens = Wefunder.client_credentials_grant(client_id: "c", client_secret: "s", now: -> { c["now_ms"] / 1000.0 },
                                                 faraday: V.faraday_for(->(_e) { V.json_response(200, c["raw"]) }))
      V.expect_subset({ "access_token" => tokens.access_token, "refresh_token" => tokens.refresh_token,
                        "expires_at_ms" => tokens.expires_at && (tokens.expires_at * 1000).round,
                        "token_type" => tokens.token_type, "scope" => tokens.scope }, c["expect"])
    end
  end

  vectors["scenarios"].each do |s|
    it s["name"] do
      oauth_responses = s["oauth_responses"].dup
      oauth_params = []
      api_bearers = []
      persisted = []
      lock = Mutex.new
      handler = lambda do |env|
        lock.synchronize do
          if env.url.path.end_with?("/oauth/token")
            oauth_params << URI.decode_www_form(env.body.to_s).to_h
            raise "unexpected OAuth call" if oauth_responses.empty?

            next V.json_response(200, oauth_responses.shift)
          end
          bearer = env.request_headers["Authorization"]
          api_bearers << bearer
          api = s["api"]
          next [401, {}, "{}"] if api["reject_bearer"] && bearer == api["reject_bearer"]

          [200, { "content-type" => "application/json" }, api["accept_body"]]
        end
      end
      store = Object.new
      store.define_singleton_method(:save) { |tokens| persisted << tokens.refresh_token }
      opts = { faraday: V.faraday_for(handler) }
      opts[:now] = -> { s["now_ms"] / 1000.0 } if s.key?("now_ms")
      client = s["client"]
      if (cc = client["client_credentials"])
        wf = Wefunder::Client.from_client_credentials(client_id: cc["client_id"], client_secret: cc["client_secret"],
                                                      scopes: cc["scopes"], **opts)
        call = -> { wf.offerings.list }
      else
        t = client["tokens"]
        tokens = Wefunder::TokenSet.new(access_token: t["access_token"], refresh_token: t["refresh_token"],
                                        expires_at: t["expires_at_ms"] && (t["expires_at_ms"] / 1000.0))
        wf = Wefunder::Client.new(tokens: tokens, client_id: client["client_id"], client_secret: client["client_secret"],
                                  store: store, **opts)
        call = -> { wf.users.me }
      end
      result = "ok"
      error_status = nil
      begin
        Array.new(s["concurrent_requests"]) { Thread.new { call.call } }.each(&:join)
      rescue Wefunder::Error => e
        result = "error"
        error_status = e.status
      end
      e = s["expect"]
      expect(result).to eq(e["result"])
      expect(error_status).to eq(e["error_status"]) if e.key?("error_status")
      expect(oauth_params.size).to eq(e["oauth_calls"])
      expect(oauth_params.map { |p| p["grant_type"] }).to eq(e["oauth_grant_types"]) if e.key?("oauth_grant_types")
      (e["oauth_params"] || []).each_with_index { |want, i| V.expect_subset(oauth_params[i], want) }
      expect(wf.tokens.access_token).to eq(e["final_access_token"]) if e.key?("final_access_token")
      expect(wf.tokens.refresh_token).to eq(e["final_refresh_token"]) if e.key?("final_refresh_token")
      expect(persisted).to eq(e["persisted_refresh_tokens"]) if e.key?("persisted_refresh_tokens")
      expect(api_bearers.last).to eq(e["last_api_bearer"]) if e.key?("last_api_bearer")
      expect(api_bearers.size).to eq(e["api_calls"]) if e.key?("api_calls")
    end
  end
end

RSpec.describe "conformance/oauth.json" do
  vectors = V.vector("oauth.json")
  k = vectors["constants"]

  it "constants" do
    expect(Wefunder::DEFAULT_API_BASE_URL).to eq(k["api_base_url"])
    expect(Wefunder::DEFAULT_API_VERSION).to eq(k["default_api_version"])
    expect(Wefunder::OAuth::DEFAULT_AUTHORIZE_BASE_URL).to eq(k["authorize_base_url_live"])
    expect(Wefunder::OAuth::SANDBOX_AUTHORIZE_BASE_URL).to eq(k["authorize_base_url_sandbox"])
    expect(Wefunder::OAuth::DEFAULT_TOKEN_BASE_URL).to eq(k["token_base_url"])
  end

  vectors["mode_from_token"].each do |c|
    it("mode_from_token: #{c["token"].inspect}") { expect(Wefunder.mode_for_token(c["token"])).to eq(c["expect"]) }
  end

  it "pkce: RFC 7636 vector + generated pairs obey the relation" do
    p = vectors["pkce"]
    expect(Wefunder.pkce_challenge(p["verifier"])).to eq(p["challenge"])
    g = Wefunder.generate_pkce
    expect(g.code_challenge_method).to eq(p["method"])
    expect(g.code_verifier).to match(Regexp.new(p["verifier_charset_regex"]))
    expect(Wefunder.pkce_challenge(g.code_verifier)).to eq(g.code_challenge)
  end

  vectors["authorize_url"].each do |c|
    it "authorize_url: #{c["name"]}" do
      url = URI(Wefunder.create_authorization_url(
                  client_id: c["client_id"], redirect_uri: c["redirect_uri"], scopes: c["scopes"], state: c["state"],
                  code_challenge: c["code_challenge"], authorize_base_url: c["authorize_base_url"],
                  token_base_url: c["token_base_url"], oauth_base_url: c["oauth_base_url"]
                ))
      expect("#{url.scheme}://#{url.host}#{url.path}").to eq(c["expect"]["base"])
      params = URI.decode_www_form(url.query).to_h
      (c["expect"]["params"] || {}).each { |key, value| expect(params[key]).to eq(value) }
    end
  end

  # Snapshot the request at call time — Faraday reuses the env, so after the call env.body is
  # the RESPONSE body.
  Captured = Struct.new(:verb, :url, :headers, :body)
  capture = lambda do
    seen = []
    [seen, V.faraday_for(lambda do |env|
      seen << Captured.new(env.method, env.url.to_s, env.request_headers.to_h, env.body.to_s)
      V.json_response(200, { "access_token" => "at_test_x" })
    end)]
  end

  vectors["token_host"].each do |c|
    it "token_host: #{c["name"]}" do
      seen, faraday = capture.call
      o = c["overrides"]
      Wefunder.client_credentials_grant(client_id: "c", client_secret: "s", faraday: faraday,
                                        token_base_url: o["token_base_url"], oauth_base_url: o["oauth_base_url"])
      expect(seen.first.url).to eq(c["expect_url"])
    end
  end

  vectors["token_requests"]["cases"].each do |c|
    it "token_requests: #{c["name"]}" do
      seen, faraday = capture.call
      case c["grant"]
      when "client_credentials"
        Wefunder.client_credentials_grant(client_id: c["client_id"], client_secret: c["client_secret"], scopes: c["scopes"],
                                          faraday: faraday)
      when "authorization_code"
        Wefunder.exchange_code(client_id: c["client_id"], client_secret: c["client_secret"], code: c["code"],
                               redirect_uri: c["redirect_uri"], code_verifier: c["code_verifier"], faraday: faraday)
      else
        Wefunder.refresh_token(client_id: c["client_id"], client_secret: c["client_secret"], refresh_token: c["refresh_token"],
                               faraday: faraday)
      end
      req = seen.first
      expect(req.verb).to eq(:post)
      expect(req.headers["Content-Type"]).to start_with("application/x-www-form-urlencoded")
      params = URI.decode_www_form(req.body).to_h
      expect(params).to eq(c["expect"]["params"])
      (c["expect"]["absent"] || []).each { |key| expect(params).not_to have_key(key) }
    end
  end

  it "token_requests: non-2xx raises with the status in the message" do
    e = vectors["token_requests"]["error"]
    faraday = V.faraday_for(->(_env) { [e["status"], {}, e["body"]] })
    expect { Wefunder.refresh_token(client_id: "c", refresh_token: "r", faraday: faraday) }
      .to raise_error(Wefunder::OAuth::TokenError, /#{e["expect_message_includes"]}/)
  end
end

RSpec.describe "conformance/manifest.json" do
  it "vendored vectors match the pinned manifest" do
    manifest = V.vector("manifest.json")
    manifest["files"].each do |name, sha|
      actual = Digest::SHA256.hexdigest(File.binread(File.join(V::ROOT, "conformance", name)))
      expect(actual).to eq(sha), "#{name} differs from the pinned manifest — run script/sync_conformance.rb"
    end
  end
end
