defmodule Broken.Wanted.Fake do
  @moduledoc false
  # A configurable fake: what `wanted/1` answers and what `coverage/1` reports are chosen by
  # the test, per process, so the fixtures below differ in one fact each.
  @spec subscribe([String.t()], keyword()) :: :ok
  def subscribe(symbols, _opts) do
    Process.put(:wanted_fake_symbols, symbols)
    :ok
  end

  @spec update_symbols([String.t()], keyword()) :: :ok
  def update_symbols(symbols, _opts) do
    Process.put(:wanted_fake_symbols, symbols)
    :ok
  end

  @spec coverage(keyword()) :: %{String.t() => atom()}
  def coverage(_opts) do
    covered = Process.get(:wanted_fake_symbols, [])
    Map.new(covered ++ Process.get(:wanted_fake_extra_covered, []), &{&1, :stream})
  end

  @spec wanted(keyword()) :: term()
  def wanted(_opts) do
    asked = Process.get(:wanted_fake_symbols, [])

    case Process.get(:wanted_fake_mode, :list) do
      :list -> asked
      :map_set -> MapSet.new(asked)
      :drops_one -> Enum.drop(asked, 1)
      :route_map -> Map.new(asked, &{&1, :stream})
    end
  end
end

defmodule Broken.Wanted.NotAdopted do
  @moduledoc false
  @spec subscribe([String.t()], keyword()) :: :ok
  def subscribe(_symbols, _opts), do: :ok

  @spec update_symbols([String.t()], keyword()) :: :ok
  def update_symbols(_symbols, _opts), do: :ok

  @spec coverage(keyword()) :: map()
  def coverage(_opts), do: %{}
end

defmodule DpExchange.Core.WantedConformanceTest do
  # Process-scoped state only, so it is async-safe.
  use ExUnit.Case, async: true

  alias Broken.Wanted.{Fake, NotAdopted}
  alias DpExchange.Core.{AdapterContract, ReferenceVenue}

  @pairs ["BTC-USD", "ETH-USD"]

  describe "wanted_fault/3 (assertion 40)" do
    test "a fake that does not export wanted/1 is never faulted" do
      assert AdapterContract.wanted_fault(NotAdopted, @pairs, []) == nil
    end

    test "a list holding everything subscribed conforms" do
      assert AdapterContract.wanted_fault(Fake, @pairs, []) == nil
    end

    test "a MapSet holding everything subscribed conforms" do
      Process.put(:wanted_fake_mode, :map_set)
      assert AdapterContract.wanted_fault(Fake, @pairs, []) == nil
    end

    test "a symbol subscribed and missing from wanted/1 is named" do
      Process.put(:wanted_fake_mode, :drops_one)

      assert AdapterContract.wanted_fault(Fake, @pairs, []) ==
               {:subscribed_not_wanted, ["BTC-USD"]}
    end

    test "a symbol coverage/1 reports that was never asked for is named" do
      Process.put(:wanted_fake_extra_covered, ["XRP-USD"])

      assert AdapterContract.wanted_fault(Fake, @pairs, []) ==
               {:covered_not_wanted, ["XRP-USD"]}
    end

    test "a route map is not a collection of symbols" do
      Process.put(:wanted_fake_mode, :route_map)

      assert {:not_a_collection, %{} = answer} = AdapterContract.wanted_fault(Fake, @pairs, [])
      assert map_size(answer) == 2
    end

    test "the reference venue exports wanted/1 and conforms" do
      Code.ensure_loaded(ReferenceVenue)
      assert function_exported?(ReferenceVenue, :wanted, 1)
      assert AdapterContract.wanted_fault(ReferenceVenue, ["BTC-USD", "ETH-USD"], []) == nil
    end
  end

  describe "candle_ask_fault/1 (assertion 37)" do
    test "only a non-empty success gives the group something to check" do
      assert AdapterContract.candle_ask_fault({:ok, [:a_bar]}) == nil
      assert AdapterContract.candle_ask_fault({:ok, []}) == {:no_candles, {:ok, []}}
      assert AdapterContract.candle_ask_fault({:error, :x}) == {:no_candles, {:error, :x}}
      assert AdapterContract.candle_ask_fault({:refused, :y}) == {:no_candles, {:refused, :y}}

      assert AdapterContract.candle_ask_fault({:raised, %RuntimeError{}}) ==
               {:no_candles, {:raised, %RuntimeError{}}}
    end
  end

  describe "nothing_examined?/2 (assertion 39)" do
    test "active endpoints none of which was inspected examined nothing" do
      two = [{:get_price, 2}, {:get_trades, 2}]

      assert AdapterContract.nothing_examined?([{:get_price, 2}], [false])
      assert AdapterContract.nothing_examined?(two, [false, false])
    end

    test "one inspected answer is enough, and no active endpoint is not a failure" do
      two = [{:get_price, 2}, {:get_trades, 2}]

      refute AdapterContract.nothing_examined?(two, [false, true])
      refute AdapterContract.nothing_examined?([], [])
    end
  end

  describe "family_reason_fault/3 (assertion 41)" do
    test "an unlisted symbol must be refused :not_listed" do
      assert AdapterContract.family_reason_fault({:refused, :not_listed}, nil, :v) == nil

      assert AdapterContract.family_reason_fault({:refused, :symbol_not_listed}, nil, :v) ==
               {:unlisted_symbol, {:refused, :symbol_not_listed}}

      assert AdapterContract.family_reason_fault({:error, {:invalid_symbol, "X"}}, nil, :v) ==
               {:unlisted_symbol, {:error, {:invalid_symbol, "X"}}}
    end

    test "a padded credential must be {:invalid_credentials, venue}" do
      good = {:error, {:invalid_credentials, :v}}
      assert AdapterContract.family_reason_fault(nil, good, :v) == nil

      assert AdapterContract.family_reason_fault(nil, {:ok, []}, :v) ==
               {:padded_credentials, {:ok, []}}

      wrong_venue = {:error, {:invalid_credentials, :other}}

      assert AdapterContract.family_reason_fault(nil, wrong_venue, :v) ==
               {:padded_credentials, wrong_venue}
    end

    test "an option the venue did not opt in to is not judged" do
      assert AdapterContract.family_reason_fault(nil, nil, :v) == nil
    end

    test "a named option answered with the nil-answer stand-in is faulted, not skipped" do
      assert AdapterContract.family_reason_fault(:nil_answer, nil, :v) ==
               {:unlisted_symbol, :nil_answer}

      assert AdapterContract.family_reason_fault(nil, :nil_answer, :v) ==
               {:padded_credentials, :nil_answer}
    end

    test "the reference venue gives both reasons" do
      assert ReferenceVenue.get_price("NOPE-USD", []) == {:refused, :not_listed}

      assert ReferenceVenue.get_balances(%{api_key: " k\n"}, []) ==
               {:error, {:invalid_credentials, :reference_venue}}

      assert {:ok, [_balance]} = ReferenceVenue.get_balances(%{api_key: "k"}, [])
    end
  end
end
