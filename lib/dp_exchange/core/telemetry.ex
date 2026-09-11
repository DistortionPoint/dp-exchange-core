defmodule DpExchange.Core.Telemetry do
  @moduledoc """
  Standardised `:telemetry` event names, emitted through the functions below. A consumer
  attaches to these names without coupling to any particular venue's implementation —
  which is what makes one metrics dashboard work across the whole family.

  Telemetry is the **metrics** channel: high-frequency, individually unimportant,
  aggregate-only, and lossy by nature. A condition a consumer must act on is not a
  metric and does not belong here.

  ## Why the category is `:link` and not `:ws`

  These events were named `[:dp_exchange, :ws, …]`. That names a **transport**, and
  under the facade contract no venue's transport is a consumer's concern — a venue
  streaming over MQTT or long-polling has no "ws" to report, so it would either emit a
  lie or emit nothing and look permanently disconnected.

  The category is the venue **link**: the fact that there is a live route to the venue,
  and whether it is up. What carries that route is package-internal.

  ## These names were documented for a long time before anything emitted them

  This module said, in its first line, that these are the events "every venue package
  emits". None of them did. There was not one `:telemetry.execute/3` call anywhere in the
  family — not in Core, not in any of the five venues — for the whole time this spec
  existed.

  That is the worst shape a missing feature can take, and worse than an error would have
  been. `:telemetry.attach/4` against a name nobody emits **succeeds**. So a consumer wired
  a dashboard to `[:dp_exchange, :request, :stop]`, got no error, and saw an empty panel —
  which reads as *a venue with no traffic*, not as *a spec nothing implements*. The failure
  mode is a metric that stays plausible while only its meaning is wrong, which is the defect
  this family names most often, sitting in the observability layer where it is least likely
  to be questioned.

  It was found the same way and in the same week as the identical hole in
  `Core.Venue.subscribe/2`'s back-pressure paragraph — by reading the contract and grepping
  for anything that honoured it. Two for two on the things Core declared and nobody built,
  which is the real lesson: **a guarantee written in a doc and nowhere else is not a
  guarantee, it is a plan.**

  ## Emitting through this module, not through `:telemetry.execute/3` directly

  The functions below exist so no venue has to name an event itself. Five packages writing
  `[:dp_exchange, :link, :up]` by hand is five chances to write `:link_up`, and the drift a
  shared contract exists to prevent would be invisible: the wrong name emits successfully
  and simply never reaches the handler. It also keeps `:telemetry` a dependency of Core
  alone — a venue calling `:telemetry.execute/3` directly would be using a transitive
  dependency it never declared.

  ## Emitting is safe for the caller

  `:telemetry.execute/3` runs every attached handler **synchronously, in the calling
  process**. A consumer's handler that raises would otherwise be a consumer's bug taking
  down a venue's request path. `:telemetry` itself guards this — since 1.0 it wraps each
  handler invocation and detaches one that raises, rather than propagating — so these calls
  cannot be the reason a market-data call fails. That property is load-bearing and is why
  they are not additionally wrapped here: a `try` around a call that already cannot raise
  would only hide a real fault in this module.

  ## Event names

  All names are nested lists under `[:dp_exchange, <category>, <event>]`.

  ### Request lifecycle

  - `[:dp_exchange, :request, :start]` — about to fire an outbound
    request. Measurements: `%{system_time: integer}`. Metadata:
    `%{provider:, endpoint:, method:}`.
  - `[:dp_exchange, :request, :stop]` — request returned (either
    success or error). Measurements: `%{duration: integer (native)}`.
    Metadata: `%{provider:, endpoint:, method:, status:, result:}`.
  - `[:dp_exchange, :request, :exception]` — request raised an
    exception. Measurements: `%{duration: integer}`. Metadata: same
    as `:stop` plus `%{kind:, reason:, stacktrace:}`.

  ### Rate limiting

  - `[:dp_exchange, :rate_limit, :hit]` — caller was rate-limited.
    Measurements: `%{count: 1}`. Metadata: `%{provider:, retry_after_ms:}`.
  - `[:dp_exchange, :rate_limit, :acquire]` — caller acquired tokens.
    Measurements: `%{tokens: pos_integer, wait_ms: non_neg_integer}`.
    Metadata: `%{provider:, weight:}`.

  ### Link lifecycle

  - `[:dp_exchange, :link, :up]` — a live route to the venue was established.
    Metadata: `%{provider:}`.
  - `[:dp_exchange, :link, :down]` — the route was lost.
    Metadata: `%{provider:, reason:}`.
  - `[:dp_exchange, :link, :event]` — a payload arrived over the route.
    Measurements: `%{bytes: integer}`. Metadata: `%{provider:, type:}`.
  - `[:dp_exchange, :link, :reconnect_attempt]` — re-establishing after a drop.
    Metadata: `%{provider:, attempt: integer, delay_ms: integer}`.

  No `endpoint` metadata: a URL is transport, and a venue with no URL to report would
  have to invent one.
  """

  @doc "All telemetry event prefixes this module documents."
  @spec event_prefixes() :: [[atom()]]
  def event_prefixes do
    [
      [:dp_exchange, :request, :start],
      [:dp_exchange, :request, :stop],
      [:dp_exchange, :request, :exception],
      [:dp_exchange, :rate_limit, :hit],
      [:dp_exchange, :rate_limit, :acquire],
      [:dp_exchange, :link, :up],
      [:dp_exchange, :link, :down],
      [:dp_exchange, :link, :event],
      [:dp_exchange, :link, :reconnect_attempt]
    ]
  end

  @typedoc "Metadata every request event carries: which venue, which endpoint, which verb."
  @type request_metadata :: %{
          required(:provider) => atom() | String.t(),
          required(:endpoint) => String.t(),
          required(:method) => atom() | String.t(),
          optional(atom()) => term()
        }

  @doc """
  Emits `[:dp_exchange, :request, :start]` and returns the monotonic instant to pass to
  `request_stop/3` or `request_exception/3`.

  Two clocks on purpose, and it is not redundancy. The measurement is
  `System.system_time/0`, because a consumer correlating a request against a venue's own
  logs needs a wall-clock instant that means the same thing on both sides. The returned
  value is `System.monotonic_time/0`, because the *duration* computed from it must not be
  a function of whether NTP stepped the clock mid-request — the same distinction
  `dp_exchange_webull`'s rejected-symbol TTL had to be corrected for, and the same one
  `:telemetry.span/3` makes.
  """
  @spec request_start(request_metadata()) :: integer()
  def request_start(metadata) do
    :telemetry.execute(
      [:dp_exchange, :request, :start],
      %{system_time: System.system_time()},
      metadata
    )

    System.monotonic_time()
  end

  @doc """
  Emits `[:dp_exchange, :request, :stop]` — for **any** outcome, success or error.

  Recording only successes is the same mistake this family already made in its rate-limit
  accounting, where a bucket that counted only 2xx under-reported real usage as "83/240"
  against 395 calls actually sent. A latency panel built on successes alone shows a venue
  getting faster exactly as it starts failing, because the slow calls are the ones dropping
  out of the sample.
  """
  @spec request_stop(integer(), request_metadata(), keyword()) :: :ok
  def request_stop(start_time, metadata, extra \\ []) do
    :telemetry.execute(
      [:dp_exchange, :request, :stop],
      %{duration: System.monotonic_time() - start_time},
      Enum.into(extra, metadata)
    )
  end

  @doc """
  Emits `[:dp_exchange, :request, :exception]` — a request that raised rather than
  returning.

  Distinct from a `:stop` carrying an error result, and the distinction is the point: an
  error result is the venue answering badly, an exception is this package failing to ask.
  Folding them together makes a client-side bug indistinguishable from a venue outage on
  every dashboard built from these events.
  """
  @spec request_exception(integer(), request_metadata(), keyword()) :: :ok
  def request_exception(start_time, metadata, extra \\ []) do
    :telemetry.execute(
      [:dp_exchange, :request, :exception],
      %{duration: System.monotonic_time() - start_time},
      Enum.into(extra, metadata)
    )
  end

  @doc """
  Emits `[:dp_exchange, :rate_limit, :hit]` — the caller was told to wait.

  `retry_after_ms` is what the limiter (or the venue's own `Retry-After`) said, in
  milliseconds. Always milliseconds here even where a venue's header is in seconds: one
  unit across the family is the whole reason these names are standardised, and a panel
  summing a mixture of the two is wrong by a factor of a thousand without looking wrong.
  """
  @spec rate_limit_hit(atom() | String.t(), non_neg_integer()) :: :ok
  def rate_limit_hit(provider, retry_after_ms) do
    :telemetry.execute(
      [:dp_exchange, :rate_limit, :hit],
      %{count: 1},
      %{provider: provider, retry_after_ms: retry_after_ms}
    )
  end

  @doc """
  Emits `[:dp_exchange, :rate_limit, :acquire]` — the caller got its tokens.

  `wait_ms` of zero is the normal, healthy case and is still emitted. A panel that only
  sees the waits cannot tell a limiter that is never binding from one that is not running
  at all, and `Core.HttpClient` fails closed when no limiter is reachable — so "no acquire
  events" is a condition worth being able to see.
  """
  @spec rate_limit_acquire(atom() | String.t(), pos_integer(), non_neg_integer()) :: :ok
  def rate_limit_acquire(provider, weight, wait_ms) do
    :telemetry.execute(
      [:dp_exchange, :rate_limit, :acquire],
      %{tokens: weight, wait_ms: wait_ms},
      %{provider: provider, weight: weight}
    )
  end

  @doc """
  Emits `[:dp_exchange, :link, :up]` — a live route to the venue was established.

  "Route", not "socket": what carries it is package-internal, and a venue that polls has a
  link too. See "Why the category is `:link` and not `:ws`" above.
  """
  @spec link_up(atom()) :: :ok
  def link_up(provider),
    do: :telemetry.execute([:dp_exchange, :link, :up], %{count: 1}, %{provider: provider})

  @doc """
  Emits `[:dp_exchange, :link, :down]` — the route was lost.

  `reason` is already-inspected text, never a raw term: telemetry metadata is read by
  aggregators that group by value, and a raw reason carrying a pid or a socket ref makes
  every occurrence a distinct series. It is also the shape `Core.Notice`'s own
  `details.reason` uses, so the two channels agree about one event.
  """
  @spec link_down(atom(), String.t()) :: :ok
  def link_down(provider, reason) when is_binary(reason) do
    :telemetry.execute(
      [:dp_exchange, :link, :down],
      %{count: 1},
      %{provider: provider, reason: reason}
    )
  end

  @doc """
  Emits `[:dp_exchange, :link, :event]` — a payload arrived over the route.

  The high-frequency one: once per frame, so it is on the hot path of every streaming
  venue and deliberately does nothing but execute. `type` names the kind of payload in the
  venue's own terms; `bytes` is the size on the wire, which is what makes this usable as a
  throughput signal rather than only a count.
  """
  @spec link_event(atom(), atom() | String.t(), non_neg_integer()) :: :ok
  def link_event(provider, type, bytes) do
    :telemetry.execute(
      [:dp_exchange, :link, :event],
      %{count: 1, bytes: bytes},
      %{provider: provider, type: type}
    )
  end

  @doc """
  Emits `[:dp_exchange, :link, :reconnect_attempt]` — re-establishing after a drop.

  Emitted per attempt, with the attempt number and the delay about to be waited, so a
  consumer can see a backoff working rather than only that reconnects are happening. A
  venue that reconnects immediately reports `delay_ms: 0` rather than omitting the field —
  absent and zero mean different things, and only one of them is true here.
  """
  @spec link_reconnect_attempt(atom(), pos_integer(), non_neg_integer()) :: :ok
  def link_reconnect_attempt(provider, attempt, delay_ms) do
    :telemetry.execute(
      [:dp_exchange, :link, :reconnect_attempt],
      %{count: 1},
      %{provider: provider, attempt: attempt, delay_ms: delay_ms}
    )
  end

  @doc """
  Strips a URL down to what is safe and useful as `:endpoint` metadata.

  Query string removed, and that is a security decision rather than tidiness: telemetry
  metadata reaches logs, aggregators and third-party exporters, and a query string is the
  one part of a URL that can carry a token. No venue in this family signs in the query
  today — every one uses headers — but `endpoint` is emitted on every request from every
  venue present and future, and "none of them do that yet" is not a property a consumer's
  log retention should depend on. Truncated at 200 characters so an unusually long path
  cannot turn a metrics label into a memory problem.
  """
  @spec endpoint(String.t()) :: String.t()
  def endpoint(url) when is_binary(url) do
    url |> String.split("?") |> List.first() |> String.slice(0, 200)
  end
end
