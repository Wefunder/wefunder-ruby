# frozen_string_literal: true

module Wefunder
  # Holds the live token state and owns recovery + persistence. Two strategies, picked
  # automatically: refresh_token ROTATION (a refresh token + client_id present) or
  # client_credentials RE-MINT (built from cc grant inputs; cc tokens carry no refresh token).
  # Concurrent callers coalesce: the transport passes the token it just used, and if the
  # manager already holds a different one, another caller recovered in the meantime and the
  # current set is returned without a round-trip. The rotated set is persisted (store +
  # callback) BEFORE the retried request can use it. Thread-safe (Mutex).
  # Raised when the token store failed to save a rotated token set. +tokens+ is the rotated
  # set that is NOT yet durable and NOT yet in use; the manager keeps it pending and retries
  # the save on the next call (or persist it yourself and call +mark_persisted!(tokens)+). Until it is
  # saved no request is made with it — the consumed refresh token is never reused either.
  class TokenPersistenceError < StandardError
    attr_reader :tokens

    def initialize(tokens, cause)
      super("Token store failed to save the rotated token set: #{cause.message}")
      @tokens = tokens
    end
  end

  class TokenManager
    DEFAULT_EXPIRY_LEEWAY_SECONDS = 30.0

    # The durable, in-use token set. A rotated set that could not be persisted is held in
    # +pending_tokens+ instead until a save succeeds.
    attr_reader :current, :pending_tokens

    def initialize(tokens, client_id: nil, client_secret: nil, re_mint: nil, on_token_refresh: nil, store: nil,
                   faraday: nil, now: nil, expiry_leeway_seconds: DEFAULT_EXPIRY_LEEWAY_SECONDS,
                   token_base_url: nil, oauth_base_url: nil, timeout: nil)
      @current = tokens
      @client_id = client_id
      @client_secret = client_secret
      @re_mint = re_mint
      @on_token_refresh = on_token_refresh
      @store = store
      @faraday = faraday
      @timeout = timeout
      @now = now || -> { Time.now.to_f }
      @leeway = expiry_leeway_seconds
      @token_base_url = OAuth.resolve_token_base(token_base_url: token_base_url, oauth_base_url: oauth_base_url)
      @lock = Mutex.new
    end

    # True if an expired token can be recovered (rotate a refresh token or re-mint).
    def can_refresh?
      can_rotate? || !@re_mint.nil?
    end

    # A valid access token, refreshing proactively if expired / within the leeway. If a rotated
    # set is pending persistence, the save is retried first — no request uses an undurable token.
    def access_token
      @lock.synchronize { publish_pending! if @pending_tokens } if @pending_tokens # re-check under the lock
      refresh(stale_token: @current.access_token) if near_expiry? && can_refresh?
      @current.access_token
    end

    # Tell the manager you persisted +tokens+ (the set from a TokenPersistenceError) yourself.
    # Publishes it only if it is still the pending set; a stale acknowledgment (the manager has
    # since rotated again) is a no-op and returns false, so an older save can never publish a
    # newer, unsaved set.
    def mark_persisted!(tokens)
      @lock.synchronize do
        return false unless @pending_tokens && same_token_set?(@pending_tokens, tokens)

        @current = @pending_tokens
        @pending_tokens = nil
        true
      end
    end

    # Recover the token (after a 401 or proactively). If +stale_token+ is no longer the current
    # token, someone else already recovered and the current set is returned.
    def refresh(stale_token: nil)
      @lock.synchronize do
        # A rotated set awaiting persistence: retry the save rather than rotating again (the
        # old refresh token was consumed by that rotation).
        return publish_pending! if @pending_tokens
        return @current if stale_token && @current.access_token != stale_token

        previous_refresh = @current.refresh_token
        nxt =
          if can_rotate?
            set = OAuth.refresh_token(client_id: @client_id, client_secret: @client_secret, refresh_token: previous_refresh,
                                      token_base_url: @token_base_url, faraday: @faraday, now: @now, timeout: @timeout)
            # Some servers omit a fresh refresh_token on rotation-disabled flows; keep the old one.
            set.refresh_token ||= previous_refresh
            set
          elsif @re_mint
            @re_mint.call
          else
            raise AuthError, "Access token expired and no refresh token / re-mint capability is configured."
          end
        @pending_tokens = nxt
        publish_pending!
      end
    end

    private

    # Persist BEFORE publishing (caller holds the lock): no thread may use the rotated token
    # until it is durable, and a failed save must not leave the process working in memory but
    # unable to reconnect after a restart. On failure the set stays in +pending_tokens+ and
    # TokenPersistenceError is raised; the next call retries the save.
    def publish_pending!
      tokens = @pending_tokens
      begin
        @store&.save(tokens)
        # on_token_refresh is a persistence path too, so it runs BEFORE publication and a failure
        # keeps the set pending exactly like a store failure.
        @on_token_refresh&.call(tokens)
      rescue StandardError => e
        raise TokenPersistenceError.new(tokens, e)
      end
      @pending_tokens = nil
      @current = tokens
      tokens
    end

    def same_token_set?(a, b)
      a.access_token == b.access_token && a.refresh_token == b.refresh_token
    end

    def can_rotate?
      !@current.refresh_token.nil? && !@current.refresh_token.empty? && !@client_id.nil?
    end

    def near_expiry?
      exp = @current.expires_at
      !exp.nil? && @now.call >= exp - @leeway
    end
  end
end
