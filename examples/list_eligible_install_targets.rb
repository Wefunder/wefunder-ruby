# frozen_string_literal: true

# operationId: listEligibleInstallTargets — companies or syndicates the token's user could install your
# app on (read:installations). An investor's empty list is not a failure.
require "wefunder"

module ListEligibleInstallTargetsExample
  def self.example(wf)
    # region listEligibleInstallTargets
    targets = wf.installations.eligible_targets(target_type: "company")
    targets.each { |target| puts "#{target.id} #{target.name} #{target.tier} #{target.installed}" }
    # endregion
    targets
  end
end
