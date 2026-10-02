# frozen_string_literal: true

module Wefunder
  # Holds the live token state and owns recovery + persistence. Two strategies, picked
  # automatically: refresh_token ROTATION (a refresh token + client_id present) or
  # client_credentials RE-MINT (built from cc grant inputs; cc tokens carry no refresh token).
  # Concurrent callers coalesce: the transport passes the token it just used, and if the
  # manager already holds a different one, another caller recovered in the meantime and the
  # current set is returned without a round-trip. The rotated set is persisted (store +
  # callback) BEFORE the retried request can use it. Thread-safe (Mutex).
  class TokenManager
    DEFAULT_EXPIRY_LEEWAY_SECONDS = 30.0

    attr_reader :current

    def initialize(tokens, client_id: nil, client_secret: nil, re_mint: nil, on_token_refresh: nil, store: nil,
                   faraday: nil, now: nil, expiry_leeway_seconds: DEFAULT_EXPIRY_LEEWAY_SECONDS,
                   token_base_url: nil, oauth_base_url: nil)
      @current = tokens
      @client_id = client_id
      @client_secret = client_secret
      @re_mint = re_mint
      @on_token_refresh = on_token_refresh
      @store = store
      @faraday = faraday
      @now = now || -> { Time.now.to_f }
      @leeway = expiry_leeway_seconds
      @token_base_url = OAuth.resolve_token_base(token_base_url: token_base_url, oauth_base_url: oauth_base_url)
      @lock = Mutex.new
    end

    # True if an expired token can be recovered (rotate a refresh token or re-mint).
    def can_refresh?
      can_rotate? || !@re_mint.nil?
    end

    # A valid access token, refreshing proactively if expired / within the leeway.
    def access_token
      refresh(stale_token: @current.access_token) if near_expiry? && can_refresh?
      @current.access_token
    end

    # Recover the token (after a 401 or proactively). If +stale_token+ is no longer the current
    # token, someone else already recovered and the current set is returned.
    def refresh(stale_token: nil)
      @lock.synchronize do
        return @current if stale_token && @current.access_token != stale_token

        previous_refresh = @current.refresh_token
        nxt =
          if can_rotate?
            set = OAuth.refresh_token(client_id: @client_id, client_secret: @client_secret, refresh_token: previous_refresh,
                                      token_base_url: @token_base_url, faraday: @faraday, now: @now)
            # Some servers omit a fresh refresh_token on rotation-disabled flows; keep the old one.
            set.refresh_token ||= previous_refresh
            set
          elsif @re_mint
            @re_mint.call
          else
            raise AuthError, "Access token expired and no refresh token / re-mint capability is configured."
          end
        @current = nxt
        @store&.save(nxt)
        @on_token_refresh&.call(nxt)
        nxt
      end
    end

    private

    def can_rotate?
      !@current.refresh_token.nil? && !@current.refresh_token.empty? && !@client_id.nil?
    end

    def near_expiry?
      exp = @current.expires_at
      !exp.nil? && @now.call >= exp - @leeway
    end
  end
end
