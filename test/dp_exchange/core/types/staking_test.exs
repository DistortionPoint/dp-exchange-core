defmodule DpExchange.Core.Types.StakingTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.{StakingBalance, StakingRate, StakingTransaction}

  describe "StakingBalance.by_provider defaults to %{}, never nil (C7)" do
    # The typespec is a map, not `map() | nil` — "empty means no breakdown" (the
    # moduledoc's own words) is only true if `new/1` can actually reach an empty map.
    # Before this fix, an omitted `:by_provider` defaulted to `nil` via a bare defstruct
    # entry, and an explicit `by_provider: nil` (a decode bug from a venue field that came
    # back JSON `null`) reached the struct unchanged either way.
    @balance_attrs [asset: "ETH", staked: Decimal.new("10"), provider: :v]

    test "omitted defaults to an empty map" do
      assert StakingBalance.new(@balance_attrs).by_provider == %{}
    end

    test "an explicit nil normalises to an empty map rather than leaking through" do
      assert StakingBalance.new(@balance_attrs ++ [by_provider: nil]).by_provider == %{}
    end

    test "a real breakdown is kept" do
      breakdown = %{"provider_a" => Decimal.new("6"), "provider_b" => Decimal.new("4")}

      assert StakingBalance.new(@balance_attrs ++ [by_provider: breakdown]).by_provider ==
               breakdown
    end
  end

  describe "StakingRate.bps_to_pct/1" do
    # Lives in Core rather than in each venue package because it is the conversion most
    # likely to be done inconsistently, and a rate wrong by 100x still looks like a rate.
    test "converts basis points to a percentage" do
      assert Decimal.equal?(StakingRate.bps_to_pct(Decimal.new("450")), Decimal.new("4.5"))
    end

    test "accepts the shapes venues actually send" do
      assert Decimal.equal?(StakingRate.bps_to_pct(450), Decimal.new("4.5"))
      assert Decimal.equal?(StakingRate.bps_to_pct("450"), Decimal.new("4.5"))
      assert Decimal.equal?(StakingRate.bps_to_pct(450.0), Decimal.new("4.5"))
    end

    test "a rate the venue did not state is nil, not a crash" do
      # This handed a binary straight to `Decimal.new/1`, which RAISES on a string that is
      # not a number. A venue omitting a rate, or naming it in words, took the caller down
      # rather than reporting an absent rate — from a helper whose entire purpose is to make
      # this conversion safe to do with whatever the venue sent.
      #
      # `nil` is a rate the venue did not state. It is not zero, which is a rate.
      assert StakingRate.bps_to_pct("") == nil
      assert StakingRate.bps_to_pct("n/a") == nil
      assert StakingRate.bps_to_pct("--") == nil
      assert StakingRate.bps_to_pct(nil) == nil
    end

    test "padding is not a reason to fail" do
      # `Decimal.new("  500  ")` raises. Whitespace around a number does not change it.
      assert Decimal.equal?(StakingRate.bps_to_pct("  450  "), Decimal.new("4.5"))
    end

    test "NaN and Infinity are refused, in every shape they arrive in" do
      # Both parse cleanly, so both used to become a `Decimal` and then a rate. Every venue
      # package in this family already refuses them and records why beside each copy:
      # `Decimal.add(nan, 1)` is NaN and poisons a consumer's arithmetic silently,
      # `Decimal.compare(nan, _)` raises in the CONSUMER's process naming Decimal rather
      # than the venue that sent it, and an Infinity is quieter still — it compares greater
      # than everything and never raises at all.
      #
      # The shared helper was less careful than the five copies it exists to replace.
      for bad <- ["NaN", "nan", "Infinity", "inf", "-Inf"] do
        assert StakingRate.bps_to_pct(bad) == nil, "#{bad} must not become a rate"
      end

      assert StakingRate.bps_to_pct(Decimal.new("NaN")) == nil
      assert StakingRate.bps_to_pct(Decimal.new("Infinity")) == nil
    end

    test "zero stays zero" do
      assert Decimal.equal?(StakingRate.bps_to_pct(0), Decimal.new("0"))
    end
  end

  describe "StakingTransaction.settled?/1" do
    defp redemption(remaining) do
      %StakingTransaction{
        id: "abc",
        type: :unstake,
        asset: "ETH",
        amount: Decimal.new("10"),
        amount_remaining: remaining && Decimal.new(remaining),
        provider: :reference
      }
    end

    test "nothing remaining means settled" do
      assert StakingTransaction.settled?(redemption("0")) == true
    end

    test "something remaining means not settled" do
      assert StakingTransaction.settled?(redemption("4")) == false
    end

    test "no progress reported is nil — unknown, and specifically not 'complete'" do
      # This is the assertion that matters. A caller reading a missing amount_remaining as
      # "finished" would spend an asset that is still unbonding, which can take days.
      assert StakingTransaction.settled?(redemption(nil)) == nil
    end
  end

  describe "the staking shapes" do
    test "a transaction keeps the venue's own type alongside the normalised one" do
      # A normalisation that loses the original cannot be audited when it turns out wrong.
      tx = %StakingTransaction{
        id: "abc",
        type: :reward,
        venue_type: "Interest",
        asset: "ETH",
        amount: Decimal.new("0.01"),
        provider: :reference
      }

      assert tx.type == :reward
      assert tx.venue_type == "Interest"
    end

    test "a rate carries percentages, and leaves the other nil rather than deriving it" do
      # Turning a simple rate into an APY needs a compounding frequency the venue did not
      # state. Assuming one is inventing a number.
      rate = %StakingRate{asset: "ETH", rate_pct: Decimal.new("4.5"), provider: :reference}

      assert rate.apy_pct == nil
    end
  end
end
