defmodule DpExchange.Core.Types.Order do
  @moduledoc """
  Normalised order, returned by every venue package.

  `:created_at` and `:updated_at` are **the venue's own** values where it supplies them
  and `nil` where it does not. `nil` is the honest answer; a substituted local clock
  would be a plausible value with the wrong meaning.

  Not every venue supports every `t:order_type/0` or reports every `t:status/0`. The
  union here is what the contract can *express*; what a given venue can actually accept
  is declared by that package's `capabilities/0`, and asking for one it does not support
  is an error rather than a silent downgrade to the nearest available type.

  ## Why the enforced keys still admit `nil`

  All seven are enforced, and all but `provider` allow `nil`. That is not laxity — it is the
  same rule as everywhere else here: **the venue's word, or nothing.**

  A venue sending a status this package does not recognise gets `nil`, never the nearest
  atom a caller might branch on. Coinbase's `close_position/3` returns an order whose side
  the venue never states — the venue worked the side out from a position this package did
  not read — and filling in `:sell` because closing is usually selling is wrong exactly
  where it matters, on a short.

  **`symbol` and `id` joined them on 2026-09-01.** Robinhood acknowledges a cancel request
  without describing the order it cancelled: there is an id and nothing else, and inventing
  a symbol to satisfy a type would put a guess where the venue was silent.

  The keys stay enforced so a constructor must *decide*. The types admit `nil` so the
  decision can be "the venue did not say".
  """

  alias DpExchange.Core.Capabilities
  alias DpExchange.Core.Types.{OrderLeg, Validate}

  @enforce_keys [:id, :symbol, :side, :order_type, :quantity, :status, :provider]
  defstruct [
    :id,
    :symbol,
    :side,
    :order_type,
    # `Capabilities.supported_time_in_force` says which a venue accepts; without this the
    # type could not say which one an order actually used. A caller reading an order back
    # could not distinguish an IOC that expired from a GTC still working.
    :time_in_force,
    :quantity,
    :price,
    :stop_price,
    :status,
    :filled_quantity,
    :average_price,
    :fee,
    :fee_currency,
    # Empty for an ordinary single-instrument order. Non-empty for a spread, which the
    # venue fills as a unit or not at all — see `Types.OrderLeg`. A venue that cannot
    # trade multi-leg refuses rather than decomposing: submitting the legs separately is
    # something the venue never received, and reports back as though it had. A venue that
    # cannot accept multi-leg refuses.
    :legs,
    :created_at,
    :updated_at,
    :provider
  ]

  @type side :: :buy | :sell

  # The atoms behind `t:order_type/0` and `t:status/0`, kept beside them so `new/1` checks the
  # vocabulary the types state. "A status this package does not recognise gets `nil`, never
  # the nearest atom" (moduledoc) was only a convention until the constructor enforced it.
  #
  # The last four joined on 2026-10-11 to match `Core.Capabilities`, which has named them
  # since Schwab's extraction: a venue could DECLARE it accepts `:trailing_stop` while the
  # order it then returned could not say so — `new/1` refused it, so Webull built a struct
  # literal outside this type to keep the round trip. One vocabulary for both, not two.
  @order_types [
    :market,
    :limit,
    :stop,
    :stop_limit,
    :post_only,
    :ioc,
    :fok,
    :trailing_stop,
    :trailing_stop_limit,
    :market_on_close,
    :limit_on_close
  ]
  @statuses [:pending, :open, :partially_filled, :filled, :cancelled, :rejected, :expired]

  @type order_type ::
          :market
          | :limit
          | :stop
          | :stop_limit
          | :post_only
          | :ioc
          | :fok
          | :trailing_stop
          | :trailing_stop_limit
          | :market_on_close
          | :limit_on_close

  @type status ::
          :pending
          | :open
          | :partially_filled
          | :filled
          | :cancelled
          | :rejected
          | :expired

  # The atoms of `DpExchange.Core.Capabilities.time_in_force/0`, which `new/1` checks against.
  @type time_in_force :: :gtc | :ioc | :fok | :gtd | :day | :gfw | :gfm

  @type t :: %__MODULE__{
          id: String.t() | nil,
          symbol: String.t() | nil,
          side: side() | nil,
          order_type: order_type() | nil,
          time_in_force: time_in_force() | nil,
          quantity: Decimal.t() | nil,
          price: Decimal.t() | nil,
          stop_price: Decimal.t() | nil,
          status: status() | nil,
          filled_quantity: Decimal.t() | nil,
          average_price: Decimal.t() | nil,
          fee: Decimal.t() | nil,
          fee_currency: String.t() | nil,
          legs: [DpExchange.Core.Types.OrderLeg.t()] | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          provider: atom() | String.t()
        }

  # Only `:provider` is required non-nil. `@enforce_keys` names six other fields, and this
  # module's own moduledoc says why they all still admit `nil`: "the venue's word, or
  # nothing." A validating constructor that rejected `id: nil` would break the exact case
  # `Order` was widened for — Robinhood's cancel acknowledgement, which has an id and
  # nothing else — so `new/1` narrows `DpExchange.Core.Types.Validate`'s check to the one
  # field this type does NOT allow to be absent-in-spirit-but-present-as-nil.
  @required_non_nil [:provider]

  @doc """
  Builds a `t:t/0`, failing closed only if `:provider` is absent or `nil`.

  Every other enforced key may legitimately be `nil` here — see the moduledoc's "Why the
  enforced keys still admit `nil`". `@enforce_keys` still guards their *presence*; this adds
  the one field where `nil` was never intended, using
  `DpExchange.Core.Types.Validate`.

  A `:quantity` or `:filled_quantity` below zero raises: a size is never negative, a negative
  one is a decode bug (a sign flipped, a delta read as a level), and a consumer summing fills
  against it would conclude the order is over-filled. Zero stays legal (an order nothing has
  filled). Prices are not held to a sign here: a venue's `0` for the price of a market order is
  common, and which fields a venue states is the venue's word.

  **Every closed vocabulary is refused outside what its type states, with no default.** `:side`
  is `:buy`, `:sell` or `nil`; `:order_type` and `:status` are the atoms of `t:order_type/0` and
  `t:status/0` or `nil`; `:time_in_force` is one of `DpExchange.Core.Capabilities.time_in_force/0`
  or `nil` (it used to be any atom, so `:good_til_cancelled` or `:GTC` built and matched no
  branch of a consumer's `case`). `nil` is "the venue did not say", never a stand-in for an
  unrecognised word. `:legs` is `nil` or a proper list of `DpExchange.Core.Types.OrderLeg`.

  **A status is refused beside a `:filled_quantity` that contradicts it.** Only when the
  venue stated both (a `nil` size states nothing, so no judgement is made):

    * `:filled` or `:partially_filled` with a `:filled_quantity` of zero: nothing was filled,
      so the order is neither. A venue's status word read as `:filled` where the fill figure
      says otherwise is the decode bug this catches, and a consumer who trusts the status
      books a position that does not exist.
    * `:pending`, `:open` or `:partially_filled` with a `:filled_quantity` at or above a
      positive `:quantity`: the whole size is filled, so nothing is left to be working or
      partial.
    * `:filled` with a `:filled_quantity` below a positive `:quantity`: `:filled` means the
      entire quantity traded. A cancel that landed after a part fill is `:cancelled` with
      the figure in `:filled_quantity`, not `:filled`: a consumer reading `:filled` as
      "nothing is left" would book a position larger than the one held.

  `:cancelled`, `:rejected` and `:expired` carry whatever was filled before they ended, so
  they are not judged against it. A `:filled_quantity` *above* `:quantity` is not judged
  either: which of the two a venue rounded is the venue's word.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    __MODULE__
    |> Validate.new!(@required_non_nil, attrs)
    |> Validate.decimals!([
      :quantity,
      :price,
      :stop_price,
      :filled_quantity,
      :average_price,
      :fee
    ])
    |> Validate.non_negative!([:quantity, :filled_quantity])
    |> Validate.one_of!(:side, [:buy, :sell, nil])
    |> Validate.one_of!(:order_type, [nil | @order_types])
    |> Validate.one_of!(:status, [nil | @statuses])
    |> Validate.one_of!(:time_in_force, [nil | Capabilities.time_in_force()])
    |> status_consistent!()
    |> legs!()
  end

  defp status_consistent!(%__MODULE__{status: status} = built) do
    case contradiction(status, built.quantity, built.filled_quantity) do
      nil ->
        built

      reason ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}.new/1: status #{inspect(status)} contradicts " <>
                "filled_quantity #{Validate.show(built.filled_quantity)} (quantity " <>
                "#{Validate.show(built.quantity)}) — #{reason}"
    end
  end

  defp contradiction(_status, _quantity, nil), do: nil

  defp contradiction(status, quantity, filled) do
    cond do
      status in [:filled, :partially_filled] and Decimal.compare(filled, 0) == :eq ->
        "nothing is filled, so the order is not #{status}"

      status in [:pending, :open, :partially_filled] and fully_filled?(quantity, filled) ->
        "the whole quantity is filled, so the order is not #{status}"

      status == :filled and partly_filled?(quantity, filled) ->
        "only part of the quantity is filled, so the order is not filled"

      true ->
        nil
    end
  end

  defp fully_filled?(nil, _filled), do: false

  defp fully_filled?(quantity, filled),
    do: Decimal.compare(quantity, 0) == :gt and Decimal.compare(filled, quantity) != :lt

  defp partly_filled?(nil, _filled), do: false

  defp partly_filled?(quantity, filled),
    do: Decimal.compare(quantity, 0) == :gt and Decimal.compare(filled, quantity) == :lt

  defp legs!(%__MODULE__{legs: nil} = built), do: built

  defp legs!(%__MODULE__{legs: legs} = built) when is_list(legs) do
    case Enum.reject(legs, &is_struct(&1, OrderLeg)) do
      [] ->
        built

      [other | _rest] ->
        raise ArgumentError,
              "#{inspect(__MODULE__)}.new/1: field :legs holds #{Validate.show(other)} — " <>
                "every leg must be a DpExchange.Core.Types.OrderLeg"
    end
  end

  defp legs!(%__MODULE__{legs: other}) do
    raise ArgumentError,
          "#{inspect(__MODULE__)}.new/1: field :legs holds #{Validate.show(other)} — must be " <>
            "a list of DpExchange.Core.Types.OrderLeg, or nil"
  end
end
