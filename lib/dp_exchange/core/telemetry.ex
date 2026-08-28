defmodule DpExchange.Core.Telemetry do
  @moduledoc """
  Standardised `:telemetry` event names that every venue package emits. A consumer
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
end
