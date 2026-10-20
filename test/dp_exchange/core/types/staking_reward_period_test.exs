defmodule DpExchange.Core.Types.StakingRewardPeriodTest do
  @moduledoc """
  `StakingReward`'s window is typed `DateTime.t() | nil`, and `Validate.new!/3` cannot hold it
  to that by name: `:period_start` and `:period_end` are `Date`s on a filing, so they are not in
  the global time-field rule. The window used to build from a `Date`, a string or an epoch
  integer, and `DateTime.compare/2` in the consumer then crashed over a value the type said
  could not occur.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.{StakingReward, Validate}

  @valid [asset: "ETH", amount: Decimal.new("0.01"), provider: :reference]
  @start ~U[2026-08-25 00:00:00Z]
  @finish ~U[2026-09-01 00:00:00Z]

  describe "StakingReward.new/1 and its window" do
    test "a DateTime window, or none, builds" do
      window = [period_start: @start, period_end: @finish]

      assert %StakingReward{period_start: @start, period_end: @finish} =
               StakingReward.new(@valid ++ window)

      assert %StakingReward{period_start: nil, period_end: nil} = StakingReward.new(@valid)
    end

    test "a value that is not a DateTime is refused, naming the field" do
      for field <- [:period_start, :period_end],
          bad <- [~D[2026-08-25], "2026-08-25T00:00:00Z", 1_787_000_000, :today] do
        error = assert_raise ArgumentError, fn -> StakingReward.new(@valid ++ [{field, bad}]) end

        assert Exception.message(error) =~ inspect(field)
        assert Exception.message(error) =~ "a DateTime"
      end
    end

    test "a NaiveDateTime is refused too: a window with no zone cannot be placed" do
      assert_raise ArgumentError, ~r/NaiveDateTime/, fn ->
        StakingReward.new(@valid ++ [period_end: ~N[2026-09-01 00:00:00]])
      end
    end
  end

  describe "Validate.datetimes!/2" do
    test "returns the struct when each field is nil or a DateTime" do
      built = %StakingReward{asset: "ETH", amount: Decimal.new(1), provider: :v}
      assert Validate.datetimes!(built, [:period_start, :period_end]) == built

      with_start = %{built | period_start: @start}
      assert Validate.datetimes!(with_start, [:period_start]) == with_start
    end

    test "raises on a field holding anything else" do
      built = %StakingReward{asset: "ETH", amount: Decimal.new(1), provider: :v, period_end: 5}

      assert_raise ArgumentError, ~r/:period_end.*a DateTime/, fn ->
        Validate.datetimes!(built, [:period_start, :period_end])
      end
    end
  end
end
