# frozen_string_literal: true

# operationId: listInvestmentSessions — every investment session your app created (read:investment_sessions; beta).
require "wefunder"

module ListInvestmentSessionsExample
  def self.example(wf)
    # region listInvestmentSessions
    wf.investment_sessions.all(status: "in_progress").each { |session| puts "#{session.id} #{session.attributes.status}" }
    # endregion
    nil
  end
end
