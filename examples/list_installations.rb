# frozen_string_literal: true

# operationId: listInstallations — where your app is installed (read:installations). An installation is
# what makes a company/syndicate an AUDIENCE for your webhooks — no install, no deliveries.
require "wefunder"

module ListInstallationsExample
  def self.example(wf)
    # region listInstallations
    installs = wf.installations.list
    installs.data.each { |install| puts "#{install.id} #{install.attributes.target.id} #{install.attributes.status}" }
    # endregion
    installs
  end
end
