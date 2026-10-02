# frozen_string_literal: true

# Guide: act for a company or syndicate. `wf` holds a MANAGER's user token with
# `read:installations write:installations` (listing needs the read scope; write does not imply
# it). Install, then mint the installation's own token — it has no expiry and no refresh;
# revoking the install revokes it. `client_options` is harness (tests inject a transport).
require "wefunder"

module InstallTargetExample
  def self.example(wf, syndicate_id = "syn_abc123Example", client_options: {})
    # region guides/install-target
    # 1. Which companies / syndicates may this user install on? (Only those — an investor's
    #    empty list is not a failure.)
    targets = wf.wrap { wf.raw.installations.list_eligible_install_targets(target_type: "syndicate") }
    targets.data.each { |t| puts "#{t.id} #{t.name}#{" (already installed)" if t.installed}" }

    # 2. Install. The response carries the install (`data`) AND its token. If the app is already
    #    installed here the API answers 409 `already_installed` — its details["installation"] is
    #    the existing install's id, so mint a fresh token for that instead. Any other error
    #    (revoked install, missing scope) still raises.
    begin
      body = WefunderGenerated::CreateInstallationRequest.new(target_type: "syndicate", target_id: syndicate_id,
                                                              scopes: ["read:syndicates"])
      installed = wf.wrap { wf.raw.installations.create_installation(body) }
      installation_token = installed.token.access_token
    rescue Wefunder::Error => e
      raise unless e.type == "already_installed" && e.details.is_a?(Hash) && e.details["installation"]

      mint = WefunderGenerated::CreateInstallationTokenRequest.new(scopes: ["read:syndicates"]) # same scopes as above
      minted = wf.wrap do
        wf.raw.installations.create_installation_token(e.details["installation"], create_installation_token_request: mint)
      end
      installation_token = minted.token.access_token # shown once — store it
    end

    # 3. First request AS the installation.
    as_syndicate = Wefunder::Client.new(access_token: installation_token, **client_options)
    deals = as_syndicate.wrap { as_syndicate.raw.syndicate_deals.list_syndicate_deals(syndicate_id) }
    puts "#{deals.data.size} deals"
    # endregion
    deals
  end
end
