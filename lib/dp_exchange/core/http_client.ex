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

  @type http_response :: %{
          status: integer(),
          headers: headers(),
          body: String.t()
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

  ## Returns
  - `{:ok, http_response()}` on success
  - `{:error, reason}` on failure
  """
  @spec request(http_method(), String.t(), headers(), body(), rate_limited_request_options()) ::
          {:ok, http_response()} | {:error, String.t()}
  def request(method, url, headers \\ [], body \\ nil, opts \\ []) do
    _timeout = Keyword.get(opts, :timeout, 30_000)
    retry_attempts = Keyword.get(opts, :retry_attempts, 3)
    log_requests = Keyword.get(opts, :log_requests, true)

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
    case request(:get, full_url, Keyword.get(opts, :headers, []), nil, opts) do
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
  @spec build_auth_headers(http_method(), String.t(), body(), map(), atom()) :: headers()
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
        case make_http_request(method, url, headers, body, opts) do
          {:ok, response} ->
            # Record successful request for rate limiting
            record_successful_request(opts)
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
              retry_delay = Keyword.get(opts, :retry_delay, 1000)
              backoff_delay = retry_delay * (4 - attempts_left)
              provider = Keyword.get(opts, :provider, "unknown")
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
    timeout = Keyword.get(opts, :timeout, 30_000)

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

            status when status in 400..499 ->
              {:error, "Client error (#{status}): #{format_body(resp_body)}"}

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
    provider = Keyword.get(opts, :provider, "unknown")
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
        if Keyword.get(opts, :rate_limit_blocking, false) do
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

  defp record_successful_request(opts) do
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

  defp weight(opts), do: Keyword.get(opts, :weight, 1)

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
