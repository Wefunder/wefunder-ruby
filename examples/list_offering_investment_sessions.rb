# frozen_string_literal: true

# operationId: listOfferingInvestmentSessions — one offering's investment sessions (read:investment_sessions; beta).
require "wefunder"

module ListOfferingInvestmentSessionsExample
  def self.example(wf)
    # region listOfferingInvestmentSessions
    page = wf.investment_sessions.list_for_offering("ofr_2nVb8KxQ4tLm9RcW7pHs3FdY", status: "completed")
    page.data.each { |session| puts "#{session.id} #{session.attributes.status}" }
    # endregion
    page
  end
end
