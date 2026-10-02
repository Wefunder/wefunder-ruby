# frozen_string_literal: true

# Official Ruby SDK for the Wefunder API (beta).
#
#   wf = Wefunder::Client.from_client_credentials(client_id: ..., client_secret: ..., scopes: ["read:public"])
#   wf.offerings.all(sort: "newest").each { |offering| puts offering.id }
require "wefunder_generated"
require_relative "wefunder/version"
require_relative "wefunder/errors"
require_relative "wefunder/oauth"
require_relative "wefunder/token_manager"
require_relative "wefunder/transport"
require_relative "wefunder/pagination"
require_relative "wefunder/webhooks"
require_relative "wefunder/client"

module Wefunder
  class << self
    def generate_pkce = OAuth.generate_pkce
    def pkce_challenge(...) = OAuth.pkce_challenge(...)
    def create_authorization_url(...) = OAuth.create_authorization_url(...)
    def exchange_code(...) = OAuth.exchange_code(...)
    def client_credentials_grant(...) = OAuth.client_credentials_grant(...)
    def refresh_token(...) = OAuth.refresh_token(...)
  end
end
