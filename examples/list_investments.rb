# frozen_string_literal: true

# operationId: listInvestments — the Investment Delta API (read:investments).
require "wefunder"

module ListInvestmentsExample
  def self.example(wf)
    # region listInvestments
    # First sync: no cursor. Persist meta.next_cursor after EVERY page — it is always present,
    # even on the last one — and pass it back next time for only what changed.
    page = wf.investments.list(company_id: "co_abc123Example")
    page.data.each { |record| puts "#{record.id} #{record.visible}" }
    checkpoint = page.meta.next_cursor

    # Or let the SDK walk every page (stops on has_more=false):
    changed = wf.investments.collect(company_id: "co_abc123Example", updated_since: Time.utc(2026, 9, 1))
    # endregion
    [page, checkpoint, changed]
  end
end
