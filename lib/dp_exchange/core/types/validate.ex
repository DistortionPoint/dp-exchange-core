defmodule DpExchange.Core.Types.Validate do
  @moduledoc """
  The validating constructor every `Types.*` struct builds `new/1` on.

  ## `@enforce_keys` guards presence, not `nil`

  `@enforce_keys [:open, :high, :low, :close, ...]` makes `struct!(Candle, attrs)` raise
  when a key is **absent** from `attrs`. It does nothing when the key is **present and
  `nil`**: `struct!(Candle, open: nil, high: ..., ...)` builds without complaint, even
  though `Candle`'s own typespec declares `open: Decimal.t()` — never `Decimal.t() | nil`.

  That gap is not academic. A `nil` in a field the typespec calls non-nilable is exactly
  what a JSON decode bug produces — `Map.get(json, "open")` on a key the venue renamed
  returns `nil`, silently, and every value downstream stays plausible until the struct
  reaches `Decimal.compare/2` or similar, several calls away from where the bad data
  actually entered. The error message at that point names a `Decimal` function, not the
  venue response that caused it.

  ## What `new!/3` adds

  `struct!/2`, plus a check that every field named in `required_non_nil` is present AND
  non-nil, raising `ArgumentError` naming the offending field when it is not. A caller gets
  a message pointing at the exact field and the venue's own module, at the moment the
  struct was about to be built — not a `FunctionClauseError` inside `Decimal` three frames
  later with no indication which field was the problem.

  ## What this deliberately does not do

  **No coercion, no defaulting, no guessing.** A `nil` where the type forbids one is an
  error, full stop — the same rule this whole family applies everywhere else. `new!/3`
  fails closed; it does not repair the input.

  **Two further values are refused in any field**, however deeply nested in a list, tuple
  or plain map: a `Decimal` that is `NaN` or infinite, which is not a number any field of
  these types can carry, and a `NaiveDateTime`, because every time in this family is a
  `DateTime` and a time with no zone cannot be placed.

  **Closed vocabularies are checked per type, not here.** `new!/3` knows nothing about which
  field is a `:buy | :sell`. A type whose typespec states one pipes its result through
  `one_of!/3` (and `positive_integer!/2` for a count), so `Fill`, `Trade`, `Position` and
  `OrderLeg` refuse a side outside what they state. The `Decimal` fields are not type-checked:
  a venue builds these with integers in its own tests and the typespec is the contract.

  ## Struct literals still work

  Nothing here removes `defstruct` or `@enforce_keys` from any `Types.*` module, and
  `%Candle{...}` remains a valid, unchecked way to build one — internal code and tests that
  already construct known-good values by hand are unaffected. `new/1` (built on this
  module, one per type) is the path a venue package's *decoder* should prefer, because it
  is the one that turns a decode bug into an error at the boundary instead of a crash three
  calls downstream.
  """

  @doc """
  Builds `module`'s struct from `attrs`, raising `ArgumentError` naming the field if any of
  `required_non_nil` is absent or explicitly `nil`.

  `required_non_nil` is ordinarily the type's own `@enforce_keys` — the fields whose
  typespec admits no `nil`. A type that deliberately allows `nil` on some enforced keys
  (see `DpExchange.Core.Types.Order`, which enforces presence of seven keys but documents
  that six of them may honestly be `nil`) passes a narrower list naming only the fields
  that must never be `nil`.
  """
  @spec new!(module(), [atom()], keyword() | map()) :: struct()
  def new!(module, required_non_nil, attrs) when is_atom(module) and is_list(required_non_nil) do
    attrs_map = Map.new(attrs)

    case Enum.find(required_non_nil, fn field -> is_nil(Map.get(attrs_map, field)) end) do
      nil ->
        refuse_unrepresentable!(module, attrs_map)
        struct!(module, attrs_map)

      field ->
        raise ArgumentError,
              "#{inspect(module)}.new/1: required field #{inspect(field)} is nil or absent — " <>
                "a nil here is what a decode bug on a renamed venue field produces, and this " <>
                "constructor fails closed rather than build a struct the typespec says cannot occur"
    end
  end

  @doc """
  Returns `built` if its `field` holds one of `allowed`, and raises `ArgumentError` naming
  the field and the value otherwise.

  For a closed vocabulary a type's own typespec states — `side: :buy | :sell`,
  `liquidity: :maker | :taker | nil`. `new!/3` refuses a `nil` and a NaN; it cannot refuse
  `side: :long` on a `Fill`, `side: "buy"` on a `Trade`, or `:buy` on a `Position`, and each
  of those is a plausible value with the wrong meaning: a position built `:buy` is read by
  a consumer matching `:long | :short` as no side at all, or as the wrong one. Include `nil`
  in `allowed` only where the type's typespec does.
  """
  @spec one_of!(struct(), atom(), [term()]) :: struct()
  def one_of!(%module{} = built, field, allowed) when is_atom(field) and is_list(allowed) do
    value = Map.fetch!(built, field)

    if value in allowed do
      built
    else
      raise ArgumentError,
            "#{inspect(module)}.new/1: field #{inspect(field)} is #{inspect(value)} — must " <>
              "be one of #{inspect(allowed)}"
    end
  end

  @doc """
  Returns `built` if its `field` holds a positive integer, and raises `ArgumentError`
  naming the field and the value otherwise.

  For a count or a ratio whose typespec is `pos_integer()`. A `Decimal` `1`, a float `1.0`
  and a `0` all read as "one leg" or "no legs" to whoever gets there first.
  """
  @spec positive_integer!(struct(), atom()) :: struct()
  def positive_integer!(%module{} = built, field) when is_atom(field) do
    case Map.fetch!(built, field) do
      value when is_integer(value) and value > 0 ->
        built

      value ->
        raise ArgumentError,
              "#{inspect(module)}.new/1: field #{inspect(field)} is #{inspect(value)} — " <>
                "must be a positive integer"
    end
  end

  # **Not-a-number and no-timezone are refused too, in any field.** A nil check let
  # `price: Decimal.new("NaN")` build: `Decimal.parse/1` reads "NaN" and "Infinity" in full,
  # so a venue sending one arrives as a well-formed `Decimal` that poisons arithmetic
  # silently and RAISES in `Decimal.compare/2` (`TopOfBook.crossed?/1`, `mid/1`) in the
  # consumer's process. And `observed_at: ~N[...]` built, a time with no zone where every
  # type in this family promises a `DateTime`. Neither is ever a legitimate value here: no
  # type has a field typed `NaiveDateTime`, and no quantity is infinite.
  #
  # **Inside lists and tuples too.** The scan was top-level only, so the `{price, quantity}`
  # levels of an `OrderBook`, `OrderBookDelta` or `VolumeProfile` carried a NaN straight past
  # it, which is the exact Decimal-raising value this check exists to stop, one container
  # deeper. Found 2026-10-10 by reading the path. Structs other than these two are not
  # descended into: a nested `Types.*` value was built by its own `new/1`.
  defp refuse_unrepresentable!(module, attrs_map) do
    Enum.each(attrs_map, fn {field, value} -> refuse_value!(module, field, value) end)
  end

  defp refuse_value!(module, field, %Decimal{coef: coef}) when coef in [:NaN, :inf] do
    raise ArgumentError,
          "#{inspect(module)}.new/1: field #{inspect(field)} is #{inspect(coef)} — not a " <>
            "number any field of this type can carry"
  end

  defp refuse_value!(module, field, %NaiveDateTime{}) do
    raise ArgumentError,
          "#{inspect(module)}.new/1: field #{inspect(field)} is a NaiveDateTime — every " <>
            "time in this family is a DateTime, and a time with no zone cannot be placed"
  end

  defp refuse_value!(module, field, values) when is_list(values),
    do: refuse_list!(module, field, values)

  defp refuse_value!(module, field, value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.each(&refuse_value!(module, field, &1))

  # Plain maps too, keys and values: `VolumeProfile.buy_at_price`, `OptionChain.expiries`
  # (Decimal strikes as keys) and `StakingBalance.by_provider` carry Decimals inside maps,
  # and a NaN there passed the scan and then raised in `Decimal.compare/2` or `add/2` inside
  # the consumer (`VolumeProfile.point_of_control/1`). Structs are skipped, as above.
  defp refuse_value!(module, field, value) when is_map(value) and not is_struct(value) do
    Enum.each(value, fn {key, inner} ->
      refuse_value!(module, field, key)
      refuse_value!(module, field, inner)
    end)
  end

  defp refuse_value!(_module, _field, _value), do: :ok

  # Walked by hand because `Enum.each/2` raises `FunctionClauseError` on an improper list,
  # which names Enumerable and not the field a decoder built the tail of.
  defp refuse_list!(_module, _field, []), do: :ok

  defp refuse_list!(module, field, [head | tail]) do
    refuse_value!(module, field, head)
    refuse_list!(module, field, tail)
  end

  defp refuse_list!(module, field, _improper_tail) do
    raise ArgumentError,
          "#{inspect(module)}.new/1: field #{inspect(field)} holds an improper list — every " <>
            "list in this family is proper, and a tail that is not a list cannot be scanned"
  end
end
