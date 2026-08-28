defmodule DpExchange.Core.NoticeTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Notice

  doctest Notice

  describe "new/3" do
    test "builds a notice with the fields a consumer needs to act" do
      notice = Notice.new(:link_down, :some_venue, message: "socket closed")

      assert notice.kind == :link_down
      assert notice.provider == :some_venue
      assert notice.message == "socket closed"
      assert %DateTime{} = notice.at
      assert notice.details == %{}
    end

    test "the timestamp defaults to now, which is correct for a notice" do
      # Unlike market data there is no venue event time to preserve. The package is
      # reporting on itself, so the moment it noticed IS the fact.
      before = DateTime.utc_now()
      notice = Notice.new(:link_up, :v)

      assert DateTime.compare(notice.at, before) in [:eq, :gt]
    end

    test "an explicit time is kept" do
      at = ~U[2026-08-27 12:00:00Z]
      assert %Notice{at: ^at} = Notice.new(:link_up, :v, at: at)
    end
  end

  describe "the kind vocabulary is closed" do
    test "every declared kind can be built" do
      for kind <- Notice.kinds() do
        assert %Notice{kind: ^kind} = Notice.new(kind, :v)
      end
    end

    test "an unknown kind raises rather than becoming a notice nobody matches" do
      # A typo would otherwise produce a notice that no consumer matches on and that
      # therefore nobody ever sees — the failure being loud is the whole point.
      assert_raise ArgumentError, ~r/unknown notice kind/, fn ->
        Notice.new(:lnik_down, :v)
      end
    end

    test "the vocabulary covers every group the contract names" do
      kinds = Notice.kinds()

      for kind <- [:link_up, :link_down, :link_reconnecting, :link_recovered] do
        assert kind in kinds
      end

      for kind <- [:credentials_rejected, :credentials_expiring, :session_refresh_failed] do
        assert kind in kinds
      end

      for kind <- [
            :rate_limited,
            :coverage_change,
            :catalog_change,
            :refusal,
            :data_quality,
            :degraded
          ] do
        assert kind in kinds
      end
    end

    test "no kind names a transport" do
      # "The venue link is down" is the fact; whether that link is a WebSocket, an MQTT
      # session or a polling loop is package-internal and not a consumer's concern.
      for kind <- Notice.kinds() do
        name = to_string(kind)

        for transport <- ~w(websocket ws socket mqtt http poll sse grpc) do
          refute name =~ transport, "notice kind #{kind} names a transport"
        end
      end
    end
  end

  describe "a notice never carries credentials" do
    test "a credential-shaped key in details is refused, not redacted" do
      # Refused rather than redacted: redaction implies someone chose what to hide and
      # got it right. Refusing means the value never reaches a struct a consumer logs.
      for key <- [:api_key, :api_secret, :secret, :passphrase, :token, :private_key] do
        assert_raise ArgumentError, ~r/credential-shaped keys/, fn ->
          Notice.new(:credentials_rejected, :v, details: %{key => "sk-live-abc123"})
        end
      end
    end

    test "the check is case-insensitive and covers string keys" do
      assert_raise ArgumentError, ~r/credential-shaped keys/, fn ->
        Notice.new(:credentials_rejected, :v, details: %{"API_KEY" => "x"})
      end
    end

    test "naming WHICH credential failed is allowed — that is the useful part" do
      notice =
        Notice.new(:credentials_rejected, :v,
          message: "the trading key was rejected",
          details: %{credential_name: "trading", rejected_at: ~U[2026-08-27 12:00:00Z]}
        )

      assert notice.details.credential_name == "trading"
    end

    test "non-map details are refused" do
      assert_raise ArgumentError, ~r/must be a map/, fn ->
        Notice.new(:link_up, :v, details: [api_key: "x"])
      end
    end
  end

  describe "severity" do
    test "defaults reflect how much a consumer should care" do
      assert Notice.new(:link_down, :v).severity == :error
      assert Notice.new(:credentials_rejected, :v).severity == :error
      assert Notice.new(:rate_limited, :v).severity == :warning
      assert Notice.new(:link_up, :v).severity == :info
      assert Notice.new(:catalog_change, :v).severity == :info
    end

    test "a caller with better information overrides the default" do
      assert Notice.new(:catalog_change, :v, severity: :error).severity == :error
    end
  end

  describe "catalog_change carries whether it was observed or announced" do
    test "a diffed delisting says so" do
      # Most venues do not announce a delisting — the pair simply stops appearing — so
      # the package learns it by diffing and must not present that as the venue's word.
      notice =
        Notice.new(:catalog_change, :v,
          details: %{symbol: "OLD-USD", status: :delisted, observed: true}
        )

      assert notice.details.observed
      assert notice.details.status == :delisted
    end
  end
end
