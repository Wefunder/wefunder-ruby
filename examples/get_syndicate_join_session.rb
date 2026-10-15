# frozen_string_literal: true

# operationId: getSyndicateJoinSession — the state of one join session (read:syndicates; beta).
require "wefunder"

module GetSyndicateJoinSessionExample
  def self.example(wf)
    # region getSyndicateJoinSession
    session = wf.join_sessions.get("syn_aB3xQ9k2vF8mNp1zT5wY7Qc4", "js_7hQExampleSession001")
    puts "#{session.dig("attributes", "status")} #{session.dig("attributes", "ineligible_reason")}"
    # endregion
    session
  end
end
