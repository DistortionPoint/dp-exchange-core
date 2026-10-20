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

  describe "two limiters under one supervisor" do
    test "child_spec/1 takes its id from the name, so two accounts' limiters can coexist" do
      suffix = System.unique_integer([:positive])
      a = :"acct_a_#{suffix}"
      b = :"acct_b_#{suffix}"

      # Linked to the test, and a supervisor ends when its parent does.
      {:ok, sup} =
        Supervisor.start_link(
          [{Limiter, name: a, limits: slow()}, {Limiter, name: b, limits: slow()}],
          strategy: :one_for_one
        )

      ids = sup |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      assert ids == Enum.sort([a, b])

      # And they are separate buckets: draining one leaves the other untouched.
      assert :ok = Limiter.acquire(:v, 1, limiter: a, timeout: 0)
      assert {:error, :rate_limit_timeout} = Limiter.acquire(:v, 1, limiter: a, timeout: 0)
      assert :ok = Limiter.acquire(:v, 1, limiter: b, timeout: 0)
    end

    test "an unnamed limiter keeps the module as its id" do
      assert %{id: Limiter} = Limiter.child_spec(limits: slow())
    end
  end

  describe "a malformed :limits fails at start, not on the first request" do
    # It used to fail on the first acquire: `reserve/3` destructures
    # `%{limit: _, per_ms: _, burst: _}`, so a missing key raised a `MatchError` INSIDE this
    # GenServer. A supervisor then restarts it, the next request crashes it again, and what
    # a consumer sees is a crash loop whose message names `reserve/3` rather than the
    # configuration that is wrong.
    #
    # Not hypothetical: `Capabilities.ceiling` declares `:burst` OPTIONAL and this module
    # declares it REQUIRED, so a ceiling read straight off `capabilities/0` — the obvious
    # thing to do, and the shape that reads as correct — is exactly the map that used to
    # crash. Found by probing the limiter with `%{limit: 10, per_ms: 1_000}` while chasing
    # an unrelated flake.
    #
    # Trapped rather than `assert_raise`d: the raise happens in the GenServer being started,
    # not in the caller, so `start_link/1` reports it as an `{:error, {exception, stack}}`
    # and would otherwise take the test process down with it.
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    defp start_with_limits(limits) do
      Limiter.start_link(name: :"lim_#{System.unique_integer([:positive])}", limits: limits)
    end

    test "an unknown option stops the limiter instead of running on the default limit" do
      name = :"lim_#{System.unique_integer([:positive])}"

      assert {:error, {:unknown_option, :limit}} =
               Limiter.start_link(name: name, limit: %{default: %{limit: 1}})

      assert Process.whereis(name) == nil
    end

    test "a ceiling straight off capabilities/0, with no :burst, is refused by name" do
      assert {:error, {%ArgumentError{message: message}, _stack}} =
               start_with_limits(%{coinbase: %{limit: 10, per_ms: 1_000}})

      assert message =~ ":coinbase"
      assert message =~ ":burst"
      # The message has to say what to do, not only that something is wrong.
      assert message =~ "Core.Capabilities.ceiling"
    end

    test "every malformed shape is refused, not just a missing :burst" do
      for bad <- [
            %{limit: 10, burst: 10},
            %{per_ms: 1_000, burst: 10},
            %{limit: 10, per_ms: 0, burst: 10},
            %{limit: -1, per_ms: 1_000, burst: 10},
            %{limit: 10, per_ms: 1_000, burst: -1},
            %{limit: "10", per_ms: 1_000, burst: 10},
            :not_a_map
          ] do
        assert {:error, {%ArgumentError{}, _stack}} = start_with_limits(%{venue: bad}),
               "#{inspect(bad)} was accepted as a limit"
      end
    end

    test ":limits that is not a map at all is refused too" do
      assert {:error, {%ArgumentError{}, _stack}} = start_with_limits([])
    end

    test "a well-formed limits map starts" do
      assert {:ok, pid} = start_with_limits(%{venue: %{limit: 12, per_ms: 60_000, burst: 12}})
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    # This test used to assert the opposite — that `limit: 0` starts — on the reasoning that
    # "zero is a real declaration, and `dp_exchange_schwab` relies on it being expressible".
    # The first half is true and is why `Core.Capabilities` accepts it. The second half was
    # false in the direction that mattered: schwab relies on it being expressible in
    # `capabilities/0`, and deliberately does NOT hand it to this limiter — it passes
    # `max(orders, 1)`, with a comment saying why. So the assertion defended a behaviour no
    # caller in the family wanted, and it stopped one line short of the thing that mattered:
    # the limiter accepted the zero and then died on the very first request, because `:limit`
    # is the divisor in the GCRA arithmetic. `start_link` returning `{:ok, pid}` was the whole
    # test, and `{:ok, pid}` was never the question.
    test "a zero limit is refused at start — it is the GCRA divisor, and it used to crash" do
      assert {:error, {%ArgumentError{message: message}, _stack}} =
               start_with_limits(%{venue: %{limit: 0, per_ms: 60_000, burst: 0}})

      assert message =~ ":venue"
      assert message =~ "limit: 0"
      # The message has to distinguish the two places zero means different things, or the
      # reader's next move is to delete the zero from `capabilities/0`, where it is correct.
      assert message =~ "Core.Capabilities.ceiling"
    end

    test "the zero that IS legal stays legal where it belongs — in the declaration" do
      # The two statements are both true and they are about different things: a ceiling of
      # zero says this application's registration was granted none of the endpoint; a limiter
      # rate of zero says nothing at all, because there is no rate to divide by. Asserted
      # together so that a later change cannot "make them consistent" by breaking the one
      # that is right.
      caps =
        DpExchange.Core.Capabilities.new(
          endpoints: %{},
          supported_quotes: ~w(USD),
          public_ceiling: %{limit: 0, per_ms: 60_000}
        )

      assert caps.public_ceiling.limit == 0
    end
  end

  describe "D-E.1 — a weight-N acquire is ONE atomic reservation" do
    test "acquiring weight N consumes N tokens, not N separate acquires" do
      # A refill interval of ten seconds, so the bucket cannot refill between the two calls.
      opts = start_limiter(%{default: %{limit: 10, per_ms: 100_000, burst: 10}})

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

    test "a :timeout that is not a non-negative integer or :infinity is refused, not obeyed" do
      opts = start_limiter(slow())
      assert :ok = Limiter.acquire(:venue, 1, opts)

      # Erlang term order puts a binary above every integer: `wait_ms > "30"` was false, so
      # an exhausted bucket was waited out in full instead of failing closed.
      for bad <- ["30", 30.0, -1, :soon] do
        assert {:error, {:invalid_timeout, ^bad}} =
                 Limiter.acquire(:venue, 1, opts ++ [timeout: bad])
      end
    end

    test "timeout: :infinity waits out the bucket rather than timing out" do
      opts = start_limiter(%{default: %{limit: 20, per_ms: 1_000, burst: 1}})
      assert :ok = Limiter.acquire(:venue, 1, opts)
      assert :ok = Limiter.acquire(:venue, 1, opts ++ [timeout: :infinity])
    end

    test "a wait no process can sleep is a timeout under :infinity, and spends nothing" do
      # `acquire/3` sleeps AFTER the reservation is committed, and `Process.sleep/1` raises past
      # 2^32 - 1 ms. A weight of ten billion asks for years: it raised in the caller with the
      # tokens already spent. It is `:rate_limit_timeout` now, and the bucket is untouched.
      opts = start_limiter(%{default: %{limit: 1, per_ms: 1_000, burst: 1}})

      assert {:error, :rate_limit_timeout} =
               Limiter.acquire(:venue, 10_000_000_000, opts ++ [timeout: :infinity])

      assert {:ok, %{next_allowed_in_ms: 0}} = Limiter.inspect_provider(:venue, opts)
      assert :ok = Limiter.acquire(:venue, 1, opts ++ [timeout: 0])
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

  # ## Why these windows are 100 seconds and not one
  #
  # Every test in this block ends by asserting the bucket is empty, and this bucket refills
  # CONTINUOUSLY. At `per_ms: 1_000` with `limit: 3` a token comes back every ~333ms, so the
  # closing `check/3` was only refused if the three acquires ahead of it finished inside that
  # window. They normally do; on a loaded `async: true` run with `max_cases: 20` they
  # sometimes do not, and the test failed intermittently — observed once in six consecutive
  # full-suite runs, passing the other five.
  #
  # That is the same flake `dp_exchange_coinbase`'s limiter test carried and was fixed for:
  # ANY "the bucket is empty now" assertion races a refilling bucket, and no amount of
  # tightening the code under test removes the race, because it is in the assertion.
  #
  # Widening `per_ms` to 100_000 puts the refill interval at 9 seconds or more for every
  # limit used here, which no scheduling delay in a unit test reaches — while keeping the
  # property each test actually exists for. `100000/3` is 33333.333…, exactly as
  # non-terminating as `1000/3`, so the float hazard below is still exercised.
  describe "a declared ceiling grants exactly what it declares" do
    test "3 per second grants three, not two" do
      # Float arithmetic made this grant TWO: 1000/3 is 333.333…, three of those sum to
      # 1000.0000000000002, and `ceil/1` turned that fraction into a whole millisecond of
      # wait. A limiter that quietly under-grants leaves a third of the venue's budget
      # unused and nothing in the system says so.
      opts = start_limiter(%{default: %{limit: 3, per_ms: 100_000, burst: 3}})

      for i <- 1..3 do
        assert :ok = Limiter.acquire(:venue, 1, opts ++ [timeout: 0]), "acquire #{i} of 3"
      end

      assert {:rate_limited, _wait} = Limiter.check(:venue, 1, opts)
    end

    test "the awkward divisors grant their full allowance too" do
      # 3, 6, 7, 9 and 11 all divide 1000 badly. Each must still grant exactly `limit`.
      for limit <- [3, 6, 7, 9, 11] do
        opts = start_limiter(%{default: %{limit: limit, per_ms: 100_000, burst: limit}})

        for i <- 1..limit do
          assert :ok = Limiter.acquire(:venue, 1, opts ++ [timeout: 0]),
                 "limit #{limit}: acquire #{i} was refused"
        end

        assert {:rate_limited, _wait} = Limiter.check(:venue, 1, opts)
      end
    end

    test "a weight-N acquire spends exactly N of the allowance" do
      opts = start_limiter(%{default: %{limit: 9, per_ms: 100_000, burst: 9}})

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

      # Two hundred tokens at ten a second: a reservation the caller sleeps out for ~20 s, far
      # longer than any pause in this test, and shut down below rather than waited for.
      waiter =
        Task.async(fn -> Limiter.acquire(:slow_venue, 200, opts ++ [timeout: 60_000]) end)

      # Wait until the limiter has taken that reservation, or the check below would only be
      # asking an idle limiter and prove nothing about a held one.
      :ok = await_rate_limited(:slow_venue, opts)

      # While that caller sleeps out its reservation, the limiter still answers, and the
      # caller is still asleep: had the limiter slept for it, this call could not have been
      # answered before the waiter finished.
      assert :ok = Limiter.check(:other_venue, 1, opts)
      assert Task.yield(waiter, 0) == nil
      Task.shutdown(waiter, :brutal_kill)
    end

    defp await_rate_limited(provider, opts, tries \\ 500) do
      case Limiter.check(provider, 1, opts) do
        {:rate_limited, _wait} ->
          :ok

        :ok when tries > 0 ->
          Process.sleep(10)
          await_rate_limited(provider, opts, tries - 1)
      end
    end
  end

  describe "C3 — :timeout must survive an explicit nil" do
    test "an exhausted bucket with timeout: nil still fails closed, not waits forever" do
      # `wait_ms > timeout` becomes `wait_ms > nil` whenever `:timeout` is forwarded as an
      # explicit `nil` — the shape `HttpClient.limiter_opts/1` produces when nothing
      # upstream ever set it. Erlang term ordering makes that comparison ALWAYS false,
      # because `nil` sorts above every integer, so "fail closed after N ms" silently
      # became "wait however long it takes". Verified live against an exhausted bucket.
      opts = start_limiter(%{default: %{limit: 1, per_ms: 60_000, burst: 1}})

      # Spend the one-token burst, so the next acquire needs a real wait — close to a
      # full minute at this rate, comfortably past any sane default ceiling.
      assert :ok = Limiter.acquire(:venue, 1, opts ++ [timeout: 0])

      {elapsed_us, result} =
        :timer.tc(fn -> Limiter.acquire(:venue, 1, opts ++ [timeout: nil]) end)

      assert {:error, :rate_limit_timeout} = result

      # The refusal is decided on the SERVER, before any sleep — `acquire/3` only sleeps
      # in the caller once the server has already said the wait fits the timeout. So a
      # correct refusal here is near-instant. Before this fix, `nil` took the `{:ok,
      # wait_ms}` branch instead, and the caller would have gone on to `Process.sleep/1`
      # the full ~60s wait — this bound is what would have caught that.
      assert elapsed_us < 1_000_000
    end
  end

  describe "unknown messages" do
    test "an unknown call is answered rather than crashing the caller" do
      opts = start_limiter(fast())
      assert {:error, :unknown_call} = GenServer.call(opts[:limiter], :nonsense)
    end

    test "a stray message is ignored: the limiter keeps its state and keeps answering" do
      opts = start_limiter(fast())
      pid = Process.whereis(opts[:limiter])

      assert :ok = Limiter.acquire(:venue, 1, opts)
      before = :sys.get_state(pid)

      send(pid, :not_a_message_this_server_knows)
      send(pid, {:also, :unknown})

      assert :sys.get_state(pid) == before
      assert Process.whereis(opts[:limiter]) == pid
      assert :ok = Limiter.check(:venue, 1, opts)
    end
  end

  describe "a limit nobody configured" do
    test "no entry for the provider and no :default falls back to 10 per second, burst 10" do
      opts = start_limiter(%{})

      # Ten fit in an idle bucket's burst; eleven can never fit, and the wait is the
      # eleventh token's whole emission interval (100 ms at 10 per second).
      assert :ok = Limiter.check(:venue, 10, opts)
      assert {:rate_limited, 100} = Limiter.check(:venue, 11, opts)
    end
  end

  describe "a limiter that dies while being asked" do
    # A process registered under the limiter's name that exits on its first call, so the
    # caller sees a real `GenServer.call` exit rather than a "not running".
    defp register_dying_limiter do
      name = :"dying_limiter_#{System.unique_integer([:positive])}"
      parent = self()

      pid =
        spawn(fn ->
          Process.register(self(), name)
          send(parent, {:registered, name})

          receive do
            {:"$gen_call", _from, _request} -> exit(:limiter_died)
          end
        end)

      assert_receive {:registered, ^name}, 5_000
      {pid, [limiter: name]}
    end

    test "acquire and check answer {:limiter_unavailable, reason}, never :ok" do
      {_pid, opts} = register_dying_limiter()

      assert {:error, {:limiter_unavailable, {:limiter_died, _reason}}} =
               Limiter.acquire(:v, 1, opts)

      {_pid, opts} = register_dying_limiter()

      assert {:error, {:limiter_unavailable, {:limiter_died, _reason}}} =
               Limiter.check(:v, 1, opts)

      {_pid, opts} = register_dying_limiter()

      assert {:error, {:limiter_unavailable, {:limiter_died, _reason}}} =
               Limiter.inspect_provider(:v, opts)
    end

    test "record and penalize still answer :ok: metering is never why a request fails" do
      {_pid, opts} = register_dying_limiter()
      assert :ok = Limiter.record(:v, 1, opts)

      {_pid, opts} = register_dying_limiter()
      assert :ok = Limiter.penalize(:v, 1_000, opts)
    end
  end

  describe "penalize/3 — a venue's Retry-After holds the bucket" do
    test "an ms that is not a non-negative integer raises, naming the value" do
      opts = start_limiter(fast())

      for bad <- [-1, 1.5, "5000", nil] do
        assert_raise ArgumentError, ~r/#{Regex.escape(inspect(bad))}/, fn ->
          Limiter.penalize("v", bad, opts)
        end
      end
    end

    test "a hold longer than a process can sleep is refused, and holds nothing" do
      # `acquire/3` answers `:rate_limit_timeout` for any wait past 2^32 - 1 ms even under
      # `timeout: :infinity`, so such a hold could never be served: it closed the bucket for
      # as long as the limiter ran.
      opts = start_limiter(fast())
      longest = 4_294_967_295

      assert_raise ArgumentError, ~r/4294967296/, fn ->
        Limiter.penalize("v", longest + 1, opts)
      end

      assert :ok = Limiter.check("v", 1, opts)

      # The bound itself is a hold like any other.
      assert :ok = Limiter.penalize("v", longest, opts)
      assert {:rate_limited, wait_ms} = Limiter.check("v", 1, opts)
      assert wait_ms > longest - 60_000 and wait_ms <= longest
    end

    test "holds a bucket with room closed for the stated time" do
      opts = start_limiter(fast())

      # A minute, so that the seconds a loaded machine can spend between the two calls do not
      # move the remaining wait out of the window below.
      :ok = Limiter.penalize("v", 60_000, opts)

      assert {:rate_limited, wait_ms} = Limiter.check("v", 1, opts)
      assert wait_ms > 55_000 and wait_ms <= 60_000
    end

    test "never shortens a hold already in place" do
      opts = start_limiter(fast())

      :ok = Limiter.penalize("v", 60_000, opts)
      :ok = Limiter.penalize("v", 1_000, opts)

      assert {:rate_limited, wait_ms} = Limiter.check("v", 1, opts)
      assert wait_ms > 50_000
    end

    test "holds only the bucket it names" do
      opts = start_limiter(fast())

      :ok = Limiter.penalize("v /bars", 5_000, opts)

      assert :ok = Limiter.check("v /snapshot", 1, opts)
    end

    test "cannot fail — a limiter that is not running is not the caller's problem" do
      assert :ok = Limiter.penalize("v", 1_000, limiter: :no_such_limiter)
    end
  end

  describe "HttpClient against this limiter: concurrent non-blocking requests" do
    test "a 1/s bucket with a burst of 1 lets exactly one of eight simultaneous requests out" do
      # The race this closes: `check` reserved nothing, so concurrent callers all passed it
      # before any recorded. dp_exchange_webull, 2026-10-03: two requests 250 ms apart went
      # through such a bucket and the venue answered 429.
      opts = start_limiter(%{default: %{limit: 60, per_ms: 60_000, burst: 1}})
      sent = :counters.new(1, [:atomics])

      plug = fn conn ->
        :counters.add(sent, 1, 1)
        Req.Test.json(conn, %{})
      end

      results =
        1..8
        |> Enum.map(fn _n ->
          Task.async(fn ->
            DpExchange.Core.HttpClient.request(:get, "http://venue.test/x", [], nil,
              plug: plug,
              provider: "v",
              retry_attempts: 1,
              limiter: opts[:limiter]
            )
          end)
        end)
        |> Task.await_many()

      assert :counters.get(sent, 1) == 1
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    end
  end
end

defmodule DpExchange.Core.DefaultRateLimiterPruneTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.DefaultRateLimiter, as: Limiter

  # Per-endpoint keys carry ids (`"venue /orders/<uuid>"`), one new key per request, and
  # none was ever removed. A `tat` at or behind now is exactly an absent one, so the sweep
  # drops only keys whose answer it cannot change.
  test "an idle key is swept, a held one is kept, and answers are unchanged" do
    name = :"limiter_prune_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Limiter, name: name, limits: %{default: %{limit: 1_000, per_ms: 1_000, burst: 1_000}}}
      )

    assert :ok = Limiter.acquire("venue /orders/1", 1, limiter: name)
    assert :ok = Limiter.penalize("venue /bars", 60_000, limiter: name)

    # The idle key's theoretical arrival time is `now + 1 ms` at a 1,000-per-second rate, so it
    # is swept only once a whole millisecond of the limiter's monotonic clock has passed. A
    # sleep is a lower bound on elapsed time, never an upper one, so this cannot be too short
    # on a slow machine, only wasteful, and 5 ms of waste is the whole cost.
    Process.sleep(5)

    send(pid, :prune)
    tat = :sys.get_state(pid).tat

    refute Map.has_key?(tat, "venue /orders/1")
    assert Map.has_key?(tat, "venue /bars")
    assert :ok = Limiter.acquire("venue /orders/1", 1, limiter: name)
  end
end
