# The decisions the conformance suite makes inside groups 1, 3, 5, 8, 11, 14, 23 to 30, each
# handed a value that is wrong in one specific way. `contract_teeth_test.exs` does the same
# for the other groups. A check that lives only inside a `test` body in a consuming package
# cannot be shown to fail; these are the same functions the suite calls.

defmodule Broken.Teeth.HalfOptional do
  @moduledoc false
  # `list_instruments/1` is the optional callback; this exports its name at another arity,
  # so a caller at the declared arity gets an `UndefinedFunctionError`.
  @spec list_instruments(term(), term()) :: :ok
  def list_instruments(_a, _b), do: :ok
end

defmodule Broken.Teeth.WholeOptional do
  @moduledoc false
  @spec list_instruments(term()) :: {:ok, list()}
  def list_instruments(_opts), do: {:ok, []}
end

defmodule Broken.Teeth.SetFake do
  @moduledoc false
  # A fake whose subscription set misbehaves in the way `opts[:mode]` names. The set lives in
  # the calling process, so two async tests never share one.
  @spec subscribe([String.t()], keyword()) :: :ok
  def subscribe(symbols, opts) do
    case opts[:mode] do
      :subscribe_replaces -> put(symbols)
      :ignores_second -> if get() == [], do: put(symbols)
      :never_covers -> :ok
      _conforming -> put(Enum.uniq(get() ++ symbols))
    end

    :ok
  end

  @spec update_symbols([String.t()], keyword()) :: :ok
  def update_symbols(symbols, opts) do
    case opts[:mode] do
      :update_adds -> put(Enum.uniq(get() ++ symbols))
      :update_ignored -> :ok
      _conforming -> put(Enum.uniq(symbols))
    end

    :ok
  end

  @spec unsubscribe([String.t()], keyword()) :: :ok
  def unsubscribe(symbols, opts) do
    case opts[:mode] do
      :unsubscribe_ignores -> :ok
      :unsubscribe_clears -> put([])
      _conforming -> put(get() -- symbols)
    end

    :ok
  end

  @spec coverage(keyword()) :: %{String.t() => :stream}
  def coverage(opts) do
    if opts[:mode] == :never_covers, do: %{}, else: Map.new(get(), &{&1, :stream})
  end

  defp get, do: Process.get({__MODULE__, :set}, [])
  defp put(symbols), do: Process.put({__MODULE__, :set}, symbols)
end

defmodule Broken.Teeth.DeliveryFake do
  @moduledoc false
  # A fake whose `subscribe/2` delivers to the process named by `:to`, misbehaving on a nil
  # `:to` or on a lower-case symbol in the way `opts[:mode]` names.
  @spec subscribe([String.t()], keyword()) :: :ok
  def subscribe(symbols, opts) do
    deliver(Keyword.get(opts, :mode, :conforming), Keyword.get(opts, :to), symbols)
    :ok
  end

  defp deliver(:exits_on_nil, nil, _symbols), do: exit(:boom)
  defp deliver(:silent_on_nil, nil, _symbols), do: :ok
  defp deliver(:raises_on_nil, nil, symbols), do: send_all(nil, symbols, & &1)
  defp deliver(:no_upcase, to, symbols), do: send_all(to || self(), symbols, & &1)
  defp deliver(_conforming, to, symbols), do: send_all(to || self(), symbols, &String.upcase/1)

  defp send_all(to, symbols, normalise) do
    for symbol <- symbols, do: send(to, {:dp_exchange, :teeth, %{symbol: normalise.(symbol)}})
    :ok
  end
end

defmodule DpExchange.Core.ContractTeethDecisionsTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{AdapterContract, Capabilities, ReferenceVenue}
  alias DpExchange.Core.Types.{Balance, OrderBook, TopOfBook}
  alias DpExchange.Core.Types.Quote, as: Q

  defp d(text), do: Decimal.new(text)

  @now ~U[2026-08-27 12:00:00Z]
  @pairs ["BTC-USD", "ETH-USD"]

  defp set_fault(mode) do
    AdapterContract.subscription_set_fault(Broken.Teeth.SetFake, @pairs, mode: mode)
  end

  defp nil_recipient(opts, wait) do
    AdapterContract.nil_recipient_fault(Broken.Teeth.DeliveryFake, @pairs, opts, wait)
  end

  defp levels(prices), do: Enum.map(prices, &{d(&1), d("1")})

  defp quote_with(attrs) do
    struct!(Q, [symbol: "BTC-USD", price: d("1"), observed_at: @now, provider: :teeth] ++ attrs)
  end

  defp balance_with(attrs) do
    struct!(
      Balance,
      [currency: "USD", balance: nil, timestamp: @now, provider: :teeth] ++ attrs
    )
  end

  describe "assertion 1: an optional callback is whole or absent" do
    test "a module exporting the name at another arity is named" do
      assert AdapterContract.half_implemented_optionals(Broken.Teeth.HalfOptional) ==
               [{:list_instruments, 1, [2]}]
    end

    test "a whole implementation and an absent one are not faulted" do
      assert AdapterContract.half_implemented_optionals(Broken.Teeth.WholeOptional) == []
      assert AdapterContract.half_implemented_optionals(Broken.OverDeclares) == []
    end
  end

  describe "assertion 3: identity" do
    test "provider_name/0 is a non-blank string" do
      assert AdapterContract.provider_name_fault("Coinbase") == nil
      assert AdapterContract.provider_name_fault("  ") == {:provider_name, "  "}
      assert AdapterContract.provider_name_fault("") == {:provider_name, ""}
      assert AdapterContract.provider_name_fault(nil) == {:provider_name, nil}
      assert AdapterContract.provider_name_fault(:coinbase) == {:provider_name, :coinbase}
    end

    test "runtime_id/0 is the atom of the module's last segment, underscored" do
      assert AdapterContract.runtime_id_fault(DpExchange.Coinbase, :coinbase) == nil
      assert AdapterContract.runtime_id_fault(DpExchange.Some.VenueName, :venue_name) == nil

      assert AdapterContract.runtime_id_fault(DpExchange.Coinbase, :foo) ==
               {:runtime_id, :foo, "coinbase"}

      # An atom that stringifies to a word no segment is, and a string that is not an atom.
      assert AdapterContract.runtime_id_fault(DpExchange.Coinbase, nil) ==
               {:runtime_id, nil, "coinbase"}

      assert AdapterContract.runtime_id_fault(DpExchange.Coinbase, "coinbase") ==
               {:runtime_id, "coinbase", "coinbase"}
    end

    test "asset_classes/0 is a non-empty list of the classes a host switches on" do
      assert AdapterContract.asset_classes_fault([:crypto, :equity]) == nil
      assert AdapterContract.asset_classes_fault([:event_contract]) == nil
      assert AdapterContract.asset_classes_fault([]) == {:asset_classes, []}

      assert AdapterContract.asset_classes_fault([:crypto, :forex]) ==
               {:asset_classes, [:crypto, :forex]}

      assert AdapterContract.asset_classes_fault(nil) == {:asset_classes, nil}
      assert AdapterContract.asset_classes_fault("crypto") == {:asset_classes, "crypto"}
    end
  end

  describe "assertion 5: an active endpoint answers with the struct it promises" do
    test "a struct of another module, a raw map, a stray list entry and a raise are named" do
      balance = balance_with([])

      assert AdapterContract.answer_type_fault({:ok, balance}, [Balance]) == nil
      assert AdapterContract.answer_type_fault({:ok, [balance, balance]}, [Balance]) == nil
      assert AdapterContract.answer_type_fault({:ok, []}, [Balance]) == nil

      assert AdapterContract.answer_type_fault({:ok, balance}, [Q]) == inspect(Balance)

      assert AdapterContract.answer_type_fault({:ok, [balance]}, [Q]) ==
               "a list containing #{inspect(Balance)}"

      assert AdapterContract.answer_type_fault({:ok, [balance, :raw]}, [Balance]) ==
               "a list containing :raw"

      assert AdapterContract.answer_type_fault({:ok, %{currency: "USD"}}, [Balance]) =~
               "a raw map"

      assert AdapterContract.answer_type_fault({:raised, %ArgumentError{message: "boom"}}, [Q]) ==
               "a raise: boom"
    end

    test "a refusal or an error is not a success, so it is not judged" do
      assert AdapterContract.answer_type_fault({:error, :nope}, [Balance]) == nil
      assert AdapterContract.answer_type_fault({:refused, :not_listed}, [Balance]) == nil
      assert AdapterContract.answer_type_fault(:ok, [Balance]) == nil
    end
  end

  describe "assertion 8: declarations are consistent with each other" do
    test "an absence the capabilities do not declare unsupported is named" do
      caps =
        Capabilities.new(
          endpoints: %{{:get_transfers, 2} => :unsupported, {:get_price, 2} => :proven},
          supported_quotes: ~w(USD)
        )

      assert AdapterContract.unrecorded_absences([{:get_transfers, 2}], caps) == []

      assert AdapterContract.unrecorded_absences([{:get_transfers, 2}, {:get_price, 2}], caps) ==
               [{:get_price, 2}]

      # An endpoint never named is active by default, so it cannot be an absence either.
      assert AdapterContract.unrecorded_absences([{:get_trades, 2}], caps) == [{:get_trades, 2}]
    end

    test "a streamed kind whose pull endpoint the venue does not serve is named" do
      absent = [{:get_price, 2}, {:get_trades, 2}]

      assert AdapterContract.streamed_but_absent(absent, [:quotes, :candles]) ==
               [{:quotes, {:get_price, 2}}]

      assert AdapterContract.streamed_but_absent(absent, [:trades, :quotes]) ==
               [{:quotes, {:get_price, 2}}, {:trades, {:get_trades, 2}}]

      assert AdapterContract.streamed_but_absent(absent, []) == []
      assert AdapterContract.streamed_but_absent([], [:quotes]) == []
    end

    test "a streamable kind this contract has no word for is named, in either list" do
      caps = %Capabilities{
        endpoints: %{},
        supported_quotes: ["USD"],
        streamable: [:quotes, :bogus],
        authenticated_streamable: [:bogus, :mystery]
      }

      assert AdapterContract.unknown_stream_kinds(caps) == [:bogus, :mystery]

      known = %Capabilities{caps | streamable: [:quotes], authenticated_streamable: [:orders]}
      assert AdapterContract.unknown_stream_kinds(known) == []
    end
  end

  describe "assertion 11: no facade answer carries a process" do
    test "a pid, port or reference anywhere inside an answer is found" do
      ref = make_ref()

      assert AdapterContract.carries_process?(self())
      assert AdapterContract.carries_process?({:ok, [%{pid: self()}]})
      assert AdapterContract.carries_process?({:ok, %{ref => 1}})
      assert AdapterContract.carries_process?({:ok, balance_with(currency: self())})
      assert AdapterContract.carries_process?([1, 2, {:nested, ref}])
    end

    test "plain data, structs of data and dates are not" do
      refute AdapterContract.carries_process?({:ok, [balance_with([])]})
      refute AdapterContract.carries_process?(%{a: [1, "two", :three, @now, d("1.5")]})
      refute AdapterContract.carries_process?(nil)
    end
  end

  describe "assertions 14 and 23: venue time is the venue's own, observed time is there" do
    test "a conforming Quote, OrderBook and TopOfBook are not faulted" do
      assert AdapterContract.time_fault(quote_with(venue_time: nil), Q) == nil
      assert AdapterContract.time_fault(quote_with(venue_time: @now), Q) == nil

      book = %OrderBook{symbol: "X", bids: [], asks: [], observed_at: @now, provider: :teeth}
      assert AdapterContract.time_fault(book, OrderBook) == nil

      top = %TopOfBook{symbol: "X", observed_at: @now, provider: :teeth}
      assert AdapterContract.time_fault(top, TopOfBook) == nil
    end

    test "an epoch integer, a NaiveDateTime or a string in venue_time is named" do
      assert AdapterContract.time_fault(quote_with(venue_time: 1_700_000_000), Q) ==
               {:venue_time, 1_700_000_000}

      naive = ~N[2026-08-27 12:00:00]
      assert AdapterContract.time_fault(quote_with(venue_time: naive), Q) == {:venue_time, naive}

      assert AdapterContract.time_fault(quote_with(venue_time: "2026-08-27"), Q) ==
               {:venue_time, "2026-08-27"}

      top = %TopOfBook{symbol: "X", observed_at: @now, venue_time: 5, provider: :teeth}
      assert AdapterContract.time_fault(top, TopOfBook) == {:venue_time, 5}
    end

    test "a missing or non-DateTime observed_at is named, before venue_time" do
      assert AdapterContract.time_fault(quote_with(observed_at: nil), Q) == {:observed_at, nil}

      assert AdapterContract.time_fault(quote_with(observed_at: 1, venue_time: 2), Q) ==
               {:observed_at, 1}
    end

    test "a struct of another kind, or no struct, is named" do
      top = %TopOfBook{symbol: "X", observed_at: @now, provider: :teeth}

      assert AdapterContract.time_fault(top, Q) == {:wrong_struct, top}
      plain = %{observed_at: @now}
      assert AdapterContract.time_fault(plain, Q) == {:wrong_struct, plain}
      assert AdapterContract.time_fault(:nope, Q) == {:wrong_struct, :nope}
    end
  end

  describe "assertion 24: a balance names the asset it is a balance of" do
    test "a conforming Balance is not faulted, and an unknown :balance is allowed" do
      assert AdapterContract.balance_fault(balance_with([])) == nil
      assert AdapterContract.balance_fault(balance_with(balance: d("0"))) == nil
    end

    test "a missing or blank currency, timestamp or provider is named" do
      assert AdapterContract.balance_fault(balance_with(currency: nil)) == {:currency, nil}
      assert AdapterContract.balance_fault(balance_with(currency: "")) == {:currency, ""}
      assert AdapterContract.balance_fault(balance_with(currency: "  ")) == {:currency, "  "}
      assert AdapterContract.balance_fault(balance_with(currency: :usd)) == {:currency, :usd}

      assert AdapterContract.balance_fault(balance_with(timestamp: nil)) == {:timestamp, nil}

      assert AdapterContract.balance_fault(balance_with(timestamp: 1_700_000_000)) ==
               {:timestamp, 1_700_000_000}

      assert AdapterContract.balance_fault(balance_with(provider: nil)) == {:provider, nil}
    end

    test "a raw map is not a Balance" do
      raw = %{currency: "USD"}
      assert AdapterContract.balance_fault(raw) == {:wrong_struct, raw}
    end
  end

  describe "assertion 25: books are best first, and the fixture is deep enough to tell" do
    test "bids descending and asks ascending are not faulted" do
      assert AdapterContract.book_ordering_fault(levels(~w(3 2 1)), :desc) == nil
      assert AdapterContract.book_ordering_fault(levels(~w(1 2 3)), :asc) == nil
    end

    test "the venue's row order kept the wrong way round is named" do
      assert AdapterContract.book_ordering_fault(levels(~w(1 2)), :desc) ==
               {:unsorted, [d("1"), d("2")]}

      assert AdapterContract.book_ordering_fault(levels(~w(2 1)), :asc) ==
               {:unsorted, [d("2"), d("1")]}

      # One level out of place in the middle is as wrong as a reversed side.
      assert {:unsorted, _prices} = AdapterContract.book_ordering_fault(levels(~w(3 1 2)), :desc)
    end

    test "a side too thin to be misordered is named, so the check cannot pass on nothing" do
      assert AdapterContract.book_ordering_fault(levels(~w(1)), :desc) == {:too_thin, 1}
      assert AdapterContract.book_ordering_fault([], :asc) == {:too_thin, 0}
    end

    test "a level without a Decimal price, or a side that is not a list, is named" do
      bad = {nil, d("1")}

      assert AdapterContract.book_ordering_fault([bad | levels(~w(2 1))], :desc) ==
               {:unreadable_level, bad}

      assert AdapterContract.book_ordering_fault([:x, :y], :desc) == {:unreadable_level, :x}

      assert AdapterContract.book_ordering_fault({:not, :a_list}, :desc) ==
               {:unreadable_level, {:not, :a_list}}
    end
  end

  describe "assertion 37: the reference venue's candles sit on every declared width's grid" do
    test "a bar for each width it declares opens on that width's boundary" do
      widths = ReferenceVenue.capabilities().historical_timeframes
      assert widths != []

      for width <- widths do
        assert {:ok, [_bar | _rest] = candles} =
                 ReferenceVenue.get_historical_prices("BTC-USDC", width, [], [])

        assert AdapterContract.candle_series_fault(candles, width, [:crypto]) == nil
      end
    end
  end

  describe "assertion 38: the reference venue refuses a depth it cannot honour" do
    test "a depth that is not a whole number of levels it carries is invalid_option" do
      for bad <- [0, -1, 3, 1.5, "1", :all] do
        assert ReferenceVenue.get_order_book("BTC-USDC", depth: bad) ==
                 {:error, {:invalid_option, :depth, bad}}
      end
    end

    test "limit stays tolerated and an absent depth returns the whole book" do
      assert {:ok, book} = ReferenceVenue.get_order_book("BTC-USDC", limit: 1)
      assert length(book.bids) == 2 and length(book.asks) == 2
    end
  end

  describe "assertion 26: subscribe adds, update_symbols replaces, unsubscribe removes" do
    test "a fake that keeps the three operations apart is not faulted" do
      assert set_fault(:conforming) == nil
    end

    test "each way of collapsing them is named" do
      assert set_fault(:subscribe_replaces) == {:subscribe_dropped, ["BTC-USD"]}
      assert set_fault(:ignores_second) == {:subscribe_missed, "ETH-USD"}
      assert set_fault(:unsubscribe_ignores) == {:unsubscribe_left, "BTC-USD"}
      assert set_fault(:unsubscribe_clears) == {:unsubscribe_overreached, "ETH-USD"}
      assert set_fault(:update_adds) == {:update_left, "ETH-USD"}
      assert set_fault(:update_ignored) == {:update_not_taken, "BTC-USD"}
    end

    test "a fake that reports no coverage at all cannot be compared, and is named" do
      assert set_fault(:never_covers) == {:never_covered, "BTC-USD"}
    end
  end

  describe "assertion 27: a forwarded nil is an absent option" do
    test "a fake that delivers to the caller is not faulted" do
      assert nil_recipient([mode: :conforming], 5_000) == nil
    end

    # The fakes below send synchronously from the calling process, so a message that is going
    # to arrive is already in the mailbox: the short wait decides nothing.
    test "a fake that goes quiet on nil delivers nothing, and is named" do
      assert nil_recipient([mode: :silent_on_nil], 100) == :nothing_delivered
    end

    test "a fake that raises or exits on nil is named, whichever way it fails" do
      assert {:raised, %ArgumentError{}} = nil_recipient([mode: :raises_on_nil], 100)
      assert nil_recipient([mode: :exits_on_nil], 100) == {:escaped, :exit, :boom}
    end
  end

  describe "assertion 28: a streaming call answers when no feed is running" do
    test "a value of every allowed shape is not faulted" do
      assert AdapterContract.streaming_call_fault(fn -> :ok end) == nil
      assert AdapterContract.streaming_call_fault(fn -> {:error, :feed_not_started} end) == nil
      assert AdapterContract.streaming_call_fault(fn -> %{"BTC-USD" => :stream} end) == nil
    end

    test "an exit, a throw and a raise in the caller are named" do
      assert AdapterContract.streaming_call_fault(fn -> exit(:noproc) end) ==
               {:escaped, :exit, :noproc}

      assert AdapterContract.streaming_call_fault(fn -> throw(:up) end) == {:escaped, :throw, :up}

      assert {:escaped, :error, %ArgumentError{}} =
               AdapterContract.streaming_call_fault(fn -> raise ArgumentError, "x" end)
    end

    test "any other answer is not a value the callback allows" do
      assert AdapterContract.streaming_call_fault(fn -> nil end) == {:not_a_value, nil}
      assert AdapterContract.streaming_call_fault(fn -> {:ok, 1} end) == {:not_a_value, {:ok, 1}}
      assert AdapterContract.streaming_call_fault(fn -> [] end) == {:not_a_value, []}
    end
  end

  describe "assertion 29: a lower-case subscription is delivered under the canonical symbol" do
    test "a fake that upper-cases is not faulted" do
      opts = [mode: :conforming]

      assert AdapterContract.lower_case_delivery_fault(
               Broken.Teeth.DeliveryFake,
               "BTC-USD",
               opts,
               5_000
             ) == nil
    end

    test "a fake that delivers the symbol as given certifies silence, and is named" do
      opts = [mode: :no_upcase]

      assert AdapterContract.lower_case_delivery_fault(
               Broken.Teeth.DeliveryFake,
               "BTC-USD",
               opts,
               100
             ) == :not_delivered
    end
  end

  describe "assertion 30: a quote's volume states its window" do
    test "no volume and no window, or a volume and a stated window, are not faulted" do
      assert AdapterContract.volume_window_fault(quote_with([])) == nil

      for window <- Q.volume_windows() do
        assert AdapterContract.volume_window_fault(
                 quote_with(volume: d("5"), volume_window: window)
               ) == nil
      end
    end

    test "a volume with no window, or one outside the vocabulary, is named" do
      assert AdapterContract.volume_window_fault(quote_with(volume: d("5"))) ==
               {:unstated_window, nil}

      bogus = quote_with(volume: d("5"), volume_window: :bogus)
      assert AdapterContract.volume_window_fault(bogus) == {:unstated_window, :bogus}
    end

    test "a window with no volume to describe is named" do
      assert AdapterContract.volume_window_fault(quote_with(volume_window: :print)) ==
               {:window_without_volume, :print}
    end

    test "a value that is not a Quote is named" do
      assert AdapterContract.volume_window_fault(:nope) == {:wrong_struct, :nope}
    end
  end
end
