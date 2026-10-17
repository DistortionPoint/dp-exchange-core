defmodule DpExchange.Core.Options do
  @moduledoc """
  Refuses a facade option the call does not read.

  A misspelled `limt:` or `sinse:` that is silently ignored returns a plausible answer to a
  different question than the caller asked: the "nearby substitute where there should be an
  error" this family exists to avoid. Every facade function that takes a keyword `opts` calls
  `check/2` at the boundary, before anything is sent and before an internal key (`:limiter`
  and the like) is added, so a stray key is a caller error.

  ## Where it sits in the check order

  Positional arguments first (subscriber, symbols, symbol, range), then the options, then
  credentials. An option error is decided before anything is sent, so it is a plain
  `{:error, _}`, never `:order_unconfirmed`. A function that answers
  `Venue.not_supported()` keeps doing so whatever the options: the endpoint's absence is the
  more useful answer.

  ## What is allowed

  A function's allowed list is `transport_options/0` plus the keys it reads itself. The
  transport keys are shared because every venue forwards them to `Core.HttpClient` or reads
  them as test seams; the venue names the rest. A nil-valued key is still a key: a forwarded
  `limt: nil` is refused too, because a caller who typed the key meant something by it.

  ## What it answers

    * `:ok`
    * `{:error, {:unknown_option, key}}` - the first key (in the caller's order) not allowed
    * `{:error, {:invalid_options, opts}}` - `opts` is not a keyword list
  """

  # The keys every facade call may carry. Taken from what the five venue facades forward to
  # `Core.HttpClient` (`Keyword.take` lists in each `request_opts/1`) plus the credentials and
  # environment seams, and from `Core.HttpClient`'s own option docs. Venue-specific meaning
  # (limit, since, depth, category, ...) is deliberately not here.
  @transport_options [
    # The credential map or struct the call is made as.
    :credentials,
    # Which of a venue's environments (sandbox, production) to talk to.
    :environment,
    # Overrides the venue's base URL; a test seam and a proxy hook.
    :base_url,
    # Test seams handed to `Req`: an in-process plug, an adapter function, or a full
    # `:req_adapter` (see `Core.HttpClient`).
    :plug,
    :adapter,
    :req_adapter,
    # The rate limiter (name or module) the call is metered in.
    :limiter,
    # Wait for the limiter instead of failing when the bucket is empty.
    :rate_limit_blocking,
    # Tokens this request costs.
    :weight,
    # Whole-request timeout in milliseconds, or `:infinity`.
    :timeout,
    # Attempts in all, and the base delay between them.
    :retry_attempts,
    :retry_delay,
    # Ceiling in seconds on a venue's `Retry-After` that is honoured.
    :max_retry_after_s,
    # The most of a response body that is received.
    :max_body_bytes,
    # Whether the request is logged.
    :log_requests
  ]

  @doc """
  The option keys every facade call may carry, whatever the venue.

  Credentials, the environment and base URL, the `Req` test seams (`:plug`, `:adapter`,
  `:req_adapter`), and the limiter, timeout and retry knobs `Core.HttpClient` reads. A venue
  checks `opts` against `transport_options() ++ its_own_keys`.
  """
  @spec transport_options() :: [atom()]
  def transport_options, do: @transport_options

  @doc """
  Checks `opts` against the keys `allowed`.

  Answers `:ok`, `{:error, {:unknown_option, key}}` for the first key not in `allowed` (a
  key holding `nil` counts), or `{:error, {:invalid_options, opts}}` when `opts` is not a
  keyword list.

  ## Examples

      iex> DpExchange.Core.Options.check([limit: 5], [:limit])
      :ok

      iex> DpExchange.Core.Options.check([limt: 5], [:limit])
      {:error, {:unknown_option, :limt}}

      iex> DpExchange.Core.Options.check([limt: nil], [:limit])
      {:error, {:unknown_option, :limt}}

      iex> DpExchange.Core.Options.check(%{limit: 5}, [:limit])
      {:error, {:invalid_options, %{limit: 5}}}
  """
  @spec check(term(), [atom()]) ::
          :ok | {:error, {:unknown_option, atom()} | {:invalid_options, term()}}
  def check(opts, allowed) when is_list(allowed) do
    if Keyword.keyword?(opts) do
      case Enum.find(opts, fn {key, _value} -> key not in allowed end) do
        nil -> :ok
        {key, _value} -> {:error, {:unknown_option, key}}
      end
    else
      {:error, {:invalid_options, opts}}
    end
  end
end
