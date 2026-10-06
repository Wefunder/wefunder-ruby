# frozen_string_literal: true

# operationId: createInstallation — install your app on a company or syndicate the user can edit
# (write:installations) and receive the company-owned token the install stands for.
require "wefunder"

module CreateInstallationExample
  def self.example(wf)
    # region createInstallation
    install = wf.installations.create(target_type: "company", target_id: "co_abc123Example",
                                      scopes: ["read:offerings", "read:investments"])
    puts install.data.id, install.token.access_token # the token is shown once — store it
    # endregion
    install
  end
end
