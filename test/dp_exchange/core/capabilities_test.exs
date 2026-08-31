defmodule DpExchange.Core.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Capabilities, Timeframe}

  doctest Capabilities

  defp caps(overrides \\ []) do
    Capabilities.new(Keyword.merge([endpoints: %{}, supported_quotes: ~w(USD USDC)], overrides))
  end

  describe "the activation map is one map, not a field per endpoint" do
    test "maturity/2 answers per endpoint" do
      declaration =
        caps(
          endpoints: %{
            {:get_price, 2} => :proven,
            {:get_order_book, 2} => :experimental,
            {:place_order, 3} => :unsupported
          }
        )

      assert Capabilities.maturity(declaration, {:get_price, 2}) == :proven
      assert Capabilities.maturity(declaration, {:get_order_book, 2}) == :experimental
      assert Capabilities.maturity(declaration, {:place_order, 3}) == :unsupported
    end

    test "an undeclared endpoint is :experimental — the only honest default" do
      # Not :unsupported, which would claim a refusal the venue never made. Not :proven,
      # which is earned by production use rather than by silence.
      assert Capabilities.maturity(caps(), {:anything, 9}) == :experimental
    end

    test "active? treats :proven and :experimental alike" do
      # Maturity says how well a thing is known, never whether it runs.
      declaration =
        caps(endpoints: %{{:a, 0} => :proven, {:b, 0} => :experimental, {:c, 0} => :unsupported})

      assert Capabilities.active?(declaration, {:a, 0})
      assert Capabilities.active?(declaration, {:b, 0})
      refute Capabilities.active?(declaration, {:c, 0})
    end

    test "endpoints_at/2 lists a whole maturity band" do
      declaration =
        caps(endpoints: %{{:a, 0} => :proven, {:b, 0} => :proven, {:c, 0} => :unsupported})

      assert Enum.sort(Capabilities.endpoints_at(declaration, :proven)) == [{:a, 0}, {:b, 0}]
      assert Capabilities.endpoints_at(declaration, :unsupported) == [{:c, 0}]
    end

    test "an unknown maturity is refused" do
      assert_raise ArgumentError, ~r/unknown maturity/, fn ->
        caps(endpoints: %{{:get_price, 2} => :probably_fine})
      end
    end

    test "a bare function name is refused — arity distinguishes two of the same name" do
      assert_raise ArgumentError, ~r/must be \{function, arity\}/, fn ->
        caps(endpoints: %{:get_price => :proven})
      end
    end
  end

  describe "transport is never declared" do
    test "the struct has no transport field" do
      # Both endpoints exist on every venue, so there is nothing to declare and nothing
      # for a consumer to branch on. These four existed only because a host was starting
      # and sharding the venue's connections.
      fields = %Capabilities{endpoints: %{}, supported_quotes: []} |> Map.keys()

      for gone <- [
            :has_websocket,
            :websocket_module,
            :feed_module,
            :stream_channels,
            :pairs_per_socket,
            :authenticated_channels
          ] do
        refute gone in fields, "#{gone} is transport and must not be declared"
      end
    end

    test "streamable speaks normalised data kinds, not venue channel names" do
      declaration = caps(streamable: [:quotes, :order_book, :trades])

      assert declaration.streamable == [:quotes, :order_book, :trades]
      assert :order_book in Capabilities.data_kinds()
    end

    test "a venue channel name is refused" do
      # `"level2"` is one venue's word; `:order_book` is everyone's.
      assert_raise ArgumentError, ~r/streamable/, fn -> caps(streamable: [:level2]) end
    end

    test "authenticated_streamable must be a subset of streamable" do
      # A kind needing credentials that the venue cannot stream at all is a declaration
      # that can never be true, and a consumer would go looking for the credential.
      assert_raise ArgumentError, ~r/must first be a kind the venue streams/, fn ->
        caps(streamable: [:quotes], authenticated_streamable: [:fills])
      end
    end
  end

  describe "collection policy is not declared — it is not the venue's call" do
    test "the struct has no collection-policy field" do
      fields = %Capabilities{endpoints: %{}, supported_quotes: []} |> Map.keys()

      for gone <- [:auto_collect, :default_quotes, :overview_suits_collection] do
        refute gone in fields, "#{gone} is consumer policy, not venue capability"
      end
    end

    test "the venue declares what it CAN serve, including catalogue scale" do
      declaration = caps(supported_quotes: ~w(USD EUR), catalog_size: :vast)

      assert declaration.supported_quotes == ~w(USD EUR)
      assert declaration.catalog_size == :vast
    end

    test "an unknown catalogue class is refused" do
      assert_raise ArgumentError, ~r/catalog_size/, fn -> caps(catalog_size: :enormous) end
    end
  end

  describe "credentials buy one of three things, not two" do
    test "the three-way answer is expressible" do
      for benefit <- [:no_difference, :higher_ceiling, :required] do
        assert %Capabilities{credential_benefit: ^benefit} =
                 caps(
                   credential_benefit: benefit,
                   authenticated_ceiling: %{limit: 100, per_ms: 1_000}
                 )
      end
    end

    test "claiming a higher ceiling without naming it is refused" do
      # The whole point of that value is that there are two ceilings and a caller needs
      # the second one. Without it a package holding credentials meters against the
      # public limit and leaves most of its budget unused.
      assert_raise ArgumentError, ~r/authenticated_ceiling is nil/, fn ->
        caps(credential_benefit: :higher_ceiling)
      end
    end

    test "both ceilings can be carried at once" do
      declaration =
        caps(
          credential_benefit: :higher_ceiling,
          public_ceiling: %{limit: 10, per_ms: 1_000},
          authenticated_ceiling: %{limit: 100, per_ms: 1_000}
        )

      assert declaration.public_ceiling.limit == 10
      assert declaration.authenticated_ceiling.limit == 100
    end

    test "a malformed ceiling is refused" do
      assert_raise ArgumentError, ~r/public_ceiling must be/, fn ->
        caps(public_ceiling: %{limit: 10})
      end
    end

    test "a ceiling may carry the venue's published burst depth" do
      # Gemini publishes one — "a burst rate of five additional requests that are
      # queued" — and before this the number had to be hardcoded beside the declaration
      # rather than in it, which is the drift this struct exists to prevent.
      declaration = caps(public_ceiling: %{limit: 120, per_ms: 60_000, burst: 5})

      assert declaration.public_ceiling.burst == 5
    end

    test "a ceiling without a burst is still valid — most venues publish none" do
      # `nil` here means "not published", which a consumer can tell apart from a declared
      # burst. A venue that does not state one must not be made to invent it.
      declaration = caps(public_ceiling: %{limit: 10, per_ms: 1_000})

      refute Map.has_key?(declaration.public_ceiling, :burst)
    end

    test "a burst that is not a positive integer is refused" do
      # A burst of zero is a limiter that never lets anything through, and a string
      # reaches the limiter's arithmetic before anyone notices.
      for bad <- [0, -1, "5", 5.0] do
        assert_raise ArgumentError, ~r/:burst must be a pos_integer/, fn ->
          caps(public_ceiling: %{limit: 10, per_ms: 1_000, burst: bad})
        end
      end
    end
  end

  describe "Kind 2 — domain constraints that had no declaration at all" do
    test "order types and time-in-force are declarable" do
      declaration =
        caps(
          supported_order_types: [:market, :limit, :post_only],
          supported_time_in_force: [:gtc, :ioc]
        )

      assert :post_only in declaration.supported_order_types
      assert :gtc in declaration.supported_time_in_force
    end

    test "an order type outside the contract's vocabulary is refused" do
      assert_raise ArgumentError, ~r/supported_order_types/, fn ->
        caps(supported_order_types: [:trailing_stop])
      end
    end

    test "short selling is a domain constraint on side, not a data semantic" do
      assert caps(supports_short_selling: true).supports_short_selling
    end

    test "instrument types default to spot only" do
      assert caps().supported_instrument_types == [:spot]

      assert caps(supported_instrument_types: [:spot, :perp]).supported_instrument_types ==
               [:spot, :perp]
    end
  end

  describe "margin — the two halves must agree" do
    test ":per_account is accepted — a venue may margin without a single ceiling" do
      # Reg-T equities forced this. A Schwab margin account carries five different buying
      # powers that are not multiples of one another, and a cash account at the same venue
      # carries none of them. No number is true. `nil` would read as "nobody said", which
      # is what the guard below exists to catch; `:per_account` says "the venue has none"
      # and points the caller at the balance response.
      declaration = caps(supports_margin: true, max_leverage: :per_account)

      assert declaration.max_leverage == :per_account
    end

    test ":per_account without margin is refused, exactly as a number would be" do
      assert_raise ArgumentError, ~r/supports_margin is false/, fn ->
        caps(supports_margin: false, max_leverage: :per_account)
      end
    end

    test "a leverage that is neither a Decimal nor :per_account is refused" do
      # A bare integer or a string would be parsed by guessing, and a leverage parsed by
      # guessing is a leverage sized wrong.
      for bad <- [5, "5", 5.0, :unlimited] do
        assert_raise ArgumentError, ~r/neither a Decimal nor :per_account/, fn ->
          caps(supports_margin: true, max_leverage: bad)
        end
      end
    end

    test "the nil refusal names :per_account, so the third option is discoverable" do
      # An error that states the rule but not the remedy sends a venue author looking for
      # a number to invent.
      error =
        assert_raise ArgumentError, fn -> caps(supports_margin: true) end

      assert error.message =~ ":per_account"
    end

    test "margin with a leverage ceiling is accepted" do
      declaration = caps(supports_margin: true, max_leverage: Decimal.new(5))
      assert Decimal.equal?(declaration.max_leverage, Decimal.new(5))
    end

    test "margin without a ceiling is refused" do
      # A caller sizing a leveraged order has nothing to size against, and guessing is
      # how a position exceeds what the venue will accept.
      assert_raise ArgumentError, ~r/max_leverage is nil/, fn -> caps(supports_margin: true) end
    end

    test "a leverage ceiling without margin is refused" do
      assert_raise ArgumentError, ~r/supports_margin is false/, fn ->
        caps(max_leverage: Decimal.new(5))
      end
    end
  end

  describe "history — a claim of candles must name widths" do
    test "claiming the endpoint with no widths is refused" do
      assert_raise ArgumentError, ~r/historical_timeframes is empty/, fn ->
        caps(endpoints: %{{:get_historical_prices, 4} => :proven}, historical_timeframes: [])
      end
    end

    test "a width outside the vocabulary is refused" do
      assert_raise ArgumentError, ~r/outside the timeframe vocabulary/, fn ->
        caps(
          endpoints: %{{:get_historical_prices, 4} => :proven},
          historical_timeframes: ~w(1h 3m)
        )
      end
    end

    test "1w and 1M are accepted — nameable is wider than bucketable, deliberately" do
      # Core models no boundary for either, and never will: a weekly bar's start depends
      # on the venue's week, and a month is not a fixed number of seconds. That is a
      # reason not to check their alignment, not a reason to refuse a venue that serves
      # them. Schwab's /pricehistory serves both, and before this the only ways to ship
      # were to omit a real width or to not ship.
      declaration =
        caps(
          endpoints: %{{:get_historical_prices, 4} => :experimental},
          historical_timeframes: ~w(1d 1w 1M)
        )

      assert declaration.historical_timeframes == ~w(1d 1w 1M)
      assert Timeframe.seconds("1w") == :error
    end

    test "a venue whose history endpoint is unsupported need not name widths" do
      declaration =
        caps(endpoints: %{{:get_historical_prices, 4} => :unsupported}, historical_timeframes: [])

      assert declaration.historical_timeframes == []
    end
  end

  describe "provenance — declare what you measured" do
    test "a declaration can say when it was measured and against what" do
      # A capability declaration is a claim about a real venue. An unlabelled number is
      # worse than a missing one, and a drafted table was once wrong in 7 of 21 rows.
      declaration =
        caps(measured_at: ~D[2026-08-27], measured_against: "GET /api/v3/exchangeInfo")

      assert declaration.measured_at == ~D[2026-08-27]
      assert declaration.measured_against =~ "exchangeInfo"
    end

    test "provenance is optional — nil says 'not measured' rather than pretending" do
      assert caps().measured_at == nil
      assert caps().measured_against == nil
    end
  end
end
