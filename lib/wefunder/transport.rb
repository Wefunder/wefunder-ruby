# frozen_string_literal: true

require "faraday"

module Wefunder
  # The retry/refresh Faraday middleware. Owns the Authorization header (reads the managed
  # token per attempt) and applies the contract-driven policy:
  # * 401 → recover the token (rotation or re-mint) and retry ONCE, any method.
  # * 429 → honour X-RateLimit-Reset (NOT Retry-After) and retry, bounded.
  # * 5xx / network error → retry IDEMPOTENT methods only (GET/HEAD/OPTIONS) with jittered
  #   exponential backoff. Writes are never auto-retried.
  # Every attempt re-sends the same body (Faraday bodies are strings), which is what made
  # the equivalent Node fix necessary.
  class Transport < Faraday::Middleware
    IDEMPOTENT_METHODS = %w[GET HEAD OPTIONS].freeze
    RATE_LIMIT_RESET_HEADER = "x-ratelimit-reset"
    NETWORK_ERRORS = [Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError].freeze

    RetryOptions = Struct.new(:max_retries, :base_delay_ms, :max_delay_ms, keyword_init: true) do
      def self.defaults = new(max_retries: 2, base_delay_ms: 250.0, max_delay_ms: 60_000.0)
    end

    # How long to wait for a 429. X-RateLimit-Reset may be absolute epoch SECONDS (values
    # above ~1e9) or a delta in seconds. Absent/non-numeric → 1s; clamped to [0, max].
    def self.rate_limit_wait_ms(reset_header, now_ms, max_delay_ms)
      fallback = [1000.0, max_delay_ms].min
      return fallback if reset_header.nil?

      n = Float(reset_header, exception: false)
      return fallback if n.nil?

      wait = n > 1_000_000_000 ? (n * 1000) - now_ms : n * 1000
      wait.clamp(0.0, max_delay_ms)
    end

    # min(base·2ⁿ + base·2ⁿ·0.5·random, max) for retry attempt n (1-based).
    def self.backoff_ms(attempt, opts, random_value)
      exp = opts.base_delay_ms * (2**attempt)
      [exp + (exp * 0.5 * random_value), opts.max_delay_ms].min
    end

    def initialize(app, token_manager: nil, retry_options: nil, sleep: nil, now_ms: nil, random: nil)
      super(app)
      @token_manager = token_manager
      @retry = retry_options || RetryOptions.defaults
      @sleep = sleep || ->(ms) { Kernel.sleep(ms / 1000.0) }
      @now_ms = now_ms || -> { Time.now.to_f * 1000 }
      @random = random || -> { Kernel.rand }
    end

    def call(env)
      idempotent = IDEMPOTENT_METHODS.include?(env.method.to_s.upcase)
      token = @token_manager&.access_token
      refreshed = false
      attempt = 0
      loop do
        env.request_headers["Authorization"] = "Bearer #{token}" if token
        response = nil
        error = nil
        begin
          response = @app.call(env.dup)
        rescue *NETWORK_ERRORS => e
          error = e
        end
        status = response&.status

        if status == 401 && !refreshed && @token_manager&.can_refresh?
          refreshed = true
          token = @token_manager.refresh(stale_token: token).access_token
          next
        end

        delay = nil
        if status == 429 && attempt < @retry.max_retries
          delay = self.class.rate_limit_wait_ms(response.headers[RATE_LIMIT_RESET_HEADER], @now_ms.call, @retry.max_delay_ms)
        elsif (error || (status && status >= 500)) && idempotent && attempt < @retry.max_retries
          delay = self.class.backoff_ms(attempt + 1, @retry, @random.call)
        end
        if delay
          attempt += 1
          @sleep.call(delay)
          next
        end

        return response if response

        raise error
      end
    end
  end

  RetryOptions = Transport::RetryOptions
end
