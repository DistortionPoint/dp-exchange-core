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
        struct!(module, attrs_map)

      field ->
        raise ArgumentError,
              "#{inspect(module)}.new/1: required field #{inspect(field)} is nil or absent — " <>
                "a nil here is what a decode bug on a renamed venue field produces, and this " <>
                "constructor fails closed rather than build a struct the typespec says cannot occur"
    end
  end
end
