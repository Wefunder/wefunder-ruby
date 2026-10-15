# frozen_string_literal: true

# operationId: createSyndicateJoinSession — mint a hosted join session for one person (write:syndicate_members; beta).
require "wefunder"

module CreateSyndicateJoinSessionExample
  def self.example(wf)
    # region createSyndicateJoinSession
    session = wf.join_sessions.create("syn_aB3xQ9k2vF8mNp1zT5wY7Qc4", email: "member@example.com", name: "Ada Example",
                                                                      require_approval: true,
                                                                      success_url: "https://yourapp.example/joined")
    puts session.dig("attributes", "url") # send the person here; the outcome arrives as join_session.* webhooks
    # endregion
    session
  end
end
