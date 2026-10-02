# frozen_string_literal: true

# operationId: createWebhookEndpoint — register a signed delivery target (write:webhooks, live API).
require "wefunder"

module CreateWebhookEndpointExample
  def self.example(wf)
    # region createWebhookEndpoint
    endpoint = wf.webhook_endpoints.create(
      url: "https://yourapp.com/webhooks/wefunder", # public HTTPS; localhost / private IPs are rejected
      events: ["offering.opened", "investment.executed"],
      mode: "live" # "test" endpoints receive sandbox events
    )
    # The signing secret is returned ONLY here and on rotate — store it now.
    save_secret(endpoint.attributes.secret)
    # endregion
    endpoint
  end

  # harness stand-in for your secrets store
  def self.save_secret(_secret) = nil
end
