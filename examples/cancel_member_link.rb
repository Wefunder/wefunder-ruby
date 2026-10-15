# frozen_string_literal: true

# operationId: cancelMemberLink — stop an unused link from opening the deal page (write:invite_links).
require "wefunder"

module CancelMemberLinkExample
  def self.example(wf)
    # region cancelMemberLink
    link = wf.member_links.cancel("il_8kQm2xVb7nRt4WcY9pLe3HdA")
    puts link.attributes.state # "canceled"
    # endregion
    link
  end
end
