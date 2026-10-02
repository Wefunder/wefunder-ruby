# frozen_string_literal: true

# operationId: listCompanyInvestmentChanges — the company-scoped Investment Delta feed
# (read:investments or read:companies; the user must be able to edit the company).
require "wefunder"

module ListCompanyInvestmentChangesExample
  def self.example(wf, company_id = "co_abc123Example")
    # region listCompanyInvestmentChanges
    # Walk every change for one company. Persist meta.next_cursor after each page — it is
    # always present, even on the last page — and pass it back next sync for only what changed.
    cursor = nil
    loop do
      page = wf.wrap { wf.raw.investment_delta.list_company_investment_changes(company_id, cursor: cursor, per_page: 50) }
      page.data.each { |record| puts "#{record.id} #{record.visible}" }
      cursor = page.meta.next_cursor
      break unless page.meta.has_more
    end
    # endregion
    cursor
  end
end
