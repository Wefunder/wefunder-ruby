# frozen_string_literal: true

# operationId: createReferralCode — mint a code with your app's server key (write:referral_codes; beta).
require "wefunder"

module CreateReferralCodeExample
  def self.example(wf)
    # region createReferralCode
    code = wf.referral_codes.create(label: "October newsletter",
                                    company_id: "co_7hQExampleCompany0001", # omit to credit any company
                                    utm: { source: "newsletter", campaign: "october" })
    puts "#{code.id} #{code.attributes.link_parameter}" # e.g. "wfr=ref_…" — append to any wefunder.com link
    # endregion
    code
  end
end
