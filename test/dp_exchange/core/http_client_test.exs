defmodule DpExchange.Core.HttpClientTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, DefaultRateLimiter, HttpClient}

  @moduletag :capture_log

  # A real limiter module, not a mock: it implements the behaviour and answers from
  # configuration. It reads that configuration through the same process-scoped seam a
  # venue fake will, which is what lets these tests run concurrently while each one
  # makes the limiter behave differently — the case global config cannot express.
  defmodule StubLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    alias DpExchange.Core.Config

    # Modelled on `DefaultRateLimiter`'s contract, because `HttpClient` now relies on it:
    # `acquire/3` RESERVES when it answers `:ok` (reported as `:counted`), and a bucket that
    # is full refuses an acquire as `:rate_limit_timeout`, committing nothing.
    @impl true
    def acquire(provider, weight, _opts) do
      case answer(:acquire, provider) do
        :ok ->
          report({:counted, provider, weight})
          :ok

        {:rate_limited, _ms} ->
          {:error, :rate_limit_timeout}

        other ->
          other
      end
    end

    @impl true
    def check(provider, _weight, _opts), do: answer(:check, provider)

    @impl true
    def record(provider, weight, _opts) do
      report({:recorded, provider, weight})
      :ok
    end

    @impl true
    def penalize(provider, ms, _opts) do
      report({:penalized, provider, ms})
      :ok
    end

    defp answer(which, key) do
      report({which, :key, key})
      report({which, :called})

      # A map answers per key, so one bucket can refuse while another has room.
      case Config.get(:dp_exchange_core, :stub_answer, :ok) do
        %{} = per_key -> Map.get(per_key, key, :ok)
        answer -> answer
      end
    end

    defp report(message) do
      case Config.find_override(:stub_report_to) do
        {:ok, pid} -> send(pid, message)
        :none -> :ok
      end
    end
  end

  # Refuses every reservation, yet has room when asked how long to wait: a bucket that
  # refilled between the refusal and the question.
  defmodule RefillingLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :rate_limit_timeout}

    @impl true
    def check(_provider, _weight, _opts), do: :ok

    @impl true
    def record(_provider, _weight, _opts), do: :ok

    @impl true
    def penalize(_provider, _ms, _opts), do: :ok
  end

  # A loopback listener that answers one request with `response` and closes. A real socket,
  # because `request/2` and `get/1` have no options through which to pass a `:plug`.
  defp serve_once(response) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      {:ok, _request} = :gen_tcp.recv(socket, 0)
      :ok = :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
    end)

    "http://127.0.0.1:#{port}/x"
  end

  defp json_response(json) do
    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
      "content-length: #{byte_size(json)}\r\nconnection: close\r\n\r\n" <> json
  end

  defp use_stub(answer \\ :ok) do
    Config.put_override(:rate_limit_module, StubLimiter)
    Config.put_override(:stub_answer, answer)
    Config.put_override(:stub_report_to, self())
  end

  # No request in this file is allowed to reach the network. Every one either stops at
  # the limiter, or points at a closed port with retries off.
  defp request(opts) do
    HttpClient.request(
      :get,
      "http://127.0.0.1:1/never",
      [],
      nil,
      Keyword.put_new(opts, :retry_attempts, 0)
    )
  end

  describe "the limiter is resolved at call time, through the process-scoped seam" do
    test "an override in this process is used" do
      use_stub({:rate_limited, 1_000})
      request(provider: "v")
      assert_received {:check, :called}
    end

    test "the override does not leak to a process that did not set it" do
      # The whole reason this resolves through Config rather than Application.get_env/3:
      # a global swap would reconfigure every async test running beside this one.
      use_stub()

      task =
        Task.async(fn ->
          Process.delete(:"$callers")
          Config.get(:dp_exchange_core, :rate_limit_module, :fell_back)
        end)

      assert Task.await(task) == :fell_back
    end
  end

  describe "rate-limit outcomes fail closed in both directions" do
    test "a check that says rate-limited stops the request" do
      use_stub({:rate_limited, 1_500})
      assert {:error, {:exchange_error, "v", message}} = request(provider: "v")
      assert message =~ "retry after 2s"
    end

    test "retry_after rounds UP — rounding down retries while still limited" do
      use_stub({:rate_limited, 1_001})
      assert {:error, {:exchange_error, "v", message}} = request(provider: "v")
      assert message =~ "retry after 2s"
    end

    test "a limiter that cannot answer stops the request rather than allowing it" do
      # Not knowing whether there is capacity is not the same as having it. The
      # implementation this replaced mapped exactly this condition to :ok in `check`
      # while `acquire` beside it failed closed on the same condition, undocumented.
      use_stub({:error, :store_unreachable})

      assert {:error, {:exchange_error, "v", "Rate limiter unavailable"}} = request(provider: "v")
    end

    test "blocking mode acquires instead of checking" do
      use_stub({:error, :nope})
      request(provider: "v", rate_limit_blocking: true)

      assert_received {:acquire, :called}
      refute_received {:check, :called}
    end

    test "a blocking request is metered once — acquire reserves, so nothing records again" do
      # `acquire/3` commits the reservation. Recording the same request afterwards counted
      # every blocking request twice, so a venue feed pacing itself with
      # `rate_limit_blocking: true` ran at half its declared ceiling.
      use_stub()
      request(provider: "v", rate_limit_blocking: true)

      assert_received {:counted, "v", 1}
      refute_received {:counted, "v", 1}
      refute_received {:recorded, _key, _weight}
    end

    test "a non-blocking request reserves atomically — acquire with no wait — and records nothing" do
      # It used to `check` (which reserves nothing), send, then `record`. Concurrent callers
      # all passed the check before any recorded, so two requests 250 ms apart went through
      # a 1/s bucket and drew a venue 429 (dp_exchange_webull, 2026-10-03).
      use_stub()
      request(provider: "v")

      assert_received {:acquire, :key, "v"}
      assert_received {:counted, "v", 1}
      refute_received {:check, :called}
      refute_received {:recorded, _key, _weight}
    end

    test "per-endpoint metering reserves in the provider's AND the endpoint's own bucket" do
      # A venue stating "1 request per second per App Key" beside a global per-minute cap
      # needs both. The endpoint is the URL's path, never its query.
      use_stub()

      HttpClient.request(:get, "http://127.0.0.1:1/never?symbol=BTCUSD", [], nil,
        provider: "v",
        rate_limit_per_endpoint: true,
        retry_attempts: 0
      )

      assert_received {:counted, "v", 1}
      assert_received {:counted, "v /never", 1}
    end

    test "a URL with no path meters its endpoint bucket under the root path" do
      use_stub()

      HttpClient.request(:get, "http://127.0.0.1:1", [], nil,
        provider: "v",
        rate_limit_per_endpoint: true,
        retry_attempts: 0
      )

      assert_received {:counted, "v /", 1}
    end

    test "per-endpoint metering stops at the first bucket that refuses, and asks how long" do
      use_stub({:rate_limited, 1_500})

      assert {:error, {:exchange_error, "v", message}} =
               request(provider: "v", rate_limit_per_endpoint: true)

      assert message =~ "retry after 2s"
      # Asked first, with nothing reserved: every bucket must have room before any is spent.
      assert_received {:check, :key, "v"}
      refute_received {:acquire, :key, "v"}
      refute_received {:acquire, :key, "v /never"}
      refute_received {:counted, _key, _weight}
    end

    test "an endpoint bucket that refuses does not spend the provider bucket's token" do
      # The provider was reserved, then the endpoint refused, and the provider's token was
      # gone for a request never sent.
      use_stub(%{"v /never" => {:rate_limited, 1_500}})

      assert {:error, {:exchange_error, "v", message}} =
               request(provider: "v", rate_limit_per_endpoint: true)

      assert message =~ "retry after 2s"
      assert_received {:check, :key, "v"}
      assert_received {:check, :key, "v /never"}
      refute_received {:counted, _key, _weight}
    end

    test "blocking: an endpoint wait beyond the timeout does not spend the provider's token" do
      # (1) acquire on the provider bucket reserves and sleeps, (2) acquire on the endpoint
      # bucket times out, (3) nothing is sent and the provider's token is gone. Asking every
      # bucket with check/3 first refuses before anything is reserved.
      use_stub(%{"v /never" => {:rate_limited, 60_000}})

      assert {:error, {:exchange_error, "v", :rate_limit_timeout}} =
               request(provider: "v", rate_limit_per_endpoint: true, rate_limit_blocking: true)

      assert_received {:check, :key, "v"}
      assert_received {:check, :key, "v /never"}
      refute_received {:acquire, :key, _key}
      refute_received {:counted, _key, _weight}
    end

    test "blocking: waits within the timeout on both buckets still block and reserve both" do
      use_stub(%{"v" => {:rate_limited, 10}, "v /never" => {:rate_limited, 10}})

      request(provider: "v", rate_limit_per_endpoint: true, rate_limit_blocking: true)

      # The stub's acquire maps a rate-limited answer to a timeout, so the point here is only
      # that the pre-check let both buckets through to the acquire step.
      assert_received {:acquire, :key, "v"}
    end

    test "on a blocking limiter the request is signed again after the wait, and that is sent" do
      # Signed once and then held by a blocking limiter, two callers on an incrementing
      # nonce were released in either order, and the earlier signature reached the venue
      # second and was refused as a replay.
      use_stub()
      test = self()
      counter = :counters.new(1, [])

      headers = fn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        send(test, {:signed, n})
        [{"x-nonce", Integer.to_string(n)}]
      end

      plug = fn conn ->
        send(test, {:sent_nonce, Plug.Conn.get_req_header(conn, "x-nonce")})
        Req.Test.json(conn, %{})
      end

      HttpClient.request(:get, "http://venue.test/x", headers, nil,
        provider: "v",
        plug: plug,
        rate_limit_blocking: true,
        retry_attempts: 0
      )

      {:messages, messages} = Process.info(self(), :messages)
      reserved = Enum.find_index(messages, &(&1 == {:counted, "v", 1}))
      resigned = Enum.find_index(messages, &(&1 == {:signed, 2}))

      assert reserved != nil and resigned != nil
      assert reserved < resigned
      assert_received {:sent_nonce, ["2"]}
    end

    test "a request that cannot be signed fails with that reason before the limiter is asked" do
      # Asked first, an unstarted limiter answered "Rate limiter unavailable" for a request
      # that had no credentials, and a running one spent a token on it.
      use_stub()

      assert {:error, :missing_credentials} =
               HttpClient.request(
                 :get,
                 "http://127.0.0.1:1/never",
                 fn -> {:error, :missing_credentials} end,
                 nil,
                 provider: "v",
                 retry_attempts: 0
               )

      refute_received {:acquire, :key, "v"}
      refute_received {:counted, _key, _weight}
    end

    test "a signature that fails after a blocking wait is returned, and nothing is sent" do
      use_stub()
      test = self()
      counter = :counters.new(1, [])

      headers = fn ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 -> [{"x-nonce", "1"}]
          _later -> {:error, :signer_gone}
        end
      end

      plug = fn conn ->
        send(test, :sent)
        Req.Test.json(conn, %{})
      end

      assert {:error, :signer_gone} =
               HttpClient.request(:get, "http://venue.test/x", headers, nil,
                 provider: "v",
                 plug: plug,
                 rate_limit_blocking: true,
                 retry_attempts: 0
               )

      refute_received :sent
    end

    test "a blocking acquire that times out is the limiter's own refusal" do
      use_stub({:rate_limited, 1_000})

      assert {:error, {:exchange_error, "v", :rate_limit_timeout}} =
               request(provider: "v", rate_limit_blocking: true)
    end

    test "a limiter that cannot answer the per-endpoint pre-check stops the request" do
      use_stub({:error, :store_unreachable})

      assert {:error, {:exchange_error, "v", "Rate limiter unavailable"}} =
               request(provider: "v", rate_limit_per_endpoint: true)
    end

    test "a refusal whose wait has already elapsed still refuses, for the one-second minimum" do
      Config.put_override(:rate_limit_module, RefillingLimiter)

      assert {:error, {:exchange_error, "v", message}} = request(provider: "v")
      assert message =~ "retry after 1s"
    end

    test "a Retry-After clamped to zero holds no bucket" do
      use_stub()

      assert {:error, {:exchange_error, "v", message}} =
               HttpClient.request(:get, "http://venue.test/x", [], nil,
                 plug: responding(429, %{}, [{"retry-after", "30"}]),
                 provider: "v",
                 max_retry_after_s: 0,
                 retry_attempts: 0
               )

      assert message =~ "retry after 0s"
      refute_received {:penalized, _key, _ms}
    end

    test "without the option only the provider's bucket is metered" do
      use_stub()
      request(provider: "v")

      assert_received {:acquire, :key, "v"}
      refute_received {:acquire, :key, "v /never"}
    end

    test "a venue 429 holds the bucket for its Retry-After, not only the request that drew it" do
      # After one 429 with `retry_after=5s`, requests paced at the bucket's own 1/s drew 26
      # more in 31 s (dp_exchange_webull, 2026-10-03). The most specific bucket is held.
      use_stub()

      HttpClient.request(:get, "http://venue.test/bars?symbol=X", [], nil,
        plug: responding(429, %{}),
        provider: "v",
        rate_limit_per_endpoint: true,
        retry_attempts: 0
      )

      assert_received {:penalized, "v /bars", ms} when ms > 0
      refute_received {:penalized, "v", _ms}
    end

    test "no provider means no metering at all" do
      use_stub()
      request([])

      refute_received {:check, :called}
      refute_received {:acquire, :called}
    end
  end

  describe "build_auth_headers/5" do
    @credentials %{api_key: "key", api_secret: "c2VjcmV0", passphrase: "pass"}

    test "supports the generic schemes" do
      assert [{"Authorization", "Bearer key"}] =
               HttpClient.build_auth_headers(:get, "/x", nil, @credentials, :bearer)

      assert [{"Authorization", "Basic " <> _encoded}] =
               HttpClient.build_auth_headers(:get, "/x", nil, @credentials, :basic)

      headers = HttpClient.build_auth_headers(:get, "/x", nil, @credentials, :hmac_sha256)
      assert is_list(headers) and headers != []
    end

    test "a venue supplies its own scheme as a function, not a branch here" do
      # The generic hook that replaced a `:coinbase_cdp_jwt` case. Venue knowledge
      # stays inside the venue package.
      builder = fn method, path, _body, creds ->
        [{"X-Venue-Auth", "#{method}:#{path}:#{creds.api_key}"}]
      end

      assert [{"X-Venue-Auth", "get:/orders:key"}] =
               HttpClient.build_auth_headers(:get, "/orders", nil, @credentials, builder)
    end

    test "an unknown scheme raises rather than sending the request unsigned" do
      # It answered `[]`, so a typo'd scheme authenticated nothing and the request went out
      # anyway — failing open on the one decision that must fail closed.
      assert_raise ArgumentError, ~r/unknown auth_type :no_such_scheme/, fn ->
        HttpClient.build_auth_headers(:get, "/x", nil, @credentials, :no_such_scheme)
      end
    end

    test "a missing, nil or empty credential is refused, not interpolated as an empty string" do
      # `"#{nil}"` is "", so `:bearer` built `Authorization: Bearer ` and `:basic` built
      # `Basic Og==` from an unset config value, and the request went out looking signed.
      for scheme <- [:bearer, :basic, :hmac_sha256],
          bad <- [%{api_key: nil, api_secret: "s"}, %{api_key: "", api_secret: "s"}, %{}] do
        assert_raise ArgumentError, ~r/missing, nil or empty/, fn ->
          HttpClient.build_auth_headers(:get, "/x", nil, bad, scheme)
        end
      end

      assert_raise ArgumentError, ~r/:api_secret/, fn ->
        HttpClient.build_auth_headers(:get, "/x", nil, %{api_key: "k"}, :basic)
      end
    end

    test "the refusal names the field and never carries a value" do
      error =
        assert_raise ArgumentError, fn ->
          HttpClient.build_auth_headers(:get, "/x", nil, %{api_key: "k", api_secret: nil}, :basic)
        end

      refute error.message =~ ~s("k")
    end
  end

  describe "the request log never carries a credential in the URL" do
    test "the debug line and the retry warning drop the query, the fragment and userinfo" do
      use_stub()
      plug = fn conn -> Req.Test.json(%{conn | status: 503}, %{}) end

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          HttpClient.request(
            :get,
            "http://user:hunter2@venue.test/x?api_key=SECRET-IN-QUERY#frag",
            [],
            nil,
            provider: "v",
            plug: plug,
            retry_attempts: 2,
            retry_delay: 1
          )
        end)

      assert log =~ "HTTP Request: GET http://venue.test/x"
      assert log =~ "[HttpClient] retry"
      refute log =~ "SECRET-IN-QUERY"
      refute log =~ "hunter2"
      refute log =~ "user:"
    end
  end

  describe "request/5 refuses retry options that would crash mid-retry" do
    test "a retry_attempts that is not a non-negative integer raises before any request" do
      for bad <- ["3", 3.0, -1, :many] do
        assert_raise ArgumentError, ~r/retry_attempts/, fn ->
          HttpClient.request(:get, "http://127.0.0.1:1/x", [], nil, retry_attempts: bad)
        end
      end
    end

    test "a retry_delay that is not a non-negative integer raises before any request" do
      for bad <- ["1000", 1.5, -5] do
        assert_raise ArgumentError, ~r/retry_delay/, fn ->
          HttpClient.request(:get, "http://127.0.0.1:1/x", [], nil, retry_delay: bad)
        end
      end
    end
  end

  describe "parse_rate_limit_headers/1 — standard shape only" do
    test "reads the conventional x-ratelimit-* trio" do
      headers = [
        {"X-RateLimit-Limit", "100"},
        {"X-RateLimit-Remaining", "37"},
        {"X-RateLimit-Reset", "30"}
      ]

      assert %{limit: 100, remaining: 37, reset_time: %DateTime{}} =
               HttpClient.parse_rate_limit_headers(headers)
    end

    test "header names are matched case-insensitively" do
      headers = [{"x-ratelimit-limit", "10"}, {"X-RATELIMIT-REMAINING", "5"}]
      assert %{limit: 10, remaining: 5} = HttpClient.parse_rate_limit_headers(headers)
    end

    test "atom header names are read, in a list or a map, rather than raising" do
      list = [{:"x-ratelimit-limit", "10"}, {:"X-RateLimit-Remaining", "5"}]
      assert %{limit: 10, remaining: 5} = HttpClient.parse_rate_limit_headers(list)

      map = %{"x-ratelimit-limit" => ["10"], "x-ratelimit-remaining": "5"}
      assert %{limit: 10, remaining: 5} = HttpClient.parse_rate_limit_headers(map)
    end

    test "absent headers are nil — which means 'did not say', not 'no limit'" do
      assert nil == HttpClient.parse_rate_limit_headers([])
      assert nil == HttpClient.parse_rate_limit_headers([{"X-RateLimit-Limit", "100"}])
    end

    test "an unparseable value is nil rather than a guess" do
      headers = [{"X-RateLimit-Limit", "lots"}, {"X-RateLimit-Remaining", "5"}]
      assert nil == HttpClient.parse_rate_limit_headers(headers)
    end

    test "a negative limit or remaining is nil, not a budget" do
      assert nil ==
               HttpClient.parse_rate_limit_headers([
                 {"X-RateLimit-Limit", "-1"},
                 {"X-RateLimit-Remaining", "5"}
               ])

      assert nil ==
               HttpClient.parse_rate_limit_headers([
                 {"X-RateLimit-Limit", "100"},
                 {"X-RateLimit-Remaining", "-5"}
               ])

      assert %{limit: 0, remaining: 0} =
               HttpClient.parse_rate_limit_headers([
                 {"X-RateLimit-Limit", "0"},
                 {"X-RateLimit-Remaining", "0"}
               ])
    end

    test "a value that merely STARTS with digits is not read as those digits" do
      # The case `"lots"` above cannot reach: `Integer.parse/1` answers `{integer, rest}` for
      # anything beginning with a number, so ignoring `rest` read a budget out of a header
      # this package cannot actually read — `"12abc"` became 12. A malformed header is
      # exactly when guessing is worst, because the guess is unverifiable and silently
      # changes how hard this package hits the venue.
      assert nil ==
               HttpClient.parse_rate_limit_headers([
                 {"X-RateLimit-Limit", "100 requests"},
                 {"X-RateLimit-Remaining", "37"}
               ])

      assert nil ==
               HttpClient.parse_rate_limit_headers([
                 {"X-RateLimit-Limit", "100"},
                 {"X-RateLimit-Remaining", "37/100"}
               ])

      # And the same for the reset, which `parse_reset/1` promises to answer `nil` for
      # "rather than a guessed instant" — a promise it could not keep while a partial parse
      # produced one.
      assert %{reset_time: nil} =
               HttpClient.parse_rate_limit_headers([
                 {"X-RateLimit-Limit", "100"},
                 {"X-RateLimit-Remaining", "37"},
                 {"X-RateLimit-Reset", "30s"}
               ])
    end

    test "a negative reset is nil, and answers at once rather than hanging" do
      # Every value at or below one year used to be treated as a delta and handed to
      # `DateTime.add/3`, negatives included. `DateTime.add/3` computes a date for any
      # offset, and for one this large that took longer than 4 seconds in the calling
      # process, on a request that had already succeeded.
      #
      # Measured in reductions of the calling process, not in milliseconds: the work the old
      # code did was billions of reductions, the fix is a few thousand, and a count of work
      # does not move with how loaded the machine running the suite is.
      task =
        Task.async(fn ->
          {:reductions, before} = Process.info(self(), :reductions)

          parsed =
            HttpClient.parse_rate_limit_headers([
              {"X-RateLimit-Limit", "100"},
              {"X-RateLimit-Remaining", "37"},
              {"X-RateLimit-Reset", "-99999999999999999999999"}
            ])

          {:reductions, finished} = Process.info(self(), :reductions)
          {parsed, finished - before}
        end)

      assert {:ok, {%{limit: 100, remaining: 37, reset_time: nil}, reductions}} =
               Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill)

      assert reductions < 1_000_000
    end

    test "a reset value outside the representable range is nil, not a raise" do
      # `DateTime.from_unix!/1` RAISES on an out-of-range value, and this ran on every
      # response. A venue moving its reset header from seconds to milliseconds — ordinary
      # drift — sends `"1787936147000"`, which is `invalid Unix time` as seconds, and the
      # exception came out of `parse_rate_limit_headers/1` rather than out of anything that
      # looked like a header problem. A header this package cannot read must not be able to
      # fail the request it rode in on.
      assert %{limit: 100, remaining: 37, reset_time: nil} =
               HttpClient.parse_rate_limit_headers([
                 {"X-RateLimit-Limit", "100"},
                 {"X-RateLimit-Remaining", "37"},
                 {"X-RateLimit-Reset", "1787936147000"}
               ])
    end

    test "a large reset is an absolute timestamp, a small one a delta" do
      # Nothing in the header says which form a venue uses, so the split is by
      # plausibility: no delta is 50 years, and no unix timestamp is 30 seconds.
      base = [{"X-RateLimit-Limit", "1"}, {"X-RateLimit-Remaining", "1"}]

      %{reset_time: delta} =
        HttpClient.parse_rate_limit_headers(base ++ [{"X-RateLimit-Reset", "30"}])

      assert DateTime.diff(delta, DateTime.utc_now()) in 29..31

      %{reset_time: absolute} =
        HttpClient.parse_rate_limit_headers(base ++ [{"X-RateLimit-Reset", "1800000000"}])

      assert absolute == DateTime.from_unix!(1_800_000_000)
    end

    test "it no longer takes a provider — there is no venue dispatch left" do
      # `function_exported?/3` answers false for a module that is merely not loaded yet,
      # so without this the test asserts "not exported" when it means "does not exist".
      # It failed one run in six before the ensure_loaded!.
      Code.ensure_loaded!(HttpClient)

      refute function_exported?(HttpClient, :parse_rate_limit_headers, 2)
      assert function_exported?(HttpClient, :parse_rate_limit_headers, 1)
    end
  end

  describe "no venue knowledge remains in the module" do
    test "no venue name appears in dispatch position" do
      # Matches the dispatch syntax rather than the bare word, so the moduledoc can go
      # on explaining WHY the table was removed without the check tripping over it.
      source = File.read!("lib/dp_exchange/core/http_client.ex")

      for venue <- ~w(coinbase gemini kraken binance webull robinhood schwab) do
        refute source =~ ~r/"#{venue}"\s*->/i,
               "a #{venue} branch in shared code is the D-C pattern"

        refute source =~ ~r/:#{venue}\s*->/i,
               "a #{venue} branch in shared code is the D-C pattern"
      end
    end

    test "the venue-specific auth scheme and headers are gone" do
      source = File.read!("lib/dp_exchange/core/http_client.ex")

      refute source =~ ~r/def .*coinbase_cdp_jwt/
      refute source =~ ~r/"cb-after"|"cb-before"/
    end

    test "the Coinbase JWT builder is gone" do
      Code.ensure_loaded!(HttpClient)
      refute function_exported?(HttpClient, :coinbase_cdp_jwt, 2)
    end
  end

  # --- the request pipeline itself -------------------------------------------
  #
  # Driven through Req's `:plug` seam rather than a mock: the plug is a real function
  # returning a real response, and everything between it and the assertion is the
  # production path.

  defp responding(status, body), do: responding(status, body, [])

  defp responding(status, body, headers) do
    fn conn ->
      conn =
        Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_resp_header(acc, k, v) end)

      Req.Test.json(%{conn | status: status}, body)
    end
  end

  defp get(opts) do
    HttpClient.request(
      :get,
      "http://venue.test/x",
      [],
      nil,
      Keyword.put_new(opts, :retry_attempts, 0)
    )
  end

  describe "response handling" do
    test "2xx returns the parsed body" do
      assert {:ok, %{status: 200, body: %{"ok" => true}}} =
               get(plug: responding(200, %{ok: true}))
    end

    test "decode_body: false hands back the bytes, so a JSON-number amount keeps its digits" do
      raw = ~s({"amount":1234.567890123456789})

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, raw)
      end

      # Control: Req's default float decode loses the tail the venue sent.
      assert {:ok, %{body: %{"amount" => float}}} = get(plug: plug)
      refute Decimal.equal?(Decimal.from_float(float), Decimal.new("1234.567890123456789"))

      assert {:ok, %{status: 200, body: ^raw}} = get(plug: plug, decode_body: false)

      assert {:ok, %{"amount" => exact}} = Jason.decode(raw, floats: :decimals)
      assert Decimal.equal?(exact, Decimal.new("1234.567890123456789"))

      # `get/3` used to decode those bytes with native floats, undoing the option one
      # function later for the only caller that asked for it not to be undone.
      assert {:ok, %{"amount" => via_get}} =
               HttpClient.get("http://venue.test/x", [],
                 plug: plug,
                 decode_body: false,
                 retry_attempts: 0
               )

      assert Decimal.equal?(via_get, Decimal.new("1234.567890123456789"))
    end

    test "a body over :max_body_bytes is refused, and one at the limit is accepted" do
      raw = ~s({"pad":"#{String.duplicate("x", 40)}"})
      size = byte_size(raw)

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, raw)
      end

      assert {:ok, %{status: 200, body: %{"pad" => _pad}}} = get(plug: plug, max_body_bytes: size)

      assert {:error, {:response_too_large, limit}} = get(plug: plug, max_body_bytes: size - 1)
      assert limit == size - 1

      # A provider puts the call through the limiter; the stub lets it through.
      use_stub()

      assert {:error, {:exchange_error, "v", {:response_too_large, 5}}} =
               get(plug: plug, max_body_bytes: 5, provider: "v")
    end

    test "a body over the limit from a transport that ignores :into is refused after the fact" do
      adapter = fn request ->
        {request, Req.Response.new(status: 200, body: String.duplicate("x", 100))}
      end

      assert {:error, {:response_too_large, 10}} =
               get(adapter: adapter, max_body_bytes: 10)
    end

    test "a body split across chunks is counted as a whole and cut at the limit" do
      plug = fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        Enum.reduce(1..10, conn, fn _n, acc -> elem(Plug.Conn.chunk(acc, "0123456789"), 1) end)
      end

      assert {:error, {:response_too_large, 99}} = get(plug: plug, max_body_bytes: 99)
      assert {:ok, %{status: 200, body: body}} = get(plug: plug, max_body_bytes: 100)
      assert byte_size(body) == 100
    end

    test "an oversized body is not retried" do
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        Plug.Conn.send_resp(conn, 200, String.duplicate("y", 50))
      end

      assert {:error, {:response_too_large, 10}} =
               get(plug: plug, max_body_bytes: 10, retry_attempts: 3, retry_delay: 1)

      assert :counters.get(counter, 1) == 1
    end

    test "an oversized body is reported on the :stop event" do
      handler = "max-body-#{System.unique_integer([:positive])}"
      test = self()

      :telemetry.attach(
        handler,
        [:dp_exchange, :request, :stop],
        fn _event, _measure, meta, _config -> send(test, {:stop, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      plug = fn conn -> Plug.Conn.send_resp(conn, 200, String.duplicate("z", 50)) end
      assert {:error, {:response_too_large, 10}} = get(plug: plug, max_body_bytes: 10)

      assert_receive {:stop, %{result: :error, reason: :response_too_large} = meta}, 5_000
      assert meta.max_body_bytes == 10
      assert meta.status == 200
    end

    test "a non-JSON body below the limit is returned as the bytes, as before" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, "plain")
      end

      assert {:ok, %{status: 200, body: "plain"}} = get(plug: plug)
      assert {:ok, %{status: 200, body: "plain"}} = get(plug: plug, max_body_bytes: 5)
    end

    test "decode_body: false keeps its bytes under a limit, and the default limit is 16 MiB" do
      raw = ~s({"amount":1234.567890123456789})

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, raw)
      end

      assert {:ok, %{body: ^raw}} = get(plug: plug, decode_body: false, max_body_bytes: 1_000)

      big = String.duplicate("a", 16_777_217)
      big_plug = fn conn -> Plug.Conn.send_resp(conn, 200, big) end
      assert {:error, {:response_too_large, 16_777_216}} = get(plug: big_plug)
    end

    test ":max_body_bytes that is not a positive integer is refused in the caller" do
      for bad <- [0, -1, "10", 1.5, :infinity] do
        assert_raise ArgumentError, ~r/max_body_bytes/, fn -> get(max_body_bytes: bad) end
      end
    end

    test "4xx is a client error and is not retried" do
      # A bad symbol or an unauthorized key is permanent. Retrying it burns the
      # venue's rate limit to get the same answer.
      assert {:error, message} = get(plug: responding(404, %{msg: "no such symbol"}))
      assert message =~ "Client error (404)"
    end

    test "5xx is a server error" do
      assert {:error, message} = get(plug: responding(503, %{}))
      assert message =~ "Server error (503)"
    end

    test "raw_status: true hands a 4xx back intact so a venue can tell refusal from error" do
      # The contract makes `{:refused, reason}` permanent and `{:error, reason}` possibly
      # transient, and the venue says which in the 4xx body. Flattened into a message,
      # that evidence is only recoverable by string-matching — and matching "404" also
      # matches a body that happens to contain it.
      body = %{"result" => "error", "reason" => "InvalidSymbol"}

      assert {:ok, %{status: 400, body: returned}} =
               HttpClient.request(:get, "https://venue.test/thing", [], nil,
                 plug: responding(400, body),
                 retry_attempts: 0,
                 raw_status: true
               )

      assert returned["reason"] == "InvalidSymbol"
    end

    test "get/3 with raw_status caps the body it quotes in the error message" do
      big = %{"detail" => String.duplicate("x", 50_000)}

      assert {:error, message} =
               HttpClient.get("https://venue.test/thing", [],
                 plug: responding(400, big),
                 retry_attempts: 0,
                 raw_status: true
               )

      assert message =~ "HTTP 400:"
      assert byte_size(message) < 4_000
    end

    test "raw_status leaves 5xx alone — a server error is not a considered answer" do
      assert {:error, message} =
               HttpClient.request(:get, "https://venue.test/thing", [], nil,
                 plug: responding(503, %{}),
                 retry_attempts: 0,
                 raw_status: true
               )

      assert message =~ "Server error (503)"
    end

    test "without raw_status a 4xx is still the message string every caller matches on" do
      # Opt-in, so existing refusal detection keeps working. Changing this silently would
      # turn a working `{:refused, :not_listed}` into a permanent error.
      assert {:error, message} = get(plug: responding(404, %{}))
      assert message =~ "Client error (404)"
    end

    test "an unexpected status is reported as such rather than assumed successful" do
      assert {:error, message} = get(plug: responding(301, %{}))
      assert message =~ "Unexpected status (301)"
    end

    test "a venue 429 surfaces with the interval the venue named" do
      # The caller decides when to try again, so it gets the venue's own number rather
      # than the number reaching only a log line. Our own limiter already surfaced its
      # seconds; the asymmetry had no argument behind it.
      plug = responding(429, %{}, [{"retry-after", "42"}])
      assert {:error, message} = get(plug: plug)
      assert message =~ "retry after 42s"
    end

    test "a negative Retry-After is not a wait, and falls back to the floor" do
      plug = responding(429, %{}, [{"retry-after", "-30"}])
      assert {:error, message} = get(plug: plug)
      assert message =~ "retry after 5s"
    end

    test "an HTTP-date Retry-After is read, and a date already past is one second" do
      # RFC 9110 allows either form. Only the integer was read, so a date got the 5 s floor
      # and the venue was re-hit inside its own penalty.
      plug = responding(429, %{}, [{"retry-after", "Sun, 06 Nov 1994 08:49:37 GMT"}])
      assert {:error, message} = get(plug: plug)
      assert message =~ "retry after 1s"
    end

    test "a single-digit day and a padded integer Retry-After are read" do
      # `Sun, 6 Nov 1994` has no leading zero; it failed ISO 8601 parsing and got the floor.
      plug = responding(429, %{}, [{"retry-after", "Sun, 6 Nov 1994 08:49:37 GMT"}])
      assert {:error, message} = get(plug: plug)
      assert message =~ "retry after 1s"

      plug = responding(429, %{}, [{"retry-after", " 42 "}])
      assert {:error, message} = get(plug: plug)
      assert message =~ "retry after 42s"
    end

    test "raw_status does not change a 429: it is still the rate-limit error" do
      plug = responding(429, %{}, [{"retry-after", "7"}])
      assert {:error, message} = get(plug: plug, raw_status: true)
      assert message =~ "retry after 7s"
    end

    test "a Retry-After past the ceiling is clamped to it, in either form" do
      # Unbounded, `Retry-After: 86400` held the bucket through `penalize/3` for a day.
      for value <- ["86400", "Thu, 01 Jan 2099 00:00:00 GMT"] do
        assert {:error, message} = get(plug: responding(429, %{}, [{"retry-after", value}]))
        assert message =~ "retry after 600s"
      end

      plug = responding(429, %{}, [{"retry-after", "86400"}])
      assert {:error, message} = get(plug: plug, max_retry_after_s: 30)
      assert message =~ "retry after 30s"
    end

    test "a malformed :max_retry_after_s is refused before anything is sent" do
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        Plug.Conn.send_resp(conn, 429, "")
      end

      for bad <- ["30", -5, :infinity, 1.5] do
        assert_raise ArgumentError, ~r/:max_retry_after_s/, fn ->
          get(plug: plug, max_retry_after_s: bad)
        end
      end

      assert :counters.get(counter, 1) == 0
    end

    test ":timeout, :weight and the boolean flags are refused before anything is sent" do
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        Plug.Conn.send_resp(conn, 200, "{}")
      end

      for {key, bad} <- [
            timeout: "30000",
            timeout: -1,
            timeout: 1.5,
            weight: "5",
            weight: 0,
            weight: -2,
            weight: 1.0,
            raw_status: "false",
            raw_status: 1,
            log_requests: "no",
            rate_limit_blocking: :yes,
            rate_limit_per_endpoint: "true",
            decode_body: "false",
            decode_body: 0
          ] do
        assert_raise ArgumentError, ~r/#{key}/, fn -> get([{:plug, plug}, {key, bad}]) end
      end

      assert :counters.get(counter, 1) == 0
    end

    test "a 3xx is not retried — the same request gets the same redirect" do
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        responding(301, %{}).(conn)
      end

      assert {:error, message} = get(plug: plug, retry_attempts: 3, retry_delay: 1)
      assert message =~ "Unexpected status (301)"
      assert :counters.get(counter, 1) == 1
    end

    test "a 5xx whose body quotes a 4xx message is still retried" do
      # `String.contains?/2` read "Client error (4" anywhere in the message, body included.
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        responding(503, %{"detail" => "upstream said Client error (404)"}).(conn)
      end

      assert {:error, _message} = get(plug: plug, retry_attempts: 3, retry_delay: 1)
      assert :counters.get(counter, 1) == 3
    end

    test "a large error body is excerpted in the message, and says how large it was" do
      # Odd-offset multi-byte text, so the cut lands inside a character.
      page = "a" <> String.duplicate("é", 600_000)

      plug = fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(503, page)
      end

      assert {:error, message} = get(plug: plug, retry_attempts: 1)
      assert message =~ "Server error (503)"
      assert message =~ "(#{byte_size(page)} bytes)"
      assert byte_size(message) < 2_200
      assert String.valid?(message)
    end

    test "an error body that is not text is shown as bytes, so the message stays valid text" do
      binary = <<255, 254, 0, 1, 200>>

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.resp(500, binary)
      end

      assert {:error, message} = get(plug: plug, retry_attempts: 1)
      assert message =~ "Server error (500)"
      assert String.valid?(message)
      assert message =~ "255"

      big = :binary.copy(<<255>>, 10_000)

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.resp(502, big)
      end

      assert {:error, message} = get(plug: plug, retry_attempts: 1)
      assert String.valid?(message)
      assert message =~ "(10000 bytes)"
      assert byte_size(message) < 2_200
    end

    test "garbage, empty and zero Retry-After values never crash and never exceed the ceiling" do
      for {value, expected} <- [
            {"soon", "5s"},
            {"", "5s"},
            {"12abc", "5s"},
            {"1e3", "5s"},
            {"Sun, 06 Foo 1994 08:49:37 GMT", "5s"},
            {"99999999999999999999999999", "600s"},
            {"Fri, 31 Dec 9999 23:59:59 GMT", "600s"}
          ] do
        assert {:error, message} = get(plug: responding(429, %{}, [{"retry-after", value}]))
        assert message =~ "retry after #{expected}", "Retry-After #{inspect(value)}: #{message}"
      end
    end

    test "a small error body is carried whole" do
      assert {:error, message} = get(plug: responding(500, %{"reason" => "down"}))
      assert message =~ ~s("reason" => "down")
      refute message =~ "bytes)"
    end

    test "the venue's Retry-After is read, whichever header shape it arrives in" do
      # Req returns headers as `%{"name" => ["value"]}` while the pair form is the
      # other convention. Handling only pairs made every `Retry-After` a venue sent
      # invisible, so a 429 always fell back to the floor — found by this test.
      assert HttpClient.parse_rate_limit_headers(%{
               "x-ratelimit-limit" => ["100"],
               "x-ratelimit-remaining" => ["7"]
             }) == %{limit: 100, remaining: 7, reset_time: nil}
    end

    test "a venue 429 is wrapped with venue context when a provider is given" do
      use_stub()

      assert {:error, {:exchange_error, "v", message}} =
               get(plug: responding(429, %{}), provider: "v")

      assert message =~ "Rate limited by the venue"
    end

    test "an error is wrapped with venue context when a provider is given" do
      use_stub()

      assert {:error, {:exchange_error, "v", message}} =
               get(plug: responding(500, %{}), provider: "v")

      assert message =~ "Server error"
    end

    test "an error is unwrapped when no provider is given" do
      assert {:error, message} = get(plug: responding(500, %{}))
      assert is_binary(message)
    end
  end

  describe "counting — nothing fills the bucket unless something reports what left" do
    test "a successful request is counted against the venue" do
      # The incident: a venue acquired before every request and recorded none, so its
      # ceiling metered against a bucket nothing wrote to and every check passed.
      use_stub()

      assert {:ok, _response} = get(plug: responding(200, %{}), provider: "v")
      assert_received {:counted, "v", 1}
    end

    test "weight is carried through to the reservation" do
      use_stub()

      assert {:ok, _response} = get(plug: responding(200, %{}), provider: "v", weight: 5)
      assert_received {:counted, "v", 5}
    end

    test "a request with no provider records nothing" do
      use_stub()

      assert {:ok, _response} = get(plug: responding(200, %{}))
      refute_received {:recorded, _venue, _weight}
    end
  end

  describe "the default arities, against a real loopback socket" do
    test "request/2 is a GET with no headers and no body" do
      url = serve_once(json_response(~s({"ok":true})))

      assert {:ok, %{status: 200, body: %{"ok" => true}}} = HttpClient.request(:get, url)
    end

    test "get/1 and get/2 default the params and the options" do
      assert {:ok, %{"ok" => true}} = HttpClient.get(serve_once(json_response(~s({"ok":true}))))

      assert {:ok, %{"ok" => true}} =
               HttpClient.get(serve_once(json_response(~s({"ok":true}))), symbol: "BTC-USD")
    end
  end

  describe "get/3 errors" do
    test "an error is tagged with the venue once, not nested inside its own tag" do
      use_stub()

      assert {:error, {:exchange_error, "v", message}} =
               HttpClient.get("http://venue.test/x", [],
                 plug: responding(500, %{}),
                 provider: "v",
                 retry_attempts: 0
               )

      assert is_binary(message)
      assert message =~ "Server error"
    end

    test "a refusal request/5 returns untagged is tagged once by get/3" do
      refused = "refused: credentials are not sent over plain http"

      assert {:error, {:exchange_error, "v", ^refused}} =
               HttpClient.get("http://venue.test/x", [],
                 headers: [{"authorization", "Bearer test-secret-not-real"}],
                 provider: "v",
                 retry_attempts: 0
               )
    end

    test "without a provider the error is the bare message" do
      assert {:error, "Server error" <> _rest} =
               HttpClient.get("http://venue.test/x", [],
                 plug: responding(500, %{}),
                 retry_attempts: 0
               )
    end

    test "a 2xx body that is not JSON is reported as such" do
      plug = fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, "nope")
      end

      assert {:error, "Invalid JSON response"} =
               HttpClient.get("http://venue.test/x", [], plug: plug, retry_attempts: 0)
    end

    test "a 2xx body that decodes to a bare scalar is not an object or a list" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "42")
      end

      assert {:error, "Unexpected response format"} =
               HttpClient.get("http://venue.test/x", [], plug: plug, retry_attempts: 0)
    end

    test "a bare scalar served as text/plain is refused like one served as JSON" do
      # Req leaves a `text/plain` body as bytes, so `parse_response_body/2` decoded it with
      # Jason and returned whatever came out: `{:ok, nil}` for `null`, `{:ok, 42}` for `42`.
      # The same bytes as `application/json` were already "Unexpected response format".
      for scalar <- ["null", "42", "\"x\"", "true"] do
        plug = fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("text/plain")
          |> Plug.Conn.send_resp(200, scalar)
        end

        assert {:error, "Unexpected response format"} =
                 HttpClient.get("http://venue.test/x", [], plug: plug, retry_attempts: 0)

        assert {:error, "Unexpected response format"} =
                 HttpClient.get("http://venue.test/x", [],
                   plug: plug,
                   retry_attempts: 0,
                   decode_body: false
                 )
      end
    end

    test "a JSON object served as text/plain is still decoded" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, ~s({"a": 1}))
      end

      assert {:ok, %{"a" => 1}} =
               HttpClient.get("http://venue.test/x", [], plug: plug, retry_attempts: 0)
    end

    test "with :provider, a body that cannot be read is tagged with the venue like any failure" do
      use_stub()

      not_json = fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, "nope")
      end

      scalar = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "42")
      end

      assert {:error, {:exchange_error, :venue, "Invalid JSON response"}} =
               HttpClient.get("http://venue.test/x", [],
                 plug: not_json,
                 provider: :venue,
                 retry_attempts: 0
               )

      assert {:error, {:exchange_error, :venue, "Unexpected response format"}} =
               HttpClient.get("http://venue.test/x", [],
                 plug: scalar,
                 provider: :venue,
                 retry_attempts: 0
               )
    end
  end

  describe "get/3" do
    test "sends headers from opts — they used to be dropped silently" do
      # Hardcoded to [] before, so a caller passing authentication headers got a 401
      # with nothing at the call site to explain it.
      plug = fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-venue-auth") == ["signed"]
        Req.Test.json(conn, %{})
      end

      assert {:ok, _body} =
               HttpClient.get("http://venue.test/x", [],
                 plug: plug,
                 retry_attempts: 0,
                 headers: [{"x-venue-auth", "signed"}]
               )
    end

    test "builds a query string from a keyword list" do
      plug = fn conn ->
        assert conn.query_string =~ "symbol=BTC-USD"
        Req.Test.json(conn, %{})
      end

      assert {:ok, _response} =
               HttpClient.get("http://venue.test/x", [symbol: "BTC-USD"],
                 plug: plug,
                 retry_attempts: 0
               )
    end

    test "drops nil parameters rather than sending them empty" do
      plug = fn conn ->
        refute conn.query_string =~ "limit"
        Req.Test.json(conn, %{})
      end

      assert {:ok, _response} =
               HttpClient.get("http://venue.test/x", [symbol: "BTC", limit: nil],
                 plug: plug,
                 retry_attempts: 0
               )
    end

    test "a list value is refused rather than concatenated into one word" do
      # `to_string(["BTC", "ETH"])` is "BTCETH": a well-formed query for a product that
      # does not exist.
      assert_raise ArgumentError, ~r/:symbols has no single query-string spelling/, fn ->
        HttpClient.get("http://venue.test/x", [symbols: ["BTC", "ETH"]],
          plug: fn conn -> Req.Test.json(conn, %{}) end,
          retry_attempts: 0
        )
      end
    end

    test "a plain-map value is refused" do
      assert_raise ArgumentError, fn ->
        HttpClient.get("http://venue.test/x", [filter: %{a: 1}],
          plug: fn conn -> Req.Test.json(conn, %{}) end,
          retry_attempts: 0
        )
      end
    end

    test "keys are form-encoded, not interpolated raw" do
      plug = fn conn ->
        assert conn.query_string == "a+b=1&c%26d=x%3Dy"
        Req.Test.json(conn, %{})
      end

      assert {:ok, _response} =
               HttpClient.get("http://venue.test/x", [{"a b", 1}, {"c&d", "x=y"}],
                 plug: plug,
                 retry_attempts: 0
               )
    end

    test "accepts a map of parameters" do
      plug = fn conn ->
        assert conn.query_string =~ "a=1"
        Req.Test.json(conn, %{})
      end

      assert {:ok, _response} =
               HttpClient.get("http://venue.test/x", %{a: 1}, plug: plug, retry_attempts: 0)
    end
  end

  describe "retry" do
    test "a transient failure is retried up to the configured count" do
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 -> Req.Test.json(%{conn | status: 500}, %{})
          _later -> Req.Test.json(conn, %{ok: true})
        end
      end

      assert {:ok, %{status: 200}} = get(plug: plug, retry_attempts: 3, retry_delay: 1)
      assert :counters.get(counter, 1) == 2
    end

    test "a 4xx is NOT retried, even with attempts remaining" do
      # A bad symbol or an unauthorised key is permanent. Retrying spends the venue's
      # rate limit to be told the same thing again.
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        Req.Test.json(%{conn | status: 401}, %{})
      end

      assert {:error, message} = get(plug: plug, retry_attempts: 3, retry_delay: 1)
      assert message =~ "Client error (401)"
      assert :counters.get(counter, 1) == 1
    end

    test "retries are exhausted rather than looping forever" do
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        Req.Test.json(%{conn | status: 500}, %{})
      end

      assert {:error, _message} = get(plug: plug, retry_attempts: 2, retry_delay: 1)
      assert :counters.get(counter, 1) == 2
    end

    for method <- [:post, :put, :delete] do
      test "a #{method} is sent once by default, never silently re-sent after a 5xx" do
        counter = :counters.new(1, [])

        plug = fn conn ->
          :counters.add(counter, 1, 1)
          Req.Test.json(%{conn | status: 500}, %{})
        end

        assert {:error, _message} =
                 HttpClient.request(unquote(method), "http://venue.test/x", [], "{}",
                   plug: plug,
                   retry_delay: 1
                 )

        assert :counters.get(counter, 1) == 1
      end

      test "a #{method} retries only when the venue opts in with retry_attempts" do
        counter = :counters.new(1, [])

        plug = fn conn ->
          :counters.add(counter, 1, 1)
          Req.Test.json(%{conn | status: 500}, %{})
        end

        assert {:error, _message} =
                 HttpClient.request(unquote(method), "http://venue.test/x", [], "{}",
                   plug: plug,
                   retry_attempts: 2,
                   retry_delay: 1
                 )

        assert :counters.get(counter, 1) == 2
      end
    end

    test "a retry_attempts above the hardcoded default does not crash on backoff" do
      # `backoff_delay = retry_delay * (4 - attempts_left)` hardcoded `4` as
      # `retry_attempts + 1` for the default of 3. Any caller configuring
      # `retry_attempts: 5` or higher (a documented, supported option, not an edge case)
      # starts `attempts_left` above 4, so `4 - attempts_left` goes negative on the very
      # first retry and `Process.sleep/1` raises `FunctionClauseError` — in the CALLING
      # process, uncaught, exactly the failure shape this module's own moduledoc already
      # records for `retry_attempts: nil`. Verified: before this fix, this test raised
      # instead of asserting.
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        Req.Test.json(%{conn | status: 500}, %{})
      end

      assert {:error, message} = get(plug: plug, retry_attempts: 5, retry_delay: 1)
      assert message =~ "Server error (500)"
      assert :counters.get(counter, 1) == 5
    end
  end

  describe "body parsing" do
    test "a JSON body arrives decoded" do
      assert {:ok, %{body: %{"a" => 1}}} = get(plug: responding(200, %{a: 1}))
    end

    test "a non-JSON body is returned as-is rather than being forced" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 200, "plain text") end
      assert {:ok, %{body: "plain text"}} = get(plug: plug)
    end
  end

  describe "C1 — retry_attempts: nil no longer crashes the calling process" do
    test "an explicit nil retry_attempts falls back to the default instead of nil > 1" do
      # Erlang term ordering puts `nil` ABOVE every integer, so `nil > 1` is `true` — a
      # forwarded `retry_attempts: nil` silently entered the retry branch and then died
      # computing `4 - nil`, an `ArithmeticError` raised directly in the CALLING process
      # (this function is a plain call, not a supervised worker), which this library does
      # not supervise. Verified: before this fix, this test raised instead of asserting.
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          3 -> Req.Test.json(conn, %{ok: true})
          _still_failing -> Req.Test.json(%{conn | status: 500}, %{})
        end
      end

      assert {:ok, %{status: 200}} =
               get(plug: plug, retry_attempts: nil, retry_delay: 1)

      # The default (3) applied, not a crash and not "no retries".
      assert :counters.get(counter, 1) == 3
    end

    test "a persistent failure with retry_attempts: nil still terminates, using the default" do
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        Req.Test.json(%{conn | status: 500}, %{})
      end

      assert {:error, message} = get(plug: plug, retry_attempts: nil, retry_delay: 1)
      assert message =~ "Server error (500)"
      # Exactly the default retry_attempts (3) worth of attempts, then it gives up.
      assert :counters.get(counter, 1) == 3
    end
  end

  describe "C4 — every request actually put on the wire is counted, not only 2xx" do
    test "a retried 5xx is counted once per attempt, not only on the eventual success" do
      # The same mechanism as this module's own moduledoc incident: a bucket that only
      # counts successes under-counts real usage. A 5xx that gets retried genuinely
      # reached the wire and genuinely consumed the venue's quota twice here, not once.
      use_stub()
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)

        case :counters.get(counter, 1) do
          1 -> Req.Test.json(%{conn | status: 500}, %{})
          _later -> Req.Test.json(conn, %{ok: true})
        end
      end

      assert {:ok, %{status: 200}} =
               get(plug: plug, provider: "v", retry_attempts: 3, retry_delay: 1)

      assert_received {:counted, "v", 1}
      assert_received {:counted, "v", 1}
      refute_received {:counted, "v", 1}
    end

    test "a permanent 4xx that is never retried is still counted — it reached the wire once" do
      use_stub()

      assert {:error, _message} = get(plug: responding(404, %{}), provider: "v")

      assert_received {:counted, "v", 1}
    end

    test "a venue 429 is counted — the request was sent and the quota was spent either way" do
      use_stub()

      assert {:error, {:exchange_error, "v", _message}} =
               get(plug: responding(429, %{}), provider: "v")

      assert_received {:counted, "v", 1}
    end

    test "a request refused by OUR OWN limiter before it left the process is not counted" do
      # Nothing was put on the wire here, so nothing should be metered as if it had been.
      use_stub({:rate_limited, 1_000})

      assert {:error, {:exchange_error, "v", _message}} =
               get(plug: responding(200, %{}), provider: "v")

      refute_received {:counted, "v", _weight}
    end
  end

  describe "transport failure" do
    test "a raising transport is contained rather than escaping to the caller" do
      plug = fn _conn -> raise "transport exploded" end
      assert {:error, message} = get(plug: plug, retry_attempts: 1)
      assert message =~ "Request"
    end
  end

  describe ":timeout bounds the whole request, not each chunk" do
    # A local socket on 127.0.0.1 that answers with headers promising a body, then drips one
    # byte of it every 100 ms. `receive_timeout` is Finch's per-chunk timer, so each byte
    # restarted it and a request "bounded" at 300 ms never finished. Finch's
    # `request_timeout` is the whole-response timer, and it defaults to `:infinity`.
    test "a response that trickles in is cut off at :timeout" do
      use_stub()
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listener)

      server =
        spawn_link(fn ->
          {:ok, socket} = :gen_tcp.accept(listener)
          {:ok, _request} = :gen_tcp.recv(socket, 0)
          :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 10000\r\n\r\n")
          drip = fn drip -> :gen_tcp.send(socket, "x") && Process.sleep(100) && drip.(drip) end

          try do
            drip.(drip)
          catch
            _kind, _reason -> :ok
          end
        end)

      started = System.monotonic_time(:millisecond)

      task =
        Task.async(fn ->
          HttpClient.request(:get, "http://127.0.0.1:#{port}/", [], nil,
            provider: "test",
            timeout: 300,
            retry_attempts: 1
          )
        end)

      assert {:ok, {:error, _reason}} =
               Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill)

      # The body would take 10,000 bytes at 100 ms each (~1,000 s) if `:timeout` did not cut
      # it off, so any bound well under that tells the two apart; this one leaves a loaded
      # machine room to be slow without the test deciding anything about speed.
      assert System.monotonic_time(:millisecond) - started < 8_000

      Process.unlink(server)
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end
  end

  describe "headers as a function are resolved again for every attempt" do
    # A signature that expires, or carries a one-time nonce, cannot be retried byte for
    # byte. Re-sending the first attempt's headers meant a stale or replayed signature,
    # which the venue refuses as unauthorised.
    test "a retry carries a fresh signature, not the first attempt's" do
      use_stub()
      counter = :counters.new(1, [])
      test_pid = self()

      signer = fn ->
        :counters.add(counter, 1, 1)
        {:ok, [{"x-signature", "sig-#{:counters.get(counter, 1)}"}]}
      end

      plug = fn conn ->
        [signature] = Plug.Conn.get_req_header(conn, "x-signature")
        send(test_pid, {:sent, signature})

        if signature == "sig-1",
          do: Plug.Conn.resp(conn, 503, "busy"),
          else: Req.Test.json(conn, %{"ok" => true})
      end

      assert {:ok, %{status: 200}} =
               HttpClient.request(:get, "https://venue.test/x", signer, nil,
                 provider: "v",
                 plug: plug,
                 retry_attempts: 2,
                 retry_delay: 1
               )

      assert_received {:sent, "sig-1"}
      assert_received {:sent, "sig-2"}
    end

    test "a signer that fails is returned at once, never retried" do
      use_stub()
      test_pid = self()
      signer = fn -> send(test_pid, :signed) && {:error, :missing_credentials} end

      assert {:error, :missing_credentials} =
               HttpClient.request(:get, "https://venue.test/x", signer, nil,
                 provider: "v",
                 plug: fn _conn -> raise "must not be sent" end,
                 retry_attempts: 3
               )

      assert_received :signed
      refute_received :signed
    end
  end

  describe "the :exception event carries the documented metadata" do
    test "stacktrace and status are present when the request raised" do
      use_stub()
      provider = "exc-#{System.unique_integer([:positive])}"
      test_pid = self()
      handler_id = "http-exception-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:dp_exchange, :request, :exception],
        fn _event, _measurements, metadata, _config ->
          if metadata.provider == provider, do: send(test_pid, {:exception_event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, {:exchange_error, ^provider, "Request exception: " <> _rest}} =
               HttpClient.request(:get, "https://venue.test/x", [], nil,
                 provider: provider,
                 plug: fn _conn -> raise "boom" end,
                 retry_attempts: 1
               )

      assert_received {:exception_event, metadata}
      assert is_list(metadata.stacktrace)
      assert metadata.status == nil
      assert metadata.result == :exception
    end

    test "a transport that exits is an error tuple and an :exception event, not an exit" do
      use_stub()
      provider = "exit-#{System.unique_integer([:positive])}"
      test_pid = self()
      handler_id = "http-exit-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:dp_exchange, :request, :exception],
        fn _event, _measurements, metadata, _config ->
          if metadata.provider == provider, do: send(test_pid, {:exit_event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, {:exchange_error, ^provider, "Request exception: " <> _rest}} =
               HttpClient.request(:get, "https://venue.test/x", [], nil,
                 provider: provider,
                 plug: fn _conn -> exit(:transport_gone) end,
                 retry_attempts: 1
               )

      assert_received {:exit_event, metadata}
      assert metadata.kind == :exit
      assert metadata.result == :exception
    end

    test "a transport that throws closes the span with an :exception event, kind :throw" do
      use_stub()
      provider = "throw-#{System.unique_integer([:positive])}"
      test_pid = self()
      handler_id = "http-throw-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:dp_exchange, :request, :exception],
        fn _event, _measurements, metadata, _config ->
          if metadata.provider == provider, do: send(test_pid, {:throw_event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      adapter = fn _request -> throw(:transport_gone) end

      assert {:error, {:exchange_error, ^provider, "Request exception: " <> _rest}} =
               HttpClient.request(:get, "https://venue.test/x", [], nil,
                 provider: provider,
                 req_adapter: adapter,
                 retry_attempts: 1
               )

      assert_receive {:throw_event, metadata}, 5_000
      assert metadata.kind == :throw
      assert metadata.result == :exception
      assert metadata.status == nil
    end

    test "the stacktrace carries arities, never the arguments of the failed call" do
      use_stub()
      provider = "scrub-#{System.unique_integer([:positive])}"
      test_pid = self()
      handler_id = "http-scrub-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:dp_exchange, :request, :exception],
        fn _event, _measurements, metadata, _config ->
          if metadata.provider == provider, do: send(test_pid, {:scrub_event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # A plug that fails to match its argument: the top frame of the stacktrace then holds
      # the argument list, and that list is the request, headers and all.
      assert {:error, {:exchange_error, ^provider, "Request exception: " <> _rest}} =
               HttpClient.request(
                 :get,
                 "https://venue.test/x",
                 [{"authorization", "Bearer sk-live-SECRET"}],
                 nil,
                 provider: provider,
                 plug: fn %{no_such_key: _value} = conn -> conn end,
                 retry_attempts: 1
               )

      assert_receive {:scrub_event, metadata}, 5_000
      assert [_first | _rest] = metadata.stacktrace
      refute Enum.any?(metadata.stacktrace, &match?({_m, _f, args, _l} when is_list(args), &1))
      refute inspect(metadata) =~ "sk-live-SECRET"
    end
  end

  describe ":req_adapter, the documented transport seam" do
    test "is handed to Req as its :adapter instead of raising an unknown option" do
      use_stub()
      test_pid = self()

      adapter = fn request ->
        send(test_pid, :adapter_called)
        {request, Req.Response.new(status: 200, body: %{"ok" => true})}
      end

      assert {:ok, %{status: 200}} =
               HttpClient.request(:get, "https://venue.test/x", [], nil,
                 req_adapter: adapter,
                 retry_attempts: 0
               )

      assert_received :adapter_called
    end

    test "an explicit :adapter wins over it" do
      use_stub()
      test_pid = self()

      answer = fn tag ->
        fn request ->
          send(test_pid, tag)
          {request, Req.Response.new(status: 200, body: %{})}
        end
      end

      assert {:ok, _response} =
               HttpClient.request(:get, "https://venue.test/x", [], nil,
                 adapter: answer.(:explicit),
                 req_adapter: answer.(:seam),
                 retry_attempts: 0
               )

      assert_received :explicit
      refute_received :seam
    end
  end

  describe "credentials never travel over plain http" do
    # The adapter is NOT the `plug:` seam, so a request that got past the check would reach it.
    defp answering(test_pid) do
      fn request ->
        send(test_pid, :sent)
        {request, Req.Response.new(status: 200, body: "{}")}
      end
    end

    test "a request carrying a credential header to a remote http:// host is refused unsent" do
      use_stub()

      assert {:error, "refused: credentials are not sent over plain http"} =
               HttpClient.request(
                 :get,
                 "http://venue.test/x",
                 [{"X-API-Key", "test-key-not-real"}],
                 nil,
                 adapter: answering(self()),
                 retry_attempts: 0
               )

      refute_received :sent
    end

    test "a per-attempt signer counts as credentials" do
      use_stub()

      assert {:error, "refused: credentials are not sent over plain http"} =
               HttpClient.request(
                 :get,
                 "http://venue.test/x",
                 fn -> [{"x-signature", "test-sig-not-real"}] end,
                 nil,
                 adapter: answering(self()),
                 retry_attempts: 0
               )

      refute_received :sent
    end

    test "the shorter arities refuse the same way: request/3 and request/4" do
      refused = {:error, "refused: credentials are not sent over plain http"}
      creds = [{"authorization", "Bearer test-secret-not-real"}]

      assert HttpClient.request(:get, "http://venue.test/x", creds) == refused
      assert HttpClient.request(:post, "http://venue.test/x", creds, "{}") == refused
    end

    test "a map of headers is read like a list of pairs, so a credential in one is refused" do
      use_stub()

      assert {:error, "refused: credentials are not sent over plain http"} =
               HttpClient.request(
                 :get,
                 "http://venue.test/x",
                 %{"Authorization" => "Bearer test-secret-not-real"},
                 nil,
                 adapter: answering(self()),
                 retry_attempts: 0
               )

      refute_received :sent

      assert {:ok, _response} =
               HttpClient.request(
                 :get,
                 "http://venue.test/x",
                 %{"accept" => "application/json"},
                 nil,
                 adapter: answering(self()),
                 retry_attempts: 0
               )

      assert_received :sent
    end

    test "a header entry that is not a name/value pair is not judged as a credential" do
      # Stopped by the limiter before anything is sent, so what is asserted is only which
      # refusal answered: the limiter's, not the cleartext backstop's.
      use_stub({:rate_limited, 1_000})

      assert {:error, {:exchange_error, "v", message}} =
               HttpClient.request(
                 :get,
                 "http://venue.test/x",
                 [:odd, {"accept", "application/json"}],
                 nil,
                 provider: "v",
                 retry_attempts: 0
               )

      assert message =~ "Throttled by our own rate limiter"
    end

    test "a value that is not headers in any documented form is left to the transport" do
      use_stub({:rate_limited, 1_000})

      assert {:error, {:exchange_error, "v", message}} =
               HttpClient.request(:get, "http://venue.test/x", :not_headers, nil,
                 provider: "v",
                 retry_attempts: 0
               )

      assert message =~ "Throttled by our own rate limiter"
    end

    test "https, a loopback http host and an unauthenticated http request still go out" do
      use_stub()
      creds = [{"authorization", "Bearer test-secret-not-real"}]

      for {url, headers} <- [
            {"https://venue.test/x", creds},
            {"http://127.0.0.1:1/x", creds},
            {"http://venue.test/x", [{"accept", "application/json"}]}
          ] do
        assert {:ok, _response} =
                 HttpClient.request(:get, url, headers, nil,
                   adapter: answering(self()),
                   retry_attempts: 0
                 )

        assert_received :sent
      end
    end
  end

  describe "a transport error never echoes the request it failed on" do
    test "Mint's invalid_header_value keeps the header name and drops the value" do
      use_stub()
      provider = "hdr-#{System.unique_integer([:positive])}"
      test_pid = self()
      handler_id = "http-hdr-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:dp_exchange, :request, :stop],
        fn _event, _measurements, metadata, _config ->
          if metadata.provider == provider, do: send(test_pid, {:stop_event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # What Mint answers for a header it refuses to send: the VALUE is in the reason.
      refusal = %Mint.HTTPError{
        module: Mint.HTTP1,
        reason: {:invalid_header_value, "authorization", "Bearer test-secret-not-real"}
      }

      assert {:error, {:exchange_error, ^provider, message}} =
               HttpClient.request(
                 :get,
                 "https://venue.test/x",
                 [{"authorization", "Bearer test-secret-not-real"}],
                 nil,
                 provider: provider,
                 adapter: fn request -> {request, refusal} end,
                 retry_attempts: 1
               )

      assert message =~ "authorization"
      refute message =~ "test-secret-not-real"

      assert_receive {:stop_event, metadata}, 5_000
      refute inspect(metadata) =~ "test-secret-not-real"
    end

    test "Mint's invalid_request_target keeps the kind and drops the target" do
      use_stub()

      # The target is the path and query, and a venue that authenticates in the query puts
      # the credential there.
      refusal = %Mint.HTTPError{
        module: Mint.HTTP1,
        reason: {:invalid_request_target, "/x?token=test-secret-not-real"}
      }

      assert {:error, {:exchange_error, "v", message}} =
               HttpClient.request(:get, "https://venue.test/x", [], nil,
                 provider: "v",
                 adapter: fn request -> {request, refusal} end,
                 retry_attempts: 0
               )

      assert message =~ "invalid_request_target"
      refute message =~ "test-secret-not-real"
    end

    test "a KeyError's term, which can be a plain-map credential, is not printed" do
      use_stub()
      provider = "key-#{System.unique_integer([:positive])}"

      assert {:error, {:exchange_error, ^provider, message}} =
               HttpClient.request(:get, "https://venue.test/x", [], nil,
                 provider: provider,
                 plug: fn _conn ->
                   Map.fetch!(%{api_secret: "test-secret-not-real"}, :api_key)
                 end,
                 retry_attempts: 1
               )

      assert message =~ "Request exception"
      refute message =~ "test-secret-not-real"
    end
  end

  describe "a params map is sent in key order" do
    test "more than 32 keys, where a map has no iteration order of its own" do
      params = Map.new(1..40, fn n -> {"k#{String.pad_leading("#{n}", 2, "0")}", n} end)

      expected =
        params
        |> Enum.sort()
        |> Enum.map_join("&", fn {key, value} -> "#{key}=#{value}" end)

      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:query, conn.query_string})
        Req.Test.json(conn, %{"ok" => true})
      end

      assert {:ok, %{"ok" => true}} =
               HttpClient.get("http://venue.test/q", params, plug: plug, retry_attempts: 0)

      assert_receive {:query, ^expected}, 5_000
    end

    test "a keyword list keeps the order the caller wrote, because venues sign it" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:query, conn.query_string})
        Req.Test.json(conn, %{"ok" => true})
      end

      assert {:ok, %{"ok" => true}} =
               HttpClient.get("http://venue.test/q", [zeta: 1, alpha: 2, mid: 3],
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, "zeta=1&alpha=2&mid=3"}, 5_000
    end
  end

  describe "a blocking wait on two buckets is one rate-limit hit, not two" do
    test "the pre-check is quiet; acquire reports the wait it sleeps" do
      # `check/3` and `acquire/3` both report a wait as `[:rate_limit, :hit]`. The pre-check
      # asks every bucket first on the blocking path, so one throttled request counted twice.
      suffix = System.unique_integer([:positive])
      provider = "dbl#{suffix}"
      endpoint = "#{provider} /x"
      limiter = :"dbl_limiter_#{suffix}"

      start_supervised!(
        {DefaultRateLimiter,
         name: limiter,
         limits: %{
           provider => %{limit: 1_000, per_ms: 1_000, burst: 1_000},
           endpoint => %{limit: 2, per_ms: 1_000, burst: 1}
         }}
      )

      Config.put_override(:rate_limit_module, DefaultRateLimiter)
      test_pid = self()
      handler_id = "dbl-hit-#{suffix}"

      :telemetry.attach(
        handler_id,
        [:dp_exchange, :rate_limit, :hit],
        fn _event, _measurements, metadata, _config ->
          if metadata.provider in [provider, endpoint], do: send(test_pid, {:hit, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      send_one = fn ->
        HttpClient.request(:get, "https://venue.test/x", [], nil,
          provider: provider,
          limiter: limiter,
          rate_limit_per_endpoint: true,
          rate_limit_blocking: true,
          plug: fn conn -> Req.Test.json(conn, %{"ok" => true}) end,
          retry_attempts: 1
        )
      end

      assert {:ok, _first} = send_one.()
      refute_received {:hit, _metadata}

      assert {:ok, _second} = send_one.()
      assert_receive {:hit, %{provider: ^endpoint, retry_after_ms: wait}}, 5_000
      assert wait > 0
      refute_receive {:hit, _again}, 500
    end
  end

  describe ":rate_limit_key selects only the bucket; :provider stays the identity" do
    test "the limiter is handed the key, and the request event carries the provider" do
      use_stub()
      test_pid = self()
      handler_id = "rlk-stop-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:dp_exchange, :request, :stop],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:rlk_stop, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, _response} =
               HttpClient.request(:post, "https://venue.test/orders", [], "{}",
                 provider: :rlk_venue,
                 rate_limit_key: :rlk_venue_orders,
                 plug: fn conn -> Req.Test.json(conn, %{"ok" => true}) end
               )

      assert_received {:counted, :rlk_venue_orders, 1}
      refute_received {:counted, :rlk_venue, _weight}
      assert_receive {:rlk_stop, %{provider: :rlk_venue}}, 5_000
    end

    test "a refusal is tagged with the provider, and the bucket is the key" do
      use_stub({:rate_limited, 1_500})

      assert {:error, {:exchange_error, :rlk_venue, message}} =
               request(provider: :rlk_venue, rate_limit_key: :rlk_venue_orders)

      assert message =~ "own rate limiter"
      assert_received {:check, :key, :rlk_venue_orders}
      refute_received {:check, :key, :rlk_venue}
    end

    test "the limiter's own hit event names the provider, not the key" do
      suffix = System.unique_integer([:positive])
      provider = :"rlk_#{suffix}"
      bucket = :"rlk_#{suffix}_orders"
      limiter = :"rlk_limiter_#{suffix}"

      start_supervised!(
        {DefaultRateLimiter,
         name: limiter, limits: %{bucket => %{limit: 1, per_ms: 60_000, burst: 1}}}
      )

      Config.put_override(:rate_limit_module, DefaultRateLimiter)
      test_pid = self()
      handler_id = "rlk-hit-#{suffix}"

      :telemetry.attach(
        handler_id,
        [:dp_exchange, :rate_limit, :hit],
        fn _event, _measurements, metadata, _config ->
          if metadata.provider in [provider, bucket], do: send(test_pid, {:rlk_hit, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      send_one = fn ->
        HttpClient.request(:get, "https://venue.test/x", [], nil,
          provider: provider,
          rate_limit_key: bucket,
          limiter: limiter,
          plug: fn conn -> Req.Test.json(conn, %{"ok" => true}) end,
          retry_attempts: 1
        )
      end

      assert {:ok, _first} = send_one.()
      assert {:error, {:exchange_error, ^provider, _message}} = send_one.()
      assert_receive {:rlk_hit, %{provider: ^provider, retry_after_ms: wait}}, 5_000
      assert wait > 0
      refute_receive {:rlk_hit, %{provider: ^bucket}}, 500
    end
  end

  describe "retry backoff is jittered" do
    test "every wait is at least the configured delay and at most a quarter longer" do
      # Without jitter every caller that failed together slept the same `retry_delay * n` and
      # retried together. The jitter only lengthens the wait, so the configured delay is a floor.
      waits = for _sample <- 1..200, do: HttpClient.backoff_ms(1_000, 2)

      assert Enum.all?(waits, &(&1 >= 2_000 and &1 <= 2_500))
      assert length(Enum.uniq(waits)) > 1
    end

    test "a zero delay stays zero" do
      assert HttpClient.backoff_ms(0, 3) == 0
    end
  end
end
