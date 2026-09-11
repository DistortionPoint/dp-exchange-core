defmodule DpExchange.Core.TelemetryTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{DefaultRateLimiter, HttpClient, Telemetry}

  # The whole point of this file. `Core.Telemetry` documented nine event names and said
  # every venue package emitted them; nothing in the family emitted a single one, for as
  # long as the spec existed. `:telemetry.attach/4` against a name nobody emits SUCCEEDS,
  # so the hole was invisible from a consumer's side: an empty dashboard reads as a venue
  # with no traffic, not as a spec nothing implements.
  #
  # Every test here therefore attaches a real handler and asserts the event arrives. A test
  # that only called the emitter and checked it returned `:ok` would pass just as happily

  # against the version that emitted nothing.
  # Attaches a real handler and forwards matching events to the test process.
  #
  # **Scoped to one provider, and it has to be.** `:telemetry` handlers are GLOBAL to the
  # VM, not to a test: a handler attached here receives events emitted by every other test
  # running concurrently in this `async: true` suite. An unscoped handler passed in
  # isolation and failed in the full run — a `refute_receive` caught a `:rate_limit, :hit`
  # from a different test's limiter, and a `refute_receive` for `:stop` caught another
  # test's HTTP call. Filtering on a provider unique to each test is what makes these
  # assertions mean what they say. It is also worth knowing about the real thing: a
  # consumer attaching one handler sees every venue, and `:provider` is how it tells them
  # apart.
  defp attach(events, provider) do
    test_pid = self()
    handler_id = "telemetry-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        if Map.get(metadata, :provider) == provider do
          send(test_pid, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp unique_provider, do: :"venue_#{System.unique_integer([:positive])}"

  describe "the event names are the ones documented" do
    test "every prefix in event_prefixes/0 is reachable through a function on this module" do
      # A name emitted by hand somewhere would drift from this list silently: the wrong name
      # executes successfully and simply never reaches a handler. Attaching to the DECLARED
      # list and then exercising every emitter is what ties the two together.
      provider = unique_provider()
      :ok = attach(Telemetry.event_prefixes(), provider)

      metadata = %{provider: provider, endpoint: "https://example.test/v1/x", method: :get}
      start = Telemetry.request_start(metadata)
      Telemetry.request_stop(start, metadata, status: 200, result: :ok)
      Telemetry.request_exception(start, metadata, kind: :error, reason: "boom")
      Telemetry.rate_limit_hit(provider, 1_500)
      Telemetry.rate_limit_acquire(provider, 2, 0)
      Telemetry.link_up(provider)
      Telemetry.link_down(provider, ":closed")
      Telemetry.link_event(provider, :quote, 412)
      Telemetry.link_reconnect_attempt(provider, 2, 250)

      for event <- Telemetry.event_prefixes() do
        assert_receive {:telemetry, ^event, _measurements, _metadata},
                       500,
                       "no emitter reached #{inspect(event)} — it is declared and unimplemented"
      end
    end
  end

  describe "request events" do
    test "start carries a wall-clock instant and returns a monotonic one" do
      # Two clocks, deliberately. The measurement is wall-clock so a consumer can line an
      # event up against the venue's own logs; the returned value is monotonic so the
      # duration computed from it is not a function of whether NTP stepped mid-request.
      provider = unique_provider()
      :ok = attach([[:dp_exchange, :request, :start]], provider)

      before_monotonic = System.monotonic_time()
      returned = Telemetry.request_start(%{provider: provider, endpoint: "/x", method: :get})

      assert_receive {:telemetry, [:dp_exchange, :request, :start], measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.provider == provider

      assert returned >= before_monotonic
      # On the monotonic scale, nowhere near the epoch one.
      assert abs(returned - System.system_time()) > 1_000_000_000
    end

    test "stop carries a duration measured from the start value" do
      provider = unique_provider()
      :ok = attach([[:dp_exchange, :request, :stop]], provider)

      start = System.monotonic_time()

      Telemetry.request_stop(start, %{provider: provider, endpoint: "/x", method: :get},
        status: 500
      )

      assert_receive {:telemetry, [:dp_exchange, :request, :stop], measurements, metadata}
      assert measurements.duration >= 0
      assert metadata.status == 500
      assert metadata.provider == provider
    end

    test "exception is its own event, not a stop carrying an error" do
      # An error RESULT is the venue answering badly; an exception is this package failing
      # to ask. Folding them together makes a client-side bug indistinguishable from a
      # venue outage.
      provider = unique_provider()

      :ok =
        attach([[:dp_exchange, :request, :stop], [:dp_exchange, :request, :exception]], provider)

      Telemetry.request_exception(System.monotonic_time(), %{provider: provider}, reason: "boom")

      assert_receive {:telemetry, [:dp_exchange, :request, :exception], _measurements, metadata}
      assert metadata.reason == "boom"
      refute_receive {:telemetry, [:dp_exchange, :request, :stop], _measurements, _metadata}, 50
    end
  end

  describe "endpoint/1 keeps secrets out of metadata" do
    test "the query string is removed" do
      # Not tidiness. Telemetry metadata reaches logs, aggregators and third-party
      # exporters, and the query string is the one part of a URL that can carry a token.
      assert Telemetry.endpoint("https://api.test/v1/orders?api_key=SECRET&x=1") ==
               "https://api.test/v1/orders"
    end

    test "a URL with no query is unchanged" do
      assert Telemetry.endpoint("https://api.test/v1/orders") == "https://api.test/v1/orders"
    end

    test "an unusually long path is truncated rather than becoming a metrics label" do
      long = "https://api.test/" <> String.duplicate("a", 500)
      assert String.length(Telemetry.endpoint(long)) == 200
    end
  end

  describe "HttpClient emits for real requests, not only in principle" do
    test "a successful request emits start and stop with the venue's status" do
      provider = unique_provider()
      :ok = attach([[:dp_exchange, :request, :start], [:dp_exchange, :request, :stop]], provider)

      assert {:ok, _response} =
               request(
                 "https://api.test/v1/ping?token=SECRET",
                 responding(200, %{ok: true}),
                 provider
               )

      assert_receive {:telemetry, [:dp_exchange, :request, :start], _measurements, start_meta}
      assert start_meta.provider == provider
      assert start_meta.method == :get
      # The token the caller passed never reaches metadata.
      assert start_meta.endpoint == "https://api.test/v1/ping"
      refute start_meta.endpoint =~ "SECRET"

      assert_receive {:telemetry, [:dp_exchange, :request, :stop], measurements, stop_meta}
      assert measurements.duration >= 0
      assert stop_meta.status == 200
      assert stop_meta.result == :ok
    end

    test "a failing request still emits stop — the slow calls must not drop out of the sample" do
      # Recording only successes shows a venue getting FASTER exactly as it starts failing,
      # because the slow calls are the ones dropping out of the sample.
      provider = unique_provider()
      :ok = attach([[:dp_exchange, :request, :stop]], provider)

      assert {:error, _reason} =
               request("https://api.test/v1/ping", responding(503, %{error: "down"}), provider)

      assert_receive {:telemetry, [:dp_exchange, :request, :stop], _measurements, metadata}
      assert metadata.result == :error
      # No HTTP status is reported as `nil`, never `0` — a request that never got a status
      # must not put a value in a numeric series that means "not a status at all". A 503
      # DID get one, so it reports it.
      assert metadata.status == 503
    end

    test "a venue 429 emits a rate_limit hit in milliseconds, whatever unit the venue used" do
      provider = unique_provider()
      :ok = attach([[:dp_exchange, :rate_limit, :hit]], provider)

      request(
        "https://api.test/v1/ping",
        responding(429, %{error: "slow down"}, [{"retry-after", "2"}]),
        provider
      )

      assert_receive {:telemetry, [:dp_exchange, :rate_limit, :hit], measurements, metadata}
      assert measurements.count == 1
      # The venue's header said 2 SECONDS. One unit across the family is the point of a
      # shared spec; a panel summing a mixture is wrong by a factor of a thousand without
      # ever looking wrong.
      assert metadata.retry_after_ms == 2_000
    end

    # A real, permissive limiter, because `HttpClient` fails closed without one: a request
    # carrying `:provider` and finding no limiter answers `"Rate limiter unavailable"` and
    # never reaches the wire, so a telemetry test run that way would assert against a
    # request that did not happen.
    defp request(url, plug, provider) do
      opts = start_limiter(%{default: %{limit: 1_000, per_ms: 1_000, burst: 1_000}})

      HttpClient.request(
        :get,
        url,
        [],
        nil,
        [provider: provider, plug: plug, retry_attempts: 0] ++ opts
      )
    end

    defp responding(status, body), do: responding(status, body, [])

    defp responding(status, body, headers) do
      fn conn ->
        conn =
          Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_resp_header(acc, k, v) end)

        Req.Test.json(%{conn | status: status}, body)
      end
    end
  end

  describe "DefaultRateLimiter emits" do
    # A unique child id as well as a unique name: `{Limiter, opts}` takes its id from the
    # module, so a single test starting more than one collides with itself.
    defp start_limiter(limits) do
      name = :"limiter_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: name,
        start: {DefaultRateLimiter, :start_link, [[name: name, limits: limits]]}
      })

      [limiter: name]
    end

    test "an acquire reports the tokens granted and the wait, including a zero wait" do
      # A panel that only sees the waits cannot tell a limiter that is never binding from
      # one that is not running at all — and `HttpClient` fails closed with no limiter, so
      # "no acquire events" is a condition worth being able to see.
      provider = unique_provider()
      :ok = attach([[:dp_exchange, :rate_limit, :acquire]], provider)
      opts = start_limiter(%{default: %{limit: 1_000, per_ms: 1_000, burst: 1_000}})

      assert :ok = DefaultRateLimiter.acquire(provider, 1, opts)

      assert_receive {:telemetry, [:dp_exchange, :rate_limit, :acquire], measurements, metadata}
      assert measurements.tokens == 1
      assert measurements.wait_ms == 0
      assert metadata.provider == provider
      assert metadata.weight == 1
    end

    test "a non-blocking check that is throttled emits a hit — the DEFAULT path" do
      # `HttpClient` uses `check/3` unless `rate_limit_blocking: true`, and that option
      # defaults to false. Emitting only from `acquire/3` would mean the default
      # configuration of the whole family reports no rate-limit hits at all — a metric
      # reading zero because nothing counts, which looks exactly like a metric reading zero
      # because nothing is being throttled.
      provider = unique_provider()
      :ok = attach([[:dp_exchange, :rate_limit, :hit]], provider)
      opts = start_limiter(%{default: %{limit: 1, per_ms: 10_000, burst: 1}})

      :ok = DefaultRateLimiter.record(provider, 1, opts)

      assert {:rate_limited, wait_ms} = DefaultRateLimiter.check(provider, 1, opts)
      assert wait_ms > 0

      assert_receive {:telemetry, [:dp_exchange, :rate_limit, :hit], %{count: 1}, metadata}
      assert metadata.provider == provider
      assert metadata.retry_after_ms == wait_ms
    end

    test "an unthrottled check emits no hit — the hit rate must not equal the request rate" do
      provider = unique_provider()
      :ok = attach([[:dp_exchange, :rate_limit, :hit]], provider)
      opts = start_limiter(%{default: %{limit: 1_000, per_ms: 1_000, burst: 1_000}})

      assert :ok = DefaultRateLimiter.check(provider, 1, opts)

      refute_receive {:telemetry, [:dp_exchange, :rate_limit, :hit], _measurements, _metadata}, 50
    end
  end

  describe "link events" do
    test "down carries an already-inspected reason, never a raw term" do
      # Aggregators group by value; a raw reason carrying a pid or a socket ref makes every
      # occurrence a distinct series.
      provider = unique_provider()
      :ok = attach([[:dp_exchange, :link, :down]], provider)

      Telemetry.link_down(provider, inspect({:remote, 1006, "abnormal"}))

      assert_receive {:telemetry, [:dp_exchange, :link, :down], _measurements, metadata}
      assert is_binary(metadata.reason)
    end

    test "down refuses a non-binary reason at the call site" do
      assert_raise FunctionClauseError, fn -> Telemetry.link_down(:any_venue, {:raw, :term}) end
    end

    test "event carries bytes, which is what makes it a throughput signal" do
      provider = unique_provider()
      :ok = attach([[:dp_exchange, :link, :event]], provider)

      Telemetry.link_event(provider, :order_book, 2_048)

      assert_receive {:telemetry, [:dp_exchange, :link, :event], measurements, metadata}
      assert measurements.bytes == 2_048
      assert measurements.count == 1
      assert metadata.type == :order_book
    end

    test "a reconnect with no delay reports zero rather than omitting the field" do
      # Absent and zero mean different things, and only one of them is true here.
      provider = unique_provider()
      :ok = attach([[:dp_exchange, :link, :reconnect_attempt]], provider)

      Telemetry.link_reconnect_attempt(provider, 1, 0)

      assert_receive {:telemetry, [:dp_exchange, :link, :reconnect_attempt], _m, metadata}
      assert metadata.attempt == 1
      assert metadata.delay_ms == 0
    end
  end
end
