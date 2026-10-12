# frozen_string_literal: true

# Guide: act for a company or syndicate. `wf` holds a MANAGER's user token with
# `read:installations write:installations` (listing needs the read scope; write does not imply
# it). Install, then mint the installation's own token — it has no expiry and no refresh;
# revoking the install revokes it. `client_options` is harness (tests inject a transport).
require "wefunder"

module InstallTargetExample
  def self.example(wf, syndicate_id = "syn_aB3xQ9k2vF8mNp1zT5wY7Qc4", client_options: {})
    # region guides/install-target
    # 1. Which companies / syndicates may this user install on? (Only those — an investor's
    #    empty list is not a failure.)
    wf.installations.eligible_targets(target_type: "syndicate").each do |t|
      puts "#{t.id} #{t.name}#{" (already installed)" if t.installed}"
    end

    # 2. Install. The response carries the install (`data`) AND its token. If the app is already
    #    installed here the API answers 409 `already_installed`; install_or_mint_token mints a
    #    fresh token for that existing install instead, re-requesting the same scopes. Any other
    #    error (revoked install, missing scope) still raises.
    installed = wf.installations.install_or_mint_token(target_type: "syndicate", target_id: syndicate_id,
                                                       scopes: ["read:syndicates"])
    installation_token = installed.token.access_token # shown once — store it

    # 3. First request AS the installation.
    as_syndicate = Wefunder::Client.new(access_token: installation_token, **client_options)
    deals = as_syndicate.wrap { as_syndicate.raw.syndicate_deals.list_syndicate_deals(syndicate_id) }
    puts "#{deals.data.size} deals"
    # endregion
    deals
  end
end
