# wefunder

Official Ruby SDK for the [Wefunder API](https://docs.wefunder.com). **Beta** — the API is pre-launch
and `0.x` releases may include breaking changes.

- A `Wefunder::Client` on [Faraday](https://lostisland.github.io/faraday/) with a generated, typed
  layer for every public operation
- OAuth 2.0: `client_credentials` for server-to-server, `authorization_code` + PKCE for user consent,
  refresh-token rotation handled for you
- Automatic retries (rate limits, transient errors) and one-shot token recovery on 401
- Lazy auto-pagination over opaque cursors
- Typed errors with the `request_id` support asks for
- Webhook signature verification, envelope parsing, and dispatch

Requires Ruby 3.2+.

## Install

```bash
gem install wefunder --pre
# or in a Gemfile:
gem "wefunder", "~> 0.1.0.beta"
```

`--pre` is needed while the SDK is in beta (pre-release gems are not selected by default).

## Authentication

### Server-to-server

```ruby
require "wefunder"

wf = Wefunder::Client.from_client_credentials(
  client_id: ENV.fetch("WEFUNDER_CLIENT_ID"),
  client_secret: ENV.fetch("WEFUNDER_CLIENT_SECRET"),
  scopes: ["read:public"]
)
page = wf.offerings.list
```

Client-credentials tokens represent the application, not a user. They cannot call user-scoped
endpoints such as `wf.users.me` or `wf.portfolio.get`. The SDK mints a new token automatically when a
client-credentials token expires.

### User authorization with PKCE

Generate the authorization URL on your server; store `state` and the PKCE verifier in the user's
session before redirecting:

```ruby
pkce = Wefunder.generate_pkce
state = SecureRandom.urlsafe_base64(32)
save_oauth_attempt(state: state, code_verifier: pkce.code_verifier)

url = Wefunder.create_authorization_url(
  client_id: client_id, redirect_uri: redirect_uri, scopes: ["read:investments"], state: state, pkce: pkce
)
```

The consent host is chosen from the `client_id`: `pk_test_` ids go to the sandbox, everything else to
wefunder.com. On the callback, validate `state` and exchange the code:

```ruby
attempt = consume_oauth_attempt(state)
tokens = Wefunder.exchange_code(
  client_id: client_id, client_secret: client_secret, # omit for public clients
  code: params[:code], redirect_uri: redirect_uri, code_verifier: attempt.code_verifier
)

wf = Wefunder::Client.new(tokens: tokens, client_id: client_id, client_secret: client_secret, store: TokenStore.new)
```

### Refresh tokens

Refresh tokens rotate. When the SDK refreshes an access token it calls `store.save(tokens)` with the
new set **before** retrying the request. Persist the entire token set each time:

```ruby
class TokenStore
  def save(tokens)
    DB.save_tokens(tokens.access_token, tokens.refresh_token, tokens.expires_at)
  end
end
```

The rotated set is saved **before** any thread can use it. If `store.save` raises, the SDK raises
`Wefunder::TokenPersistenceError` and keeps the rotated set *pending*: no request is made with it, the
consumed refresh token is never reused, and the next call retries the save (or persist
`error.tokens` yourself and call `wf.token_manager.mark_persisted!`). Alert on this error; a process
that keeps failing to save cannot reconnect after a restart.

Concurrent requests that hit a 401 at the same time share one refresh (the client is thread-safe).
If several application instances can use the same OAuth connection, serialize refreshes for that
connection yourself.

## Calling the API

```ruby
offerings = wf.offerings.list(sort: "newest")
investments = wf.investments.list(company_id: "co_example")
portfolio = wf.portfolio.get
```

Namespaces: `users`, `offerings`, `investments`, `portfolio`, `campaigns`, `syndicates`, `intents`,
`attribution`, and `webhook_endpoints`. Query parameters are keyword arguments; enum-typed ones take
plain strings, and `Time` / `DateTime` / `Date` values are sent as ISO 8601.

`wf.investments` is the Investment Delta API. `list` without a cursor bootstraps; pass `updated_since:`
or the `meta.next_cursor` you saved from your last page to receive only records that changed since then.
`next_cursor` is always present, even on the final page, so persist it after every sync.

The API base URL is `https://api.wefunder.com`. Paths are version-free; the SDK sends the API version in
the `Wefunder-Version` request header.

## Pagination

```ruby
page = wf.offerings.list(sort: "newest")           # one page, and its cursor
puts page.meta.next_cursor

wf.offerings.all(sort: "most_raised").each do |offering|  # every item, lazily (an Enumerator)
  puts offering.id
end

investments = wf.investments.collect                # everything in one Array
```

Cursors are opaque. Pass the value returned by the API without modifying it.

## Errors and retries

API failures raise `Wefunder::Error`:

```ruby
begin
  wf.syndicates.get("syn_example")
rescue Wefunder::Error => e
  puts e.status, e.type, e.message, e.request_id, e.remediation
end
```

The SDK retries idempotent `GET` requests after transient network errors, `5xx` responses, and rate
limits (honouring `X-RateLimit-Reset`). Write requests are not retried automatically, except once after
a `401` has been recovered. Exhausted network failures raise `Wefunder::Error` with `status` 0 and
`type` `"network_error"`, from namespaces and `request` alike.

`timeout:` (seconds, default 30) applies to every request the client makes: API calls, `request`, and
the OAuth token round-trips for refresh and re-mint.

## Webhooks

### 1. Register an endpoint

Endpoints belong to your application and are managed through the live API (scope `write:webhooks`).
The signing secret is returned only on create and rotate, so store it immediately.

```ruby
endpoint = wf.webhook_endpoints.create(
  url: "https://yourapp.com/webhooks/wefunder",  # public HTTPS; localhost and private IPs are rejected
  events: ["offering.opened", "investment.executed"],
  mode: "live"                                   # "test" endpoints receive sandbox events
)
save_secret(endpoint.attributes.secret)
```

`wf.webhook_endpoints` also provides `list`, `get`, `update`, `remove`, `rotate_secret`, `reenable`,
and `test`.

### 2. Verify and handle deliveries

Pass the **raw** request body, the headers (a Rack env works), and your secret to
`Wefunder.construct_event`. It raises `Wefunder::WebhookSignatureError` (with a `reason`) when a
delivery is not authentic.

```ruby
post "/webhooks/wefunder" do
  begin
    event = Wefunder.construct_event(request.body.read, request.env, WEBHOOK_SECRET)
  rescue Wefunder::WebhookSignatureError => e
    halt 400, e.reason
  end

  Wefunder.dispatch_webhook(event, {
    "investment.executed" => ->(e) { record_funding(e.data["id"], e.data.dig("amounts", "committed")) },
    "offering.opened" => ->(e) { announce(e.data.dig("company", "name")) },
    default: ->(e) { logger.info("unhandled #{e.event}") }
  })
  200
end
```

Deliveries are at-least-once and unordered. Deduplicate on `event.id`, and where a payload carries
`occurred_at`, keep the state from the latest one you have seen.

### 3. Test your handler

`wf.webhook_endpoints.test(endpoint.id)` sends a real, signed example event and reports the outcome.
To unit-test your handler without the API, sign a fixture yourself:

```ruby
header = Wefunder.sign_webhook(body, secret)
# POST `body` to your handler with `Wefunder-Signature: <header>`
```

### Signature scheme

Each delivery carries `Wefunder-Signature: t=<unix seconds>,v1=<hex>` where `v1` is
`HMAC-SHA256(secret, "<t>.<raw body>")`. Requests whose `t` is more than five minutes from now are
rejected (`tolerance_seconds:` adjusts this). During a secret rotation the header carries one `v1` per
active secret and `construct_event` accepts either. `Wefunder.verify_webhook` and
`Wefunder.check_webhook_signature` expose the check without parsing, and `construct_event` still accepts
the retired attribution headers (`X-Wefunder-Signature` / `X-Wefunder-Timestamp`).

## Generated operations

Typed namespaces cover the common resources. Every operation in the public OpenAPI specification is
generated under `WefunderGenerated::<Tag>Api` and reachable through `wf.raw.<tag>`; wrap the call to get
the same auth, retries, and typed errors:

```ruby
members = wf.wrap { wf.raw.syndicate_members.list_syndicate_members("syn_example") }
```

For a path the generated layer does not know yet, `wf.request(:get, path, query:, body:, headers:)`
sends a fully-wrapped request and returns the decoded JSON.

## Development

```bash
bundle install
bundle exec rubocop
bundle exec rspec                             # hermetic — live examples are tagged :e2e and filtered out
WEFUNDER_E2E=1 bundle exec rspec spec/e2e     # live sandbox; also needs WEFUNDER_CLIENT_ID / WEFUNDER_CLIENT_SECRET
```

The live group is opt-in by tag, not by path: without `WEFUNDER_E2E=1` it never runs, even when sandbox
credentials happen to be exported in your shell.

Generated files in `lib/wefunder_generated/` come from `openapi/openapi.yaml` via `script/generate`
(openapi-generator in Docker; no Java needed) and are never edited by hand.

### Conformance vectors

`conformance/*.json` is the cross-language behavioural contract shared with `wefunder-node` and
`wefunder-python`: signatures, token rotation, pagination, retries, errors. `spec/conformance_spec.rb`
runs every case. The files are vendored from `Wefunder/wefunder-node` at the ref in `conformance/PIN`;
refresh with `ruby script/sync_conformance.rb [ref]`. Never edit a vector to make the shell pass.

### Examples

`examples/` is the source of truth for the Ruby snippets on docs.wefunder.com; see
`examples/README.md`. After adding one, run `ruby script/build_examples_manifest.rb` and remove its
`operationId` from `examples/coverage-allowlist.json`.

### Updating the API specification

```bash
script/sync_spec /path/to/wefunder   # public-tier spec → openapi/openapi.yaml
script/generate                      # → lib/wefunder_generated
bundle exec rspec
```

Commit the specification and generated client together.

### Releasing

Set the version in `lib/wefunder/version.rb` (e.g. `0.1.0.beta2`), rebuild `examples_manifest.json`,
commit, then:

```bash
git tag v0.1.0.beta2
git push --follow-tags
```

The release workflow verifies the tag, runs the checks, and publishes to RubyGems via trusted publishing.
