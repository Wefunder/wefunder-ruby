# frozen_string_literal: true

# operationId: getReferralCode — one referral code by id (read:referral_codes; beta).
require "wefunder"

module GetReferralCodeExample
  def self.example(wf)
    # region getReferralCode
    code = wf.referral_codes.get("ref_7hQExampleCode00001")
    puts "#{code.attributes.label} #{code.attributes.active}"
    # endregion
    code
  end
end
