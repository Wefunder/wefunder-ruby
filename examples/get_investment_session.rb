# frozen_string_literal: true

# operationId: getInvestmentSession — one investment session by id (read:investment_sessions; beta).
require "wefunder"

module GetInvestmentSessionExample
  def self.example(wf)
    # region getInvestmentSession
    session = wf.investment_sessions.get("is_7hQExampleSession001")
    puts session.attributes.status
    # endregion
    session
  end
end
