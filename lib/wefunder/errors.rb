# frozen_string_literal: true

require "json"

module Wefunder
  # Response header carrying the partner-facing request id (Stripe-style +req_…+).
  REQUEST_ID_HEADER = "X-Wf-Request-Id"
  # +type+ reported when the body is not the documented envelope.
  FALLBACK_ERROR_TYPE = "api_error"

  # An API call failed. Mapped from the REAL error envelope
  # (api/v2/base_controller.rb#render_error):
  #   {"error": {"type", "message", "details"?, "request_id", "remediation"?}}
  # +request_id+ and +remediation+ are NESTED under +error+. The +X-Wf-Request-Id+ response
  # header is set on every authenticated response — even an HTML 502 from the edge — so it
  # is preferred over the body's id.
  class Error < StandardError
    DOCUMENTATION_URL = "https://docs.wefunder.com/api-reference"

    attr_reader :status, :type, :request_id, :details, :remediation

    def initialize(status:, type:, message:, request_id: nil, details: nil, remediation: nil)
      super(message)
      @status = status
      @type = type
      @request_id = request_id
      @details = details
      @remediation = remediation
    end

    # One-line summary for logs. (+message+ stays the server's message verbatim — in Ruby
    # +Exception#message+ delegates to +to_s+, so this is deliberately NOT a +to_s+ override.)
    def summary
      parts = ["#{status} #{type}: #{message}"]
      parts << "(request_id=#{request_id})" if request_id
      parts << "— #{remediation}" if remediation
      parts.join(" ")
    end

    def inspect = "#<#{self.class.name} #{summary}>"

    # Prefer the +X-Wf-Request-Id+ header; fall back to a body-derived id.
    def self.request_id_from(headers, body_request_id)
      header = (headers || {}).find { |k, _| k.to_s.casecmp?(REQUEST_ID_HEADER) }&.last
      header = header.first if header.is_a?(Array)
      (header.nil? || header.empty? ? nil : header) || body_request_id
    end

    # Build an Error from a failed response's parts. Degrades gracefully when the body is
    # not the documented shape (non-JSON, empty, or a bare object).
    def self.from_response(status, headers, body, reason_phrase: nil)
      parsed = parse_body(body)
      err = parsed.is_a?(Hash) && parsed["error"].is_a?(Hash) ? parsed["error"] : {}
      top_level_request_id = parsed.is_a?(Hash) ? parsed["request_id"] : nil
      message = if err["message"].is_a?(String)
                  err["message"]
                else
                  (reason_phrase.to_s.empty? ? "Request failed" : reason_phrase)
                end
      new(
        status: status.to_i,
        type: err["type"].is_a?(String) ? err["type"] : FALLBACK_ERROR_TYPE,
        message: message,
        request_id: request_id_from(headers, err["request_id"] || top_level_request_id),
        details: err["details"],
        remediation: err["remediation"].is_a?(String) ? err["remediation"] : nil
      )
    end

    def self.parse_body(body)
      return body if body.is_a?(Hash)
      return nil if body.nil? || body.to_s.empty?

      JSON.parse(body.to_s)
    rescue JSON::ParserError
      nil
    end
    private_class_method :parse_body
  end

  # Raised when a token must be recovered but no refresh token / re-mint capability exists.
  class AuthError < Error
    def initialize(message)
      super(status: 401, type: "unauthorized", message: message)
    end
  end
end
