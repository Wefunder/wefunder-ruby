# frozen_string_literal: true

# operationId: cancelInvestmentSession — cancel a session the recipient has not completed (write:investment_sessions; beta).
require "wefunder"

module CancelInvestmentSessionExample
  def self.example(wf)
    # region cancelInvestmentSession
    session = wf.investment_sessions.cancel("is_7hQExampleSession001")
    puts session.attributes.status # "canceled"
    # endregion
    session
  end
end
