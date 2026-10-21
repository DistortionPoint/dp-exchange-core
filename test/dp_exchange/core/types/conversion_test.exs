defmodule DpExchange.Core.Types.ConversionTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.Conversion

  defp conversion(expires_at) do
    %Conversion{
      id: "q-1",
      status: :quoted,
      from_asset: "USD",
      to_asset: "BTC",
      expires_at: expires_at,
      provider: :reference
    }
  end

  describe "expired?/2" do
    test "a quote past its window is expired" do
      c = conversion(~U[2026-08-31 12:00:00Z])
      assert Conversion.expired?(c, ~U[2026-08-31 12:00:01Z]) == true
    end

    test "a quote inside its window is not" do
      c = conversion(~U[2026-08-31 12:00:00Z])
      assert Conversion.expired?(c, ~U[2026-08-31 11:59:59Z]) == false
    end

    test "the instant of expiry is expired, and one microsecond before it is not" do
      # A rate held until 12:00:00 is not one to commit at 12:00:00: the commit that lands on
      # the boundary is the one refused or filled at the current rate. Strictly-greater read
      # it as still open, the optimistic direction for a call that guards a funds-moving commit.
      expires_at = ~U[2026-08-31 12:00:00.000000Z]
      c = conversion(expires_at)

      assert Conversion.expired?(c, expires_at) == true
      assert Conversion.expired?(c, ~U[2026-08-31 11:59:59.999999Z]) == false
    end

    test "no stated expiry is nil — unknown, and specifically not 'still valid'" do
      # The dangerous reading. A caller treating an unstated window as open-ended commits
      # against a rate it was shown some time ago and may not get.
      assert Conversion.expired?(conversion(nil), ~U[2026-08-31 12:00:00Z]) == nil
    end
  end

  describe "new/1 status and values" do
    @attrs [id: "q-1", from_asset: "USD", to_asset: "BTC", provider: :reference]

    test "every documented status builds, and a quote is not coerced into a conversion" do
      # :quoted means a rate is held and nothing has moved. Reporting it as complete would
      # report an intention as a fact, so the constructor must hand back the status it was given.
      for status <- [:quoted, :committed, :settled, :expired, :failed, :cancelled] do
        assert %Conversion{status: ^status} = Conversion.new([status: status] ++ @attrs)
      end
    end

    test "a status outside the six is refused, whatever it resembles" do
      for bad <- [:complete, :pending, "quoted", "settled", nil] do
        assert_raise ArgumentError, ~r/status/, fn -> Conversion.new([status: bad] ++ @attrs) end
      end
    end

    test "a rate of zero or less and a negative amount are refused, zero amounts are legal" do
      base = [status: :quoted] ++ @attrs

      for bad <- [Decimal.new(0), Decimal.new("-1.5")] do
        assert_raise ArgumentError, ~r/rate/, fn -> Conversion.new([rate: bad] ++ base) end
      end

      for field <- [:from_amount, :to_amount] do
        assert_raise ArgumentError, ~r/#{field}/, fn ->
          Conversion.new([{field, Decimal.new("-1")}] ++ base)
        end

        assert %Conversion{} = Conversion.new([{field, Decimal.new(0)}] ++ base)
      end
    end
  end
end
