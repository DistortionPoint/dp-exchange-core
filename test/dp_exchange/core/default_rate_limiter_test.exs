defmodule DpExchange.Core.DefaultRateLimiterTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.DefaultRateLimiter, as: Limiter

  # Each test gets its own named limiter, so these run concurrently against real
  # processes with no shared bucket. That is also how a consumer would isolate one.
  defp start_limiter(limits) do
    name = :"limiter_#{System.unique_integer([:positive])}"

    # A unique child id as well as a unique name: `{Limiter, opts}` takes its id from
    # the module, so a single test starting more than one collides with itself.
    start_supervised!(%{id: name, start: {Limiter, :start_link, [[name: name, limits: limits]]}})
    [limiter: name]
  end

  defp fast, do: %{default: %{limit: 1_000, per_ms: 1_000, burst: 1_000}}
  defp slow, do: %{default: %{limit: 1, per_ms: 10_000, burst: 1}}

  describe "D-E.1 — a weight-N acquire is ONE atomic reservation" do
    test "acquiring weight N consumes N tokens, not N separate acquires" do
      opts = start_limiter(%{default: %{limit: 10, per_ms: 10_000, burst: 10}})

      assert :ok = Limiter.acquire(:venue, 10, opts)

      # The burst is now spent. An eleventh token is not free.
      assert {:rate_limited, wait} = Limiter.check(:venue, 1, opts)
      assert wait > 0
    end

    test "a reservation that cannot be honoured within the timeout consumes nothing" do
      # The defect: a loop that failed partway had already taken tokens for a request
      # that never happened, and nothing released them.
      opts = start_limiter(slow())

      assert {:error, :rate_limit_timeout} = Limiter.acquire(:venue, 5, opts ++ [timeout: 0])

      # Capacity is untouched — the failed acquire took nothing with it.
      assert :ok = Limiter.check(:venue, 1, opts)
    end

    test "concurrent weight-N acquires do not interleave" do
      # 20 tokens of burst, ten concurrent callers each taking 2. Exactly ten succeed
      # immediately; none observes a partially-applied reservation.
      opts = start_limiter(%{default: %{limit: 20, per_ms: 60_000, burst: 20}})

      results =
        1..10
        |> Task.async_stream(fn _i -> Limiter.acquire(:venue, 2, opts ++ [timeout: 0]) end,
          max_concurrency: 10
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &(&1 == :ok))
      assert {:rate_limited, _wait} = Limiter.check(:venue, 1, opts)
    end
  end

  describe "D-E.2 — check/3 honours weight" do
    test "room for one is not room for ten" do
      # The defect answered :ok here, and the caller then sent ten.
      opts = start_limiter(%{default: %{limit: 1, per_ms: 1_000, burst: 1}})

      assert :ok = Limiter.check(:venue, 1, opts)
      assert {:rate_limited, _wait} = Limiter.check(:venue, 10, opts)
    end

    test "check does not consume what it asks about" do
      opts = start_limiter(%{default: %{limit: 5, per_ms: 60_000, burst: 5}})

      for _i <- 1..20, do: assert(:ok = Limiter.check(:venue, 5, opts))
      assert :ok = Limiter.acquire(:venue, 5, opts ++ [timeout: 0])
    end
  end

  describe "D-E.3 — both entry points fail CLOSED on an unknown answer" do
    test "acquire on a limiter that is not running is an error" do
      assert {:error, :not_started} = Limiter.acquire(:venue, 1, limiter: :never_started)
    end

    test "check on a limiter that is not running is an error, NOT :ok" do
      # The defect mapped this to :ok — fail open — while acquire beside it failed
      # closed on the same condition, undocumented.
      assert {:error, :not_started} = Limiter.check(:venue, 1, limiter: :never_started)
    end

    test "the two agree on the same condition" do
      acquire = Limiter.acquire(:venue, 1, limiter: :never_started)
      check = Limiter.check(:venue, 1, limiter: :never_started)

      assert {:error, :not_started} = acquire
      assert {:error, :not_started} = check
    end
  end

  describe "D-E.4 — weight is validated at the boundary" do
    setup do: {:ok, opts: start_limiter(fast())}

    test "a weight of zero is rejected, not walked as a descending range", %{opts: opts} do
      # `Enum.to_list(1..0) == [1, 0]` on this runtime, which is how a weight of 0
      # recorded TWO requests and inflated the meter it exists to keep honest.
      assert {:error, {:invalid_weight, 0}} = Limiter.acquire(:venue, 0, opts)
      assert {:error, {:invalid_weight, 0}} = Limiter.check(:venue, 0, opts)
    end

    test "record/3 with weight zero records nothing", %{opts: opts} do
      {:ok, before} = Limiter.inspect_provider(:venue, opts)
      assert :ok = Limiter.record(:venue, 0, opts)
      {:ok, after_record} = Limiter.inspect_provider(:venue, opts)

      assert before == after_record
    end

    test "negative and non-integer weights are rejected", %{opts: opts} do
      assert {:error, {:invalid_weight, -1}} = Limiter.acquire(:venue, -1, opts)
      assert {:error, {:invalid_weight, 1.5}} = Limiter.check(:venue, 1.5, opts)
      assert {:error, {:invalid_weight, :one}} = Limiter.check(:venue, :one, opts)
    end

    test "the runtime behaviour that caused the defect is still true" do
      # Pinned so that if a future Elixir changes it, this stops being a live hazard
      # and the guard's moduledoc can say so rather than describing the past.
      assert Enum.to_list(1..0//-1) == [1, 0]
    end
  end

  describe "record/3 cannot fail" do
    test "it returns :ok even with no limiter running" do
      # Metering must never be the reason a market-data call does not happen.
      assert :ok = Limiter.record(:venue, 1, limiter: :never_started)
    end

    test "it fills the bucket that acquire and check measure against" do
      # The incident: a venue acquired before every request and recorded none, so its
      # ceiling bound nothing — 395 calls per 60s against a documented 300, while the
      # budget panel read comfortable.
      opts = start_limiter(%{default: %{limit: 5, per_ms: 60_000, burst: 5}})

      assert :ok = Limiter.check(:venue, 5, opts)
      assert :ok = Limiter.record(:venue, 5, opts)
      assert {:rate_limited, _wait} = Limiter.check(:venue, 1, opts)
    end
  end

  describe "a declared ceiling grants exactly what it declares" do
    test "3 per second grants three, not two" do
      # Float arithmetic made this grant TWO: 1000/3 is 333.333…, three of those sum to
      # 1000.0000000000002, and `ceil/1` turned that fraction into a whole millisecond of
      # wait. A limiter that quietly under-grants leaves a third of the venue's budget
      # unused and nothing in the system says so.
      opts = start_limiter(%{default: %{limit: 3, per_ms: 1_000, burst: 3}})

      for i <- 1..3 do
        assert :ok = Limiter.acquire(:venue, 1, opts ++ [timeout: 0]), "acquire #{i} of 3"
      end

      assert {:rate_limited, _wait} = Limiter.check(:venue, 1, opts)
    end

    test "the awkward divisors grant their full allowance too" do
      # 3, 6, 7, 9 and 11 all divide 1000 badly. Each must still grant exactly `limit`.
      for limit <- [3, 6, 7, 9, 11] do
        opts = start_limiter(%{default: %{limit: limit, per_ms: 1_000, burst: limit}})

        for i <- 1..limit do
          assert :ok = Limiter.acquire(:venue, 1, opts ++ [timeout: 0]),
                 "limit #{limit}: acquire #{i} was refused"
        end

        assert {:rate_limited, _wait} = Limiter.check(:venue, 1, opts)
      end
    end

    test "a weight-N acquire spends exactly N of the allowance" do
      opts = start_limiter(%{default: %{limit: 9, per_ms: 1_000, burst: 9}})

      assert :ok = Limiter.acquire(:venue, 6, opts ++ [timeout: 0])
      assert :ok = Limiter.acquire(:venue, 3, opts ++ [timeout: 0])
      assert {:rate_limited, _wait} = Limiter.check(:venue, 1, opts)
    end
  end

  describe "limits are configuration, never a venue table" do
    test "a provider with no entry uses :default" do
      opts = start_limiter(%{default: %{limit: 1, per_ms: 60_000, burst: 1}})

      assert :ok = Limiter.acquire(:some_venue_nobody_configured, 1, opts ++ [timeout: 0])
      assert {:rate_limited, _wait} = Limiter.check(:some_venue_nobody_configured, 1, opts)
    end

    test "per-provider limits apply independently" do
      opts =
        start_limiter(%{
          :tight => %{limit: 1, per_ms: 60_000, burst: 1},
          :loose => %{limit: 100, per_ms: 1_000, burst: 100},
          :default => %{limit: 1, per_ms: 60_000, burst: 1}
        })

      assert :ok = Limiter.acquire(:tight, 1, opts ++ [timeout: 0])
      assert {:rate_limited, _wait} = Limiter.check(:tight, 1, opts)

      # A different provider's bucket is untouched by the first one's exhaustion.
      assert :ok = Limiter.check(:loose, 50, opts)
    end

    test "the module names no venue anywhere in its source" do
      # 2.9's check, asserted rather than eyeballed: reproducing the host's venue
      # tables inside Core would be worse than leaving them in the host.
      source = File.read!("lib/dp_exchange/core/default_rate_limiter.ex")

      for venue <- ~w(coinbase gemini kraken binance webull robinhood schwab coingecko) do
        refute source =~ ~r/#{venue}/i, "venue name #{venue} leaked into the limiter"
      end
    end
  end

  describe "acquire/3 waits rather than refusing when it can" do
    test "a wait within the timeout succeeds" do
      opts = start_limiter(%{default: %{limit: 100, per_ms: 1_000, burst: 1}})

      assert :ok = Limiter.acquire(:venue, 1, opts ++ [timeout: 1_000])
      # Second one has to wait ~10ms for the emission interval, well inside the timeout.
      assert :ok = Limiter.acquire(:venue, 1, opts ++ [timeout: 1_000])
    end

    test "the caller waits, not the limiter" do
      # One slow caller must not stall the limiter for everyone else.
      opts = start_limiter(%{default: %{limit: 10, per_ms: 1_000, burst: 1}})

      waiter = Task.async(fn -> Limiter.acquire(:slow_venue, 5, opts ++ [timeout: 5_000]) end)

      # While that caller sleeps out its reservation, the limiter still answers.
      assert :ok = Limiter.check(:other_venue, 1, opts)
      assert :ok = Task.await(waiter)
    end
  end

  describe "unknown messages" do
    test "an unknown call is answered rather than crashing the caller" do
      opts = start_limiter(fast())
      assert {:error, :unknown_call} = GenServer.call(opts[:limiter], :nonsense)
    end
  end
end
