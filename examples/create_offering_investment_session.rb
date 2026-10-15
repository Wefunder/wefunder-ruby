# frozen_string_literal: true

# operationId: createOfferingInvestmentSession — put a known investor into checkout for one offering (write:investment_sessions; beta).
require "wefunder"

module CreateOfferingInvestmentSessionExample
  def self.example(wf)
    # region createOfferingInvestmentSession
    session = wf.investment_sessions.create("ofr_2nVb8KxQ4tLm9RcW7pHs3FdY",
                                            email: "investor@example.com", allocation_cents: 250_000,
                                            success_url: "https://yourapp.example/thanks",
                                            idempotency_key: "investor@example.com-ofr_2nVb8KxQ4tLm9RcW7pHs3FdY")
    puts session.attributes.url # hand this to the investor
    # endregion
    session
  end
end
