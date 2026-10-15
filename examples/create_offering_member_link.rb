# frozen_string_literal: true

# operationId: createOfferingMemberLink — mint a member's link to one deal page (write:invite_links).
require "wefunder"

module CreateOfferingMemberLinkExample
  def self.example(wf)
    # region createOfferingMemberLink
    # `reference` is your member id. Repeating it returns the live link instead of a second one;
    # the idempotency key makes a retried request safe as well.
    link = wf.member_links.create("ofr_2nVb8KxQ4tLm9RcW7pHs3FdY", reference: "member_8812",
                                                                  idempotency_key: "member_8812-ofr_2nVb8KxQ4tLm9RcW7pHs3FdY")
    puts link.attributes.url # send this to the member; it carries no email
    # endregion
    link
  end
end
