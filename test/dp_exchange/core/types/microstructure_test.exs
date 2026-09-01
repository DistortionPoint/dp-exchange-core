defmodule DpExchange.Core.Types.MicrostructureTest do
  @moduledoc """
  `AuctionImbalance` and `VolumeProfile` — the two types the equity surface needed.

  Both exist because something a caller must act on has nowhere else to live: an auction's
  clearing state is not a quote, and a volume split by price is not a candle.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.{AuctionImbalance, VolumeProfile}

  defp imbalance(overrides \\ %{}) do
    struct!(
      %AuctionImbalance{
        symbol: "AAPL",
        auction: :closing,
        paired_quantity: Decimal.new("100"),
        imbalance_quantity: Decimal.new("25"),
        side: "2",
        observed_at: ~U[2026-08-28 20:00:00Z],
        provider: :reference
      },
      overrides
    )
  end

  describe "AuctionImbalance" do
    test "the side is the venue's own value, not an atom guessed from it" do
      # Venues publish the direction as a code and the tables differ. Webull's NOII
      # documents `imbalance_side` with the example "2" and does not say what 2 means.
      # Guessing it backwards tells a caller there is unmatched buying when there is
      # selling — wrong, plausible, and at the one moment of the day with the most volume
      # behind it.
      assert imbalance().side == "2"
      refute imbalance().side == :buy
    end

    test "the ratio is imbalance over paired" do
      assert Decimal.equal?(AuctionImbalance.imbalance_ratio(imbalance()), Decimal.new("0.25"))
    end

    test "a missing quantity gives nil, which is not zero" do
      # An unknown imbalance is not a small one. A caller treating a missing number as
      # "balanced" is making the same mistake as reading a missing liquidation price as
      # safety.
      assert AuctionImbalance.imbalance_ratio(imbalance(%{paired_quantity: nil})) == nil
      assert AuctionImbalance.imbalance_ratio(imbalance(%{imbalance_quantity: nil})) == nil
    end

    test "zero paired shares gives nil rather than an infinite ratio" do
      # A venue reporting zero paired shares has said the auction matches nothing yet.
      assert AuctionImbalance.imbalance_ratio(imbalance(%{paired_quantity: Decimal.new("0")})) ==
               nil
    end

    test "the three prices are three fields, and none of them is 'the price'" do
      full =
        imbalance(%{
          reference_price: Decimal.new("253.83"),
          near_price: Decimal.new("253.93"),
          far_price: Decimal.new("253.98")
        })

      refute Decimal.equal?(full.reference_price, full.near_price)
      refute Decimal.equal?(full.near_price, full.far_price)
      # A venue publishing only some of them leaves the rest nil.
      assert imbalance().near_price == nil
    end
  end

  defp profile(overrides \\ %{}) do
    struct!(
      %VolumeProfile{
        symbol: "AAPL",
        timeframe: "5m",
        opened_at: ~U[2026-08-28 12:00:00Z],
        total_volume: Decimal.new("1000"),
        delta: Decimal.new("200"),
        buy_volume: Decimal.new("600"),
        sell_volume: Decimal.new("400"),
        buy_at_price: %{"24.20" => Decimal.new("100"), "24.21" => Decimal.new("500")},
        sell_at_price: %{"24.20" => Decimal.new("350"), "24.21" => Decimal.new("50")},
        provider: :reference
      },
      overrides
    )
  end

  describe "VolumeProfile" do
    test "the point of control is the price with the most volume across both sides" do
      # 24.20 has 100 + 350 = 450; 24.21 has 500 + 50 = 550.
      assert VolumeProfile.point_of_control(profile()) == "24.21"
    end

    test "no split at all is nil, and nil is not a price" do
      # A caller that needs one must treat the interval as un-profiled rather than
      # substituting the close.
      assert VolumeProfile.point_of_control(profile(%{buy_at_price: %{}, sell_at_price: %{}})) ==
               nil

      assert VolumeProfile.point_of_control(profile(%{buy_at_price: nil, sell_at_price: nil})) ==
               nil
    end

    test "a tie returns the lower price, so the answer does not depend on map ordering" do
      tied =
        profile(%{
          buy_at_price: %{"24.20" => Decimal.new("100"), "24.21" => Decimal.new("100")},
          sell_at_price: %{}
        })

      assert VolumeProfile.point_of_control(tied) == "24.20"
    end

    test "one-sided volume still has a point of control" do
      assert VolumeProfile.point_of_control(
               profile(%{buy_at_price: %{"24.30" => Decimal.new("5")}, sell_at_price: %{}})
             ) == "24.30"
    end

    test "delta is the venue's own figure and is not recomputed from the totals" do
      # A venue that classifies some prints as neither aggressive buy nor sell reports
      # totals that do not reconcile, and that gap is information about its classifier
      # rather than a fault to paper over.
      disagreeing =
        profile(%{
          delta: Decimal.new("50"),
          buy_volume: Decimal.new("600"),
          sell_volume: Decimal.new("400")
        })

      assert Decimal.equal?(disagreeing.delta, Decimal.new("50"))

      refute Decimal.equal?(
               disagreeing.delta,
               Decimal.sub(disagreeing.buy_volume, disagreeing.sell_volume)
             )
    end

    test "the price maps stay keyed on the venue's own strings" do
      # Two strings that parse to equal decimals are the same level; re-keying would
      # silently merge two of the venue's rows into one.
      assert Map.has_key?(profile().buy_at_price, "24.20")
    end
  end
end
