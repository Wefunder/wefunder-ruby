# frozen_string_literal: true

# Hidden harness — NOT shown in docs (no region markers; leading `_` excludes it from the
# manifest). The e2e run-gate calls each `example(wf)` with this real sandbox client.
require "wefunder"

module ExampleBoot
  def self.client
    Wefunder::Client.from_client_credentials(client_id: ENV.fetch("WEFUNDER_CLIENT_ID"),
                                             client_secret: ENV.fetch("WEFUNDER_CLIENT_SECRET"), scopes: ["read:public"])
  end
end
