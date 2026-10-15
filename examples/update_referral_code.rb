# frozen_string_literal: true

# operationId: updateReferralCode — relabel, retarget UTM, or deactivate a code (write:referral_codes; beta).
require "wefunder"

module UpdateReferralCodeExample
  def self.example(wf)
    # region updateReferralCode
    code = wf.referral_codes.update("ref_7hQExampleCode00001", active: false)
    puts code.attributes.active # false — the link keeps resolving, nothing new is credited
    # endregion
    code
  end
end
