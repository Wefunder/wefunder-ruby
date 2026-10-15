# frozen_string_literal: true

# operationId: listOfferingMemberLinks — your app's member links on one offering (read:invite_links).
require "wefunder"

module ListOfferingMemberLinksExample
  def self.example(wf)
    # region listOfferingMemberLinks
    wf.member_links.all("ofr_2nVb8KxQ4tLm9RcW7pHs3FdY").each do |link|
      puts "#{link.id} #{link.attributes.reference} #{link.attributes.state}"
    end
    # endregion
    nil
  end
end
