# frozen_string_literal: true

# operationId: getCurrentUser — the connected user (read:profile; not for cc tokens).
require "wefunder"

module GetCurrentUserExample
  def self.example(wf)
    # region getCurrentUser
    me = wf.users.me
    puts "#{me.id} #{me.attributes.name}"
    # endregion
    me
  end
end
