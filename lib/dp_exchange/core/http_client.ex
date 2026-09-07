defmodule DpExchange.Core.HttpClient do
  @moduledoc """
  The shared HTTP request pipeline: rate limiting, retry, logging, error shaping and
  the generic authentication schemes.

  ## What it deliberately does not know

  **No venue appears in this module.** It once carried a Coinbase JWT builder and a
  `case provider do` table mapping `"coinbase"` and `"gemini"` to their own rate-limit
  header parsers. Both moved into their venue packages, because a venue fact living in
  shared code is a second place that can be wrong about that venue — and it was: every
  provider except Coinbase once fell through to Coinbase's socket codec, so one venue's
  socket spoke another's protocol at its own endpoint and delivered nothing for as long
  as that stood.

  What is left is generic: `:hmac_sha256`, `:basic` and `:bearer` auth, the request
  pipeline, query-string building, response parsing, retry, and a rate-limit header
  parser that reads only the conventional `x-ratelimit-*` shape. A venue whose scheme or
  headers differ supplies its own — see `build_auth_headers/5` and
  `parse_rate_limit_headers/1`.

  ## The limiter is resolved at call time

  Never at compile time. `Application.compile_env/3` would freeze whichever limiter the
  *consumer* configured when this dependency was compiled, so a consumer changing it
  later would either have to recompile or get a boot-time mismatch. Resolution goes
  through `DpExchange.Core.Config`, so a consumer's `async: true` test can swap the
  limiter for its own process tree without configuring it for every test beside it.

  ## Neither acquire nor check fills the bucket

  They answer "is there capacity" and, for acquire, wait until there is. Something has to
  report what actually left, or the bucket stays empty and every check passes. This
  module records on behalf of every request it makes; a venue package issuing its own
  HTTP calls must record for itself. One that did not acquired before every request and
  recorded none, so its ceiling bound nothing: 395 calls per 60s against a documented
  300, while the budget panel read 83/240.

  **This module itself repeated the same mechanism in a smaller way, found 2026-09-05.**
  `record/3` was called only from the `{:ok, response}` branch of the request pipeline — a
  retried 5xx and a venue 429 both genuinely reached the wire and genuinely consumed the
  venue's quota, and neither was recorded. The 312 calls missing from the 83/240 incident
  above were not a mystery once this was found: they were exactly the retried and
  rate-limited requests, the very shapes this branch skipped. Every outcome of
  `make_http_request/5` — success, retry, 429, or a permanent 4xx — is now recorded once,
  right after the request is actually made, before the result is inspected. See
  `record_request_sent/1`.
  """

  require Logger

  alias DpExchange.Core.{Config, DefaultRateLimiter}

  # Suppress dialyzer warnings for functions that dialyzer incorrectly analyzes
  @dialyzer {:nowarn_function, [parse_response_body: 1, get: 3]}

  @type http_method :: :get | :post | :put | :delete
  @type headers :: [{String.t(), String.t()}]
  @type body :: String.t() | nil
  @type options :: keyword()
  @type provider :: String.t()
  @type account_id :: String.t()
  @type user_id :: String.t()

  @typedoc """
  A response as it comes back from the pipeline.

  `body` is **whatever the transport decoded**, not a string. Req decodes JSON into a map
  or a list before this module sees it, and only leaves a binary when it could not.

  It was declared `String.t()`, and that was not a harmless inaccuracy: dialyzer then
  concluded that any consumer matching a decoded body was matching something impossible,
  so every function reachable only through that branch was reported as **unreachable
  dead code**. A venue package's `mix dialyzer` failed with `Function decimal/1 will
  never be called` about a function called on every price it parses.

  The application this pipeline came from hit the same class of problem from the other
  end and said so in a comment: a missing clause "poisoned dialyzer's success typing for
  every `HttpClient.request/5` caller — the whole chain got narrowed to `{:error, _}`
  only." A wrong type is worse than a missing one; it makes the tool confidently wrong,
  and the reader believes it.
  """
  @type http_response :: %{
          status: integer(),
          headers: headers() | map(),
          body: term()
        }

  @type rate_limited_request_options ::
          keyword()
          | %{
              provider: provider(),
              account_id: account_id(),
              user_id: user_id(),
              operation: String.t()
            }

  @doc """
  Make an HTTP request with provider-specific and account-aware rate limiting.

  ## Parameters
  - `method`: HTTP method (:get, :post, :put, :delete)
  - `url`: Full URL for the request
  - `headers`: List of HTTP headers
  - `body`: Request body (for POST/PUT requests)
  - `opts`: Additional options including rate limiting context

  ## Options
  - `:timeout` - Request timeout in milliseconds (default: 30_000)
  - `:retry_attempts` - Number of retry attempts (default: 3)
  - `:retry_delay` - Base delay between retries in milliseconds (default: 1000)
  - `:log_requests` - Whether to log requests (default: true)
  - `:provider` - Provider name for rate limiting (required for rate limiting)
  - `:account_id` - Account ID for account-aware rate limiting (optional)
  - `:user_id` - User ID for additional isolation (optional)
  - `:operation` - Operation type for fine-grained rate limiting (default: "default")
  - `:raw_status` - Return `{:ok, response}` for a 4xx instead of an error string
    (default: `false`). A venue package needs this to tell a **refusal** from an
    **error**: the contract makes `{:refused, reason}` permanent and `{:error, reason}`
    possibly transient, and the venue states which in the 4xx status and body. Without
    it that evidence is flattened into a message and the venue has to string-match its
    way back to it. 5xx is unaffected — a server error is not a venue's considered answer.

  ## Returns
  - `{:ok, http_response()}` on success, and on a 4xx when `raw_status: true`
  - `{:error, reason}` on failure
  """
  @typedoc """
  Why a request did not produce a response.

  Three shapes, and the spec used to name only the first — which made dialyzer tell every
  consumer that its handling of the other two was unreachable dead code.

    * `String.t()` — a plain message, when no `:provider` was given.
    * `{:exchange_error, provider, reason}` — the same message tagged with the venue,
      which is what a caller gets whenever it passes `:provider`, i.e. almost always.

  ## Rate limiting arrives as a two-element error, not a three-element one

  This spec used to advertise `{:error, :rate_limited, retry_after: seconds}` as a third
  return shape. **`request/5` never returns it.** Both rate-limit paths convert to a
  two-element error before returning, deliberately and for recorded reasons:

    * a **venue 429** becomes `"Rate limited by the venue — retry after Ns"`, because a
      three-element tuple reaching a `case` written for two-element ones crashed 152
      collector tasks in one night;
    * **our own limiter** refusing becomes `"Throttled by our own rate limiter (not the
      venue)"`, because the two used to share wording and a self-inflicted refusal was
      read as a flaky venue for weeks.

  Both keep the retry interval in the message. The spec is corrected here rather than the
  behaviour: a spec that names a shape the function cannot return sends dialyzer after
  every caller that handles it, reporting correct code as unreachable — which is exactly
  what it did to the Gemini package's rate-limit clause. Found 2026-08-28.
  """
  @type request_error :: String.t() | {:exchange_error, provider(), term()}

  @spec request(http_method(), String.t(), headers(), body(), rate_limited_request_options()) ::
          {:ok, http_response()}
          | {:error, request_error()}
  def request(method, url, headers \\ [], body \\ nil, opts \\ []) do
    # `Config.opt/3`, not `Keyword.get/3`. Every venue package forwards its own `opts`
    # unchanged by family convention, so `retry_attempts: nil` is reachable whenever a
    # venue's own caller never set it — and it was the worst instance of this trap in the
    # family: Erlang term ordering puts `nil` ABOVE every integer, so `nil > 1` is `true`.
    # A forwarded `nil` silently entered the retry branch at `do_request_with_rate_limiting/6`
    # and then died computing `4 - nil`, an `ArithmeticError` that killed the CALLING venue
    # process — one this library does not supervise. See `Config.opt/3`'s moduledoc.
    retry_attempts = Config.opt(opts, :retry_attempts, 3)
    log_requests = Config.opt(opts, :log_requests, true)

    if log_requests do
      Logger.debug("HTTP Request: #{method |> to_string() |> String.upcase()} #{url}")
    end

    do_request_with_rate_limiting(method, url, headers, body, opts, retry_attempts)
  end

  @doc """
  Convenience function for GET requests with query parameters.

  ## Parameters
  - `url`: Base URL for the request
  - `params`: Query parameters as keyword list or map
  - `opts`: Additional options

  ## Returns
  - `{:ok, parsed_json}` on success
  - `{:error, reason}` on failure
  """
  @spec get(String.t(), keyword() | map(), rate_limited_request_options()) ::
          {:ok, any()} | {:error, String.t()}
  def get(url, params \\ [], opts \\ []) do
    query_string = build_query_string(params)
    full_url = if query_string == "", do: url, else: "#{url}?#{query_string}"

    # `:headers` is read from opts rather than hardcoded to `[]`. It was hardcoded, so a
    # caller that passed authentication headers had them silently dropped and got a 401
    # with nothing to explain it — the request looked correct at the call site and was
    # not correct on the wire. Found by a venue package's tier-2 tests.
    case request(:get, full_url, Config.opt(opts, :headers, []), nil, opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        parse_response_body(body)

      {:ok, %{status: status, body: body}} ->
        wrap_exchange_error(opts, "HTTP #{status}: #{inspect(body)}")

      {:error, reason} ->
        wrap_exchange_error(opts, reason)
    end
  end

  defp parse_response_body(body) when is_map(body) or is_list(body) do
    {:ok, body}
  end

  defp parse_response_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, json} -> {:ok, json}
      {:error, _last} -> {:error, "Invalid JSON response"}
    end
  end

  defp parse_response_body(_body) do
    {:error, "Unexpected response format"}
  end

  @doc """
  Build authentication headers for API requests.

  ## Parameters
  - `method`: HTTP method
  - `path`: API endpoint path
  - `body`: Request body
  - `credentials`: API credentials
  - `auth_type`: Authentication type (:hmac_sha256, :basic, :bearer)

  ## Returns
  - List of authentication headers
  """
  @typedoc """
  How to authenticate: one of the generic schemes, or a venue's own builder.

  The function form is the hook that replaced a per-venue branch. The spec named only
  `atom()` for a while after the hook was added, so a venue passing a builder — the whole
  point of the hook — was told by dialyzer that the call "breaks the contract". Adding a
  capability without widening its spec makes the tool argue against the feature.
  """
  @type auth_scheme ::
          :hmac_sha256
          | :basic
          | :bearer
          | (http_method(), String.t(), body(), map() -> headers())

  @spec build_auth_headers(http_method(), String.t(), body(), map(), auth_scheme()) :: headers()

  def build_auth_headers(method, path, body, credentials, auth_type) do
    case auth_type do
      :hmac_sha256 ->
        build_hmac_headers(method, path, body, credentials)

      :basic ->
        build_basic_auth_headers(credentials)

      :bearer ->
        build_bearer_headers(credentials)

      # The generic hook. A venue whose scheme is its own — a signed JWT, a nonce
      # ladder, anything — passes a builder rather than adding a branch here, which is
      # what keeps venue knowledge inside the venue package.
      builder when is_function(builder, 4) ->
        builder.(method, path, body, credentials)

      _unknown ->
        []
    end
  end

  @doc """
  Parses rate-limit information from response headers, for the conventional
  `x-ratelimit-limit` / `x-ratelimit-remaining` / `x-ratelimit-reset` shape only.

  Returns `nil` when the headers do not carry it. **`nil` means "this response did not
  say", never "there is no limit"** — a caller must not read an absent header as
  headroom.

  This used to take a provider name and dispatch on it, with branches for two venues'
  bespoke headers. Those branches are venue knowledge and moved into the venue packages
  (D-C); a venue whose headers differ parses them itself, and does not need this
  function to have heard of it.
  """
  @spec parse_rate_limit_headers(headers() | map()) :: map() | nil
  def parse_rate_limit_headers(headers) do
    header_map = normalise_headers(headers)

    with {:ok, limit} <- fetch_integer(header_map, "x-ratelimit-limit"),
         {:ok, remaining} <- fetch_integer(header_map, "x-ratelimit-remaining") do
      %{limit: limit, remaining: remaining, reset_time: parse_reset(header_map)}
    else
      :error -> nil
    end
  end

  defp fetch_integer(headers, key) do
    with value when is_binary(value) <- Map.get(headers, key),
         {integer, _rest} <- Integer.parse(value) do
      {:ok, integer}
    else
      _absent_or_unparseable -> :error
    end
  end

  # `x-ratelimit-reset` is published as either a delta in seconds or an absolute unix
  # timestamp, and nothing in the header says which. A value below one year of seconds
  # cannot be a plausible unix timestamp, so it is a delta. An unparseable value returns
  # `nil` rather than a guessed instant.
  defp parse_reset(headers) do
    case fetch_integer(headers, "x-ratelimit-reset") do
      {:ok, value} when value > 31_536_000 -> DateTime.from_unix!(value)
      {:ok, value} -> DateTime.add(DateTime.utc_now(), value, :second)
      :error -> nil
    end
  end

  # Private functions

  defp build_query_string([]), do: ""

  defp build_query_string(params) when is_list(params) do
    params
    |> Enum.filter(fn {_k, v} -> v != nil end)
    |> Enum.map(fn {k, v} -> "#{k}=#{URI.encode_www_form(to_string(v))}" end)
    |> Enum.join("&")
  end

  defp build_query_string(params) when is_map(params) do
    params |> Map.to_list() |> build_query_string()
  end

  defp do_request_with_rate_limiting(method, url, headers, body, opts, attempts_left) do
    # Check rate limits before making the request
    case check_rate_limits(opts) do
      :ok ->
        response = make_http_request(method, url, headers, body, opts)

        # Recorded for every outcome, not only `{:ok, _}` — a 5xx that gets retried below
        # and a 429 (`handle_rate_limit/3`) both actually left this process and actually
        # consumed the venue's quota, exactly as a 2xx did. Recording only success is the
        # same mechanism as the incident this module's moduledoc already records: a venue
        # package that acquired before every request and recorded only its successes had a
        # bucket that under-counted real usage — "395 calls per 60s against a documented
        # 300, while the budget panel read 83/240." The 312 unrecorded calls there were
        # exactly the retried and rate-limited ones this now covers.
        record_request_sent(opts)

        case response do
          {:ok, response} ->
            {:ok, response}

          # Server returned HTTP 429 — `make_http_request/5` calls
          # `handle_rate_limit/2` which returns a 3-tuple
          # `{:error, :rate_limited, retry_after: N}`. Without this clause
          # the case below crashes with `CaseClauseError`. Surfaced
          # 2026-05-01 — 152 OrderbookCollector / Task crashes overnight
          # when Coinbase rate-limited the bumped 30s price-collection
          # cadence. Surface as a 2-tuple error so existing callers
          # (OrderbookCollector handle_fetch_error etc.) match it.
          {:error, :rate_limited, retry_after: seconds} ->
            wrap_exchange_error(
              opts,
              "Rate limited by the venue — retry after " <> to_string(seconds) <> "s"
            )

          {:error, reason} when attempts_left > 1 ->
            if client_error?(reason) do
              # 4xx errors are permanent — don't retry
              wrap_exchange_error(opts, reason)
            else
              retry_delay = Config.opt(opts, :retry_delay, 1000)

              # `4 - attempts_left` was a magic number hardcoding the DEFAULT
              # `retry_attempts` (3) as `retry_attempts + 1`. It happened to stay
              # positive only because every existing caller and every existing test used
              # the default or something smaller. `retry_attempts` is a documented,
              # caller-configurable option — `:retry_attempts` above — and a caller
              # setting it to 4 or more starts `attempts_left` above `4`, so `4 -
              # attempts_left` goes negative on the very first retry and
              # `Process.sleep/1` raises `FunctionClauseError` in the CALLING process,
              # uncaught, which this library does not supervise. Found 2026-09-06,
              # the same failure shape this module's moduledoc already records for
              # `retry_attempts: nil` (`4 - nil` via Erlang term ordering) — this is the
              # same trap for a valid, in-range integer instead of a forwarded `nil`.
              #
              # Scaled by attempts actually made instead: always >= 1, whatever
              # `retry_attempts` was configured to, and identical to the old formula's
              # own numbers at the default of 3 (1, then 2), so no existing behaviour
              # changes for the common case.
              total_attempts = Config.opt(opts, :retry_attempts, 3)
              attempts_made = total_attempts - attempts_left + 1
              backoff_delay = retry_delay * attempts_made
              provider = Config.opt(opts, :provider, "unknown")
              short_url = url |> String.split("?") |> List.first() |> String.slice(0, 80)

              Logger.warning(
                "[HttpClient] retry provider=#{provider} #{method} #{short_url} " <>
                  "in #{backoff_delay}ms; reason=#{inspect(reason)}"
              )

              Process.sleep(backoff_delay)

              do_request_with_rate_limiting(method, url, headers, body, opts, attempts_left - 1)
            end

          {:error, reason} ->
            wrap_exchange_error(opts, reason)
        end

      {:error, :rate_limit_timeout} ->
        wrap_exchange_error(opts, :rate_limit_timeout)

      # OUR limiter refused, before any request left the process.
      #
      # This said "Rate limited" — the exact wording the venue-429 branch above
      # uses — so a self-inflicted refusal was indistinguishable from the
      # exchange throttling us. Gemini's balance monitor logged
      # `{:exchange_error, "gemini", "Rate limited"}` every five minutes for
      # weeks and was read as a flaky venue; it was this branch, with the
      # provider's bucket momentarily full from its own price polling.
      #
      # Naming it after the thing that actually refused makes the next one
      # obvious, and points at the fix — a caller that can afford to wait should
      # pass `rate_limit_blocking: true` rather than losing the cycle.
      {:error, :rate_limited, retry_after: seconds} ->
        wrap_exchange_error(
          opts,
          "Throttled by our own rate limiter (not the venue) — retry after #{seconds}s; " <>
            "callers that can wait should set rate_limit_blocking: true"
        )

      # A limiter can fail to answer at all — its process not started, its backing
      # store unreachable. The implementation this replaced grew that return without
      # the callsite learning about it, and the missing clause raised
      # `CaseClauseError`, terminating whichever supervised worker was issuing the
      # request. It also poisoned dialyzer's success typing for every caller of
      # `request/5`: the whole chain narrowed to `{:error, _}` only.
      #
      # Handled explicitly here, and it FAILS CLOSED. Not knowing whether there is
      # capacity is not the same as having it.
      {:error, :rate_limiter_unavailable} ->
        wrap_exchange_error(opts, "Rate limiter unavailable")
    end
  end

  # `:plug` and `:req_adapter` are passed straight through to `Req`, which is how the
  # request pipeline is exercised without a network. It is not a test-only escape
  # hatch: a consumer with its own transport requirements uses the same seam, and a
  # venue package with an unusual one is not forced to reimplement this pipeline.
  defp transport_opts(opts), do: Keyword.take(opts, [:plug, :adapter, :req_adapter])

  defp make_http_request(method, url, headers, body, opts) do
    timeout = Config.opt(opts, :timeout, 30_000)

    request_opts =
      [
        receive_timeout: timeout,
        connect_options: [timeout: timeout],
        # Retry is this module's job, not Req's — it needs the venue's `Retry-After`
        # and the rate-limit context, neither of which Req has.
        retry: false,
        redirect: false
      ] ++ transport_opts(opts)

    try do
      case Req.request(
             [
               method: method,
               url: url,
               headers: headers,
               body: body
             ] ++ request_opts
           ) do
        {:ok, %Req.Response{status: status, headers: resp_headers, body: resp_body}} ->
          response = %{
            status: status,
            headers: resp_headers,
            body: resp_body
          }

          case status do
            status when status in 200..299 ->
              {:ok, response}

            429 ->
              handle_rate_limit(response, method, url, opts)

            # A 4xx is where a venue says *why*, and the contract has a shape for it:
            # `{:refused, reason}` is permanent and `{:error, reason}` may be transient,
            # and a caller acts on the difference. Flattening the status and body into a
            # message string destroys the only evidence that tells them apart — so a
            # venue package that wants to produce a refusal has to string-match its way
            # back, and `String.contains?(message, "404")` also matches a body that
            # happens to contain "404".
            #
            # `raw_status: true` hands the response back intact and lets the venue decide.
            # Opt-in rather than the default, because the string form is what every
            # existing caller matches on and changing it silently would turn working
            # refusal detection into a permanent error.
            status when status in 400..499 ->
              if Config.opt(opts, :raw_status, false) do
                {:ok, response}
              else
                {:error, "Client error (#{status}): #{format_body(resp_body)}"}
              end

            status when status in 500..599 ->
              {:error, "Server error (#{status}): #{format_body(resp_body)}"}

            _value ->
              {:error, "Unexpected status (#{status}): #{format_body(resp_body)}"}
          end

        {:error, reason} ->
          {:error, "Request failed: #{inspect(reason)}"}
      end

      # RESCUE: defensive boundary; Phase 2.5 audit — refine reason.
    rescue
      error ->
        {:error, "Request exception: #{inspect(error)}"}
    end
  end

  defp handle_rate_limit(response, method, url, opts) do
    # Parse rate limit headers to get more accurate retry timing
    retry_after = parse_retry_after_header(response.headers)
    provider = Config.opt(opts, :provider, "unknown")
    short_url = url |> String.split("?") |> List.first() |> String.slice(0, 80)

    Logger.warning(
      "[HttpClient] 429 provider=#{provider} #{method} #{short_url} retry_after=#{retry_after}s"
    )

    {:error, :rate_limited, retry_after: retry_after}
  end

  defp build_hmac_headers(method, path, body, credentials) do
    # Coinbase Advanced Trade API v3: timestamp in seconds, no passphrase
    timestamp = DateTime.utc_now() |> DateTime.to_unix(:second) |> to_string()

    message = timestamp <> (method |> to_string() |> String.upcase()) <> path <> (body || "")

    signature =
      :crypto.mac(:hmac, :sha256, credentials.api_secret, message)
      |> Base.encode16(case: :lower)

    [
      {"CB-ACCESS-KEY", credentials.api_key},
      {"CB-ACCESS-SIGN", signature},
      {"CB-ACCESS-TIMESTAMP", timestamp}
    ]
  end

  defp build_basic_auth_headers(credentials) do
    auth_string = Base.encode64("#{credentials.api_key}:#{credentials.api_secret}")
    [{"Authorization", "Basic #{auth_string}"}]
  end

  defp build_bearer_headers(credentials) do
    [{"Authorization", "Bearer #{credentials.api_key}"}]
  end

  # Rate limiting helper functions

  @spec check_rate_limits(keyword()) ::
          :ok
          | {:error, :rate_limit_timeout | :rate_limiter_unavailable}
          | {:error, :rate_limited, retry_after: integer()}
  defp check_rate_limits(opts) do
    case Keyword.get(opts, :provider) do
      nil ->
        :ok

      provider ->
        if Config.opt(opts, :rate_limit_blocking, false) do
          provider |> limiter().acquire(weight(opts), limiter_opts(opts)) |> normalise_acquire()
        else
          provider |> limiter().check(weight(opts), limiter_opts(opts)) |> normalise_check()
        end
    end
  end

  # Fails closed in BOTH directions. The implementation this replaced propagated the
  # error from `acquire` and mapped the identical condition to `:ok` in `check` — so a
  # limiter whose backing store was unreachable blocked nothing while reporting success,
  # undocumented and in only one of the two paths.
  defp normalise_acquire(:ok), do: :ok
  defp normalise_acquire({:error, :rate_limit_timeout}), do: {:error, :rate_limit_timeout}
  defp normalise_acquire({:error, _reason}), do: {:error, :rate_limiter_unavailable}

  defp normalise_check(:ok), do: :ok
  defp normalise_check({:error, _reason}), do: {:error, :rate_limiter_unavailable}

  defp normalise_check({:rate_limited, retry_after_ms}) do
    # The pipeline speaks seconds because `Retry-After` does. Rounded UP: rounding a
    # 1500ms wait down to one second retries while still limited.
    {:error, :rate_limited, retry_after: ceil(retry_after_ms / 1000)}
  end

  # Named for what actually happened, not for the outcome. Called once per attempt that
  # reached `make_http_request/5` — success, retried 5xx, 429, or a permanent 4xx all put a
  # request on the wire and all consumed the venue's real quota. See the call site in
  # `do_request_with_rate_limiting/6`.
  defp record_request_sent(opts) do
    case Keyword.get(opts, :provider) do
      nil -> :ok
      provider -> limiter().record(provider, weight(opts), limiter_opts(opts))
    end
  end

  # Resolved per call, never at compile time, and through `Config` rather than
  # `Application.get_env/3` so a consumer's async test can swap it for its own process
  # tree without configuring it for every test running beside it.
  defp limiter do
    Config.get(:dp_exchange_core, :rate_limit_module, DefaultRateLimiter)
  end

  defp weight(opts), do: Config.opt(opts, :weight, 1)

  # `account_id`, `user_id` and `operation` are carried through for an implementation
  # that wants them, but the ceiling itself is **per venue** (D5). A venue's published
  # limit is a property of the venue, not of whose key is presented; scoping per key
  # would let N keys multiply one venue's ceiling by N and get every one of them
  # throttled. A consumer needing more headroom than one venue allows runs clustered.
  defp limiter_opts(opts) do
    Keyword.take(opts, [:account_id, :user_id, :operation, :timeout, :limiter])
  end

  defp parse_retry_after_header(headers) do
    case fetch_integer(normalise_headers(headers), "retry-after") do
      {:ok, seconds} -> seconds
      # The venue said it is limiting us but not for how long. Five seconds is a
      # deliberate floor rather than a measurement, and retrying immediately — which
      # is what a 0 default would mean — is how a 429 becomes a 429 storm.
      :error -> 5
    end
  end

  # Normalises the two header shapes this pipeline sees. `Req` returns
  # `%{"name" => ["value"]}`; a list of `{name, value}` pairs is the other convention,
  # and a caller passing one should not silently get `nil` for every lookup.
  #
  # This is not hypothetical tidiness: with only the pair form handled, every
  # `Retry-After` a venue sent was invisible, so a 429 always used the fallback.
  defp normalise_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} -> {String.downcase(key), first_value(value)} end)
  end

  defp normalise_headers(headers) when is_list(headers) do
    Map.new(headers, fn {key, value} -> {String.downcase(key), first_value(value)} end)
  end

  defp first_value([value | _rest]), do: value
  defp first_value(value), do: value

  # Wrap an error with exchange context when provider is specified in opts.
  # Returns `{:error, {:exchange_error, provider, reason}}` for provider-aware
  # callers, or plain `{:error, reason}` when no provider context exists.
  # 4xx HTTP errors are client mistakes (bad symbol, unauthorized, etc.) — permanent, don't retry
  defp client_error?(reason) when is_binary(reason) do
    String.contains?(reason, "Client error (4")
  end

  defp wrap_exchange_error(opts, reason) do
    case Keyword.get(opts, :provider) do
      nil -> {:error, reason}
      provider -> {:error, {:exchange_error, provider, reason}}
    end
  end

  # Format response body for error messages (handles both strings and maps)
  defp format_body(body) when is_binary(body), do: body
  defp format_body(body) when is_map(body) or is_list(body), do: inspect(body)
  defp format_body(body), do: inspect(body)
end
