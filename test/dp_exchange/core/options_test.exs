defmodule DpExchange.Core.OptionsTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Options

  doctest Options

  describe "check/2" do
    test "an empty list is fine" do
      assert Options.check([], [:limit]) == :ok
      assert Options.check([], []) == :ok
    end

    test "known keys pass, in any order and with any value" do
      assert Options.check([since: 1, limit: nil], [:limit, :since]) == :ok
    end

    test "the first unknown key, in the caller's order, is named" do
      assert Options.check([limit: 1, sinse: 2, other: 3], [:limit]) ==
               {:error, {:unknown_option, :sinse}}
    end

    test "a nil-valued unknown key is refused too" do
      assert Options.check([limt: nil], [:limit]) == {:error, {:unknown_option, :limt}}
    end

    test "a key the venue did not list is unknown even when valid elsewhere" do
      assert Options.check([plug: :x], [:limit]) == {:error, {:unknown_option, :plug}}
      assert Options.check([plug: :x], [:limit | Options.transport_options()]) == :ok
    end

    test "something that is not a keyword list is {:invalid_options, opts}" do
      for bad <- [%{limit: 1}, nil, "limit", [{"limit", 1}], [:limit], [{:limit, 1}, :bad], 42] do
        assert Options.check(bad, [:limit]) == {:error, {:invalid_options, bad}}
      end
    end

    test "the credentials in a refused opts are not echoed in the tuple" do
      secret = "sk-live-OPTIONS-0123456789"
      creds = %{api_key: secret, api_secret: secret}

      for bad <- [
            %{limit: 1, credentials: creds},
            [{:limit, 1}, {:credentials, creds}, :stray],
            %{"credentials" => creds},
            # Improper: a refusal must answer, not raise in `Enum.map/2`.
            [{:limit, 1}, {:credentials, creds} | :improper_tail]
          ] do
        assert {:error, {:invalid_options, echoed}} = Options.check(bad, [:limit])

        refute inspect(echoed) =~ secret
        assert inspect(echoed) =~ ":redacted"
      end

      assert {:error, {:invalid_options, %{limit: 1}}} =
               Options.check(%{limit: 1}, [:limit])
    end
  end

  describe "transport_options/0" do
    test "is a list of unique atoms" do
      keys = Options.transport_options()

      assert Enum.all?(keys, &is_atom/1)
      assert keys == Enum.uniq(keys)
    end

    test "carries credentials, the Req seams and the limiter, timeout and retry knobs" do
      keys = Options.transport_options()

      for key <- [
            :credentials,
            :environment,
            :base_url,
            :plug,
            :adapter,
            :req_adapter,
            :limiter,
            :rate_limit_blocking,
            :timeout,
            :retry_attempts,
            :retry_delay,
            :max_retry_after_s,
            :max_body_bytes,
            :weight,
            :log_requests
          ] do
        assert key in keys
      end
    end

    test "carries no venue-specific semantic key" do
      keys = Options.transport_options()

      for key <- [:limit, :since, :depth, :include_partial, :category, :provider] do
        refute key in keys
      end
    end
  end
end
