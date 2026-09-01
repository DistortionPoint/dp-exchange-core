defmodule DpExchange.Core.Types.VolumeProfile do
  @moduledoc """
  Traded volume split by price and by side within one interval — a "footprint" bar.

  ## A candle says where; this says how much, and who lifted it

  A `Candle` gives four prices and a total volume. It cannot say that of 1,000 shares
  traded, 600 went through at the ask and 400 at the bid, nor that most of the buying
  happened at one price and the selling at another. That split is the whole content here.

  **The two are not derivable from one another in either direction.** A candle cannot be
  reconstructed from a profile that carries no open, and a profile cannot be inferred from
  a candle's single volume number — which is why this is a separate type rather than fields
  bolted onto `Candle`.

  ## `:delta` is signed, and it is not an error when it disagrees with the totals

  `:delta` is the venue's own buy-minus-sell figure. This type does **not** recompute it
  from `:buy_volume` and `:sell_volume`, and does not correct it when the three disagree: a
  venue that classifies some prints as neither aggressive buy nor aggressive sell will
  report totals that do not reconcile, and that gap is information about the venue's
  classifier rather than a fault to paper over.

  ## `:buy_at_price` and `:sell_at_price` are maps keyed on the venue's price string

  Kept as the venue sent them — `%{"24.20" => Decimal, "24.21" => Decimal}` — rather than
  re-keyed on `Decimal`. Two price strings that parse to equal decimals are the same level,
  and merging them here would silently combine two of the venue's rows into one; leaving
  them alone keeps the venue's own grid visible.

  Empty maps mean the venue reported no split, **not** that nothing traded at any price.
  """

  @enforce_keys [:symbol, :timeframe, :opened_at, :provider]
  defstruct [
    :symbol,
    :timeframe,
    :opened_at,
    :total_volume,
    :delta,
    :buy_volume,
    :sell_volume,
    :buy_at_price,
    :sell_at_price,
    :session,
    :provider
  ]

  @type t :: %__MODULE__{
          symbol: String.t(),
          timeframe: String.t(),
          opened_at: DateTime.t(),
          total_volume: Decimal.t() | nil,
          delta: Decimal.t() | nil,
          buy_volume: Decimal.t() | nil,
          sell_volume: Decimal.t() | nil,
          buy_at_price: %{String.t() => Decimal.t()} | nil,
          sell_at_price: %{String.t() => Decimal.t()} | nil,
          session: atom() | nil,
          provider: atom() | String.t()
        }

  @doc """
  The price with the most volume across both sides — the point of control.

  Returns the venue's own price string, or `nil` when neither side reported a split.
  **`nil` is not a price**, and a caller that needs one must treat the interval as
  un-profiled rather than substituting the close.

  Ties return the lower price, chosen so the answer is stable across calls rather than
  dependent on map ordering. A caller that cares about ties should read the maps.
  """
  @spec point_of_control(t()) :: String.t() | nil
  def point_of_control(%__MODULE__{buy_at_price: buys, sell_at_price: sells}) do
    buys = buys || %{}
    sells = sells || %{}

    merged =
      Map.merge(buys, sells, fn _price, buy, sell -> Decimal.add(buy, sell) end)

    case Enum.to_list(merged) do
      [] ->
        nil

      levels ->
        # An explicit comparator, because `Decimal` in a sort key would be compared by
        # Erlang term order — which orders the struct's fields, not the number. That
        # silently returns the wrong level and looks like it worked.
        levels
        |> Enum.sort(fn {price_a, volume_a}, {price_b, volume_b} ->
          case Decimal.compare(volume_a, volume_b) do
            :gt -> true
            :lt -> false
            :eq -> price_a <= price_b
          end
        end)
        |> hd()
        |> elem(0)
    end
  end
end
