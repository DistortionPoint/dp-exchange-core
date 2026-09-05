defmodule DpExchange.Core.Notice do
  @moduledoc """
  What a venue package says about **itself** — distinct from what a venue says about the
  market, and never carrying market data.

  A consumer subscribes; the package never holds a consumer's function. That inversion is
  the whole design: a package that was handed a sink would be deciding what happens next,
  which is the consumer's decision, and would be holding a reference into an application
  it must know nothing about.

  | Channel | Subject | Example |
  |---|---|---|
  | the data stream | what the **venue** says about the **market** | `%Types.Quote{}` |
  | notices | what the **package** says about **itself** | `%Notice{kind: :credentials_rejected}` |

  A consumer may want the second without the first. A monitoring process that never
  touches market data still needs to know a venue's credentials expired.

  ## Telemetry is measurement; a notice is a condition

  The two overlap enough that the line has to be stated rather than discovered.
  **Telemetry is what you aggregate. A notice is what you act on.** A request duration is
  a metric. "Your API key was rejected" is not, and it must not be delivered by a
  mechanism whose handlers run inside the emitting process and whose delivery is
  legitimately lossy.

  ## A notice is a prompt to re-read, never the record

  **Delivery is not guaranteed and a consumer's correctness must not depend on it.** This
  is not a caveat, it is the contract: reporting on the work must never become the reason
  the work does not happen, so a notice that cannot be delivered is dropped rather than
  retried or blocked on.

  The failure this warns against has already happened once, in the application these
  packages came from. Three cached copies of a symbol's status were kept in step with
  fire-and-forget casts — and a cast to a dead or restarting process returns `:ok` and is
  silently dropped. Two symbols suspended at 03:14 and 03:27 UTC opened fresh positions at
  21:46, because the message that would have stopped them had vanished with a process
  nobody noticed had restarted.

  So: a `:catalog_change` notice is a reason to re-read `list_instruments/1`, not the
  authority that a pair was delisted. A `:coverage_change` is a reason to call
  `coverage/1`. Treat a notice as a nudge and the dropped-message case degrades to
  latency; treat it as the record and the dropped-message case is silent, wrong state.

  ## It never carries credentials

  Not the key, not a fragment of it, not a redacted form. These packages are public and an
  operational notice is exactly the sort of thing that gets pasted into an issue. A
  credential notice names *which* credential failed and how — never its value.

  ## The kinds

  ### Link

  `:link_up`, `:link_down`, `:link_reconnecting`, `:link_recovered` — stated **without
  naming the transport**. "The venue link is down" is the fact; whether that link is a
  WebSocket, an MQTT session or a polling loop is package-internal and not a consumer's
  concern.

  ### Credentials

  `:credentials_rejected`, `:credentials_expiring`, `:session_refresh_failed`. Close to
  load-bearing: a consumer that cannot learn its keys stopped working finds out from the
  absence of data, which is the slowest possible signal.

  ### Pressure

  `:rate_limited` — sustained limiting, or a venue returning `429` past the point where
  retry is working. A single `429` is a metric and belongs in telemetry; a venue that will
  not stop returning them is a condition.

  ### Coverage

  `:coverage_change` — what makes `coverage/1` **pushable rather than pollable**. Drawn
  directly from an incident: 325 symbols subscribed and confirmed, 174 actually
  delivering. A drop from 325 to 174 is an event, not a number to be discovered by asking.

  ### Catalog

  `:catalog_change` — a pair added, removed, or moving `:tradable` → `:delisted`. The one
  kind that originates at the venue rather than in the package, and it belongs here rather
  than on the data stream because it is not market data: a price is what the market says,
  a delisting is a change in the venue's own shape. A consumer holding a pair needs to
  know it stopped trading even if it never subscribed to a single quote. It also makes the
  catalogue pushable rather than diffable, which matters most where diffing is worst — a
  millions-of-instruments venue cannot be re-pulled on a timer to spot one delisting.

  **Two honesty constraints.** Most venues do not *announce* a delisting; the pair simply
  stops appearing, so the package learns it by diffing internally and **must say so** —
  `observed: true` rather than announced. And a vanished pair is not evidence of a
  delisting: `DpExchange.Core.Instrument` resolves unrecognised input to `:unknown`, never
  to `:tradable`, and the two must not be conflated.

  ### Refusal and quality

  `:refusal` — a symbol the venue will not carry. `:data_quality` — a payload that did not
  parse.

  ### Degradation

  `:degraded` — the venue is answering, but from a slower path than usual.
  """

  alias DpExchange.Core.Notice

  @typedoc """
  What the notice is about.

  Deliberately a closed set. An open one would let each venue package invent its own
  vocabulary, which is the drift a shared contract exists to prevent — a consumer would be
  back to matching on venue identity to know what a notice meant.
  """
  @type kind ::
          :link_up
          | :link_down
          | :link_reconnecting
          | :link_recovered
          | :credentials_rejected
          | :credentials_expiring
          | :session_refresh_failed
          | :rate_limited
          | :coverage_change
          | :catalog_change
          | :refusal
          | :data_quality
          | :degraded

  @typedoc "How much a consumer should care. Not a log level — a call to action."
  @type severity :: :info | :warning | :error

  @enforce_keys [:kind, :provider, :severity, :at]
  defstruct [:kind, :provider, :severity, :at, :message, details: %{}]

  @type t :: %__MODULE__{
          kind: kind(),
          provider: atom() | String.t(),
          severity: severity(),
          at: DateTime.t(),
          message: String.t() | nil,
          details: map()
        }

  @kinds ~w(link_up link_down link_reconnecting link_recovered credentials_rejected
            credentials_expiring session_refresh_failed rate_limited coverage_change
            catalog_change refusal data_quality degraded)a

  @credential_keys ~w(api_key api_secret secret password passphrase token access_token
                      refresh_token private_key signature authorization bearer)a

  # Derived once, at compile time, so the runtime check below never has to turn an
  # incoming key into an atom to compare it. `@credential_keys` stays the single
  # source of truth; this is only its string projection.
  #
  # A plain list, not a `MapSet`: a `MapSet` built from a module attribute is embedded
  # in the BEAM as a literal whose internal representation Dialyzer can see directly,
  # and `MapSet.member?/2` then fails PLT analysis with a
  # `call_without_opaque`/opaqueness-type mismatch against that literal — the function's
  # own spec expects an opaque `t:MapSet.t/0`, not one it can see through. Twelve
  # entries make a linear scan irrelevant next to that.
  @credential_key_strings Enum.map(@credential_keys, &Atom.to_string/1)

  @doc """
  Builds a notice.

  `:at` defaults to now, which for a notice is correct: unlike market data there is no
  venue event time to preserve — the package is reporting on itself, and the moment it
  noticed *is* the fact.

  ## Raises

  On an unknown `kind`, because a typo would otherwise become a notice no consumer
  matches on and no one ever sees. And on **any credential-shaped key in `details`**: these
  packages are public, notices get pasted into issues, and a leak is not fixed by a later
  release.

  ## Examples

      iex> notice = DpExchange.Core.Notice.new(:link_down, :some_venue, severity: :warning)
      iex> {notice.kind, notice.severity}
      {:link_down, :warning}

      iex> DpExchange.Core.Notice.new(:not_a_real_kind, :some_venue)
      ** (ArgumentError) unknown notice kind :not_a_real_kind

      iex> DpExchange.Core.Notice.new(:link_down, :v, details: %{api_key: "sk-live-123"})
      ** (ArgumentError) notice details carry credential-shaped keys: [:api_key]. A notice names WHICH credential failed, never its value — these packages are public and notices get pasted into issues
  """
  @spec new(kind(), atom() | String.t(), keyword()) :: t()
  def new(kind, provider, opts \\ []) do
    unless kind in @kinds do
      raise ArgumentError, "unknown notice kind #{inspect(kind)}"
    end

    details = Keyword.get(opts, :details, %{})
    reject_credentials!(details)

    %Notice{
      kind: kind,
      provider: provider,
      severity: Keyword.get(opts, :severity, default_severity(kind)),
      at: Keyword.get(opts, :at, DateTime.utc_now()),
      message: Keyword.get(opts, :message),
      details: details
    }
  end

  @doc """
  Every kind this contract admits.

  A venue package must not invent its own: a consumer matching on kinds would be back to
  matching on venue identity to know what one meant.
  """
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  # Refused rather than redacted. Redaction implies someone chose what to hide and got it
  # right; refusing means the value never reached a struct that a consumer might log.
  #
  # Membership is tested against STRINGS, never atoms. `details` is built by venue
  # packages from venue-supplied content — a channel name, a raw payload key, an error
  # code — and this contract does not control its shape or its cardinality. Atomising an
  # unbounded, externally-influenced string is the same `DOS.BinToAtom` class
  # `Core.FakeInjection` already designed around (it keys its own state by a static atom
  # and puts the venue INSIDE the map, specifically to avoid a dynamic atom per venue).
  # Atoms are never garbage collected and the VM's atom table is finite: a venue whose
  # notices carry varied `details` keys over the process's lifetime must never be able to
  # walk that table to exhaustion and take the whole node down — which a guard whose
  # entire purpose is to make notices SAFE must not itself become a way to do.
  defp reject_credentials!(details) when is_map(details) do
    offending =
      details
      |> Map.keys()
      |> Enum.filter(fn key ->
        normalised = key |> to_string() |> String.downcase()
        normalised in @credential_key_strings
      end)

    if offending != [] do
      raise ArgumentError,
            "notice details carry credential-shaped keys: #{inspect(offending)}. " <>
              "A notice names WHICH credential failed, never its value — these packages " <>
              "are public and notices get pasted into issues"
    end

    :ok
  end

  defp reject_credentials!(other) do
    raise ArgumentError, "notice details must be a map, got #{inspect(other)}"
  end

  # A default, not a rule: a caller with better information overrides it. These are the
  # readings that hold when nothing more is known — a link going down is worth attention,
  # a rejected credential is broken until someone acts.
  defp default_severity(kind)
       when kind in [:link_down, :session_refresh_failed, :credentials_rejected],
       do: :error

  defp default_severity(kind)
       when kind in [
              :link_reconnecting,
              :credentials_expiring,
              :rate_limited,
              :degraded,
              :data_quality
            ],
       do: :warning

  defp default_severity(_kind), do: :info
end
