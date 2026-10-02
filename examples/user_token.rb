# frozen_string_literal: true

# Guide: act on behalf of a user (authorization_code + PKCE). The consent screen IS the
# installation on the user — there is nothing to call on /installations for this case.
# Split across your redirect handler (step 1) and your callback handler (steps 2–3).
require "securerandom"
require "wefunder"

module UserTokenExample
  TokenStore = Struct.new(:db) do
    # persist the WHOLE set; refresh tokens rotate
    def save(tokens) = db&.save_tokens(tokens)
  end

  def self.begin_authorization(save_attempt)
    # region guides/user-token
    # 1. Send the investor to consent. Keep state + the PKCE verifier in their session.
    pkce = Wefunder.generate_pkce
    state = SecureRandom.urlsafe_base64(32)
    save_attempt.call(state, pkce.code_verifier)
    authorization_url = Wefunder.create_authorization_url(
      client_id: ENV.fetch("WEFUNDER_CLIENT_ID"),
      redirect_uri: ENV.fetch("WEFUNDER_REDIRECT_URI"),
      scopes: ["read:investments"],
      state: state,
      pkce: pkce
    )
    # redirect_to authorization_url

    # 2. On the callback, exchange the code (after checking `state` matches the session).
    tokens = Wefunder.exchange_code(
      client_id: ENV.fetch("WEFUNDER_CLIENT_ID"),
      client_secret: ENV.fetch("WEFUNDER_CLIENT_SECRET", nil), # omit for public clients
      code: "AUTHORIZATION_CODE",
      redirect_uri: ENV.fetch("WEFUNDER_REDIRECT_URI"),
      code_verifier: pkce.code_verifier
    )

    # 3. Read their holdings. The access token lasts two hours; the SDK rotates the refresh
    #    token for you and hands every new set to `store.save` — persist the whole thing.
    wf = Wefunder::Client.new(
      tokens: tokens,
      client_id: ENV.fetch("WEFUNDER_CLIENT_ID"),
      client_secret: ENV.fetch("WEFUNDER_CLIENT_SECRET", nil),
      store: TokenStore.new(nil)
    )
    portfolio = wf.portfolio.get
    puts portfolio.attributes.total_current_value_cents
    # endregion
    authorization_url
  end
end
