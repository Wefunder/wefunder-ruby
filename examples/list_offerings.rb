# frozen_string_literal: true

# operationId: listOfferings — the public discovery feed (read:public).
require "wefunder"

module ListOfferingsExample
  def self.example(wf)
    # region listOfferings
    # Browse live offerings, sorted. The cursor is opaque and handled for you.
    page = wf.offerings.list(sort: "most_raised")
    page.data.each { |offering| puts "#{offering.id} #{offering.attributes.company_name}" }

    # Or stream every offering lazily, one page fetched at a time:
    wf.offerings.all(sort: "newest").each { |offering| puts offering.id }
    # endregion
    page
  end
end
