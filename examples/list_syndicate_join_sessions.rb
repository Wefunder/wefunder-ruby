# frozen_string_literal: true

# operationId: listSyndicateJoinSessions — your syndicate's join sessions (read:syndicates; beta).
require "wefunder"

module ListSyndicateJoinSessionsExample
  def self.example(wf)
    # region listSyndicateJoinSessions
    wf.join_sessions.all("syn_aB3xQ9k2vF8mNp1zT5wY7Qc4").each do |session|
      puts "#{session["id"]} #{session.dig("attributes", "status")} #{session.dig("attributes", "email")}"
    end
    # endregion
    nil
  end
end
