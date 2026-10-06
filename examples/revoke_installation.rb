# frozen_string_literal: true

# operationId: revokeInstallation — revoke an installation (write:installations). Its tokens stop working
# at once and the company drops out of your webhook audiences.
require "wefunder"

module RevokeInstallationExample
  def self.example(wf)
    # region revokeInstallation
    revoked = wf.installations.revoke("ins_9t2xExample")
    puts revoked.attributes.status # "revoked"
    # endregion
    revoked
  end
end
