defmodule DpExchange.Core.BehavioursTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.RateLimitBehaviour

  # A behaviour is a contract, so what is worth asserting is the contract itself: which
  # callbacks exist, and which a venue may omit. An optional callback that should have been
  # required is a venue silently shipping without a capability; a required one that should
  # have been optional is ceremony every venue has to fake.
  #
  # **And who adopts it.** This file used to assert that `Core.DataProvider` declared
  # exactly 24 callbacks. It did, for as long as it existed, and not one of them was ever
  # implemented by anything — the assertion pinned a dead contract and kept it green, which
  # is `Core.UnwiredCheck`'s own line ("a test is not a caller") applied to a behaviour
  # instead of a function. The ledger below exists so the next orphan is visible the day it
  # is written rather than never.

  # Every module in this package that declares a `@callback`, and who implements it.
  #
  # A new behaviour with no entry here fails this file, which is the point: adding one
  # becomes a deliberate act with a stated adopter. An entry of `:none` is allowed and is
  # not a loophole — it is a visible, reviewable claim that a contract exists with nobody on
  # the other end, which is exactly the state two modules sat in undetected.
  @behaviour_adopters %{
    DpExchange.Core.Venue => "every venue package's facade module",
    DpExchange.Core.RateLimitBehaviour => "DpExchange.Core.DefaultRateLimiter",
    DpExchange.Core.SymbolNormalizer => "each venue's own SymbolFormat module"
  }

  describe "the behaviour ledger" do
    test "every behaviour this package declares has a stated adopter" do
      # Read from the compiled beams rather than from source text: `@callback` inside a
      # `quote` (which `Core.AdapterContract` uses heavily) is not a behaviour declaration,
      # and a grep cannot tell the two apart. `behaviour_info/1` is only exported by a
      # module that genuinely declares callbacks.
      declared =
        :code.lib_dir(:dp_exchange_core)
        |> Path.join("ebin/*.beam")
        |> Path.wildcard()
        |> Enum.map(&(&1 |> Path.basename(".beam") |> String.to_atom()))
        # `Code.ensure_loaded?/1` first: `function_exported?/3` answers `false` for a module
        # that is merely on disk, and every module here is lazily loaded. Without it this
        # check finds nothing and passes vacuously — which is the same shape of hole it was
        # written to close, so it is worth the extra line and this comment.
        |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :behaviour_info, 1)))
        |> MapSet.new()

      ledger = MapSet.new(Map.keys(@behaviour_adopters))

      unlisted = MapSet.difference(declared, ledger)
      stale = MapSet.difference(ledger, declared)

      assert MapSet.to_list(unlisted) == [],
             "behaviour(s) declared with no entry in @behaviour_adopters: " <>
               "#{inspect(MapSet.to_list(unlisted))}. Add one naming who implements it — " <>
               "or `:none`, which is a reviewable claim rather than an accident. " <>
               "Core.DataProvider sat unimplemented with 24 callbacks precisely because " <>
               "nothing made that state visible."

      assert MapSet.to_list(stale) == [],
             "@behaviour_adopters names module(s) that declare no callbacks: " <>
               "#{inspect(MapSet.to_list(stale))}"
    end

    test "no entry claims an adopter of :none without saying so out loud" do
      # `:none` is permitted; a vague string is not. A behaviour's adopter is either a
      # named thing or an explicit admission that there is nobody.
      for {module, adopter} <- @behaviour_adopters do
        assert adopter == :none or (is_binary(adopter) and byte_size(adopter) > 0),
               "#{inspect(module)} has no usable adopter entry"
      end
    end
  end

  describe "RateLimitBehaviour" do
    test "declares acquire, check and record, none optional" do
      callbacks = RateLimitBehaviour.behaviour_info(:callbacks)

      assert {:acquire, 3} in callbacks
      assert {:check, 3} in callbacks
      assert {:record, 3} in callbacks
      assert RateLimitBehaviour.behaviour_info(:optional_callbacks) == []
    end

    test "defines no functions of its own — it is a pure contract" do
      # The property the host had to assert with `use Boundary, deps: []`, and that is
      # structural here. A contract module that implements anything is no longer a
      # contract both sides can depend on; it is code one of them now owns.
      #
      # Asserted through the export list rather than the BEAM `imports` chunk: cover
      # instrumentation rewrites imports, so an imports-based check fails under
      # `mix test --cover` while nothing is actually wrong. Exports are stable across
      # both compilation modes.
      own_functions =
        RateLimitBehaviour.module_info(:exports)
        |> Enum.reject(fn {name, _arity} ->
          # Compiler-generated on every module, in every compilation mode.
          name in [:module_info, :behaviour_info, :__info__]
        end)

      assert own_functions == []
    end
  end
end
