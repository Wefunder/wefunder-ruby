# frozen_string_literal: true

require "json"
require "uri"
require "faraday"

module Wefunder
  # Version-free base — the edge gateway serves the API at the host root; +/api/v2+ remains a
  # back-compat alias. The API version is pinned via the +Wefunder-Version+ header, not the path.
  DEFAULT_API_BASE_URL = "https://api.wefunder.com"
  DEFAULT_API_VERSION = "2025-01-15"
  API_VERSION_HEADER = "Wefunder-Version"

  # "live" / "test" from the access-token prefix. UX only — never used for routing.
  def self.mode_for_token(token)
    return "live" if token.to_s.start_with?("at_live_")
    return "test" if token.to_s.start_with?("at_test_")

    "unknown"
  end

  # The Wefunder client — the stable, hand-written surface over the generated layer
  # (+WefunderGenerated+). Wires: a single API host (the gateway routes live/sandbox by token
  # mode), a pinned +Wefunder-Version+, the retry/refresh transport, token rotation,
  # typed-error unwrapping, and lazy auto-pagination. +raw+ exposes every generated API.
  class Client
    attr_reader :mode, :users, :offerings, :investments, :portfolio, :campaigns, :syndicates, :intents,
                :attribution, :webhook_endpoints

    def initialize(access_token: nil, tokens: nil, client_id: nil, client_secret: nil, client_credentials: nil,
                   api_version: DEFAULT_API_VERSION, base_url: DEFAULT_API_BASE_URL, authorize_base_url: nil,
                   token_base_url: nil, oauth_base_url: nil, store: nil, on_token_refresh: nil, retry_options: nil,
                   faraday: nil, now: nil, sleep: nil, random: nil, timeout: 30)
      token_set = tokens || (access_token && TokenSet.new(access_token: access_token))
      raise ArgumentError, "Wefunder::Client: provide access_token: or tokens:" unless token_set

      _ = authorize_base_url # only /authorize uses it; see OAuth.create_authorization_url
      @mode = Wefunder.mode_for_token(token_set.access_token)
      token_base = OAuth.resolve_token_base(token_base_url: token_base_url, oauth_base_url: oauth_base_url)
      re_mint = build_re_mint(client_credentials, client_id, client_secret, token_base, faraday, now)
      @token_manager = TokenManager.new(token_set, client_id: client_id, client_secret: client_secret, re_mint: re_mint,
                                                   on_token_refresh: on_token_refresh, store: store, faraday: faraday, now: now,
                                                   token_base_url: token_base)
      @api_client = build_api_client(base_url, api_version, retry_options, faraday, now, sleep, random, timeout)
      @raw = Raw.new(@api_client)
      @users = Users.new(self)
      @offerings = Offerings.new(self)
      @investments = Investments.new(self)
      @portfolio = Portfolio.new(self)
      @campaigns = Campaigns.new(self)
      @syndicates = Syndicates.new(self)
      @intents = Intents.new(self)
      @attribution = Attribution.new(self)
      @webhook_endpoints = WebhookEndpoints.new(self)
    end

    # Mint an application token now and auto-re-mint on expiry/401 (cc tokens have no refresh
    # token). Extra options are forwarded to +new+.
    def self.from_client_credentials(client_id:, client_secret:, scopes: nil, **opts)
      tokens = OAuth.client_credentials_grant(
        client_id: client_id, client_secret: client_secret, scopes: scopes,
        token_base_url: opts[:token_base_url], oauth_base_url: opts[:oauth_base_url], faraday: opts[:faraday], now: opts[:now]
      )
      new(tokens: tokens, client_id: client_id, client_secret: client_secret, client_credentials: { scopes: scopes }, **opts)
    end

    # The current token set (rotated refresh token included).
    def tokens = @token_manager.current

    # The generated APIs, one accessor per tag (+wf.raw.syndicate_members.list_syndicate_members(id)+).
    # Wrap calls in +wrap+ to get typed errors.
    attr_reader :raw

    # Run a block of generated-API calls, converting +WefunderGenerated::ApiError+ into +Wefunder::Error+.
    def wrap
      yield
    rescue WefunderGenerated::ApiError => e
      raise Error.new(status: 0, type: "network_error", message: e.message.to_s) if e.code.nil? || e.code.zero?

      raise Error.from_response(e.code, e.response_headers, e.response_body, reason_phrase: e.message)
    end

    # Escape hatch for any path (preview ops, brand-new endpoints): full envelope — auth +
    # recovery, Wefunder-Version, retries, typed errors. Returns parsed JSON (nil for an empty
    # body). +body+ is sent as JSON unless it is a String.
    def request(method, path, query: nil, body: nil, headers: nil)
      conn = @api_client.connection(header_params: {})
      payload = body.nil? || body.is_a?(String) ? body : JSON.generate(body)
      hdrs = @api_client.default_headers.merge(headers || {})
      response = conn.run_request(method.to_s.downcase.to_sym, path, payload, hdrs) do |req|
        req.params.update((query || {}).compact.transform_keys(&:to_s))
      end
      if response.status >= 400
        raise Error.from_response(response.status, response.headers, response.body,
                                  reason_phrase: response.reason_phrase)
      end

      response.body.to_s.empty? ? nil : JSON.parse(response.body)
    end

    # Single-resource envelopes are +{data: Entity}+; return the entity for ergonomics.
    def self.data_of(envelope)
      return envelope["data"] || envelope[:data] if envelope.is_a?(Hash)

      envelope.respond_to?(:data) ? envelope.data : envelope
    end

    private

    def build_re_mint(client_credentials, client_id, client_secret, token_base, faraday, now)
      return nil unless client_credentials && client_id && client_secret

      scopes = client_credentials[:scopes] || client_credentials["scopes"]
      lambda do
        OAuth.client_credentials_grant(client_id: client_id, client_secret: client_secret, scopes: scopes,
                                       token_base_url: token_base, faraday: faraday, now: now)
      end
    end

    def build_api_client(base_url, api_version, retry_opts, faraday, now, sleep, random, timeout)
      config = WefunderGenerated::Configuration.new
      uri = URI(base_url)
      config.scheme = uri.scheme
      config.host = uri.port && uri.port != uri.default_port ? "#{uri.host}:#{uri.port}" : uri.host
      config.base_path = uri.path.to_s
      config.server_index = nil
      # The transport owns the Authorization header (it reads the managed token per attempt),
      # so the generated client's own token is a placeholder.
      config.access_token = "managed"
      config.timeout = timeout
      tm = @token_manager
      now_ms = now && -> { now.call * 1000 }
      config.configure_faraday_connection do |conn|
        conn.use Transport, token_manager: tm, retry_options: retry_opts, sleep: sleep, now_ms: now_ms, random: random
        faraday&.call(conn)
      end
      client = WefunderGenerated::ApiClient.new(config)
      client.default_headers[API_VERSION_HEADER] = api_version
      client
    end

    # Lazily-built generated API instances, one per tag.
    class Raw
      APIS = {
        activity: "ActivityApi", attribution: "AttributionApi", attribution_partners: "AttributionPartnersApi",
        attribution_webhooks: "AttributionWebhooksApi", campaigns: "CampaignsApi", companies: "CompaniesApi",
        explore: "ExploreApi", installations: "InstallationsApi", intents: "IntentsApi",
        investment_delta: "InvestmentDeltaApi", investments: "InvestmentsApi", portfolio: "PortfolioApi",
        syndicate_deals: "SyndicateDealsApi", syndicate_members: "SyndicateMembersApi",
        syndicate_portfolio: "SyndicatePortfolioApi", syndicate_statistics: "SyndicateStatisticsApi",
        syndicates: "SyndicatesApi", users: "UsersApi", webhook_endpoints: "WebhookEndpointsApi"
      }.freeze

      def initialize(api_client)
        @api_client = api_client
        @apis = {}
      end

      APIS.each do |name, klass|
        define_method(name) { @apis[name] ||= WefunderGenerated.const_get(klass).new(@api_client) }
      end
    end

    # Base for the resource namespaces.
    class Namespace
      def initialize(client)
        @client = client
      end

      private

      def wrap(&) = @client.wrap(&)
      def raw = @client.raw
      def data_of(env) = Client.data_of(env)

      # Auto-paginate a list method, keeping +opts+ on every page and threading the cursor.
      def pages(opts, &fetch)
        Wefunder.paginate { |cursor| wrap { fetch.call(cursor.nil? ? opts : opts.merge(cursor: cursor)) } }
      end
    end

    class Users < Namespace
      # GET /users/me (needs read:profile; a client_credentials token gets 403).
      def me = data_of(wrap { raw.users.get_current_user })
    end

    class Offerings < Namespace
      # One page of GET /explore (+sort:+, +cursor:+, filters). Returns the envelope.
      def list(**opts) = wrap { raw.explore.list_offerings(opts) }
      # Every offering, lazily, +opts+ preserved across pages.
      def all(**opts) = pages(opts) { |o| raw.explore.list_offerings(o) }
      def get(offering_id) = data_of(wrap { raw.explore.get_offering(offering_id) })
      def stats(offering_id) = data_of(wrap { raw.investments.get_offering_stats(offering_id) })
    end

    # The Investment Delta API. +list+ without a cursor bootstraps; +next_cursor+ is always
    # present (persist it after every sync) and +has_more+ terminates.
    class Investments < Namespace
      def list(**opts) = wrap { raw.investments.list_investments(opts) }
      def all(**opts) = pages(opts) { |o| raw.investments.list_investments(o) }
      def collect(**) = all(**).to_a
      def get(investment_id) = data_of(wrap { raw.investments.get_investment(investment_id) })
    end

    class Portfolio < Namespace
      Positions = Class.new(Namespace) do
        def list(**opts) = wrap { raw.portfolio.list_portfolio_positions(opts) }
        def all(**opts) = pages(opts) { |o| raw.portfolio.list_portfolio_positions(o) }
      end

      attr_reader :positions

      def initialize(client)
        super
        @positions = Positions.new(client)
      end

      # The portfolio summary (+status:+, +company:+ filters).
      def get(**opts) = data_of(wrap { raw.portfolio.get_portfolio(opts) })
    end

    class Campaigns < Namespace
      def list(**opts) = wrap { raw.campaigns.list_campaigns(opts) }
      def all(**opts) = pages(opts) { |o| raw.campaigns.list_campaigns(o) }
    end

    class Syndicates < Namespace
      def list(**opts) = wrap { raw.syndicates.list_syndicates(opts) }
      def all(**opts) = pages(opts) { |o| raw.syndicates.list_syndicates(o) }
      def get(syndicate_id) = data_of(wrap { raw.syndicates.get_syndicate(syndicate_id) })
      def portfolio(syndicate_id, **opts) = data_of(wrap { raw.syndicate_portfolio.get_syndicate_portfolio(syndicate_id, opts) })

      def portfolio_positions(syndicate_id, **opts)
        pages(opts) { |o| raw.syndicate_portfolio.list_syndicate_portfolio_positions(syndicate_id, o) }
      end
    end

    class Intents < Namespace
      def list(**opts) = wrap { raw.intents.list_intents(opts) }
      def all(**opts) = pages(opts) { |o| raw.intents.list_intents(o) }
      def get(intent_id) = data_of(wrap { raw.intents.get_intent(intent_id) })
      def create(body) = data_of(wrap { raw.intents.create_intent(WefunderGenerated::CreateIntentRequest.new(body)) })
      def preview(body) = data_of(wrap { raw.intents.preview_intent(WefunderGenerated::PreviewIntentRequest.new(body)) })
    end

    class Attribution < Namespace
      def me = data_of(wrap { raw.attribution_partners.get_attribution_me })
    end

    # Endpoints belong to your application and are managed through the LIVE API
    # (write:webhooks). The signing secret is returned only on create and rotate.
    class WebhookEndpoints < Namespace
      def create(url:, events:, mode: nil)
        attrs = { url: url, events: Array(events) }
        attrs[:mode] = mode if mode
        data_of(wrap do
          raw.webhook_endpoints.create_webhook_endpoint(WefunderGenerated::CreateWebhookEndpointRequest.new(attrs))
        end)
      end

      # The list envelope (+meta.quota+ is the max endpoints per app).
      def list = wrap { raw.webhook_endpoints.list_webhook_endpoints }
      def get(endpoint_id) = data_of(wrap { raw.webhook_endpoints.get_webhook_endpoint(endpoint_id) })

      # +events+ replaces the list wholesale.
      def update(endpoint_id, **changes)
        body = WefunderGenerated::UpdateWebhookEndpointRequest.new(changes)
        data_of(wrap { raw.webhook_endpoints.update_webhook_endpoint(endpoint_id, update_webhook_endpoint_request: body) })
      end

      def remove(endpoint_id) = data_of(wrap { raw.webhook_endpoints.delete_webhook_endpoint(endpoint_id) })
      # A new secret; the old one keeps signing for 24h and deliveries carry both v1s.
      def rotate_secret(endpoint_id) = data_of(wrap { raw.webhook_endpoints.rotate_webhook_endpoint_secret(endpoint_id) })
      def reenable(endpoint_id) = data_of(wrap { raw.webhook_endpoints.reenable_webhook_endpoint(endpoint_id) })

      # Send a real, signed example event to the endpoint and report the outcome.
      def test(endpoint_id, event = nil)
        opts = event ? { test_webhook_endpoint_request: WefunderGenerated::TestWebhookEndpointRequest.new(event: event) } : {}
        data_of(wrap { raw.webhook_endpoints.test_webhook_endpoint(endpoint_id, opts) })
      end
    end
  end
end
