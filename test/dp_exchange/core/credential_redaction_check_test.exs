defmodule DpExchange.Core.CredentialRedactionCheckTest do
  @moduledoc """
  Exercises `DpExchange.Core.CredentialRedactionCheck` against real compiled `.beam`
  files, reusing `DpExchange.Core.UnwiredFixture` — it already compiles arbitrary source
  into `.beam` files under a controllable `lib_root` AND loads the resulting modules into
  this node, which is both what this check needs: it reads `lib_root` membership from the
  `.beam` file on disk, then calls `struct/2` and `inspect/1` on the already-loaded
  module.

  The first two tests reconstruct the actual pre-fix and post-fix shape found across four
  of five venue packages on 2026-09-07 (a `Credentials` struct with no `@derive`, then the
  same struct with `@derive {Inspect, except: [...]}` added) — proof this check would have
  caught the real fix's absence, without touching any venue repo.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{CredentialRedactionCheck, UnwiredFixture}

  defp uniq, do: System.unique_integer([:positive, :monotonic])

  defp violation_fields(violations) do
    Enum.map(violations, fn v -> {v.module, v.field} end)
  end

  describe "the defect this check exists for" do
    test "the pre-fix shape: a Credentials struct with no Inspect redaction at all" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "credentials.ex",
            code: """
            defmodule Credentials#{u} do
              defstruct [:api_key, :api_secret]
            end
            """
          }
        ])

      assert {:ok, violations} = CredentialRedactionCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "Credentials#{u}"])

      assert {mod, :api_key} in violation_fields(violations),
             "no Inspect override at all — the real pre-fix shape of every one of the " <>
               "four venue Credentials structs before their fix commit — must be caught"

      assert {mod, :api_secret} in violation_fields(violations)
    end

    test "the post-fix shape: @derive {Inspect, except: [...]} naming every secret field" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "credentials.ex",
            code: """
            defmodule Credentials#{u} do
              @derive {Inspect, except: [:api_key, :api_secret]}
              defstruct [:api_key, :api_secret]
            end
            """
          }
        ])

      assert {:ok, violations} = CredentialRedactionCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "Credentials#{u}"])

      refute Enum.any?(violations, &(&1.module == mod)),
             "the exact fix all four affected venues shipped — @derive {Inspect, " <>
               "except: [...]} naming every secret field — must pass"
    end
  end

  describe "run/2 — a hand-written defimpl Inspect is equally valid" do
    test "a custom Inspect implementation that never mentions @derive still passes" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "credentials.ex",
            code: """
            defmodule HandRolled#{u} do
              defstruct [:api_key, :api_secret]
            end

            defimpl Inspect, for: HandRolled#{u} do
              def inspect(_value, _opts), do: "#HandRolled#{u}<redacted>"
            end
            """
          }
        ])

      assert {:ok, violations} = CredentialRedactionCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "HandRolled#{u}"])

      refute Enum.any?(violations, &(&1.module == mod)),
             "this check verifies the rendered inspect/1 OUTPUT, not the presence of " <>
               "@derive — a hand-written defimpl that redacts is just as valid a fix"
    end

    test "a custom Inspect implementation that DOES print the secret is still caught" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "credentials.ex",
            code: """
            defmodule LeakyImpl#{u} do
              defstruct [:api_key]
            end

            defimpl Inspect, for: LeakyImpl#{u} do
              def inspect(value, _opts), do: "#LeakyImpl#{u}<\#{value.api_key}>"
            end
            """
          }
        ])

      assert {:ok, violations} = CredentialRedactionCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "LeakyImpl#{u}"])

      assert {mod, :api_key} in violation_fields(violations),
             "a defimpl Inspect exists, but it prints the raw field — checking for the " <>
               "OUTPUT rather than for @derive's presence is exactly what catches this"
    end
  end

  describe "run/2 — the secret-name list" do
    test "app_key and app_secret (Webull's own field names) are checked" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "credentials.ex",
            code: """
            defmodule WebullLike#{u} do
              defstruct [:app_key, :app_secret, :access_token]
            end
            """
          }
        ])

      assert {:ok, violations} = CredentialRedactionCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "WebullLike#{u}"])
      fields = violation_fields(violations)

      assert {mod, :app_key} in fields
      assert {mod, :app_secret} in fields
      assert {mod, :access_token} in fields
    end

    test "client_secret (Schwab's own field name) is checked" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "credentials.ex",
            code: """
            defmodule SchwabLike#{u} do
              defstruct [:client_id, :client_secret, :refresh_token]
            end
            """
          }
        ])

      assert {:ok, violations} = CredentialRedactionCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "SchwabLike#{u}"])
      fields = violation_fields(violations)

      assert {mod, :client_secret} in fields
      assert {mod, :refresh_token} in fields
    end

    test "client_id is deliberately NOT a secret name — an unredacted client_id passes" do
      # Schwab's own real struct redacts client_id too, but that is Schwab choosing to
      # hide more than required, not evidence the name itself is secret-shaped — see the
      # moduledoc. A venue that leaves a genuinely public client_id readable must not be
      # flagged for it.
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "credentials.ex",
            code: """
            defmodule PublicClientId#{u} do
              @derive {Inspect, except: [:client_secret]}
              defstruct [:client_id, :client_secret]
            end
            """
          }
        ])

      assert {:ok, violations} = CredentialRedactionCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "PublicClientId#{u}"])

      refute Enum.any?(violations, &(&1.module == mod and &1.field == :client_id))
    end

    test "private_key (Robinhood's own field name) is checked" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "credentials.ex",
            code: """
            defmodule RobinhoodLike#{u} do
              defstruct [:api_key, :private_key]
            end
            """
          }
        ])

      assert {:ok, violations} = CredentialRedactionCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "RobinhoodLike#{u}"])
      fields = violation_fields(violations)

      assert {mod, :api_key} in fields
      assert {mod, :private_key} in fields
    end

    test "a field name that merely contains a secret word as a substring is not matched" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "not_secret.ex",
            code: """
            defmodule TokenType#{u} do
              defstruct [:token_type, :tokenizer_state]
            end
            """
          }
        ])

      assert {:ok, violations} = CredentialRedactionCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "TokenType#{u}"])

      refute Enum.any?(violations, &(&1.module == mod)),
             "field NAME must match exactly — :token_type and :tokenizer_state are not " <>
               ":token, and matching by substring would be exactly the over-broad check " <>
               "the moduledoc argues against"
    end
  end

  describe "run/2 — what is not a candidate at all" do
    test "a plain map with a secret-named key, never a struct, is never flagged" do
      # This is the actual pre-fix shape of the original defect — Feed/Socket held
      # `Keyword.get(opts, :credentials)` as a bare MAP, never a struct — and this proves
      # the documented limitation directly: this check cannot see it, by design, because
      # nothing here is a struct at all.
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "feed.ex",
            code: """
            defmodule RawMapFeed#{u} do
              use GenServer

              @impl true
              def init(opts) do
                {:ok, %{credentials: Keyword.get(opts, :credentials)}}
              end
            end
            """
          }
        ])

      assert {:ok, violations} = CredentialRedactionCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "RawMapFeed#{u}"])

      refute Enum.any?(violations, &(&1.module == mod)),
             "RawMapFeed#{u} holds credentials as a bare map, never a struct — this is " <>
               "the documented boundary of what this check can see, proven directly " <>
               "rather than only asserted in prose"
    end

    test "a struct with no secret-named field at all passes trivially" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "quote.ex",
            code: """
            defmodule PlainQuote#{u} do
              defstruct [:symbol, :price, :timestamp]
            end
            """
          }
        ])

      assert {:ok, violations} = CredentialRedactionCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "PlainQuote#{u}"])
      refute Enum.any?(violations, &(&1.module == mod))
    end

    test "a struct with @enforce_keys on an unrelated field still constructs cleanly" do
      # struct/2 (never struct!/2) must be used internally, or this would raise
      # ArgumentError on any struct enforcing a field other than the secret one — proven
      # here rather than only asserted, since DpExchange.Core.Notice (a real struct in
      # this same package) enforces :kind, :provider, :severity and :at.
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "enforced.ex",
            code: """
            defmodule Enforced#{u} do
              @enforce_keys [:id]
              defstruct [:id, :api_key]
            end
            """
          }
        ])

      assert {:ok, violations} = CredentialRedactionCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "Enforced#{u}"])
      assert {mod, :api_key} in violation_fields(violations)
    end

    test "a module whose source is outside lib_root is never analysed" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "../not_lib/outside_credentials.ex",
            code: """
            defmodule OutsideCredentials#{u} do
              defstruct [:api_key, :api_secret]
            end
            """
          }
        ])

      assert {:ok, violations} = CredentialRedactionCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "OutsideCredentials#{u}"])
      refute Enum.any?(violations, &(&1.module == mod))
    end
  end

  describe "run/2 — I/O edge cases" do
    test "an empty beam_dir yields no violations" do
      lib_root =
        Path.join([File.cwd!(), "tmp", "unwired_check_test", "credential_empty_lib_#{uniq()}"])

      beam_dir =
        Path.join([File.cwd!(), "tmp", "unwired_check_test", "credential_empty_beam_#{uniq()}"])

      File.mkdir_p!(beam_dir)

      assert {:ok, []} = CredentialRedactionCheck.run(beam_dir, lib_root)
    end
  end

  describe "format/1" do
    test "renders one line per violation naming the module, field and location" do
      violations = [%{module: Some.Credentials, field: :api_secret, file: "/a/credentials.ex"}]

      rendered = CredentialRedactionCheck.format(violations)

      assert rendered =~ "Some.Credentials"
      assert rendered =~ ":api_secret"
      assert rendered =~ "/a/credentials.ex"
      assert rendered =~ "cleartext"
    end
  end
end
