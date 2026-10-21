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

defmodule Broken.Teeth.NoOptionals do
  @moduledoc false
  # Implements none of the optional callbacks. Defined here rather than borrowing a module from
  # `contract_teeth_test.exs`: test files load in parallel, so a module another file defines may
  # not exist yet when this one runs, and the test failed with `:nofile` depending on timing.
  @spec provider_name() :: String.t()
  def provider_name, do: "no-optionals"
end

defmodule Broken.Teeth.NoisyFake do
  @moduledoc false
  # Delivers one conforming notice and one that puts venue text in `details.reason`, the way
  # a feed that quotes an error into `reason` does. Sent from `subscribe/2`, to the caller.
  alias DpExchange.Core.Notice

  @spec subscribe_notices(keyword()) :: :ok
  def subscribe_notices(_opts), do: :ok

  @spec subscribe([String.t()], keyword()) :: :ok
  def subscribe(_symbols, opts) do
    to = Keyword.fetch!(opts, :to)
    send(to, {:dp_exchange, :noisy, Notice.new(:link_up, :noisy)})

    send(
      to,
      {:dp_exchange, :noisy, Notice.new(:link_down, :noisy, details: %{reason: "econnrefused"})}
    )

    :ok
  end

  @spec unsubscribe([String.t()], keyword()) :: :ok
  def unsubscribe(_symbols, _opts), do: :ok
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
      :tombstones -> put(["STALE" | get() -- symbols])
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

defmodule Broken.Teeth.RawChildSpec do
  @moduledoc false
  # Stores the consumer's `:credentials` map as given in the `{module, :start_link, [opts]}` MFA
  # a supervisor keeps and OTP prints on every child crash: the leak assertion 22 exists for.
  @spec child_spec(keyword()) :: map()
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
end

defmodule Broken.Teeth.NestedChildSpec do
  @moduledoc false
  # The same leak one level down: the secret rides inside another term in the start args.
  @spec child_spec(keyword()) :: map()
  def child_spec(opts) do
    wrapped = %{auth: {:basic, Keyword.fetch!(opts, :credentials)}}
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[config: wrapped]]}}
  end
end

defmodule Broken.Teeth.DroppingChildSpec do
  @moduledoc false
  # Takes the credentials and keeps none of them in the spec, which is fine.
  @spec child_spec(keyword()) :: map()
  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
end

defmodule Broken.Teeth.LeakyProcess do
  @moduledoc false
  # Keeps the consumer's credentials map as the process state, as four venues' Feed and
  # Socket did: OTP prints it in full in a crash report, and `:sys.get_status/2` on demand.
  use GenServer

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(credentials), do: GenServer.start_link(__MODULE__, credentials)

  @impl true
  def init(credentials), do: {:ok, %{credentials: credentials, subscribed: []}}
end

defmodule Broken.Teeth.DictionaryLeakProcess do
  @moduledoc false
  # Keeps nothing in its state, but the secret sits in the process dictionary, which
  # `:sys.get_status/2` carries too.
  use GenServer

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(credentials), do: GenServer.start_link(__MODULE__, credentials)

  @impl true
  def init(credentials) do
    Process.put(:auth, credentials)
    {:ok, %{}}
  end
end

defmodule Broken.Teeth.RedactingProcess do
  @moduledoc false
  # Holds the raw map but redacts it in `format_status/1`, the other legitimate fix.
  use GenServer

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(credentials), do: GenServer.start_link(__MODULE__, credentials)

  @impl true
  def init(credentials), do: {:ok, %{credentials: credentials}}

  @impl true
  def format_status(status) do
    Map.update(status, :state, %{}, fn state -> %{state | credentials: :redacted} end)
  end
end

defmodule Broken.Teeth.Probes do
  @moduledoc false
  # `process_probe:` functions, one per answer the group has to judge.
  alias Broken.Teeth.{DictionaryLeakProcess, LeakyProcess, RedactingProcess}
  alias DpExchange.Core.ReferenceVenue.ProcessProbe

  @spec leaky(map()) :: GenServer.on_start()
  def leaky(credentials), do: LeakyProcess.start_link(credentials)

  @spec dictionary(map()) :: GenServer.on_start()
  def dictionary(credentials), do: DictionaryLeakProcess.start_link(credentials)

  @spec redacting(map()) :: GenServer.on_start()
  def redacting(credentials), do: RedactingProcess.start_link(credentials)

  # A clean process first and a leaking one second: the second is still found.
  @spec two(map()) :: {:ok, [pid()]}
  def two(credentials) do
    {:ok, clean} = ProcessProbe.start_link(credentials)
    {:ok, leaky} = LeakyProcess.start_link(credentials)
    {:ok, [clean, leaky]}
  end

  @spec refuses(map()) :: {:error, :no_network_fake}
  def refuses(_credentials), do: {:error, :no_network_fake}

  @spec nothing(map()) :: {:ok, [pid()]}
  def nothing(_credentials), do: {:ok, []}

  @spec dead(map()) :: {:ok, pid()}
  def dead(_credentials) do
    # A pid that answers nothing to `:sys`: it has already exited.
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> {:ok, pid}
    after
      5_000 -> {:ok, pid}
    end
  end
end

defmodule Broken.Teeth.LaxWrites do
  @moduledoc false
  # Previews and replaces whatever it is handed: the request is never read.
  @spec preview_order(map(), term(), keyword()) :: {:ok, map()}
  def preview_order(_credentials, _request, _opts), do: {:ok, %{}}

  @spec replace_order(map(), String.t(), term(), keyword()) :: {:ok, map()}
  def replace_order(_credentials, _id, _changes, _opts), do: {:ok, %{}}
end

defmodule Broken.Teeth.LaxOrders do
  @moduledoc false
  # Places whatever it is handed: a float quantity, a zero price, a NaN are all an order.
  @spec place_order(map(), term(), keyword()) :: {:ok, map()}
  def place_order(_credentials, _request, _opts), do: {:ok, %{id: "placed"}}
end

defmodule Broken.Teeth.PartialOrders do
  @moduledoc false
  # Checks the quantity and forgets the price: a NaN price is placed.
  @spec place_order(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def place_order(_credentials, %{quantity: quantity}, _opts) do
    if valid?(quantity), do: {:ok, %{id: "placed"}}, else: {:error, {:invalid_quantity, quantity}}
  end

  defp valid?(%Decimal{} = value),
    do: not Decimal.nan?(value) and not Decimal.inf?(value) and Decimal.gt?(value, 0)

  defp valid?(_other), do: false
end

defmodule Broken.Teeth.RewritingOrders do
  @moduledoc false
  # Refuses the right requests with the right tags, but hands back a rewritten value (a
  # string) where the caller's own was sent, so a caller matching its value does not match.
  @spec place_order(map(), map(), keyword()) :: {:error, term()}
  def place_order(_credentials, %{quantity: quantity, price: price}, _opts) do
    if bad?(quantity),
      do: {:error, {:invalid_quantity, inspect(quantity)}},
      else: {:error, {:invalid_price, inspect(price)}}
  end

  defp bad?(%Decimal{} = value), do: Decimal.nan?(value) or Decimal.inf?(value)
  defp bad?(_other), do: true
end

defmodule Broken.Teeth.RaisingOrders do
  @moduledoc false
  # Raises where the convention answers a tuple.
  @spec place_order(map(), term(), keyword()) :: no_return()
  def place_order(_credentials, _request, _opts), do: raise(ArgumentError, "boom")
end

defmodule Broken.Teeth.RaisingWrites do
  @moduledoc false
  # Raises where the convention answers a tuple.
  @spec preview_order(map(), term(), keyword()) :: no_return()
  def preview_order(_credentials, _request, _opts), do: raise(ArgumentError, "boom")

  @spec replace_order(map(), String.t(), term(), keyword()) :: no_return()
  def replace_order(_credentials, _id, _changes, _opts), do: raise(ArgumentError, "boom")
end

defmodule DpExchange.Core.ContractTeethDecisionsTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{AdapterContract, Capabilities, Notice, ReferenceVenue}
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
      assert AdapterContract.half_implemented_optionals(Broken.Teeth.NoOptionals) == []
    end
  end

  describe "assertion 46: a no-request call refuses a transport key" do
    test "the refusal naming :timeout is the only conforming answer" do
      assert AdapterContract.no_request_transport_fault({:error, {:unknown_option, :timeout}}) ==
               nil
    end

    test "an answer that carried on is ignored, not conforming" do
      assert AdapterContract.no_request_transport_fault(:ok) == {:ignored, :ok}
      assert AdapterContract.no_request_transport_fault({:ok, []}) == {:ignored, {:ok, []}}
    end

    test "a raise, and a refusal naming another key, are faults of their own" do
      raised = {:raised, %ArgumentError{message: "boom"}}
      assert AdapterContract.no_request_transport_fault(raised) == {:raised, raised}

      other = {:error, {:unknown_option, :to}}
      assert AdapterContract.no_request_transport_fault(other) == {:wrong_error, other}

      assert AdapterContract.no_request_transport_fault({:exit, :noproc}) ==
               {:raised, {:exit, :noproc}}
    end
  end

  describe "assertion 44: the fake exports every public function the facade does" do
    test "a function the fake lacks is named, at the arity it is missing" do
      assert AdapterContract.missing_fake_exports(
               Broken.Teeth.HalfOptional,
               Broken.Teeth.NoOptionals
             ) == [{:list_instruments, 2}]

      assert AdapterContract.missing_fake_exports(
               Broken.Teeth.HalfOptional,
               Broken.Teeth.WholeOptional
             ) == [{:list_instruments, 2}]
    end

    test "the same name at another arity does not stand in for the facade's" do
      assert AdapterContract.missing_fake_exports(
               Broken.Teeth.WholeOptional,
               Broken.Teeth.HalfOptional
             ) == [{:list_instruments, 1}]
    end

    test "a fake exporting the same functions, or the same module, is not faulted" do
      assert AdapterContract.missing_fake_exports(
               Broken.Teeth.WholeOptional,
               Broken.Teeth.WholeOptional
             ) == []

      assert AdapterContract.missing_fake_exports(ReferenceVenue, ReferenceVenue) == []
    end
  end

  describe "assertion 45: the notices a fake delivers follow the documented shapes" do
    test "a batch is judged notice by notice, naming the kind" do
      notices = [
        Notice.new(:link_up, :v),
        Notice.new(:link_down, :v, details: %{reason: "text"}),
        Notice.new(:refusal, :v)
      ]

      assert AdapterContract.notice_batch_faults(notices) == [
               {:link_down, {:reason_not_matchable, "text"}},
               {:refusal, :refusal_without_symbols}
             ]

      assert AdapterContract.notice_batch_faults([]) == []
      assert AdapterContract.notice_batch_faults([:nope]) == [{nil, {:not_a_notice, :nope}}]
    end

    test "a fake delivering a text reason is caught, and the count says what was judged" do
      assert {2, [{:link_down, {:reason_not_matchable, "econnrefused"}}]} =
               AdapterContract.captured_notice_faults(
                 Broken.Teeth.NoisyFake,
                 ["BTC-USD"],
                 [],
                 nil,
                 50
               )
    end

    test "a fake that delivers no notice is judged on nothing, and says so with a zero" do
      # The quiet period is the only guard on "nothing was sent", so it is a real window.
      assert AdapterContract.captured_notice_faults(ReferenceVenue, ["ETH-USD"], [], nil, 500) ==
               {0, []}
    end

    test "a call that raises is a fault, not a pass" do
      assert {0, [{:raised, %UndefinedFunctionError{}}]} =
               AdapterContract.captured_notice_faults(
                 Broken.Teeth.NoOptionals,
                 ["BTC-USD"],
                 [],
                 nil,
                 50
               )
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

    test "a NaN price is named, not handed to Decimal.compare/2, which raises on it" do
      nan_level = {Decimal.new("NaN"), d("1")}

      assert AdapterContract.book_ordering_fault([nan_level | levels(~w(2 1))], :desc) ==
               {:unreadable_level, nan_level}

      assert AdapterContract.book_ordering_fault(levels(~w(1 2)) ++ [nan_level], :asc) ==
               {:unreadable_level, nan_level}
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
    # to arrive is already in the mailbox. The window is still the full 500 ms a quiet period
    # guarding a negative gets: it costs nothing on the positive path and cannot be short.
    test "a fake that goes quiet on nil delivers nothing, and is named" do
      assert nil_recipient([mode: :silent_on_nil], 500) == :nothing_delivered
    end

    test "a fake that raises or exits on nil is named, whichever way it fails" do
      assert {:raised, %ArgumentError{}} = nil_recipient([mode: :raises_on_nil], 500)
      assert nil_recipient([mode: :exits_on_nil], 500) == {:escaped, :exit, :boom}
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
               500
             ) == :not_delivered
    end
  end

  describe "assertion 43: every endpoint is probed, and every exclusion has a written reason" do
    test "the probed endpoints and the exclusions partition the whole behaviour" do
      callbacks = DpExchange.Core.Venue.behaviour_info(:callbacks)
      excluded = AdapterContract.unknown_option_exclusions()
      probed = AdapterContract.unknown_option_probed(callbacks)

      assert Enum.sort(probed ++ Map.keys(excluded)) == Enum.sort(callbacks)
      assert probed -- Map.keys(excluded) == probed

      # An exclusion for a callback that no longer exists would be a stale decision.
      assert Map.keys(excluded) -- callbacks == []
    end

    test "each exclusion states a reason, and a write is never one of them" do
      for {{name, arity}, reason} <- AdapterContract.unknown_option_exclusions() do
        assert is_binary(reason) and String.length(reason) > 20,
               "#{name}/#{arity} is excluded without a reason"
      end

      excluded = Map.keys(AdapterContract.unknown_option_exclusions())

      for write <- [{:place_order, 3}, {:withdraw, 5}, {:convert, 4}, {:cancel_all_orders, 2}] do
        refute write in excluded
      end

      for read <- AdapterContract.unknown_option_strict(), do: refute(read in excluded)
    end

    test "the five original reads stay judged on the probe alone" do
      assert Enum.sort(AdapterContract.unknown_option_strict()) ==
               Enum.sort([
                 {:get_price, 2},
                 {:get_top_of_book, 2},
                 {:get_symbols, 1},
                 {:get_order_book, 2},
                 {:get_trades, 2}
               ])

      assert AdapterContract.unknown_option_fault(:strict, {:refused, :not_listed}) ==
               {:ignored, {:refused, :not_listed}}

      assert AdapterContract.unknown_option_fault(:strict, {:ok, 1}) == {:ignored, {:ok, 1}}
      assert AdapterContract.unknown_option_fault(:strict, :ok) == {:ignored, :ok}
    end

    test "a write whose plain call succeeded is judged: ignoring the key is a fault" do
      probe = AdapterContract.unknown_option_probe()
      refusal = {:error, {:unknown_option, probe}}

      for baseline <- [{:ok, %{id: 1}}, :ok] do
        assert AdapterContract.unknown_option_fault(baseline, refusal) == nil
        assert AdapterContract.unknown_option_fault(baseline, {:ok, 1}) == {:ignored, {:ok, 1}}
        assert AdapterContract.unknown_option_fault(baseline, :ok) == {:ignored, :ok}

        assert AdapterContract.unknown_option_fault(baseline, {:error, :not_supported}) == nil

        assert AdapterContract.unknown_option_fault(baseline, {:error, {:invalid_amount, 1}}) ==
                 {:wrong_error, {:error, {:invalid_amount, 1}}}

        assert {:raised, {:exit, :boom}} =
                 AdapterContract.unknown_option_fault(baseline, {:exit, :boom})
      end
    end

    test "a call the fake refused for its own reason is not judged, but cannot succeed or raise" do
      baseline = {:refused, :not_found}
      other = {:error, {:invalid_address, "x"}}

      assert AdapterContract.unknown_option_fault(baseline, {:refused, :not_found}) == nil
      assert AdapterContract.unknown_option_fault(other, other) == nil

      # A probe cannot turn a refusal into a success.
      assert AdapterContract.unknown_option_fault(baseline, {:ok, 1}) == {:ignored, {:ok, 1}}
      assert AdapterContract.unknown_option_fault(baseline, :ok) == {:ignored, :ok}

      assert {:raised, {:raised, %ArgumentError{}}} =
               AdapterContract.unknown_option_fault(baseline, {:raised, %ArgumentError{}})
    end

    test "evidence is a judged answer, or the refusal of the probe itself" do
      refusal = {:error, {:unknown_option, AdapterContract.unknown_option_probe()}}

      assert AdapterContract.unknown_option_evidence?(:strict, {:ok, 1})
      assert AdapterContract.unknown_option_evidence?({:ok, 1}, {:ok, 1})
      assert AdapterContract.unknown_option_evidence?(:ok, :ok)
      assert AdapterContract.unknown_option_evidence?({:refused, :not_found}, refusal)

      refute AdapterContract.unknown_option_evidence?({:refused, :not_found}, {:refused, :x})
      refute AdapterContract.unknown_option_evidence?({:error, :x}, {:error, :x})
      refute AdapterContract.unknown_option_judged?({:raised, %ArgumentError{}})
    end

    test "the reference venue refuses the probe on every write and feed call it serves" do
      probe = AdapterContract.unknown_option_probe()
      refusal = {:error, {:unknown_option, probe}}
      extra = [{probe, true}]
      order = %{symbol: "BTC-USD", side: :buy, order_type: :limit, quantity: "1", price: "1"}

      assert ReferenceVenue.place_order(%{}, order, extra) == refusal
      assert ReferenceVenue.place_orders(%{}, [order], extra) == refusal
      assert ReferenceVenue.preview_order(%{}, order, extra) == refusal
      assert ReferenceVenue.preview_replace(%{}, "id", %{price: "1"}, extra) == refusal
      assert ReferenceVenue.close_position(%{}, "BTC-USD", extra) == refusal
      assert ReferenceVenue.cancel_all_orders(%{}, extra ++ [scope: :account]) == refusal
      assert ReferenceVenue.convert("BTC", "USD", d("1"), extra) == refusal
      assert ReferenceVenue.transfer_internal("BTC", d("1"), [], extra) == refusal
      assert ReferenceVenue.get_order(%{}, "id", extra) == refusal
      assert ReferenceVenue.get_balances(%{}, extra) == refusal
      assert ReferenceVenue.get_orders(%{}, extra) == refusal
      assert ReferenceVenue.unsubscribe(["BTC-USD"], extra) == refusal
      assert ReferenceVenue.market_status(extra) == refusal
      assert ReferenceVenue.get_historical_prices("BTC-USD", "1h", [], extra) == refusal
    end

    test "update_symbols/2 refuses an unknown option before it touches the live set" do
      probe = AdapterContract.unknown_option_probe()
      assert :ok = ReferenceVenue.subscribe(["BTC-USD"], to: self())
      assert map_size(ReferenceVenue.coverage([])) == 1

      assert {:error, {:unknown_option, ^probe}} =
               ReferenceVenue.update_symbols(["ETH-USD"], [{probe, true}])

      assert Map.keys(ReferenceVenue.coverage([])) == ["BTC-USD"]
    end
  end

  describe "assertion 47 (venue rule W4): an amount that is not a positive finite number" do
    test "the invalid amounts cover a float, zero, a negative, NaN and infinity" do
      amounts = AdapterContract.invalid_amounts()

      assert Keyword.keys(amounts) == [:float, :zero, :negative, :nan, :infinity]
      assert is_float(amounts[:float])
      assert Decimal.eq?(amounts[:zero], 0)
      assert Decimal.lt?(amounts[:negative], 0)
      assert Decimal.nan?(amounts[:nan])
      assert Decimal.inf?(amounts[:infinity])
    end

    test "the amount sits where the suite's own argument table puts it" do
      assert AdapterContract.amount_write_endpoints() ==
               [
                 {:stake, 3},
                 {:unstake, 3},
                 {:convert, 4},
                 {:withdraw, 5},
                 {:transfer_internal, 4}
               ]

      assert AdapterContract.amount_position(:stake, 3) == 1
      assert AdapterContract.amount_position(:convert, 4) == 2
      assert AdapterContract.amount_position(:withdraw, 5) == 2
      assert AdapterContract.amount_position(:transfer_internal, 4) == 1
      assert AdapterContract.amount_position(:get_price, 2) == nil

      for {name, arity} <- AdapterContract.amount_write_endpoints() do
        refute AdapterContract.amount_position(name, arity) == nil
      end
    end

    test "only the refusal that echoes the value as given conforms" do
      for {_label, value} <- AdapterContract.invalid_amounts() do
        assert AdapterContract.invalid_amount_fault({:error, {:invalid_amount, value}}, value) ==
                 nil
      end
    end

    test "a success is the dangerous fault, and it is named as accepted" do
      accepted = {:ok, %{id: "w-1"}}
      assert AdapterContract.invalid_amount_fault(accepted, 1.5) == {:accepted, accepted}
      assert AdapterContract.invalid_amount_fault(:ok, d("0")) == {:accepted, :ok}
    end

    test "another reason, another tag, a rewritten value or a raise are faults of their own" do
      for wrong <- [
            {:error, {:invalid_amount, "1.5"}},
            {:error, {:invalid_quantity, 1.5}},
            {:error, :invalid_amount},
            {:error, :not_supported},
            {:refused, :nope}
          ] do
        assert AdapterContract.invalid_amount_fault(wrong, 1.5) == {:wrong_error, wrong}
      end

      assert AdapterContract.invalid_amount_fault({:raised, %FunctionClauseError{}}, 1.5) ==
               {:raised, {:raised, %FunctionClauseError{}}}

      assert {:raised, {:exit, :boom}} = AdapterContract.invalid_amount_fault({:exit, :boom}, 1.5)
    end

    test "the reference venue refuses each invalid amount on convert/4 and transfer_internal/4" do
      for {_label, value} <- AdapterContract.invalid_amounts() do
        refusal = {:error, {:invalid_amount, value}}

        assert ReferenceVenue.convert("BTC", "USD", value, []) == refusal

        assert ReferenceVenue.transfer_internal("BTC", value, [from: "a", to: "b"], []) ==
                 refusal
      end
    end

    test "the reference venue takes a Decimal, an integer or a numeric string as an amount" do
      for amount <- [d("0.5"), 2, "3.25"] do
        assert {:ok, %DpExchange.Core.Types.Conversion{from_amount: %Decimal{}}} =
                 ReferenceVenue.convert("BTC", "USD", amount, [])
      end

      assert {:error, {:invalid_amount, "abc"}} = ReferenceVenue.convert("BTC", "USD", "abc", [])
      assert {:error, {:invalid_amount, nil}} = ReferenceVenue.convert("BTC", "USD", nil, [])
    end

    test "a transfer whose source is its destination is refused, after the amount" do
      assert {:error, {:invalid_transfer, :same_account}} =
               ReferenceVenue.transfer_internal("BTC", d("1"), [from: "a", to: "a"], [])

      assert {:error, {:invalid_amount, +0.0}} =
               ReferenceVenue.transfer_internal("BTC", 0.0, [from: "a", to: "a"], [])
    end
  end

  describe "assertion 48 (venue rule W5): stake and unstake return a StakingTransaction" do
    test "the struct is the only conforming success" do
      staking = struct(DpExchange.Core.Types.StakingTransaction, id: "s-1")

      assert AdapterContract.staking_return_fault({:ok, staking}) == nil
    end

    test "a raw map is named, a refusal is unexamined, a raise is a raise" do
      raw = {:ok, %{"id" => "1"}}
      assert AdapterContract.staking_return_fault(raw) == {:not_a_staking_transaction, raw}

      for unexamined <- [
            {:error, :not_supported},
            {:error, {:missing_credentials, :x}},
            {:refused, :no_such_asset},
            :ok
          ] do
        assert AdapterContract.staking_return_fault(unexamined) == {:unexamined, unexamined}
      end

      assert AdapterContract.staking_return_fault({:raised, %ArgumentError{}}) ==
               {:raised, {:raised, %ArgumentError{}}}

      assert {:raised, {:throw, :x}} = AdapterContract.staking_return_fault({:throw, :x})
    end
  end

  describe "assertion 49 (venue rule W6): an order id nobody placed is {:refused, :not_found}" do
    test "the unknown id is never one the reference venue mints, and two callbacks are asked" do
      id = AdapterContract.unknown_order_id()
      assert is_binary(id) and id != ""
      refute String.starts_with?(id, "order-")

      assert AdapterContract.unknown_id_endpoints() == [{:get_order, 3}, {:cancel_order, 3}]
    end

    test "the documented refusal conforms; an invented order is named" do
      assert AdapterContract.unknown_id_fault({:refused, :not_found}) == nil

      order = {:ok, struct(DpExchange.Core.Types.Order, id: "made-up")}
      assert AdapterContract.unknown_id_fault(order) == {:invented, order}
    end

    test "another refusal, an error, and a raise are faults of their own" do
      for wrong <- [
            {:refused, :other},
            {:error, :not_found},
            {:error, {:missing_option, :account_id}},
            :ok
          ] do
        assert AdapterContract.unknown_id_fault(wrong) == {:wrong_answer, wrong}
      end

      assert {:raised, {:raised, %ArgumentError{}}} =
               AdapterContract.unknown_id_fault({:raised, %ArgumentError{}})
    end

    test "the reference venue knows an order it placed, once, and refuses every other id" do
      request = %{symbol: "BTC-USD", side: :buy, order_type: :limit, quantity: "1", price: "1"}

      assert {:ok, %{id: first}} = ReferenceVenue.place_order(%{}, request, [])
      assert {:ok, %{id: second}} = ReferenceVenue.place_order(%{}, request, [])
      refute first == second

      assert {:ok, %{id: ^first, status: :open}} = ReferenceVenue.get_order(%{}, first, [])
      assert {:ok, %{status: :cancelled}} = ReferenceVenue.cancel_order(%{}, first, [])
      assert {:ok, %{status: :cancelled}} = ReferenceVenue.get_order(%{}, first, [])

      unknown = AdapterContract.unknown_order_id()
      assert ReferenceVenue.get_order(%{}, unknown, []) == {:refused, :not_found}
      assert ReferenceVenue.cancel_order(%{}, unknown, []) == {:refused, :not_found}
      changes = %{price: "2"}
      assert ReferenceVenue.replace_order(%{}, unknown, changes, []) == {:refused, :not_found}
      assert {:error, {:invalid_order_id, nil}} = ReferenceVenue.get_order(%{}, nil, [])
    end

    test "an order placed in one process is not known in another" do
      request = %{symbol: "BTC-USD", side: :buy, order_type: :limit, quantity: "1", price: "1"}
      {:ok, %{id: id}} = ReferenceVenue.place_order(%{}, request, [])

      task = Task.async(fn -> ReferenceVenue.get_order(%{}, id, []) end)

      assert Task.await(task, 5_000) == {:refused, :not_found}
    end

    test "a closing order is minted with its own id and is then readable" do
      assert {:ok, %{id: id, side: :sell}} = ReferenceVenue.close_position(%{}, "BTC-USD", [])
      assert {:ok, %{id: ^id}} = ReferenceVenue.get_order(%{}, id, [])
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

  describe "assertion 17: a stripped credential is refused, not served and not a crash" do
    test "a success is named, a raise, exit or throw is named, a refusal is not a fault" do
      assert AdapterContract.credential_gate_fault({:ok, 1}) == {:succeeded, {:ok, 1}}

      assert {:raised, {:raised, _exception}} =
               AdapterContract.credential_gate_fault({:raised, %{}})

      assert {:raised, {:exit, :boom}} = AdapterContract.credential_gate_fault({:exit, :boom})
      assert {:raised, {:throw, 1}} = AdapterContract.credential_gate_fault({:throw, 1})

      assert AdapterContract.credential_gate_fault({:error, {:missing_credentials, :v}}) == nil
      assert AdapterContract.credential_gate_fault({:refused, :nope}) == nil
      # A callback that returns a bare value cannot be `{:ok, _}`.
      assert AdapterContract.credential_gate_fault(:ok) == nil
    end

    test "the reference venue's stripped read is a tuple refusal or no fault" do
      answer = ReferenceVenue.get_order(%{}, "id", credentials: %{})
      assert AdapterContract.credential_gate_fault(answer) == nil
    end
  end

  describe "assertion 50: preview and replace hold the order-write discipline" do
    @request %{symbol: "BTC-USD", side: :buy, order_type: :limit, quantity: "1", price: "1"}

    defp discipline_cases do
      AdapterContract.order_write_discipline_cases(
        [%{}, @request, []],
        [%{}, "order-1", %{price: "1"}, []]
      )
    end

    defp discipline_faults(module) do
      caps = ReferenceVenue.capabilities()
      cases = AdapterContract.eligible_cases(module, caps, discipline_cases())
      {length(cases), AdapterContract.case_faults(module, cases)}
    end

    test "the cases are place_order's refusals for preview and an empty or non-map change" do
      cases = discipline_cases()

      assert {:preview_order, [%{}, "not-an-order-request", []],
              {:invalid_order_request, "not-an-order-request"}} in cases

      assert {:preview_order, [%{}, Map.delete(@request, :order_type), []],
              {:missing_field, :order_type}} in cases

      for bad <- [%{}, nil, "price", [price: "1"]] do
        assert {:replace_order, [%{}, "order-1", bad, []], {:invalid_order_request, bad}} in cases
      end
    end

    test "the reference venue passes every case" do
      assert {9, []} = discipline_faults(ReferenceVenue)
    end

    test "a venue that previews and replaces anything is named for every case" do
      assert {9, faults} = discipline_faults(Broken.Teeth.LaxWrites)
      assert length(faults) == 9

      assert Enum.all?(faults, fn {_name, _arity, _expected, fault} ->
               match?({:answered, {:ok, %{}}}, fault)
             end)
    end

    test "a venue that raises is named, not passed" do
      assert {9, faults} = discipline_faults(Broken.Teeth.RaisingWrites)
      assert length(faults) == 9
      assert Enum.all?(faults, fn {_name, _arity, _expected, fault} -> fault == :raised end)
    end
  end

  describe "assertion 22: child_spec/1 does not store a secret a supervisor would print" do
    test "a child_spec that keeps the raw credentials map is named, with what OTP would print" do
      assert {:leaked, rendered} =
               AdapterContract.child_spec_credential_fault(Broken.Teeth.RawChildSpec)

      assert rendered =~ "dpx-credential-canary-"
      assert rendered =~ "start: {Broken.Teeth.RawChildSpec, :start_link"
    end

    test "a secret nested inside another term of the start args is found too" do
      assert {:leaked, _rendered} =
               AdapterContract.child_spec_credential_fault(Broken.Teeth.NestedChildSpec)
    end

    test "a redacting wrapper and a spec that keeps no credentials are not faulted" do
      assert AdapterContract.child_spec_credential_fault(ReferenceVenue) == nil
      assert AdapterContract.child_spec_credential_fault(Broken.Teeth.DroppingChildSpec) == nil
    end
  end

  describe "assertion 51: a running process does not print the secret it holds" do
    test "a process holding the raw credentials map is named, with the text around the secret" do
      assert {:leaked, pid, excerpt} =
               AdapterContract.process_credential_fault({Broken.Teeth.Probes, :leaky})

      assert is_pid(pid)
      assert excerpt =~ "dpx-process-canary-"
      assert excerpt =~ "api_key"
    end

    test "a secret kept only in the process dictionary is found too" do
      assert {:leaked, _pid, excerpt} =
               AdapterContract.process_credential_fault({Broken.Teeth.Probes, :dictionary})

      assert excerpt =~ "dpx-process-canary-"
    end

    test "a leaking process is found even when it is not the first one the probe starts" do
      assert {:leaked, _pid, _excerpt} =
               AdapterContract.process_credential_fault({Broken.Teeth.Probes, :two})
    end

    test "a redacting struct and a format_status/1 redactor are not faulted" do
      assert AdapterContract.process_credential_fault(
               {DpExchange.Core.ReferenceVenue.ProcessProbe, :start_link}
             ) == nil

      assert AdapterContract.process_credential_fault({Broken.Teeth.Probes, :redacting}) == nil
    end

    test "the probe's processes are stopped afterwards, leaking or not" do
      assert {:leaked, pid, _excerpt} =
               AdapterContract.process_credential_fault({Broken.Teeth.Probes, :leaky})

      # Monitoring a dead pid answers `:DOWN` at once, so this holds whether or not the kill
      # has landed yet; the wait only bounds a process that was never stopped.
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end

    test "a probe that examines nothing is a failure, never a pass" do
      for name <- [:refuses, :nothing, :dead] do
        assert {:probe_failed, _answer} =
                 AdapterContract.process_credential_fault({Broken.Teeth.Probes, name})
      end
    end

    test "no probe at all is not a fault: the group is opt-in" do
      assert AdapterContract.process_credential_fault(nil) == nil
    end
  end

  @order_base %{
    symbol: "BTC-USDC",
    side: :buy,
    order_type: :limit,
    time_in_force: :gtc,
    quantity: Decimal.new("0.001"),
    price: Decimal.new("1")
  }

  # The group's own cases, shaped as the suite shapes them (`[credentials, request, opts]`).
  defp value_cases do
    for {request, reason} <- AdapterContract.order_value_cases(@order_base),
        do: {:place_order, [%{}, request, []], reason}
  end

  defp case_count(base), do: length(AdapterContract.order_value_cases(base))

  describe "assertion 52: a quantity or price that is not a positive finite number" do
    test "each of quantity and price is spoiled by a float, zero, a negative, NaN and infinity" do
      cases = AdapterContract.order_value_cases(@order_base)

      assert length(cases) == 10

      for {request, {tag, value}} <- cases do
        key = if tag == :invalid_quantity, do: :quantity, else: :price
        other = if key == :quantity, do: :price, else: :quantity

        # Only the field named is bad, and the value is carried exactly as given.
        assert tag in [:invalid_quantity, :invalid_price]
        assert request[key] == value
        assert request[other] == @order_base[other]
        assert Map.delete(request, key) == Map.delete(@order_base, key)
      end

      values = for {_request, {:invalid_quantity, value}} <- cases, do: value
      finite = for %Decimal{coef: coef} = value <- values, is_integer(coef), do: value

      assert Enum.any?(values, &is_float/1)
      assert Enum.any?(values, &match?(%Decimal{coef: :NaN}, &1))
      assert Enum.any?(values, &match?(%Decimal{coef: :inf}, &1))
      assert Enum.any?(finite, &Decimal.lt?(&1, 0))
      assert Enum.any?(finite, &Decimal.eq?(&1, 0))
    end

    test "a key the request does not carry is not probed, and a request with neither is empty" do
      assert case_count(Map.delete(@order_base, :price)) == 5
      assert case_count(Map.delete(@order_base, :quantity)) == 5
      assert case_count(Map.drop(@order_base, [:price, :quantity])) == 0

      # A nil is not a value to spoil either: it is a key the request leaves unsaid.
      assert case_count(%{@order_base | price: nil}) == 5
    end

    test "the reference venue refuses every case, with the tag and the value as given" do
      assert AdapterContract.case_faults(ReferenceVenue, value_cases()) == []
    end

    test "a venue that places whatever it is handed is named on every case" do
      faults = AdapterContract.case_faults(Broken.Teeth.LaxOrders, value_cases())

      assert length(faults) == 10
      assert Enum.all?(faults, &match?({:place_order, 3, _expected, {:answered, {:ok, _}}}, &1))
    end

    test "a venue that checks the quantity and forgets the price is named on the price cases" do
      faults = AdapterContract.case_faults(Broken.Teeth.PartialOrders, value_cases())
      tags = for {_name, _arity, {tag, _value}, _fault} <- faults, do: tag

      assert tags == List.duplicate(:invalid_price, 5)
    end

    test "a refusal that rewrites the value is not the value as given" do
      faults = AdapterContract.case_faults(Broken.Teeth.RewritingOrders, value_cases())

      answers = for {:place_order, 3, _expected, {:answered, answer}} <- faults, do: answer

      assert length(faults) == 10
      assert Enum.all?(answers, &match?({:error, _reason}, &1))
    end

    test "a raise is named as a raise, not taken for a refusal" do
      faults = AdapterContract.case_faults(Broken.Teeth.RaisingOrders, value_cases())

      assert length(faults) == 10
      assert Enum.all?(faults, &match?({:place_order, 3, _expected, :raised}, &1))
    end
  end

  describe "assertion 26: the add and remove cycle returns the set to empty" do
    test "a fake that keeps an entry for a symbol it was asked to forget is named" do
      assert set_fault(:tombstones) == {:state_not_restored, ["STALE"]}
    end

    test "a fake that keeps the three operations apart ends empty and is not faulted" do
      assert set_fault(:conforming) == nil
    end
  end
end
