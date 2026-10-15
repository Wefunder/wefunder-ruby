# frozen_string_literal: true

# operationId: listReferralCodes — your app's referral codes (read:referral_codes; beta).
require "wefunder"

module ListReferralCodesExample
  def self.example(wf)
    # region listReferralCodes
    wf.referral_codes.all(active: true).each { |code| puts "#{code.id} #{code.attributes.label}" }
    # endregion
    nil
  end
end
