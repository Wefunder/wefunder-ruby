# frozen_string_literal: true

require "json"
require "openssl"

module Wefunder
  # Webhook verification + parsing for Wefunder platform events. The scheme is a single
  # Stripe-style header:
  #   Wefunder-Signature: t=<unix seconds>,v1=<hex>[,v1=<hex>]
  #   v1 = HMAC-SHA256(secret, "<t>.<raw_body>")
  # During a secret rotation the header carries one +v1+ per active secret; a delivery is
  # valid if ANY matches. Consumers enforce a replay tolerance on +t+ (documented: 5 min).
  # Every delivery body is the envelope +{id: "evt_…", event, created_at, mode, data}+ —
  # +id+ is the dedup key. The retired attribution scheme (+X-Wefunder-Signature: sha256=…+
  # + +X-Wefunder-Timestamp+) is still accepted by +construct_event+ when the new header is
  # absent, so an attribution subscriber isn't stranded.
  module Webhooks
    SIGNATURE_HEADER = "wefunder-signature"
    DEFAULT_TOLERANCE_SECONDS = 300
    LEGACY_SIGNATURE_HEADER = "x-wefunder-signature"
    LEGACY_TIMESTAMP_HEADER = "x-wefunder-timestamp"
    LEGACY_EVENT_HEADER = "x-wefunder-event"
    LEGACY_DELIVERY_ID_HEADER = "x-wefunder-delivery-id"

    FAILURE_REASONS = %w[missing_header malformed_header timestamp_out_of_tolerance signature_mismatch
                         invalid_payload].freeze
    FAILURE_MESSAGES = {
      "missing_header" => "Missing Wefunder-Signature header",
      "malformed_header" => "Wefunder-Signature header is malformed (expected t=<unix>,v1=<hex>)",
      "timestamp_out_of_tolerance" => "Webhook timestamp is outside the replay tolerance",
      "signature_mismatch" => "Webhook signature verification failed",
      "invalid_payload" => "Webhook body is not a JSON object"
    }.freeze

    # Every event name in the catalog. Kept in step with the spec's +events+ enum by
    # spec/webhooks_spec.rb, which fails when the two diverge.
    EVENT_NAMES = %w[
      investment.created investment.reinstated investment.canceled investment.converted
      investment.amount_changed investment.executed investment.changed
      offering.opened offering.closing offering.closed offering.canceled
      investment_session.created investment_session.started investment_session.completed
      investment_session.expired investment_session.canceled
      syndicate_member.invited syndicate_member.reinvited syndicate_member.applied
      syndicate_member.approved syndicate_member.joined
    ].freeze

    # Raised by +construct_event+. Respond 400 and don't process.
    class SignatureError < StandardError
      attr_reader :reason

      def initialize(reason)
        super(FAILURE_MESSAGES.fetch(reason))
        @reason = reason
      end
    end

    # A verified, parsed delivery. +timestamp+ is the signed +t+ (unix seconds).
    Event = Struct.new(:id, :event, :created_at, :mode, :data, :timestamp, keyword_init: true) do
      def known? = EVENT_NAMES.include?(event)
    end

    ParsedHeader = Struct.new(:timestamp, :signatures, keyword_init: true)

    module_function

    # HMAC-SHA256(secret, "<timestamp>.<raw body>") as lowercase hex.
    def compute_signature(secret, timestamp, payload)
      OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.".b + payload.to_s.b)
    end

    # Parse +t=<unix>,v1=<hex>[,v1=<hex>]+. nil when the shape is wrong. Unknown keys (a
    # future +v2+) are ignored on purpose.
    def parse_signature_header(header)
      timestamp = nil
      signatures = []
      header.to_s.split(",").each do |part|
        key, eq, value = part.partition("=")
        next if eq.empty?

        key = key.strip
        value = value.strip
        if key == "t"
          return nil unless value.match?(/\A\d+\z/)

          timestamp = value.to_i
        elsif key == "v1" && !value.empty?
          signatures << value
        end
      end
      return nil if timestamp.nil? || signatures.empty?

      ParsedHeader.new(timestamp: timestamp, signatures: signatures)
    end

    # Build a +Wefunder-Signature+ header value for +payload+ (for your own tests — the API
    # signs real deliveries). +additional_secrets+ adds one +v1+ per secret (rotation window).
    def sign(payload, secret, timestamp: nil, additional_secrets: [])
      t = timestamp || Time.now.to_i
      entries = [secret, *additional_secrets].map { |s| "v1=#{compute_signature(s, t, payload)}" }
      ["t=#{t}", *entries].join(",")
    end

    # The reason a delivery is NOT valid, or nil when it is. Constant-time compare against
    # every +v1+; enforces the timestamp tolerance (0 disables it).
    def check_signature(payload, header, secret, tolerance_seconds: DEFAULT_TOLERANCE_SECONDS, now: nil)
      parsed = parse_signature_header(header)
      return "malformed_header" unless parsed
      if tolerance_seconds.positive? && (now_f(now) - parsed.timestamp).abs > tolerance_seconds
        return "timestamp_out_of_tolerance"
      end

      expected = compute_signature(secret, parsed.timestamp, payload)
      parsed.signatures.any? { |sig| secure_equal?(sig, expected) } ? nil : "signature_mismatch"
    end

    # Legacy attribution scheme: +X-Wefunder-Signature: sha256=<hex>+ + +X-Wefunder-Timestamp+.
    def verify_legacy(payload, signature, timestamp, secret, tolerance_seconds: DEFAULT_TOLERANCE_SECONDS, now: nil)
      ts = Integer(timestamp.to_s, exception: false)
      return false if ts.nil?
      return false if tolerance_seconds.positive? && (now_f(now) - ts).abs > tolerance_seconds

      secure_equal?(signature.to_s, "sha256=#{compute_signature(secret, timestamp, payload)}")
    end

    # true iff the signature is valid and (when tolerance > 0) the timestamp is within
    # tolerance. Never raises. Pass +header:+ (the Wefunder-Signature value) or, for a legacy
    # attribution subscription, +signature:+ + +timestamp:+.
    def verify(payload, secret, header: nil, signature: nil, timestamp: nil,
               tolerance_seconds: DEFAULT_TOLERANCE_SECONDS, now: nil)
      return check_signature(payload, header, secret, tolerance_seconds: tolerance_seconds, now: now).nil? if header
      return false if signature.nil? || timestamp.nil?

      verify_legacy(payload, signature, timestamp, secret, tolerance_seconds: tolerance_seconds, now: now)
    end

    # Verify a delivery and parse its envelope in one step. Raises SignatureError (with
    # +reason+) on any failure. +payload+ is the RAW request body; +headers+ is any
    # case-insensitive mapping (Rack env style keys are accepted too), or the header value itself.
    def construct_event(payload, headers, secret, tolerance_seconds: DEFAULT_TOLERANCE_SECONDS, now: nil)
      get = header_getter(headers)
      header = get.call(SIGNATURE_HEADER)
      unless header
        legacy_sig = get.call(LEGACY_SIGNATURE_HEADER)
        legacy_ts = get.call(LEGACY_TIMESTAMP_HEADER)
        if legacy_sig && legacy_ts
          return construct_legacy_event(payload, get, legacy_sig, legacy_ts, secret, tolerance_seconds, now)
        end

        raise SignatureError, "missing_header"
      end
      failure = check_signature(payload, header, secret, tolerance_seconds: tolerance_seconds, now: now)
      raise SignatureError, failure if failure

      parsed = parse_signature_header(header)
      env = parse_envelope(payload)
      Event.new(id: env["id"].to_s, event: env["event"].to_s, created_at: env["created_at"].to_s,
                mode: mode_of(env["mode"]), data: env["data"], timestamp: parsed.timestamp)
    end

    # Call the handler registered for +event.event+, falling back to "default". Returns true
    # if a handler ran. Handlers are callables (procs/lambdas/method objects).
    def dispatch(event, handlers)
      handler = pick_handler(event, handlers)
      return false unless handler

      handler.call(event)
      true
    end

    # --- internals -----------------------------------------------------------------------

    def now_f(now) = (now || -> { Time.now.to_f }).call

    def secure_equal?(a, b)
      return false unless a.bytesize == b.bytesize

      OpenSSL.fixed_length_secure_compare(a, b)
    end

    def header_getter(headers)
      return ->(name) { name == SIGNATURE_HEADER ? headers : nil } if headers.is_a?(String)

      lowered = {}
      headers.each do |k, v|
        key = k.to_s.downcase
        key = key.delete_prefix("http_").tr("_", "-") if key.start_with?("http_") # Rack env style
        lowered[key] = v
      end
      lambda do |name|
        value = lowered[name]
        value = value.first if value.is_a?(Array)
        value&.to_s
      end
    end

    def parse_envelope(payload)
      parsed = JSON.parse(payload.to_s)
      raise SignatureError, "invalid_payload" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      raise SignatureError, "invalid_payload"
    end

    def mode_of(value) = value == "test" ? "test" : "live"

    def construct_legacy_event(payload, get, signature, timestamp, secret, tolerance_seconds, now)
      unless verify_legacy(payload, signature, timestamp, secret, tolerance_seconds: tolerance_seconds, now: now)
        raise SignatureError, "signature_mismatch"
      end

      env = parse_envelope(payload)
      Event.new(id: (env["id"] || get.call(LEGACY_DELIVERY_ID_HEADER)).to_s,
                event: (env["event"] || get.call(LEGACY_EVENT_HEADER)).to_s,
                created_at: env["created_at"].to_s, mode: mode_of(env["mode"]),
                data: env.key?("data") ? env["data"] : env, timestamp: timestamp.to_i)
    end

    def pick_handler(event, handlers)
      specific = event.event == "default" ? nil : (handlers[event.event] || handlers[event.event.to_sym])
      specific || handlers["default"] || handlers[:default]
    end
  end

  WebhookEvent = Webhooks::Event
  WebhookSignatureError = Webhooks::SignatureError
  WEBHOOK_EVENT_NAMES = Webhooks::EVENT_NAMES

  class << self
    def construct_event(...) = Webhooks.construct_event(...)
    def verify_webhook(...) = Webhooks.verify(...)
    def check_webhook_signature(...) = Webhooks.check_signature(...)
    def sign_webhook(...) = Webhooks.sign(...)
    def compute_webhook_signature(...) = Webhooks.compute_signature(...)
    def parse_signature_header(...) = Webhooks.parse_signature_header(...)
    def dispatch_webhook(...) = Webhooks.dispatch(...)
  end
end
