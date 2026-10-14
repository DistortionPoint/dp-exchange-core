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

  ## A response body is bounded as it is received

  `:max_body_bytes` (default 16 MiB) caps what is held for one response. Req is given
  `into: fun`, and the function counts bytes as they arrive and halts the transfer past the
  limit, so a venue, proxy or CDN sending an unbounded body cannot exhaust the calling node's
  memory. Streaming into a function skips only Req's decompression, and this pipeline never
  enables that (`compressed` is off, so no `accept-encoding` is sent and a body is never
  inflated), so below the limit the body, the JSON decoding, `decode_body: false` and
  non-JSON handling are what they were. A transport that ignores `:into` is checked after
  the fact instead; that path cannot prevent the allocation.

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
  `make_http_request/5` — success, retry, 429, or a permanent 4xx — is now counted once,
  by the reservation each attempt makes before it is sent (an `acquire/3`, with a zero
  timeout on the non-blocking path). See `check_rate_limit/2`.
  """

  require Logger

  alias DpExchange.Core.{Config, DefaultRateLimiter, Telemetry}

  # Suppress dialyzer warnings for functions that dialyzer incorrectly analyzes
  @dialyzer {:nowarn_function, [parse_response_body: 2, get: 3]}

  # The most of a response body that goes into an error message. See `format_body/1`.
  @body_excerpt_bytes 2_048

  # The most of a response body that is received at all, unless the caller says otherwise.
  # Chosen, not measured: well above any venue's largest published payload in this family
  # (candle pages, catalogue listings), and small enough that one hostile or broken response
  # cannot take the calling node's memory.
  @default_max_body_bytes 16_777_216

  # Marks a response whose body was cut at the limit, so `make_http_request/5` can turn it
  # into an error after Req's response steps have run over the (emptied) body.
  @too_large_key :dp_exchange_response_too_large
  @type http_method :: :get | :post | :put | :delete
  @type headers :: [{String.t(), String.t()}]

  @typedoc """
  Headers, or a function producing them that is called again for every attempt. Use the
  function form for a signature that expires or carries a one-time nonce, so a retry is
  signed afresh rather than replayed. See `request/5`.
  """
  @type signed_headers :: headers() | (-> headers() | {:ok, headers()} | {:error, term()})
  @type body :: String.t() | nil
  @type options :: keyword()
  @typedoc """
  The `:provider` option, echoed back as the tag of `{:exchange_error, provider, reason}`.
  Every venue passes its atom (`:gemini`, `:gemini_private`); a string is accepted too.
  """
  @type provider :: atom() | String.t()
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

  # A keyword list only. A map was in this type, and every reader of these options
  # (`Keyword.put_new_lazy/3`, `Keyword.take/2`, `Config.opt/3`) raises on one.
  @type rate_limited_request_options :: [
          {:provider, provider()}
          | {:account_id, account_id()}
          | {:user_id, user_id()}
          | {:operation, String.t()}
          | {atom(), term()}
        ]

  @doc """
  Make an HTTP request with provider-specific and account-aware rate limiting.

  ## Parameters
  - `method`: HTTP method (:get, :post, :put, :delete)
  - `url`: Full URL for the request
  - `headers`: List of HTTP headers, or a zero-arity function returning them (or
    `{:ok, list}` / `{:error, reason}`) that is called again before every attempt, so a
    signed request is re-signed on retry rather than replayed
  - `body`: Request body (for POST/PUT requests)
  - `opts`: Additional options including rate limiting context

  ## Options
  - `:timeout` - Request timeout in milliseconds (default: 30_000). It bounds the whole
    response, not each chunk, and it applies to each attempt when `:retry_attempts` retries.
  - `:retry_attempts` - Number of attempts in all (default: 3). **Applied to every method,
    POST and DELETE included.** A transport failure or 5xx after a write may mean the write
    took effect, and a retry repeats it. Whether that is safe depends on whether the venue
    deduplicates the request, which only the venue package knows. So the venue decides per
    call. A write with an idempotency key, such as a `client_order_id`, may keep the default.
    A write without one is sent with `retry_attempts: 1`. Every venue in the family does this
    for its money-moving writes.
  - `:retry_delay` - Base delay between retries in milliseconds (default: 1000)
  - `:log_requests` - Whether to log requests (default: true)
  - `:provider` - Provider name for rate limiting (required for rate limiting)
  - `:rate_limit_per_endpoint` - Also meter this request in a bucket of its own endpoint,
    keyed `"<provider> <path>"`, beside the provider's (default: `false`). For a venue that
    states a per-endpoint limit as well as a global one. The endpoint bucket takes the
    limiter's `:default` limits unless the consumer names it.
  - `:rate_limit_blocking` - Wait for the limiter instead of failing when the bucket is
    empty (default: `false`). The wait is bounded by `:timeout`.
  - `:weight` - Tokens this request costs (default: 1)
  - `:max_retry_after_s` - Ceiling, in seconds, on a venue's `Retry-After` that is
    honoured (default: 600)
  - `:account_id`, `:user_id`, `:operation` - Forwarded to the limiter, which may use them
    (optional, no defaults). `DefaultRateLimiter` ignores all three: the ceiling is per
    venue, never per key.
  - `:max_body_bytes` - The most of a response body that is received (default: 16 MiB,
    `16_777_216`). Counted as the bytes arrive; the transfer is halted the moment the total
    passes the limit, so an oversized or endless body is never held in memory. The result is
    `{:error, {:response_too_large, limit}}` (wrapped in `{:exchange_error, provider, _}` when
    `:provider` is given), is never retried, and is reported on `[:dp_exchange, :request,
    :stop]` with `result: :error, reason: :response_too_large`. A body of exactly the limit is
    accepted. A positive integer, or `ArgumentError`. The count is of the bytes on the wire:
    this pipeline never asks for compression (`Req`'s `:compressed` is off), so it is also the
    decoded size.
  - `:raw_status` - Return `{:ok, response}` for a 4xx instead of an error string
    (default: `false`). A venue package needs this to tell a **refusal** from an
    **error**: the contract makes `{:refused, reason}` permanent and `{:error, reason}`
    possibly transient, and the venue states which in the 4xx status and body. Without
    it that evidence is flattened into a message and the venue has to string-match its
    way back to it. 5xx is unaffected — a server error is not a venue's considered answer.
    **429 is unaffected too**: it is the venue's rate limit, handled by this pipeline
    (`Retry-After`, the held bucket, telemetry), and is always the "Rate limited by the venue"
    error, whether or not `:raw_status` is set.
  - `:decode_body` - Passed to `Req` (default: Req's, which decodes JSON with floats).
    `false` returns the body as bytes, for a venue that types money as a JSON number and
    must decode it without float rounding (`Jason.decode(body, floats: :decimals)`).

  ## Returns
  - `{:ok, http_response()}` on success, and on a 4xx when `raw_status: true`
  - `{:error, reason}` on failure
  """
  @typedoc """
  Why a request did not produce a response.

  Two shapes, and the spec used to name only the first — which made dialyzer tell every
  consumer that its handling of the other was unreachable dead code.

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
  @type request_error ::
          String.t()
          | {:response_too_large, pos_integer()}
          | {:exchange_error, provider(), term()}

  @spec request(
          http_method(),
          String.t(),
          signed_headers(),
          body(),
          rate_limited_request_options()
        ) ::
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

    # **Refused here, in the caller, before anything is sent.** `"3"` sorts above every
    # integer, so it entered the retry branch and died computing `"3" - attempts_left` in the
    # calling venue process, after the request had already left; `retry_delay: "1000"` died
    # the same way on the first retry. The mistake belongs at the call that made it.
    unless is_integer(retry_attempts) and retry_attempts >= 0 do
      raise ArgumentError,
            ":retry_attempts must be a non-negative integer, got #{inspect(retry_attempts)}"
    end

    retry_delay = Config.opt(opts, :retry_delay, 1000)

    unless is_integer(retry_delay) and retry_delay >= 0 do
      raise ArgumentError,
            ":retry_delay must be a non-negative integer of milliseconds, got " <>
              inspect(retry_delay)
    end

    max_body_bytes = Config.opt(opts, :max_body_bytes, @default_max_body_bytes)

    unless is_integer(max_body_bytes) and max_body_bytes > 0 do
      raise ArgumentError,
            ":max_body_bytes must be a positive integer of bytes, got #{inspect(max_body_bytes)}"
    end

    # **The endpoint, never the URL.** This logged `url` whole, so a venue that authenticates
    # in the query string (`?api_key=...`) or in the URL's userinfo wrote its credential into
    # the log on every request. `Telemetry.endpoint/1` is the one place that decides what part
    # of a URL is safe to emit, and the telemetry metadata and the retry warning already use it.
    # A function, so the message (and `Telemetry.endpoint/1`) is built only when the debug
    # level is enabled; the node usually runs at info and this is every request.
    if log_requests do
      Logger.debug(fn ->
        "HTTP Request: #{method |> to_string() |> String.upcase()} #{Telemetry.endpoint(url)}"
      end)
    end

    if cleartext_credentials?(url, headers, opts) do
      {:error, cleartext_refusal()}
    else
      do_request_with_rate_limiting(method, url, headers, body, opts, retry_attempts)
    end
  end

  # **Credentials never travel over plain http.** Every venue's base URL can be overridden
  # (config or an option, for a sandbox or a test stub), and nothing stopped an `http://`
  # one: a signed request then put the key, the signature or the bearer token on the wire
  # in the clear. Each venue now checks its own URLs; this is the backstop for any it
  # missed. A request counts as carrying credentials when it is signed per attempt (a
  # function) or names a credential-shaped header. Loopback hosts stay allowed (a local
  # stub), and so does `plug:`, which never leaves the process.
  defp cleartext_refusal, do: "refused: credentials are not sent over plain http"
  @credential_header_fragments ~w(authorization key sign token passphrase secret)

  defp cleartext_credentials?(url, headers, opts) do
    not Keyword.has_key?(opts, :plug) and credentials_in?(headers) and cleartext_remote?(url)
  end

  defp credentials_in?(headers) when is_function(headers, 0), do: true

  # A map is read like a list of pairs. `Req` accepts `%{"authorization" => ...}` as headers
  # and `resolve_headers/1` passes it through, so a map carrying a credential used to fall
  # through to the catch-all below and go out over plain http unrefused.
  defp credentials_in?(headers) when is_list(headers) or is_map(headers) do
    Enum.any?(headers, fn
      {name, _value} ->
        name = name |> to_string() |> String.downcase()
        Enum.any?(@credential_header_fragments, &String.contains?(name, &1))

      _other ->
        false
    end)
  end

  # Deliberate: a value that is not headers in any form `request/5` documents. There is
  # nothing to inspect, so it is not judged here; the transport rejects it and the failure
  # comes back as an `{:error, _}` like any other transport failure.
  defp credentials_in?(_headers), do: false

  defp cleartext_remote?(url) do
    case URI.parse(url) do
      %URI{scheme: "http", host: host} -> host not in ["localhost", "127.0.0.1", "::1"]
      _https_or_other -> false
    end
  end

  @doc """
  Convenience function for GET requests with query parameters.

  ## Parameters
  - `url`: Base URL for the request
  - `params`: Query parameters as keyword list or map. `nil` values are dropped. Keys and
    values are form-encoded. A list, tuple or plain-map value raises `ArgumentError`: it has
    no single spelling, and the venue decides between repeated keys and a comma join.
  - `opts`: Additional options

  ## Returns
  - `{:ok, parsed_json}` on success. With `decode_body: false` the bytes are decoded here
    with `Jason`'s `floats: :decimals`, so a JSON number is a `Decimal` and keeps its digits.
  - `{:error, reason}` on failure
  """
  @spec get(String.t(), keyword() | map(), rate_limited_request_options()) ::
          {:ok, any()} | {:error, request_error()}
  def get(url, params \\ [], opts \\ []) do
    query_string = build_query_string(params)
    full_url = if query_string == "", do: url, else: "#{url}?#{query_string}"

    # `:headers` is read from opts rather than hardcoded to `[]`. It was hardcoded, so a
    # caller that passed authentication headers had them silently dropped and got a 401
    # with nothing to explain it — the request looked correct at the call site and was
    # not correct on the wire. Found by a venue package's tier-2 tests.
    case request(:get, full_url, Config.opt(opts, :headers, []), nil, opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        # A body that is not JSON, or not an object or list, is tagged with the venue like
        # every other failure here. It came back bare, so the one caller who passed
        # `:provider` to tell its failures apart got two that did not say whose they were.
        case parse_response_body(body, Config.opt(opts, :decode_body, true)) do
          {:ok, _decoded} = ok -> ok
          {:error, reason} -> wrap_exchange_error(opts, reason)
        end

      {:ok, %{status: status, body: body}} ->
        # Capped like every other message built from a body (`format_body/1`). Reached only
        # with `raw_status: true`, where a 4xx is handed back whole, and this put an
        # uncapped venue error page into the error tuple. `inspect/2` with these limits is
        # byte-identical for a body inside them, so a message a caller matches is unchanged.
        wrap_exchange_error(
          opts,
          "HTTP #{status}: #{inspect(body, limit: 50, printable_limit: @body_excerpt_bytes)}"
        )

      # `request/5` has already tagged its own failures with the venue when `:provider` was
      # given, so tagging again nested the tag: `{:exchange_error, "v", {:exchange_error,
      # "v", message}}`, which no `request_error()` clause describes. A refusal `request/5`
      # returns bare (the cleartext backstop, a signer's own error) is tagged here, once.
      {:error, {:exchange_error, _provider, _reason} = tagged} ->
        {:error, tagged}

      {:error, reason} ->
        wrap_exchange_error(opts, reason)
    end
  end

  defp parse_response_body(body, _decode_body) when is_map(body) or is_list(body) do
    {:ok, body}
  end

  # **`decode_body: false` is honoured here too.** It exists so a JSON number keeps its digits
  # (`request/5`'s `:decode_body`), and `get/3` then decoded the bytes it was handed with
  # `Jason.decode/1`, whose floats are native: the loss the option was passed to avoid
  # happened one function later, silently, for the one caller that had asked for it not to.
  # A number in that body is now a `Decimal`.
  defp parse_response_body(body, decode_body) when is_binary(body) do
    floats = if decode_body == false, do: :decimals, else: :native

    case Jason.decode(body, floats: floats) do
      {:ok, json} when is_map(json) or is_list(json) ->
        {:ok, json}

      # **A bare JSON scalar is refused here exactly as it is when Req decodes it.** A body
      # `null`, `42`, `"x"` or `true` served as `text/plain` reached the caller as
      # `{:ok, nil}` / `{:ok, 42}`, while the same bytes served as `application/json` (Req
      # decodes them to a non-container) were `{:error, "Unexpected response format"}`. The
      # `{:ok, nil}` is the substitute this family refuses: a venue decoder doing `Map.get`
      # on it raised in the caller's process, or read a successful empty answer.
      {:ok, _scalar} ->
        {:error, "Unexpected response format"}

      {:error, _last} ->
        {:error, "Invalid JSON response"}
    end
  end

  defp parse_response_body(_body, _decode_body) do
    {:error, "Unexpected response format"}
  end

  @doc """
  Build authentication headers for API requests.

  ## Parameters
  - `method`: HTTP method
  - `path`: API endpoint path
  - `body`: Request body
  - `credentials`: API credentials
  - `auth_type`: Authentication type: `:hmac_sha256`, `:basic`, `:bearer`, or a 4-arity
    function `(method, path, body, credentials -> headers)` for a venue's own scheme

  ## Returns
  - List of authentication headers. An `auth_type` that is none of the above raises
    `ArgumentError`. It used to yield `[]`, so a typo'd scheme (`:hmac_sha_256`) sent the
    request **unauthenticated** — the opposite of failing closed.
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

      unknown ->
        raise ArgumentError,
              "unknown auth_type #{inspect(unknown)}: expected :hmac_sha256, :basic, :bearer " <>
                "or a 4-arity builder. Refused rather than sending the request unsigned."
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

    with {:ok, limit} <- fetch_count(header_map, "x-ratelimit-limit"),
         {:ok, remaining} <- fetch_count(header_map, "x-ratelimit-remaining") do
      %{limit: limit, remaining: remaining, reset_time: parse_reset(header_map)}
    else
      :error -> nil
    end
  end

  # A WHOLE-string parse, and the `_rest` this used to discard is the reason.
  #
  # `Integer.parse/1` answers `{integer, rest}` for anything merely STARTING with digits, so
  # a header this package cannot actually read still produced a number: `"12abc"` became 12,
  # and `"1757000000000-ish"` became a timestamp. Both then flowed on as facts — into the
  # limit/remaining budget the limiter throttles against, and into `parse_reset/1`, whose own
  # comment directly above says it answers `nil` "rather than a guessed instant". It could
  # not keep that promise while this read one out of text that is not a number.
  #
  # Header values for these are plain integers, so a partial parse means the header is
  # malformed — which is exactly when guessing is worst, because the guess is unverifiable
  # and silently changes how hard this package hits the venue.
  defp fetch_integer(headers, key) do
    # Trimmed: surrounding whitespace (`"30 "`) is not part of the value in RFC 9110, and a
    # proxy that leaves it in made a perfectly readable `Retry-After` fall to the floor.
    with value when is_binary(value) <- Map.get(headers, key),
         {integer, ""} <- Integer.parse(String.trim(value)) do
      {:ok, integer}
    else
      _absent_or_unparseable -> :error
    end
  end

  # **A count of requests is not negative.** `fetch_integer/2` answers any integer, which is
  # right for `Retry-After` (its caller treats a negative as the floor) and for the reset, but
  # `x-ratelimit-limit: -1` or `remaining: -5` came back as `%{limit: -1, remaining: -5}`: a
  # budget that is a plausible integer with no meaning, which a caller throttling on
  # `remaining` reads as "exhausted" or as an unlimited sentinel. Unreadable, so `nil`.
  defp fetch_count(headers, key) do
    case fetch_integer(headers, key) do
      {:ok, count} when count >= 0 -> {:ok, count}
      _absent_or_negative -> :error
    end
  end

  # `x-ratelimit-reset` is published as either a delta in seconds or an absolute unix
  # timestamp, and nothing in the header says which. A value below one year of seconds
  # cannot be a plausible unix timestamp, so it is a delta. An unparseable value returns
  # `nil` rather than a guessed instant.
  #
  # **A negative value is not a delta either.** Everything at or below one year used to go to
  # `DateTime.add/3`, and that included any negative number. `DateTime.add/3` does not refuse
  # an offset outside the calendar's range: it computes the date. Past about 10^20 seconds
  # that took longer than 4 seconds (measured 2026-09-27, three offsets, each killed at the
  # 4-second limit). So one header such as `x-ratelimit-reset: -99999999999999999999999`
  # stalled the calling process on a request that had already succeeded. A reset in the past
  # says nothing a caller can wait for, so it is `nil`.
  defp parse_reset(headers) do
    case fetch_integer(headers, "x-ratelimit-reset") do
      {:ok, value} when value > 31_536_000 -> absolute_reset(value)
      {:ok, value} when value >= 0 -> DateTime.add(DateTime.utc_now(), value, :second)
      {:ok, _negative} -> nil
      :error -> nil
    end
  end

  # `DateTime.from_unix/2`, not `from_unix!/2`.
  #
  # The bang version RAISES on a value outside the representable range, and a header is
  # venue-supplied text: `"1787936147000"` in a seconds field — a venue that moved to
  # milliseconds, which is an ordinary kind of drift — is `invalid Unix time`, thrown out of
  # `parse_rate_limit_headers/1`, which runs on EVERY response. A rate-limit header this
  # package cannot read must not be able to fail the request it rode in on.
  #
  # `nil` is the answer the caller already handles and the one `parse_reset/1`'s own comment
  # promises: "did not say", rather than a guessed instant.
  defp absolute_reset(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, at} -> at
      {:error, _out_of_range} -> nil
    end
  end

  # Private functions

  defp build_query_string([]), do: ""

  defp build_query_string(params) when is_list(params) do
    params
    |> Enum.filter(fn {_k, v} -> v != nil end)
    |> Enum.map_join("&", fn {k, v} ->
      URI.encode_www_form(to_string(k)) <> "=" <> URI.encode_www_form(query_value(k, v))
    end)
  end

  # Sorted by key. A map of more than 32 keys has no defined iteration order, so the same
  # params could be sent in a different order on a retry and a venue that signs the query
  # string saw two different strings. At 32 keys or fewer the map's own order IS key order,
  # so nothing changes for the common case.
  defp build_query_string(params) when is_map(params) do
    params |> Map.to_list() |> Enum.sort_by(fn {key, _value} -> key end) |> build_query_string()
  end

  # **A value with no single query spelling is refused, never flattened.** `to_string/1` on
  # a list concatenated it, so `[symbols: ["BTC", "ETH"]]` was sent as `symbols=BTCETH`: a
  # well-formed request for a product that does not exist, answered as an ordinary 404 or an
  # empty result. Whether a venue wants repeated keys or a comma join is the venue's call,
  # so the venue builds that value itself. Keys are encoded too; they were interpolated raw.
  defp query_value(key, value)
       when is_list(value) or is_tuple(value) or (is_map(value) and not is_struct(value)) do
    raise ArgumentError,
          "query parameter #{inspect(key)} has no single query-string spelling: " <>
            inspect(value) <> ". Encode lists and maps in the venue before calling get/3."
  end

  defp query_value(_key, value), do: to_string(value)

  # **Headers may be a function, called again for every attempt.** A venue that signs with
  # a timestamp or a one-time nonce cannot have its request retried byte for byte:
  # `dp_exchange_robinhood`'s signature is accepted for about 30 seconds, and
  # `dp_exchange_gemini` and `dp_exchange_webull` sign a nonce the venue refuses to see
  # twice. A retry after a timed-out first attempt re-sent the SAME signed headers, which
  # meant a stale or replayed signature. So the retry of a read could never succeed, and the
  # venue refused it as unauthorised, a credential problem the caller does not have. A zero-arity
  # function here is resolved per attempt, so every attempt carries a fresh signature. It
  # may return a header list, `{:ok, list}`, or `{:error, reason}`. An error is returned at
  # once and never retried: a request that cannot be signed will not sign on a second try.
  #
  # **Signed AFTER the limiter, not before.** The function used to be called first and the
  # limiter waited afterwards, so on a blocking limiter a signature could sit for seconds
  # before it was sent. Two concurrent callers on an incrementing nonce were then released in
  # either order, and the later-signed request reached the venue first, so the earlier one
  # was refused as `InvalidNonce`. A time-based nonce past its 30 s window was refused the
  # same way. So on a BLOCKING limiter the request is signed again once the wait is over, and
  # only that signature is sent.
  #
  # It is still signed first, too. A request that cannot be signed (no credentials) must
  # fail with that reason before the limiter is asked, or it spends a token and, with no
  # limiter running, reports "Rate limiter unavailable" in place of the reason that names
  # the fix (found 2026-10-10 by every venue's "no credentials never reaches the network"
  # test). A non-blocking limiter never waits, so its first signature is the one sent.
  defp do_request_with_rate_limiting(method, url, headers, body, opts, attempts_left) do
    case resolve_headers(headers) do
      {:ok, resolved} -> attempt(method, url, headers, resolved, body, opts, attempts_left)
      {:error, _reason} = error -> error
    end
  end

  defp resolve_headers(headers) when is_function(headers, 0) do
    case headers.() do
      {:ok, resolved} when is_list(resolved) -> {:ok, resolved}
      {:error, _reason} = error -> error
      resolved when is_list(resolved) -> {:ok, resolved}
    end
  end

  defp resolve_headers(headers), do: {:ok, headers}

  # `headers` is what each attempt resolves again; `signed` is this attempt's first
  # signature — see `do_request_with_rate_limiting/6`.
  defp attempt(method, url, headers, signed, body, opts, attempts_left) do
    # The endpoint a `rate_limit_per_endpoint: true` request is metered under — see
    # `rate_limit_keys/1`. The URL's path, never its query: `?symbol=BTCUSD` and
    # `?symbol=ETHUSD` are the same endpoint to the venue's per-endpoint limit.
    # `|| "/"`: `URI.parse("https://host").path` is `nil`, which became the endpoint bucket
    # `"<provider> "` (a trailing space and nothing after it) rather than the root path.
    # Only parsed when a per-endpoint bucket will use it (`rate_limit_keys/1` reads `:path`
    # for nothing else), so an ordinary request does not parse its URL a second time.
    opts =
      if Config.opt(opts, :rate_limit_per_endpoint, false),
        do: Keyword.put_new_lazy(opts, :path, fn -> URI.parse(url).path || "/" end),
        else: opts

    # Check rate limits before making the request, and sign only once they have cleared.
    case check_rate_limits(opts) do
      :ok -> sign_and_send(method, url, headers, signed, body, opts, attempts_left)
      refused -> rate_limit_refusal(refused, opts)
    end
  end

  defp sign_and_send(method, url, headers, signed, body, opts, attempts_left) do
    if blocking?(opts) and is_function(headers, 0) do
      case resolve_headers(headers) do
        {:ok, fresh} -> send_attempt(method, url, headers, fresh, body, opts, attempts_left)
        {:error, _reason} = error -> error
      end
    else
      send_attempt(method, url, headers, signed, body, opts, attempts_left)
    end
  end

  defp send_attempt(method, url, headers, resolved, body, opts, attempts_left) do
    # Every attempt reserved its tokens in `check_rate_limits/1` before it was sent, so
    # every outcome is already counted: a 5xx retried below and a 429 consumed the
    # venue's quota exactly as a 2xx did. Counting only successes is the incident this
    # module's moduledoc records ("395 calls per 60s against a documented 300, while
    # the budget panel read 83/240"). Nothing is recorded again afterwards, because a
    # second count halves the ceiling.
    response = make_http_request(method, url, resolved, body, opts)

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
        hold_for_retry_after(opts, seconds)

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
          backoff_delay = backoff_ms(retry_delay, attempts_made)
          provider = Config.opt(opts, :provider, "unknown")
          # Through `Telemetry.endpoint/1`, not a split on "?": that kept `user:pass@` and a
          # `#fragment`, so a credential in the URL's userinfo reached the warning.
          short_url = url |> Telemetry.endpoint() |> String.slice(0, 80)

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
  end

  @doc false
  # The wait before a retry: `retry_delay` scaled by the attempts already made, plus up to a
  # quarter of that again at random. **Without jitter every caller that failed together
  # retried together.** A venue outage or a dropped connection fails every in-flight request
  # of every feed and task at the same instant, they all slept the identical
  # `retry_delay * n`, and the whole fleet re-hit the recovering venue in one burst, which is
  # the request spike a limiter and a venue's own 429 exist to prevent. The jitter only ever
  # lengthens the wait, so the configured delay stays a floor. Public for its test alone.
  @spec backoff_ms(non_neg_integer(), pos_integer()) :: non_neg_integer()
  def backoff_ms(retry_delay, attempts_made) do
    base = retry_delay * attempts_made
    base + :rand.uniform(div(base, 4) + 1) - 1
  end

  defp rate_limit_refusal(refused, opts) do
    case refused do
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
  #
  # `:decode_body` too. Req decodes a JSON body with floats, and a venue that types money
  # as a JSON *number* loses every digit past ~17 significant ones before its own decoder
  # sees it: measured, `1234.567890123456789` arrives as `1234.567890123457`. With
  # `decode_body: false` the venue receives the bytes and decodes them itself, e.g. with
  # `Jason.decode(body, floats: :decimals)`. Absent, Req's default is unchanged.
  #
  # **`:req_adapter` is this package's name for Req's `:adapter`, and is translated here.** It
  # was passed through under its own name, and Req (0.7.5) raises `unknown option
  # :req_adapter`: the seam this comment documents, and four venue packages forward, raised an
  # `ArgumentError` in the caller's process for anyone who used it. An explicit `:adapter`
  # wins over it.
  defp transport_opts(opts) do
    taken = Keyword.take(opts, [:plug, :adapter, :decode_body])

    case Keyword.fetch(opts, :req_adapter) do
      {:ok, adapter} -> Keyword.put_new(taken, :adapter, adapter)
      :error -> taken
    end
  end

  # The one place a request actually leaves this process and comes back, which is why the
  # `[:dp_exchange, :request, :*]` events are emitted HERE and not at the public entry
  # points. `request/5`, `get/3` and every convenience wrapper funnel through this, so one
  # emission covers every venue's every call — and, more to the point, cannot be forgotten
  # by the next endpoint somebody adds.
  #
  # `:stop` fires for every outcome, including the 4xx/5xx that become `{:error, _}` below
  # and the 429 that `handle_rate_limit/4` turns into a retry. A latency panel built on
  # successes alone shows a venue getting FASTER exactly as it starts failing, because the
  # slow calls are the ones dropping out of the sample.
  defp make_http_request(method, url, headers, body, opts) do
    timeout = Config.opt(opts, :timeout, 30_000)
    max_body_bytes = Config.opt(opts, :max_body_bytes, @default_max_body_bytes)

    metadata = %{
      provider: Config.opt(opts, :provider, "unknown"),
      endpoint: Telemetry.endpoint(url),
      method: method
    }

    start_time = Telemetry.request_start(metadata)

    request_opts =
      [
        # `:timeout` is documented as the REQUEST timeout, and `receive_timeout` alone is not
        # one. It is Finch's per-chunk timer: every chunk that arrives restarts it. A response
        # that trickles in, whether from a venue, a proxy or a degraded link, kept a facade
        # call running without limit. A test measured it: a 300 ms request fed one byte every
        # 100 ms was still running at 3 s (2026-09-27). `request_timeout` is Finch's
        # whole-response timer, and it defaults to `:infinity`. Finch documents it as
        # best-effort and HTTP/1-only, and every venue here is reached over HTTP/1.
        receive_timeout: timeout,
        request_timeout: timeout,
        connect_options: [timeout: timeout],
        # Retry is this module's job, not Req's — it needs the venue's `Retry-After`
        # and the rate-limit context, neither of which Req has.
        retry: false,
        redirect: false,
        # Streamed so the size is counted as bytes arrive and the transfer halts at the limit;
        # see `capped_into/1`. A transport that ignores `:into` is checked after the fact.
        into: capped_into(max_body_bytes)
      ] ++ transport_opts(opts)

    try do
      # `{result, status}`, not just `result`. The venue's HTTP status is known right here
      # and every error branch below destroys it — `{:error, "Server error (503): …"}` keeps
      # it only inside a message string. Recovering it by parsing that string back out would
      # be the string-matching this function's own 4xx comment objects to, one layer further
      # along. Carried out explicitly instead, so `:stop` reports a 503 as a 503 and a
      # connection refusal as `nil`: without that a dashboard cannot tell a venue that is
      # erroring from a venue that is unreachable, which are different outages needing
      # different responses.
      {result, status} =
        case Req.request(
               [
                 method: method,
                 url: url,
                 headers: headers,
                 body: body
               ] ++ request_opts
             )
             |> oversized(max_body_bytes) do
          {:too_large, status} ->
            {too_large(max_body_bytes, url, opts), status}

          {:ok, %Req.Response{status: status, headers: resp_headers, body: resp_body}} ->
            response = %{
              status: status,
              headers: resp_headers,
              body: resp_body
            }

            outcome =
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
                # `raw_status: true` hands the response back intact and lets the venue
                # decide. Opt-in rather than the default, because the string form is what
                # every existing caller matches on and changing it silently would turn
                # working refusal detection into a permanent error.
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

            {outcome, status}

          # No status at all — a connection refused, a DNS failure, a TLS handshake that
          # never completed. Reported as `nil` rather than `0` or `:unknown`, because a
          # request that never got a status must not put a value into a numeric series that
          # means "not a status at all".
          {:error, reason} ->
            {{:error, "Request failed: #{describe(reason)}"}, nil}
        end

      Telemetry.request_stop(start_time, metadata, telemetry_outcome(result, status))
      result

      # RESCUE: defensive boundary; Phase 2.5 audit — refine reason.
    rescue
      error ->
        # `:exception`, not a `:stop` carrying an error. The distinction is the point: an
        # error RESULT is the venue answering badly; an exception is this package failing to
        # ask. Folding them together makes a client-side bug indistinguishable from a venue
        # outage on every dashboard built from these events.
        #
        # `:stacktrace` and `:status` are part of the documented `:exception` metadata
        # (`Core.Telemetry`) and were never set: a handler matching `%{stacktrace: _}` never
        # fired, and one grouping by `:status` saw the key absent rather than `nil`.
        Telemetry.request_exception(start_time, metadata,
          kind: :error,
          reason: describe(error),
          stacktrace: scrub_stacktrace(__STACKTRACE__),
          status: nil,
          result: :exception
        )

        {:error, "Request exception: #{describe(error)}"}
    catch
      # **An exit is not a raise, and `rescue` does not see it.** A pool checkout that times
      # out, a transport process that is not running, or a linked process dying all leave the
      # transport with `exit/1`. It passed through here, skipped the `:exception` event and
      # exited the CALLING venue process, which this library does not supervise, in place of
      # the `{:error, _}` every other transport failure becomes. Reported with `kind: :exit`.
      :exit, reason ->
        Telemetry.request_exception(start_time, metadata,
          kind: :exit,
          reason: describe(reason),
          stacktrace: scrub_stacktrace(__STACKTRACE__),
          status: nil,
          result: :exception
        )

        {:error, "Request exception: #{describe(reason)}"}
    end
  end

  # **A stacktrace frame carries the ARGUMENTS of a call that failed to match.** A
  # `FunctionClauseError` inside the transport records `{module, function, args, location}`
  # for its top frame, and the args of a request call are the request: the headers, which
  # hold the `Authorization` value or the signature. `:stacktrace` is documented
  # `:exception` metadata and reaches every attached handler, log backend and exporter, so
  # each frame is reduced to the arity its args had. Nothing a handler groups by (module,
  # function, arity, file, line) is lost.
  defp scrub_stacktrace(stacktrace) do
    Enum.map(stacktrace, fn
      {module, function, args, location} when is_list(args) ->
        {module, function, length(args), location}

      frame ->
        frame
    end)
  end

  # Bounded text for a reason that reaches an error message and telemetry. Byte-identical to
  # `inspect/1` for anything inside the limits, so a message a caller matches is unchanged.
  defp describe(term),
    do: term |> redact_reason() |> inspect(limit: 50, printable_limit: @body_excerpt_bytes)

  # **An exception struct can carry the request it failed on, and `describe/1` prints it.**
  # Mint refuses a header it cannot send with `{:invalid_header_value, name, VALUE}`: the
  # value is the `Authorization` or signature header itself (a stray newline in a key read
  # from an env file is the ordinary way to get one), and it was interpolated into the error
  # tuple returned to the caller and into `[:dp_exchange, :request, :exception]` telemetry.
  # `{:invalid_request_target, TARGET}` carries the path and query. The `term`/`value` of a
  # `KeyError`, `MatchError` or `Protocol.UndefinedError` is whatever the failing code was
  # holding, and a plain-map credential is exactly that. The kind of failure and the header
  # NAME stay; the content goes.
  defp redact_reason(
         %{__struct__: Mint.HTTPError, reason: {:invalid_header_value, name, _value}} = e
       ),
       do: %{e | reason: {:invalid_header_value, name, "[redacted]"}}

  defp redact_reason(
         %{__struct__: Mint.HTTPError, reason: {:invalid_request_target, _target}} = e
       ),
       do: %{e | reason: {:invalid_request_target, "[redacted]"}}

  defp redact_reason(%{__struct__: _module} = exception) do
    Enum.reduce([:term, :value], exception, fn field, acc ->
      if Map.has_key?(acc, field), do: Map.put(acc, field, "[redacted]"), else: acc
    end)
  end

  defp redact_reason(other), do: other

  # Counts the body as it arrives and halts the transfer once it passes `limit`. The body is
  # kept as one binary appended to in place (the BEAM extends such a binary in amortised
  # constant time), so everything below the limit reaches Req's decode step exactly as the
  # buffered path delivered it. Past the limit the partial body is dropped, so the decode
  # step never runs over truncated JSON, and the response is marked for `make_http_request/5`.
  defp capped_into(limit) do
    fn {:data, data}, {request, response} ->
      if byte_size(response.body) + byte_size(data) > limit do
        marked = %{response | body: ""} |> Req.Response.put_private(@too_large_key, limit)
        {:halt, {request, marked}}
      else
        {:cont, {request, %{response | body: response.body <> data}}}
      end
    end
  end

  # `{:too_large, status}` when the body crossed the limit: marked by `capped_into/1` as it
  # streamed, or, from an adapter that ignores `:into`, found whole and over the limit after
  # the fact (by then the allocation has happened). Any other result passes through.
  defp oversized(
         {:ok, %Req.Response{status: status, private: %{@too_large_key => _limit}}},
         _max
       ),
       do: {:too_large, status}

  defp oversized({:ok, %Req.Response{status: status, body: body}}, max)
       when is_binary(body) and byte_size(body) > max,
       do: {:too_large, status}

  defp oversized(result, _max), do: result

  defp too_large(limit, url, opts) do
    provider = Config.opt(opts, :provider, "unknown")
    short_url = url |> Telemetry.endpoint() |> String.slice(0, 80)

    Logger.warning(
      "[HttpClient] response over #{limit} bytes refused provider=#{provider} #{short_url}"
    )

    {:error, {:response_too_large, limit}}
  end

  # `result` gives the coarse bucket a dashboard groups by; `status` is carried separately
  # because every error branch above has already turned it into prose. See the comment at
  # the `{result, status}` binding.
  defp telemetry_outcome({:ok, _response}, status), do: [status: status, result: :ok]

  defp telemetry_outcome({:error, :rate_limited, retry_after: seconds}, status),
    do: [status: status, result: :rate_limited, retry_after_ms: seconds * 1_000]

  defp telemetry_outcome({:error, {:response_too_large, limit}}, status),
    do: [status: status, result: :error, reason: :response_too_large, max_body_bytes: limit]

  defp telemetry_outcome({:error, _reason}, status), do: [status: status, result: :error]

  # The longest venue `Retry-After` honoured, in seconds — see `parse_retry_after_header/2`.
  @max_retry_after_s 600

  defp handle_rate_limit(response, method, url, opts) do
    # Parse rate limit headers to get more accurate retry timing
    retry_after =
      response.headers
      |> parse_retry_after_header(DateTime.utc_now())
      |> min(Config.opt(opts, :max_retry_after_s, @max_retry_after_s))

    provider = Config.opt(opts, :provider, "unknown")
    short_url = Telemetry.endpoint(url) |> String.slice(0, 80)

    # The VENUE said to wait — distinct from this package's own limiter saying so, which
    # `DefaultRateLimiter` reports separately. Both emit `[:dp_exchange, :rate_limit, :hit]`
    # on purpose: a consumer's first question is "am I being throttled", and answering it
    # from two different event names would mean every dashboard has to know both or be
    # quietly wrong. `:provider` tells them apart when the second question comes.
    #
    # Converted to milliseconds here. The venue's header is in seconds and the limiter
    # works in milliseconds; one unit across the family is the point of a shared spec, and
    # a panel summing a mixture of the two is wrong by a factor of a thousand without ever
    # looking wrong.
    Telemetry.rate_limit_hit(provider, retry_after * 1_000)

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
      :crypto.mac(:hmac, :sha256, credential!(credentials, :api_secret), message)
      |> Base.encode16(case: :lower)

    [
      {"CB-ACCESS-KEY", credential!(credentials, :api_key)},
      {"CB-ACCESS-SIGN", signature},
      {"CB-ACCESS-TIMESTAMP", timestamp}
    ]
  end

  defp build_basic_auth_headers(credentials) do
    key = credential!(credentials, :api_key)
    secret = credential!(credentials, :api_secret)
    [{"Authorization", "Basic #{Base.encode64("#{key}:#{secret}")}"}]
  end

  defp build_bearer_headers(credentials) do
    [{"Authorization", "Bearer #{credential!(credentials, :api_key)}"}]
  end

  # **A credential that is not a non-empty string is refused, never interpolated.** `"#{nil}"`
  # is `""`, so `:bearer` with a `nil` `api_key` (an unset config value, which is the usual
  # way to get one) built `Authorization: Bearer ` and `:basic` built `Basic Og==`, and the
  # request went out looking authenticated and failed at the venue as a 401 that reads as a
  # rejected key. Nothing named the credential that was never there. The message names the
  # field and never the value.
  defp credential!(credentials, field) do
    case Map.get(credentials, field) do
      value when is_binary(value) and value != "" ->
        value

      _absent ->
        raise ArgumentError,
              "credentials #{inspect(field)} is missing, nil or empty — refusing to build " <>
                "an authentication header from nothing"
    end
  end

  # Rate limiting helper functions

  @spec check_rate_limits(keyword()) ::
          :ok
          | {:error, :rate_limit_timeout | :rate_limiter_unavailable}
          | {:error, :rate_limited, retry_after: integer()}
  defp check_rate_limits(opts) do
    keys = rate_limit_keys(opts)

    with :ok <- precheck(keys, opts), do: reserve_all(keys, opts)
  end

  # **With two buckets, a refusal on the second used to spend the first.** The provider
  # bucket was reserved, then the endpoint bucket refused, and the provider's token was gone
  # for a request never sent — the partial-failure leak `DefaultRateLimiter`'s own moduledoc
  # rules out for one bucket. On the non-blocking path every bucket is asked first with
  # `check/3`, which reserves nothing, and nothing is reserved unless all have room. Two
  # callers can still race between the check and the reservation; that narrows to the one
  # case the atomic reservation exists for, not every endpoint refusal.
  #
  # **The blocking path has the same leak, and is asked the same way.** Interleaving: (1)
  # `acquire/3` on the provider bucket reserves and sleeps its wait in this process; (2)
  # `acquire/3` on the endpoint bucket then answers `:rate_limit_timeout`; (3) no request is
  # sent, and the provider's token, already committed and waited for, is spent. It was skipped
  # here as "blocking waits, so nothing is refused", which is true of the wait and not of the
  # `:timeout` that bounds it. Each bucket is now asked first with `check/3`, which reserves
  # nothing, and a wait beyond the timeout is refused before ANY bucket is reserved. The
  # waits can still differ by the time the first sleep takes; that narrows the window, as
  # for the non-blocking path, it does not close it.
  defp precheck([_first, _second | _rest] = keys, opts) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      answer = limiter().check(key, weight(opts), limiter_opts(opts))

      case precheck_verdict(answer, blocking?(opts), Config.opt(opts, :timeout, 30_000)) do
        :ok -> {:cont, :ok}
        refused -> {:halt, refused}
      end
    end)
  end

  defp precheck(_one_or_none, _opts), do: :ok

  # Blocking: a wait within the timeout is what blocking is for. A wait beyond it, or any
  # timeout that is not an integer (left for `acquire/3` to refuse by name), is judged there.
  defp precheck_verdict({:rate_limited, wait_ms}, true, timeout)
       when is_integer(timeout) and wait_ms > timeout,
       do: {:error, :rate_limit_timeout}

  defp precheck_verdict({:rate_limited, _wait_ms}, true, _timeout), do: :ok
  defp precheck_verdict(answer, _blocking, _timeout), do: normalise_check(answer)

  defp reserve_all(keys, opts) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case check_rate_limit(key, opts) do
        :ok -> {:cont, :ok}
        refused -> {:halt, refused}
      end
    end)
  end

  # **Both paths reserve, atomically, before the request is sent.** The non-blocking path used
  # to `check/3` (which reserves nothing), send, then `record/3`. Concurrent callers all
  # passed the check before any of them recorded, so N tasks spent N tokens from a bucket
  # with room for one. Measured 2026-10-03 on `dp_exchange_webull`: a consumer fetching bars
  # in parallel per symbol sent two requests 250 ms apart through a 1/s bucket with a burst of
  # 1, and drew a 429. An `acquire/3` with a zero timeout reserves only when there is room
  # now, and commits nothing otherwise. `check/3` is consulted only after a refusal, to say
  # how long to wait.
  defp check_rate_limit(key, opts) do
    if blocking?(opts) do
      key |> limiter().acquire(weight(opts), limiter_opts(opts)) |> normalise_acquire()
    else
      case limiter().acquire(key, weight(opts), Keyword.put(limiter_opts(opts), :timeout, 0)) do
        :ok -> :ok
        {:error, :rate_limit_timeout} -> key |> how_long(opts) |> normalise_check()
        {:error, _reason} -> {:error, :rate_limiter_unavailable}
      end
    end
  end

  # A refusal whose wait has already elapsed by the time it is asked still refuses: the
  # reservation was not made, and a second attempt here would be a retry the caller did not
  # ask for. One second is the smallest wait `Retry-After` can state.
  defp how_long(key, opts) do
    case limiter().check(key, weight(opts), limiter_opts(opts)) do
      :ok -> {:rate_limited, 1_000}
      answer -> answer
    end
  end

  defp blocking?(opts), do: Config.opt(opts, :rate_limit_blocking, false)

  # **The buckets one request must clear.** The provider's, always. With
  # `rate_limit_per_endpoint: true`, also one for this endpoint alone, keyed
  # `"<provider> <path>"`.
  #
  # Some venues state a limit per endpoint and a wider one across all of them.
  # `dp_exchange_webull`'s endpoint pages say "1 request per second per App Key" and "Market
  # Data Global Limit: 600 requests per minute". One shared bucket cannot express both. At
  # 60/60s with a burst of 60, it let a backfill send a minute's budget to one endpoint in
  # an instant, and the venue answered 429 to every request past the first in that second
  # (measured in a consumer's log, 2026-10-02: 45 `retry_after=5s` on crypto bars).
  # `:path` is the URL's path, filled in by `attempt/7` unless the caller set its own.
  defp rate_limit_keys(opts) do
    case Keyword.get(opts, :provider) do
      nil ->
        []

      provider ->
        if Config.opt(opts, :rate_limit_per_endpoint, false) and Keyword.has_key?(opts, :path),
          do: [provider, "#{provider} #{Keyword.fetch!(opts, :path)}"],
          else: [provider]
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

  # **A venue's `Retry-After` holds the bucket, not only the request that drew it.** The 429
  # says the venue will refuse this bucket for that long. Honouring it for one request let
  # every other caller keep sending into the penalty: on 2026-10-03, after one 429 with
  # `retry_after=5s`, `dp_exchange_webull` sent at its bucket's own 1/s and drew 26 more in
  # 31s. The most specific bucket is held, the endpoint's when there is one, because that is
  # the limit the venue enforced. Optional on the limiter (`c:RateLimitBehaviour.penalize/3`).
  defp hold_for_retry_after(opts, seconds) when is_integer(seconds) and seconds > 0 do
    with [_first | _rest] = keys <- rate_limit_keys(opts),
         limiter = limiter(),
         true <- function_exported?(limiter, :penalize, 3) do
      limiter.penalize(List.last(keys), seconds * 1_000, limiter_opts(opts))
    end

    :ok
  end

  defp hold_for_retry_after(_opts, _seconds), do: :ok

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

  # **Both forms RFC 9110 allows, and a ceiling.** `Retry-After` is delay-seconds OR an
  # HTTP-date. Only the integer was read, so a venue saying "until 12:01:00 GMT" got the
  # five-second fallback and was re-hit inside its own penalty. And nothing bounded the
  # integer: `Retry-After: 86400`, or a malformed huge value, held the bucket through
  # `penalize/3` for a day. Clamped to `:max_retry_after_s` (600 s by default,
  # chosen, not measured) by the caller above; past it, the next 429 says wait again.
  defp parse_retry_after_header(headers, now) do
    normalised = normalise_headers(headers)

    case fetch_integer(normalised, "retry-after") do
      {:ok, seconds} when seconds >= 0 -> seconds
      # The venue said it is limiting us but not for how long. Five seconds is a
      # deliberate floor rather than a measurement, and retrying immediately — which
      # is what a 0 default would mean — is how a 429 becomes a 429 storm.
      #
      # A negative value is the same case. It is not a wait, and it used to pass straight
      # through: the caller was told to "retry after -30s", and `[:dp_exchange, :rate_limit,
      # :hit]` carried a negative `retry_after_ms` that a panel summing waits would subtract.
      {:ok, _negative} -> 5
      :error -> normalised |> Map.get("retry-after") |> http_date_delay(now)
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # IMF-fixdate, `Sun, 06 Nov 1994 08:49:37 GMT`, the form RFC 9110 requires senders to use.
  # A date already past is no wait at all, which is still not zero: one second, the
  # smallest wait the integer form can state. Anything unreadable is the five-second floor.
  defp http_date_delay(value, now) when is_binary(value) do
    with [_weekday, day, month, year, time, "GMT"] <- String.split(value, " ", trim: true),
         month_number when is_integer(month_number) <-
           Enum.find_index(@months, &(&1 == month)),
         {:ok, at, 0} <-
           DateTime.from_iso8601("#{year}-#{pad(month_number + 1)}-#{pad(day)}T#{time}Z") do
      max(DateTime.diff(at, now, :second), 1)
    else
      _unreadable -> 5
    end
  end

  defp http_date_delay(_absent, _now), do: 5

  # Takes the month number or the day as the date text spells it: a venue that writes
  # `Sun, 6 Nov 1994` (no leading zero, which RFC 9110 forbids and many servers emit anyway)
  # would otherwise fail ISO 8601 parsing and get the five-second floor.
  defp pad(number) when is_integer(number),
    do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  defp pad(text) when is_binary(text), do: String.pad_leading(text, 2, "0")

  # Normalises the two header shapes this pipeline sees. `Req` returns
  # `%{"name" => ["value"]}`; a list of `{name, value}` pairs is the other convention,
  # and a caller passing one should not silently get `nil` for every lookup.
  #
  # This is not hypothetical tidiness: with only the pair form handled, every
  # `Retry-After` a venue sent was invisible, so a 429 always used the fallback.
  defp normalise_headers(headers) when is_map(headers) or is_list(headers) do
    Map.new(headers, fn {key, value} -> {header_name(key), first_value(value)} end)
  end

  # An atom key (`:"retry-after"`) is a header name like any other; `String.downcase/1` on it
  # raised, and from `parse_rate_limit_headers/1` that is on every response.
  defp header_name(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp header_name(key), do: String.downcase(key)

  defp first_value([value | _rest]), do: value
  defp first_value(value), do: value

  # Wrap an error with exchange context when provider is specified in opts.
  # Returns `{:error, {:exchange_error, provider, reason}}` for provider-aware
  # callers, or plain `{:error, reason}` when no provider context exists.
  # 4xx HTTP errors are client mistakes (bad symbol, unauthorized, etc.) — permanent, don't retry
  #
  # A PREFIX match on the message this module itself builds, not `String.contains?/2`: a 5xx
  # whose quoted body contained "Client error (4" was read as permanent and never retried.
  # A 3xx (`redirect: false`) is permanent too: the same request gets the same redirect.
  # Any reason that is not one of these strings, including a non-binary one, is retryable
  # as before, rather than a `FunctionClauseError` in the caller.
  defp client_error?("Client error (4" <> _rest), do: true
  defp client_error?("Unexpected status (3" <> _rest), do: true
  # The same response is the same size on the next attempt, and retrying would repeat a
  # transfer that was just cut off.
  defp client_error?({:response_too_large, _limit}), do: true
  defp client_error?(_retryable), do: false

  defp wrap_exchange_error(opts, reason) do
    case Keyword.get(opts, :provider) do
      nil -> {:error, reason}
      provider -> {:error, {:exchange_error, provider, reason}}
    end
  end

  # Format response body for error messages (handles both strings and maps).
  #
  # **Capped.** The whole body used to go into the message, and from there into a warning on
  # every retry and into whatever the caller logs. A venue's 5xx is often a proxy's HTML
  # error page, and nothing bounds its size: a 1 MB page retried three times wrote megabytes
  # of log for one failed call, and the same bytes sat in every caller's error tuple. Nothing
  # in the family reads the body back out of this message — venues match the status in its
  # prefix, and a venue that needs the body passes `raw_status: true` and gets it whole.
  # The cut is marked with the full size, so a truncated message never reads as complete.
  defp format_body(body) when is_binary(body) and byte_size(body) > @body_excerpt_bytes,
    do: excerpt(body) <> "… (#{byte_size(body)} bytes)"

  defp format_body(body) when is_binary(body), do: body

  defp format_body(body),
    do: inspect(body, limit: 50, printable_limit: @body_excerpt_bytes)

  # A byte prefix, trimmed back to a whole UTF-8 character so the message stays valid text.
  # Bounded at three trims: a UTF-8 character is at most four bytes, so a prefix still
  # invalid after that was never UTF-8 and is returned as cut.
  defp excerpt(body), do: trim_to_valid(binary_part(body, 0, @body_excerpt_bytes), 3)

  defp trim_to_valid(prefix, trims_left) do
    if String.valid?(prefix) or trims_left == 0,
      do: prefix,
      else: trim_to_valid(binary_part(prefix, 0, byte_size(prefix) - 1), trims_left - 1)
  end
end
