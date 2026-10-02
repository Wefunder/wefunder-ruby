# frozen_string_literal: true

# Server-to-server: exchange client credentials for a token and make a call.
# Run: WEFUNDER_CLIENT_ID=... WEFUNDER_CLIENT_SECRET=... bundle exec ruby examples/client_credentials.rb
require "wefunder"

module ClientCredentialsExample
  def self.main
    # region guides/client-credentials
    wf = Wefunder::Client.from_client_credentials(
      client_id: ENV.fetch("WEFUNDER_CLIENT_ID"),
      client_secret: ENV.fetch("WEFUNDER_CLIENT_SECRET"),
      scopes: ["read:public"]
    )

    puts "mode: #{wf.mode}" # "live" or "test", from the token prefix

    # client_credentials holds only read:public — browse public offerings.
    # (wf.users.me would raise 403 insufficient_scope: it needs read:profile.)
    wf.offerings.all.each { |offering| puts offering.id }
    # endregion
  end
end

ClientCredentialsExample.main if $PROGRAM_NAME == __FILE__
