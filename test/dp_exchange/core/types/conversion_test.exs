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

  describe "status" do
    test "a quote is not a conversion that happened" do
      # :quoted means a rate is held and nothing has moved. Reporting it as complete would
      # report an intention as a fact.
      assert conversion(nil).status == :quoted
    end
  end
end
