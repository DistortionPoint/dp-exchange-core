defmodule DpExchange.Core.Types.MoneyMovementTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.{ApprovedAddress, DepositAddress}

  describe "ApprovedAddress.usable?/2" do
    defp approved(status, active_from \\ nil) do
      %ApprovedAddress{
        address: "0xabc",
        network: "ethereum",
        status: status,
        active_from: active_from,
        provider: :reference
      }
    end

    test "an active address is usable" do
      assert ApprovedAddress.usable?(approved(:active), ~U[2026-08-31 12:00:00Z]) == true
    end

    test "a rejected address is not" do
      assert ApprovedAddress.usable?(approved(:rejected), ~U[2026-08-31 12:00:00Z]) == false
    end

    test "a pending address before its activation is not usable" do
      a = approved(:pending, ~U[2026-09-01 12:00:00Z])
      assert ApprovedAddress.usable?(a, ~U[2026-08-31 12:00:00Z]) == false
    end

    test "a pending address after its activation is usable" do
      a = approved(:pending, ~U[2026-08-30 12:00:00Z])
      assert ApprovedAddress.usable?(a, ~U[2026-08-31 12:00:00Z]) == true
    end

    test "pending with no stated activation is nil — unknown, not usable" do
      # An allow-list exists so a stolen account cannot add an address and drain it
      # immediately. Reading an unstated activation as "usable now" removes the protection.
      assert ApprovedAddress.usable?(approved(:pending), ~U[2026-08-31 12:00:00Z]) == nil
    end
  end

  describe "DepositAddress" do
    test "memo_required defaults to nil, which is not false" do
      # A deposit sent without a required memo arrives in the venue's omnibus wallet and is
      # credited to nobody. "Nobody said" and "not needed" must stay distinguishable.
      address = %DepositAddress{
        asset: "XRP",
        network: "ripple",
        address: "rABC",
        provider: :reference
      }

      assert address.memo_required == nil
      refute address.memo_required == false
    end

    test "network is enforced, because an address without one is not usable" do
      assert_raise ArgumentError, fn ->
        struct!(DepositAddress, asset: "USDC", address: "0xabc", provider: :reference)
      end
    end
  end
end
