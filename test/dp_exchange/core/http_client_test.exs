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

    @impl true
    def acquire(_provider, _weight, _opts), do: answer(:acquire)

    @impl true
    def check(_provider, _weight, _opts), do: answer(:check)

    @impl true
    def record(provider, weight, _opts) do
      report({:recorded, provider, weight})
      :ok
    end

    defp answer(which) do
      report({which, :called})
      Config.get(:dp_exchange_core, :stub_answer, :ok)
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

  describe "recording — nothing fills the bucket unless something reports what left" do
    test "a successful request is recorded against the venue" do
      # The incident: a venue acquired before every request and recorded none, so its
      # ceiling metered against a bucket nothing wrote to and every check passed.
      use_stub()

      assert {:ok, _response} = get(plug: responding(200, %{}), provider: "v")
      assert_received {:recorded, "v", 1}
    end

    test "weight is carried through to the record" do
      use_stub()

      assert {:ok, _response} = get(plug: responding(200, %{}), provider: "v", weight: 5)
      assert_received {:recorded, "v", 5}
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

  describe "transport failure" do
    test "a raising transport is contained rather than escaping to the caller" do
      plug = fn _conn -> raise "transport exploded" end
      assert {:error, message} = get(plug: plug, retry_attempts: 1)
      assert message =~ "Request"
    end
  end
end
