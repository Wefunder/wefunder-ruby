# frozen_string_literal: true

# operationId: getReferralCodeStats — weekly cohorts per company for one code (read:referral_codes; beta).
require "wefunder"

module GetReferralCodeStatsExample
  def self.example(wf)
    # region getReferralCodeStats
    stats = wf.referral_codes.stats("ref_7hQExampleCode00001")
    stats.data.attributes.companies.each do |company|
      puts "#{company.company} #{company.level} #{company.weeks.size} weekly cohort(s)"
    end
    # endregion
    stats
  end
end
