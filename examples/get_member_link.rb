# frozen_string_literal: true

# operationId: getMemberLink — what the member did with their link (read:invite_links).
require "wefunder"

module GetMemberLinkExample
  def self.example(wf)
    # region getMemberLink
    link = wf.member_links.get("il_8kQm2xVb7nRt4WcY9pLe3HdA")
    puts [link.attributes.state, link.attributes.wefunder_user_id, link.attributes.investment_id].join(" ")
    # endregion
    link
  end
end
