# frozen_string_literal: true

# operationId: getReferralCodeStats — what one code produced, per company (read:referral_codes; beta).
# Each company's `level` decides the shape: `counts` carries weekly cohorts in `weeks`; `anonymized`
# and `full` carry per-investment rows in `investments` instead (`full` includes investor names and
# emails and needs a founder-tier installation grant on that company).
require "wefunder"

module GetReferralCodeStatsExample
  def self.example(wf)
    # region getReferralCodeStats
    stats = wf.referral_codes.stats("ref_7hQExampleCode00001")
    stats.data.attributes.companies.each do |company|
      if company.level == "counts"
        puts "#{company.company} #{company.weeks.size} weekly cohort(s)"
      else
        puts "#{company.company} #{company.level} #{company.investments.size} investment row(s)"
      end
    end
    # endregion
    stats
  end
end
