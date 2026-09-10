defmodule DpExchange.Core.Fanout do
  @moduledoc """
  Pushes a venue's events to its subscribers, and refuses to grow their mailboxes without
  a bound.

  ## Why this module exists

  `DpExchange.Core.Venue`'s `c:DpExchange.Core.Venue.subscribe/2` doc has said this since
  the contract was written:

  > A venue pushing faster than its subscriber consumes drops beyond a stated bound and
  > emits a `:degraded` notice saying so. Growing a mailbox silently until the node dies is
  > the failure this avoids; dropping silently is the failure the notice avoids.

  It was a guarantee no package provided. All five venues fanned out with a bare `send/2`
  in five identical private `fan_out/2` functions, none of which had ever looked at a
  subscriber's mailbox. A consumer reading the contract was told back-pressure was handled
  and declared; neither half was true. That is the failure this family names most often —
  a statement that stays entirely plausible while only its meaning is wrong — sitting in
  the contract itself rather than in a venue.

  The exposure is not theoretical. `dp_exchange_coinbase`'s `level2` channel measured 4258
  delta frames in the window that produced this family's coverage incident. A subscriber
  that stalls for thirty seconds against a stream like that accumulates a mailbox in the
  hundred-thousands, and the node dies with no notice, no log line and nothing in
  `coverage/1` to suggest anything was wrong: the feed was delivering perfectly the whole
  time.

  ## Newest is dropped, not oldest — and the contract used to say otherwise

  The wording above used to read *"drops oldest beyond a stated bound"*. **A sender cannot
  drop the oldest message in another process's mailbox.** Nothing in the BEAM lets one
  process remove a message another process has already been sent; the receiver owns its
  own queue. Written that way, the sentence described something no implementation could
  ever have honoured, which is part of why nothing implemented it.

  What a sender *can* do is decline to add to a queue that is already past its bound, which
  is what this module does. So the contract now states the achievable guarantee. Dropping
  the newest is also the better trade for this data: a quote or a book delta that arrives
  while a consumer is thirty thousand messages behind is worthless by the time it would be
  read, and the frames it would push out are no fresher.

  ## Checking is cheaper than the send it guards

  Measured before it was written, on the machine this family develops on:

      Process.info/2 : 0.029 us/call (empty mailbox)
      Process.info/2 : 0.028 us/call (100k backlog)
      send/2         : 0.097 us/call

  `:message_queue_len` is a counter the process already maintains, so reading it is O(1)
  and does not walk the queue — the 100k-backlog figure is the one that proves it. At 0.3x
  the cost of the `send/2` it replaces or permits, there is no case for sampling the check,
  latching it for N messages, or any of the other complications that would have been
  reasonable if it had turned out to cost more than the send. It runs on every message to
  every subscriber.

  ## One notice per transition, never one per dropped message

  A stalled subscriber that produced a notice per dropped message would emit them at the
  rate of the stream it cannot keep up with — into the same fan-out that is already
  overloaded, and to a notice subscriber that may be the very process that is behind. The
  cure would be worse than the disease.

  So the caller carries the set of subscribers currently being dropped, and `deliver/4`
  returns it back along with only the *transitions*: `:dropping` the first time a
  subscriber is found over its bound, `:resumed` the first time it is found back under.
  Both are worth a notice — a consumer needs to know when data loss started, and it needs
  to know when it stopped, because those two instants bracket exactly what it has to
  reconcile from a pull endpoint.

  The set is rebuilt from what was observed on each call rather than edited in place, so a
  subscriber that dies or unsubscribes while over its bound leaves it without needing to be
  pruned.

  ## Notices are never dropped

  `deliver/4` is for a venue's data stream. A `Core.Notice` goes out through the caller's
  own unbounded path, and must: the notice announcing that a subscriber is being dropped
  cannot be the first casualty of that same subscriber being dropped. Notices are low-volume
  by construction — link transitions, coverage changes, refusals — and no venue in this
  family has ever produced them at a rate that could bury a consumer.
  """

  alias DpExchange.Core.Notice

  @typedoc """
  A subscriber as `subscribe/2` accepts one: a pid, or a registered name to resolve at
  send time.
  """
  @type subscriber :: pid() | atom()

  @typedoc "What changed for one subscriber on this call, and what its queue measured."
  @type transition :: {pid(), :dropping | :resumed, non_neg_integer()}

  @doc """
  The default bound: #{10_000} messages queued for one subscriber.

  Chosen as the largest number that is still unambiguously a fault rather than a busy
  moment. A consumer keeping up with a book stream sits in the single or double digits; one
  that has reached five figures is not behind, it is broken, and every message after that
  point is being written to memory nobody will read in time to use.

  Overridable per venue — see `deliver/4`'s `:max_queue_len`. A consumer with a documented
  reason to buffer more can say so; the point is that the number exists and is stated, not
  that this particular one is right for everybody.
  """
  @spec default_max_queue_len() :: pos_integer()
  def default_max_queue_len, do: 10_000

  @doc """
  Reads and validates a venue's `:max_queue_len` start option, or returns the default.

  Shared rather than written per venue so five packages cannot drift into five different
  ideas of what a valid bound is — and so the failure is identical everywhere: loud, at
  `init/1`, naming the venue and the value it was given. A bound that silently fell back to
  the default because it was `"10000"` rather than `10_000` would be a back-pressure setting
  a consumer believes it configured and did not, which is the whole class of defect this
  module exists inside.

  Any positive integer is accepted, including very small ones. A bound of 1 — drop anything
  arriving while the consumer has even one message pending — is a strange choice but a
  coherent one for a latency-critical consumer that would rather have the newest frame than
  a queue, and this is not the place to overrule it.
  """
  @spec max_queue_len!(keyword(), atom()) :: pos_integer()
  def max_queue_len!(opts, venue) do
    case Keyword.get(opts, :max_queue_len, default_max_queue_len()) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError,
              "#{inspect(venue)} :max_queue_len must be a positive integer of messages, got " <>
                "#{inspect(other)}. This is the per-subscriber mailbox bound past which " <>
                "events are dropped and a :degraded notice is emitted; the default is " <>
                "#{default_max_queue_len()}."
    end
  end

  @doc """
  Sends `message` to every subscriber whose mailbox is under the bound.

  `dropping` is the set of pids that were over the bound on the previous call; pass
  `MapSet.new()` the first time. Returns `{message_sent_count, new_dropping, transitions}`
  — the caller stores `new_dropping` and reports `transitions`, which is what
  `notice_for/3` turns into a `Core.Notice`.

  ## Options

    * `:max_queue_len` — the bound, defaulting to `default_max_queue_len/0`.

  A subscriber that has died, or a registered name that resolves to nothing, is skipped
  silently: that is not back-pressure, it is an absent consumer, and every venue in this
  family already treats it that way.
  """
  @spec deliver(Enumerable.t(), term(), MapSet.t(pid()), keyword()) ::
          {non_neg_integer(), MapSet.t(pid()), [transition()]}
  def deliver(subscribers, message, dropping, opts \\ []) do
    max = Keyword.get(opts, :max_queue_len, default_max_queue_len())

    Enum.reduce(subscribers, {0, MapSet.new(), []}, fn subscriber, acc ->
      case resolve(subscriber) do
        nil -> acc
        pid -> deliver_one(pid, message, max, dropping, acc)
      end
    end)
  end

  @doc """
  Resolves a subscriber to a live pid, or `nil`.

  A pid that is no longer alive and a registered name nothing answers to are the same
  answer — there is nobody to send to. Shared here because all five venues had written it
  identically, and because `deliver/4` and a venue's own notice path have to agree on what
  counts as a reachable subscriber or a notice could be delivered to a pid the data stream
  considers gone.
  """
  @spec resolve(subscriber()) :: pid() | nil
  def resolve(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid
  end

  def resolve(name) when is_atom(name), do: Process.whereis(name)

  @doc """
  Turns one `t:transition/0` into the `Core.Notice` the contract promises.

  `:dropping` is `severity: :warning` rather than `:error`: the venue is healthy and every
  other subscriber is being served: it is this one consumer that has fallen behind, and the
  action is on the consumer's side. `:resumed` is `:info` and exists so a consumer can
  bracket the gap it needs to reconcile — without it, "data loss started" is an alarm with
  no end, and a consumer cannot tell a five-second stall from an ongoing outage.

  The bound and the measured queue length both travel in `:details`, because "we dropped
  something" without the number is a notice a consumer cannot act on.
  """
  @spec notice_for(transition(), atom(), pos_integer()) :: Notice.t()
  def notice_for({pid, :dropping, queue_len}, provider, max) do
    Notice.new(:degraded, provider,
      severity: :warning,
      message:
        "subscriber #{inspect(pid)} is #{queue_len} messages behind, past the #{max} bound " <>
          "— further events are being dropped for it until it catches up",
      details: %{subscriber: inspect(pid), queue_len: queue_len, bound: max, dropping: :newest}
    )
  end

  def notice_for({pid, :resumed, queue_len}, provider, max) do
    Notice.new(:degraded, provider,
      severity: :info,
      message:
        "subscriber #{inspect(pid)} is back under the #{max} bound (#{queue_len} queued) " <>
          "— delivery to it has resumed",
      details: %{subscriber: inspect(pid), queue_len: queue_len, bound: max, dropping: :none}
    )
  end

  # `Process.info/2` answers `nil` for a pid that died between `resolve/1` and here. That
  # race is real and its answer is the same as an absent subscriber's: nobody to send to,
  # nothing to report, and specifically NOT a back-pressure transition — reporting a dead
  # consumer as "behind" would send an operator looking for a slow process that no longer
  # exists.
  defp deliver_one(pid, message, max, was_dropping, {sent, now_dropping, transitions}) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, queue_len} when queue_len >= max ->
        transitions =
          if MapSet.member?(was_dropping, pid),
            do: transitions,
            else: [{pid, :dropping, queue_len} | transitions]

        {sent, MapSet.put(now_dropping, pid), transitions}

      {:message_queue_len, queue_len} ->
        send(pid, message)

        transitions =
          if MapSet.member?(was_dropping, pid),
            do: [{pid, :resumed, queue_len} | transitions],
            else: transitions

        {sent + 1, now_dropping, transitions}

      nil ->
        {sent, now_dropping, transitions}
    end
  end
end
