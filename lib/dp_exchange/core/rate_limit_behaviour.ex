defmodule DpExchange.Core.RateLimitBehaviour do
  @moduledoc """
  Behaviour for the rate-limit token-bucket implementation that every
  exchange adapter calls before making an API request.

  Part of the future `dp_exchange_core` Hex package. A default in-process
  bucket implementation ships in `Core.DefaultRateLimiter`; the host
  application overrides via config (`:rate_limit_module`) to plug in its
  own distributed limiter, queueing, telemetry, etc.

  Implementations must be safe to call from any process at any frequency.

  ## A pure contract, depending on nothing

  No aliases, no calls, only `@callback`s. In the host application that property had
  to be asserted with a `use Boundary, deps: []` declaration, because a contract
  living on the far side of a dependency arrow created a cycle: the implementer had
  to reference this module for the compile-time check, while this module's namespace
  said it belonged to the other side.

  Here the property is structural rather than declared. The contract ships in its own
  package and the implementer depends on that package, so there is no cycle to break
  and no boundary tool to convince — which is the shape the host was working around.
  """

  @type provider :: atom() | String.t()
  @type weight :: pos_integer()
  @type opts :: keyword()

  @doc """
  Acquire `weight` tokens for `provider`. Blocks (or returns
  `:rate_limited`) until tokens are available.

  Returns `:ok` once tokens granted, `{:error, :rate_limit_timeout}` if
  the configured `:timeout` elapses first, or `{:error, reason}` on any
  other failure.
  """
  @callback acquire(provider(), weight(), opts()) ::
              :ok | {:error, :rate_limit_timeout} | {:error, term()}

  @doc """
  Non-blocking check for `weight` tokens.

  Returns `:ok` if `weight` tokens are available right now,
  `{:rate_limited, retry_after_ms :: non_neg_integer()}` if they are not, or
  `{:error, reason}` if the implementation **could not tell**.

  ## `weight` is not decoration

  `check(provider, 10, opts)` asks whether there is room for ten. An implementation
  that answers for one and ignores the argument reports `:ok` with room for a single
  request, and the caller then sends ten. That is a real defect in the implementation
  this contract was derived from, and it was possible only because the ceiling it
  delegated to hardcoded a cost of 1.

  ## Why `{:error, reason}` exists

  Earlier this callback could return only `:ok` or `{:rate_limited, ms}`, which gives
  an implementation **no way to say it does not know** — so an implementation whose
  backing store was unreachable had to choose between inventing `:ok` (fail open, send
  the request, get throttled by the venue) and inventing a rate-limit that is not
  happening. The one it chose was `:ok`, silently, while `acquire/3` beside it failed
  closed on the same condition.

  A caller **must treat `{:error, _}` as "do not proceed"**. Not knowing whether there
  is capacity is not the same as having it.
  """
  @callback check(provider(), weight(), opts()) ::
              :ok | {:rate_limited, non_neg_integer()} | {:error, term()}

  @doc """
  Record that `weight` requests were actually SENT for `provider`.

  Neither `acquire/3` nor `check/3` fills the bucket they are measured against —
  they answer "is there capacity" and, for acquire, wait until there is. Something
  has to report what left, or the bucket stays empty and every check passes.

  For adapters that go through `Core.HttpClient` the host records on their behalf.
  An adapter issuing its own HTTP calls has to call this itself, and Webull did
  not: it acquired before every request and recorded none, so its ceiling bound
  nothing and the venue answered with HTTP 429. Measured at the point calls leave:
  395 per 60s against a documented 300, while the budget panel read 83/240.

  Deliberately cannot fail. Metering must never be the reason a market-data call
  does not happen; a missed record costs accuracy in the ceiling, not the request.
  """
  @callback record(provider(), weight(), opts()) :: :ok
end
