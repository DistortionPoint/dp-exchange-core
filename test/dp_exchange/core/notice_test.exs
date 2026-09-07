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

  # The canonical credential vocabulary, hardcoded here rather than read off the
  # module: `@credential_keys` is a private attribute, not a public surface to reach
  # into, the same reasoning the kind vocabulary above is exercised under.
  @credential_words ~w(api_key api_secret secret password passphrase token access_token
                       refresh_token private_key signature authorization bearer)

  defp mixed_case(word) do
    word
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.map_join(fn {char, i} -> if rem(i, 2) == 0, do: String.upcase(char), else: char end)
  end

  describe "a notice never carries credentials" do
    test "a credential-shaped key in details is refused, not redacted" do
      # Refused rather than redacted: redaction implies someone chose what to hide and
      # got it right. Refusing means the value never reaches a struct a consumer logs.
      for key <- @credential_words do
        assert_raise ArgumentError, ~r/credential-shaped keys/, fn ->
          Notice.new(:credentials_rejected, :v, details: %{String.to_atom(key) => "sk-live-x"})
        end
      end
    end

    test "the check is case-insensitive and covers string keys, for every credential key" do
      # C8 follow-up: the guard moved from comparing atoms to comparing strings
      # (`reject_credentials!/1` no longer calls `String.to_atom/1` on caller input at
      # all). This proves the behaviour did not weaken in the process — every key in
      # the vocabulary is still caught, atom or string, in every case.
      for key <- @credential_words,
          variant <- [key, String.upcase(key), mixed_case(key)] do
        assert_raise ArgumentError, ~r/credential-shaped keys/, fn ->
          Notice.new(:credentials_rejected, :v, details: %{variant => "x"})
        end

        assert_raise ArgumentError, ~r/credential-shaped keys/, fn ->
          Notice.new(:credentials_rejected, :v, details: %{String.to_atom(key) => "x"})
        end
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

    test "C8: many distinct, novel details keys never grow the atom table" do
      # `reject_credentials!/1` used to normalise every `details` key with
      # `String.to_atom/1` before comparing it. Atoms are never garbage collected and
      # the VM's atom table is finite (~1,048,576 by default) — `details` maps are
      # built by venue packages from venue-supplied content (a channel name, a raw
      # payload key, a symbol), so a venue varying that content over the process's
      # lifetime could walk the atom table to exhaustion through a guard whose entire
      # purpose is to make notices SAFE, killing the whole BEAM node, not just its own
      # package. Every key below is unique and unseen before this test runs, so the
      # old implementation would mint one fresh, permanent atom per iteration.
      # Asserted per-key via `String.to_existing_atom/1` rather than by watching
      # `:erlang.system_info(:atom_count)`. That count is process-GLOBAL and this suite is
      # `async: true`, so unrelated tests running concurrently move it — the first version
      # of this test did watch the count, passed locally, and then failed in CI (which runs
      # `max_cases: 8`) reporting a growth of 189 atoms that `reject_credentials!/1` had not
      # created. A test that reports a regression the code did not commit is worse than no
      # test: it teaches the reader to distrust it.
      #
      # This form is deterministic and asks the only question that matters, of the exact
      # keys in question: did building these notices mint an atom for any of them?
      keys = for i <- 1..5_000, do: "c8_regression_novel_key_#{i}_#{System.unique_integer()}"

      for key <- keys do
        Notice.new(:data_quality, :v, details: %{key => 1})
      end

      # The old implementation normalised with `key |> to_string() |> String.downcase() |>
      # String.to_atom()`, so the downcased form is precisely the atom it would have minted.
      # If that ever comes back, these stop raising and the test fails.
      for key <- keys do
        assert_raise ArgumentError, fn ->
          String.to_existing_atom(String.downcase(key))
        end
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

    test "an unknown severity raises rather than building a struct that violates its " <>
           "own typespec" do
      # `severity` is as closed a vocabulary as `kind` but, before this fix, had no
      # runtime check at all — a typo here silently built a `%Notice{}` whose `severity`
      # was outside `:info | :warning | :error`, with nothing catching it.
      assert_raise ArgumentError, ~r/unknown notice severity :critical/, fn ->
        Notice.new(:link_down, :v, severity: :critical)
      end
    end
  end

  describe "the nil-vs-absent Keyword.get trap, fixed for :severity, :at and :details" do
    # The same trap this family has paid for repeatedly elsewhere (`Config.opt/3`,
    # `PollingFeed`, `HttpClient`): a venue forwarding its own `opts` unchanged hands this
    # constructor a PRESENT key with an explicit `nil` whenever nothing upstream set it,
    # and `Keyword.get/3` only substitutes a default for an ABSENT key.

    test "an explicit nil severity falls back to the kind's default instead of building " <>
           "an invalid struct" do
      notice = Notice.new(:credentials_rejected, :v, severity: nil)
      assert notice.severity == :error
    end

    test "an explicit nil at falls back to now instead of a nil timestamp" do
      before = DateTime.utc_now()
      notice = Notice.new(:link_up, :v, at: nil)

      assert %DateTime{} = notice.at
      assert DateTime.compare(notice.at, before) in [:eq, :gt]
    end

    test "an explicit nil details falls back to an empty map instead of raising" do
      # Before this fix: `reject_credentials!/1` raised "must be a map, got nil" for
      # what is, from a forwarding caller's side, simply an unset optional field — not a
      # caller mistake worth failing on.
      notice = Notice.new(:link_up, :v, details: nil)
      assert notice.details == %{}
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
