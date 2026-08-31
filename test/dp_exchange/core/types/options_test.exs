defmodule DpExchange.Core.Types.OptionsTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.{OptionChain, OptionContract}

  defp contract(right, strike) do
    %OptionContract{
      underlying: "XYZ",
      expiry: ~D[2026-03-15],
      strike: Decimal.new(strike),
      right: right,
      provider: :reference
    }
  end

  describe "OptionContract" do
    test "carries identity and no prices" do
      # The same split as Quote vs TopOfBook. A chain row carrying lastPrice, bidPrice,
      # askPrice, markPrice and theoreticalOptionValue offers five plausible numbers and no
      # help choosing; this family has already shipped one defect from exactly that.
      c = contract(:call, "500")

      for field <- [:price, :bid, :ask, :mark, :last_price] do
        refute Map.has_key?(c, field)
      end
    end

    test "multiplier defaults to nil, which does not mean 100" do
      # Mini contracts, index options and contracts adjusted by a corporate action all
      # differ. A caller computing notional without it is wrong by a factor.
      assert contract(:call, "500").multiplier == nil
    end

    test "in_the_money?/2 for a call is underlying above strike" do
      assert OptionContract.in_the_money?(contract(:call, "500"), Decimal.new("501"))
      refute OptionContract.in_the_money?(contract(:call, "500"), Decimal.new("499"))
    end

    test "in_the_money?/2 for a put is underlying below strike" do
      assert OptionContract.in_the_money?(contract(:put, "500"), Decimal.new("499"))
      refute OptionContract.in_the_money?(contract(:put, "500"), Decimal.new("501"))
    end

    test "at the money is not in the money, on either side" do
      refute OptionContract.in_the_money?(contract(:call, "500"), Decimal.new("500"))
      refute OptionContract.in_the_money?(contract(:put, "500"), Decimal.new("500"))
    end
  end

  describe "OptionChain" do
    defp chain do
      %OptionChain{
        underlying: "XYZ",
        provider: :reference,
        expiries: %{
          ~D[2026-03-15] => %{
            Decimal.new("500") => %{call: contract(:call, "500"), put: contract(:put, "500")},
            Decimal.new("450") => %{call: contract(:call, "450"), put: nil}
          },
          ~D[2026-06-19] => %{
            Decimal.new("500") => %{call: contract(:call, "500"), put: contract(:put, "500")}
          }
        }
      }
    end

    test "expiry_dates/1 is earliest first" do
      assert OptionChain.expiry_dates(chain()) == [~D[2026-03-15], ~D[2026-06-19]]
    end

    test "strikes/2 is ascending" do
      [first, second] = OptionChain.strikes(chain(), ~D[2026-03-15])
      assert Decimal.equal?(first, Decimal.new("450"))
      assert Decimal.equal?(second, Decimal.new("500"))
    end

    test "an unlisted expiry is an empty list, not an error" do
      assert OptionChain.strikes(chain(), ~D[2030-01-18]) == []
    end

    test "a strike with only one side keeps the other as nil, not as a missing key" do
      # A caller iterating strikes must see the one-sided strike rather than have it
      # silently skipped.
      row = chain().expiries[~D[2026-03-15]][Decimal.new("450")]

      assert row.call
      assert row.put == nil
    end
  end
end
