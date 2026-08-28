defmodule DpExchange.Core.FeedBehaviour do
  @moduledoc """
  A venue's price feed: symbols in, price events out. How is the venue's business.

  ## The boundary this restores

  The application asks a venue for a feed over a symbol set and receives price
  events. It does not ask how they are produced. A venue may use a websocket,
  five MQTT sessions, an internal REST poll, or any mix of those, and may change
  that mix at runtime without anything outside the venue noticing.

  This is the design the codebase already claims — hexagonal, with the exchange
  as the adapter — and the collection layer had drifted a long way from it.
  Orchestration accreted in a shared collection layer one venue at a time, until it
  held Webull's session count, Gemini's ten-pairs-per-socket limit, Coinbase's channel
  ordering, and a `case provider do` for which module speaks which protocol. Every one
  of those is knowledge only the venue has.

  The cost of that drift was not tidiness. Shared code was making transport
  decisions with information it could not have:

    * `PollSet` had to guess which pairs a subscription was covering, because
      the only honest answer lives inside the venue.
    * Webull's documented ceiling of "3 messages per second per connection" was
      being rationed by a module that could not see it, so 151 subscribed pairs
      delivered nothing and it read as a quiet market.
    * A venue with no socket at all was reported to the user in socket terms,
      because the layer describing it was inferring transport rather than being
      told.

  ## Always a feed, even when it is really a poll

  A venue with no streaming API still implements this. Robinhood polls REST
  internally and emits events through the same sink as Coinbase's socket, so
  nothing above the adapter branches on transport. That is the point: the poll
  and the socket become an implementation detail of the venue rather than a
  fork that every consumer has to understand.

  ## Coverage is OBSERVED, never intended

  `coverage/1` must report what the feed has actually seen arrive, not what it
  subscribed. The distinction is the whole value of the callback. Webull
  subscribed 325 symbols and confirmed them while 174 delivered; a feed
  reporting its subscription would have answered "325 covered by socket" — the
  same wrong answer the collection layer was already inferring, but stamped with
  the venue's authority, which is worse than an inference known to be a guess.

  A feed that cannot observe its own delivery reports `:not_covered` rather than
  assuming. Silence is the honest answer to a question it cannot answer.

  ## This does not replace independent measurement

  `TickFreshness` stays, and stays independent. This callback is what the venue
  BELIEVES it is covering; the freshness table is what actually arrived at the
  publisher. Keeping both means their disagreement is visible, and that
  disagreement is the highest-value signal in the system — "the venue claims 325
  and 44 arrived" states an entire morning's investigation in one line. Folding
  them into a single number would throw exactly that away.
  """

  @typedoc """
  How a symbol's data is reaching us right now, as observed by the feed.

    * `:stream` — arriving pushed, without the feed asking for it each time.
    * `:internal_poll` — arriving, but the venue package is fetching it. Either the
      venue has no streaming API, or its stream does not cover this symbol and the
      feed is filling the gap itself.
    * `:not_covered` — nothing is arriving by any route the feed controls.

  `:stream` deliberately does **not** say *socket*. Whether a pushed route is a
  WebSocket, an MQTT session or long-polling is package-internal, and a consumer
  branching on it would be branching on mechanism. What a consumer legitimately needs
  is whether the data is being pushed or fetched, because only the second scales with
  catalogue size.
  """
  @type route :: :stream | :internal_poll | :not_covered

  # Two injected types used to live here and both are deliberately gone.
  #
  # `sink` — where a feed sent its price events — was injected so that an adapter never
  # referenced an application module. The package boundary does that now, and injection
  # would additionally hand the package a function that decides what happens to the
  # data, which is the consumer's decision (D6). A feed emits to whoever subscribed.
  #
  # `socket` — how a feed opened and subscribed a connection — was injected because the
  # connection machinery lived in a boundary the adapters could not reference, and
  # duplicating its state machine four times was worse. That constraint was an artefact
  # of one application's module layout. **The venue owns its transport now** (D12,
  # D20): it dials its own connection with whatever library it chose, and there is no
  # host plumbing left to pass in.
  #
  # What survives is the half that always mattered — the venue keeps the POLICY: how
  # many connections, which channels, how many symbols each carries, in what order and
  # at what pace. Those need venue knowledge, and they are exactly what shared code
  # kept getting wrong: one venue's socket stops accepting subscribes after about ten
  # pairs, which no generic layer could know.

  @doc """
  Start this venue's feed over `symbols`.

  Options carry the venue's `:credentials` and whatever else that venue needs. **No
  sink and no socket plumbing** — the feed emits to its subscribers and opens its own
  connections. The returned process is the feed's root; supervising it is the caller's
  business, and everything under it is the venue's.
  """
  @callback start_feed([String.t()], keyword()) :: {:ok, pid()} | {:error, term()}

  @doc """
  Which symbols the feed is currently delivering, and by which route.

  Observed, never intended — see the moduledoc. Symbols absent from the map are
  `:not_covered`.
  """
  @callback coverage(pid() | atom()) :: %{String.t() => route()}

  @doc """
  Add or remove symbols from a running feed, so a scope change does not require
  tearing the venue's connections down and rebuilding them.
  """
  @callback update_symbols(pid() | atom(), [String.t()]) :: :ok | {:error, term()}
end
