defmodule DpExchange.Core.HttpClientTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, HttpClient}

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

    test "an unknown scheme yields no headers rather than raising" do
      assert [] = HttpClient.build_auth_headers(:get, "/x", nil, @credentials, :no_such_scheme)
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

    test "absent headers are nil — which means 'did not say', not 'no limit'" do
      assert nil == HttpClient.parse_rate_limit_headers([])
      assert nil == HttpClient.parse_rate_limit_headers([{"X-RateLimit-Limit", "100"}])
    end

    test "an unparseable value is nil rather than a guess" do
      headers = [{"X-RateLimit-Limit", "lots"}, {"X-RateLimit-Remaining", "5"}]
      assert nil == HttpClient.parse_rate_limit_headers(headers)
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
      task =
        Task.async(fn ->
          HttpClient.parse_rate_limit_headers([
            {"X-RateLimit-Limit", "100"},
            {"X-RateLimit-Remaining", "37"},
            {"X-RateLimit-Reset", "-99999999999999999999999"}
          ])
        end)

      assert {:ok, %{limit: 100, remaining: 37, reset_time: nil}} = Task.yield(task, 1_000)
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
               Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill)

      assert System.monotonic_time(:millisecond) - started < 2_000

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
end
