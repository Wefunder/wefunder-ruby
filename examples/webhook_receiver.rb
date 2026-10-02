# frozen_string_literal: true

# Verify + handle a delivery. Framework-agnostic: pass the RAW body and the headers
# (a Rack env works — HTTP_WEFUNDER_SIGNATURE is understood).
require "wefunder"

module WebhookReceiverExample
  def self.handle_delivery(raw_body, headers, secret)
    # region guides/webhook-receiver
    begin
      event = Wefunder.construct_event(raw_body, headers, secret)
    rescue Wefunder::WebhookSignatureError => e
      return [400, e.reason] # not authentic — don't process
    end

    # Acknowledge first, then do the work. Deliveries are at-least-once and unordered:
    # deduplicate on event.id and, where a payload has occurred_at, keep the latest state.
    Wefunder.dispatch_webhook(event, {
                                "investment.executed" => lambda { |e|
                                  puts "funded #{e.data["id"]} #{e.data.dig("amounts", "committed")}"
                                },
                                "offering.opened" => ->(e) { puts "opened #{e.data.dig("company", "name")}" },
                                default: ->(e) { puts "unhandled #{e.event}" }
                              })
    # endregion
    [200, "ok"]
  end
end
