# frozen_string_literal: true

# operationId: createInstallationToken — mint a company-owned token for an install a founder made
# (write:installations). An explicit empty `scopes` grants nothing; omit it for the install's ceiling.
require "wefunder"

module CreateInstallationTokenExample
  def self.example(wf)
    # region createInstallationToken
    minted = wf.installations.mint_token("inst_7hQExampleInstall01", ["read:investments"])
    puts minted.token.access_token # shown once — store it
    # endregion
    minted
  end
end
