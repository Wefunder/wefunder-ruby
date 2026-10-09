# frozen_string_literal: true

# operationId: getInstallation — one installation by id (read:installations).
require "wefunder"

module GetInstallationExample
  def self.example(wf)
    # region getInstallation
    install = wf.installations.get("inst_7hQExampleInstall01")
    puts install.attributes.status, install.attributes.scopes.inspect
    # endregion
    install
  end
end
