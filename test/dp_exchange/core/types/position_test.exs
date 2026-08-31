defmodule DpExchange.Core.Types.PositionTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.Position

  describe "from_signed_quantity/1" do
    # A sign convention is a fact about one venue's JSON, not about the market. Getting it
    # wrong produces a position that is exactly backwards and looks entirely normal.
    test "a negative quantity is a short, and the size comes back positive" do
      assert {:short, size} = Position.from_signed_quantity(Decimal.new("-0.2"))
      assert Decimal.equal?(size, Decimal.new("0.2"))
    end

    test "a positive quantity is a long" do
      assert {:long, size} = Position.from_signed_quantity(Decimal.new("0.2"))
      assert Decimal.equal?(size, Decimal.new("0.2"))
    end

    test "zero is long by convention" do
      assert {:long, _size} = Position.from_signed_quantity(Decimal.new("0"))
    end
  end

  describe "the shape" do
    defp position(overrides \\ []) do
      struct!(
        %Position{
          symbol: "BTC-GUSD-PERP",
          side: :short,
          quantity: Decimal.new("0.2"),
          provider: :reference
        },
        overrides
      )
    end

    test "quantity is the size and side carries the direction" do
      p = position()
      assert p.side == :short
      assert Decimal.positive?(p.quantity)
    end

    test "realised and unrealised pnl are separate fields" do
      p = position(realised_pnl: Decimal.new("1234.5"), unrealised_pnl: Decimal.new("999.9"))

      # Never summed by this layer: one has happened, the other is an opinion that changes
      # with the next tick and may never be realised.
      assert Decimal.equal?(p.realised_pnl, Decimal.new("1234.5"))
      assert Decimal.equal?(p.unrealised_pnl, Decimal.new("999.9"))
    end

    test "liquidation_price defaults to nil, which means unsaid and not safe" do
      assert position().liquidation_price == nil
    end
  end
end
