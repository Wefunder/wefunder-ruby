# frozen_string_literal: true

require "digest"
require "faraday"
require "json"
require "securerandom"
require "uri"

module Wefunder
  # OAuth 2.0 helpers: authorization_code + PKCE (user flows) and client_credentials
  # (server-to-server, read:public). Refresh tokens ROTATE — every refresh returns a NEW
  # refresh token that must be persisted (the client / TokenManager does this for you).
  #
  # HOST SPLIT: /token (+ refresh) is on the API gateway, which routes test/live by the
  # credential's mode, so ONE token host serves both modes. /authorize is the browser consent
  # redirect: wefunder.com for live, oauth.wefunder-sandbox.com for pk_test_ client ids.
  # Overrides: specific (authorize_base_url / token_base_url) > oauth_base_url alias > default.
  module OAuth
    DEFAULT_AUTHORIZE_BASE_URL = "https://wefunder.com/oauth"
    SANDBOX_AUTHORIZE_BASE_URL = "https://oauth.wefunder-sandbox.com/oauth"
    DEFAULT_TOKEN_BASE_URL = "https://api.wefunder.com/oauth"
    SANDBOX_CLIENT_ID_PREFIX = "pk_test_"

    # The token endpoint answered non-2xx.
    class TokenError < StandardError
      attr_reader :status, :body

      def initialize(status, body)
        super("OAuth token request failed (#{status}): #{body}")
        @status = status
        @body = body
      end
    end

    # A token set. +expires_at+ is unix seconds (Float) or nil.
    TokenSet = Struct.new(:access_token, :refresh_token, :expires_at, :scope, :token_type, keyword_init: true) do
      def self.from_token_response(raw, now)
        expires_in = raw["expires_in"] || raw[:expires_in]
        new(
          access_token: (raw["access_token"] || raw[:access_token]).to_s,
          refresh_token: raw["refresh_token"] || raw[:refresh_token],
          expires_at: expires_in ? now + expires_in.to_f : nil,
          scope: raw["scope"] || raw[:scope],
          token_type: raw["token_type"] || raw[:token_type]
        )
      end
    end

    Pkce = Struct.new(:code_verifier, :code_challenge, :code_challenge_method, keyword_init: true)

    module_function

    def resolve_token_base(token_base_url: nil, oauth_base_url: nil, **)
      token_base_url || oauth_base_url || DEFAULT_TOKEN_BASE_URL
    end

    # Sandbox consent host for pk_test_ client ids, live otherwise.
    def default_authorize_base(client_id)
      client_id.start_with?(SANDBOX_CLIENT_ID_PREFIX) ? SANDBOX_AUTHORIZE_BASE_URL : DEFAULT_AUTHORIZE_BASE_URL
    end

    # base64url without padding (no +base64+ gem dependency — it leaves the default gems in Ruby 3.4).
    def base64url(bytes)
      [bytes].pack("m0").tr("+/", "-_").delete("=")
    end

    # RFC 7636 S256: base64url(sha256(ascii(verifier))) without padding.
    def pkce_challenge(code_verifier)
      base64url(Digest::SHA256.digest(code_verifier))
    end

    # A fresh PKCE verifier/challenge pair (RFC 7636, S256).
    def generate_pkce
      verifier = base64url(SecureRandom.random_bytes(32))
      Pkce.new(code_verifier: verifier, code_challenge: pkce_challenge(verifier), code_challenge_method: "S256")
    end

    # The URL to redirect a user to for the authorization_code + PKCE flow. +state+ is an
    # opaque CSRF token you generate and verify on the callback.
    def create_authorization_url(client_id:, redirect_uri:, scopes:, state:, pkce: nil, code_challenge: nil,
                                 authorize_base_url: nil, oauth_base_url: nil, token_base_url: nil)
      _ = token_base_url # accepted for symmetry with the token helpers; never affects /authorize
      challenge = code_challenge || pkce&.code_challenge
      raise ArgumentError, "create_authorization_url: provide pkce: or code_challenge:" unless challenge

      base = authorize_base_url || oauth_base_url || default_authorize_base(client_id)
      query = URI.encode_www_form(
        response_type: "code", client_id: client_id, redirect_uri: redirect_uri, scope: Array(scopes).join(" "),
        state: state, code_challenge: challenge, code_challenge_method: "S256"
      )
      "#{base}/authorize?#{query}"
    end

    # Exchange an authorization code (+ PKCE verifier) for a token set. Public (PKCE) clients
    # omit +client_secret+; confidential clients pass it.
    def exchange_code(client_id:, code:, redirect_uri:, code_verifier:, client_secret: nil, faraday: nil, now: nil, timeout: nil,
                      **hosts)
      params = { grant_type: "authorization_code", client_id: client_id, code: code, redirect_uri: redirect_uri,
                 code_verifier: code_verifier }
      params[:client_secret] = client_secret if client_secret
      post_token(resolve_token_base(**hosts), params, faraday, now, timeout)
    end

    # Mint an application token (server-to-server). cc tokens carry no refresh token.
    def client_credentials_grant(client_id:, client_secret:, scopes: nil, faraday: nil, now: nil, timeout: nil, **hosts)
      params = { grant_type: "client_credentials", client_id: client_id, client_secret: client_secret }
      params[:scope] = Array(scopes).join(" ") if scopes && !Array(scopes).empty?
      post_token(resolve_token_base(**hosts), params, faraday, now, timeout)
    end

    # Refresh an access token. CRITICAL: the result carries a NEW refresh token (rotation) —
    # persist it. Reusing the old one after rotation is a permanent 401.
    def refresh_token(client_id:, refresh_token:, client_secret: nil, faraday: nil, now: nil, timeout: nil, **hosts)
      params = { grant_type: "refresh_token", client_id: client_id, refresh_token: refresh_token }
      params[:client_secret] = client_secret if client_secret
      post_token(resolve_token_base(**hosts), params, faraday, now, timeout)
    end

    # +faraday+ is an optional callable that configures the connection (tests inject an
    # adapter: +->(conn) { conn.adapter :test, stubs }+). +timeout+ (seconds) covers the token
    # round-trip so refreshes honour the client's timeout like every other call.
    def post_token(base, params, faraday, now, timeout = nil)
      conn = Faraday.new do |c|
        c.options.timeout = timeout if timeout
        faraday&.call(c)
        c.adapter Faraday.default_adapter unless faraday
      end
      response = conn.post("#{base}/token", URI.encode_www_form(params),
                           "Content-Type" => "application/x-www-form-urlencoded")
      raise TokenError.new(response.status, response.body.to_s) unless (200..299).cover?(response.status)

      TokenSet.from_token_response(JSON.parse(response.body.to_s), (now || -> { Time.now.to_f }).call)
    end
  end

  TokenSet = OAuth::TokenSet
  Pkce = OAuth::Pkce
end
