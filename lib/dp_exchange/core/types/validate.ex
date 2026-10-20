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
  `OrderLeg` refuse a side outside what they state. The `Decimal` fields are type-checked
  through `decimals!/2` (and `decimal_map_values!/2` for maps of Decimals): a type pipes its
  result through them for every field its typespec states as `Decimal.t()`, and a string, a
  map or any other non-number is an `ArgumentError` naming module, field and value (an
  integer is accepted, and a venue builds these with integers in its own tests). A **float**
  is refused at the top level of any field and inside a list or
  tuple, because no field of any type is a float and a float has already lost digits. Free-form
  maps (`details`, `line_items`, `metrics`) may still hold one: they are the venue's own.

  **Value rules a type's own doc states are held per type too**, by `positive!/2` (a traded
  price, a resting bid or ask, a position or withdrawal size, a strike), `non_negative!/2`,
  `text!/2` (an address, network, asset or id is a non-blank string), `maps!/2`, `dates!/2`,
  `datetimes!/2` (a time field `new!/3` cannot recognise by name) and `symbol_lists!/2` (a
  container of the right shape or `nil`). Each names module, field and
  value, accepts `nil` (presence is `new!/3`'s job) and never repairs the input.

  ## Struct literals still work

  Nothing here removes `defstruct` or `@enforce_keys` from any `Types.*` module, and
  `%Candle{...}` remains a valid, unchecked way to build one — internal code and tests that
  already construct known-good values by hand are unaffected. `new/1` (built on this
  module, one per type) is the path a venue package's *decoder* should prefer, because it
  is the one that turns a decode bug into an error at the boundary instead of a crash three
  calls downstream.
  """

  @max_decimal_exponent 1_000

  @doc """
  The widest exponent a `Decimal` may carry in any field (`+/-1000`). Exposed so a venue
  decoder's own `decimal/1` can apply the same bound before building a value.
  """
  @spec max_decimal_exponent() :: pos_integer()
  def max_decimal_exponent, do: @max_decimal_exponent

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
  Returns `built` if every one of `fields` holds a `Decimal`, an integer or `nil`, and
  raises `ArgumentError` naming module, field and value otherwise.

  For the fields a type's typespec states as `Decimal.t()` (or `Decimal.t() | nil`). A
  `"1.5"`, `"abc"` or a map in one builds fine under `new!/3` and raises inside
  `Decimal.compare/2` in the CONSUMER's process, so a decoder that forgot to parse a number
  is refused here, at the boundary. An integer is accepted (venues build with integers in
  their own tests). `nil` passes this check because presence is `new!/3`'s job: a field
  whose typespec forbids `nil` is already in `required_non_nil`, and a field whose typespec
  allows it must not be refused here. Floats, NaN, infinities and absurd exponents are
  refused by `new!/3` itself.
  """
  @spec decimals!(struct(), [atom()]) :: struct()
  def decimals!(%module{} = built, fields) when is_list(fields) do
    Enum.each(fields, fn field ->
      case Map.fetch!(built, field) do
        nil -> :ok
        value -> decimal!(module, field, value)
      end
    end)

    built
  end

  @doc """
  Returns `built` if each of `fields` is `nil` or a number that is not negative, and raises
  `ArgumentError` naming module, field and value otherwise.

  For a size, quantity or volume: a negative one is never what a venue traded or quoted, it
  is a decode bug (a sign flipped, a delta read as a level), and every value around it stays
  plausible. Zero is allowed here, because a zero size is a real answer (an empty side, a
  flat interval); a type that cannot carry zero says so itself. Run it after `decimals!/2`,
  which guarantees the fields hold a `Decimal`, an integer or `nil`.
  """
  @spec non_negative!(struct(), [atom()]) :: struct()
  def non_negative!(%module{} = built, fields) when is_list(fields) do
    Enum.each(fields, fn field ->
      case Map.fetch!(built, field) do
        nil -> :ok
        value -> non_negative_value!(module, field, value)
      end
    end)

    built
  end

  @doc """
  Returns `built` if each of `fields` is `nil` or a number above zero, and raises
  `ArgumentError` naming module, field and value otherwise.

  For a traded price, a resting bid or ask, and a position's size: zero is not a price (a
  venue's `0` means "no resting order", which its decoder turns into `nil`) and not a size
  that is held. Run it after `decimals!/2`, which guarantees a `Decimal`, an integer or `nil`.
  """
  @spec positive!(struct(), [atom()]) :: struct()
  def positive!(%module{} = built, fields) when is_list(fields) do
    Enum.each(fields, fn field ->
      case Map.fetch!(built, field) do
        nil -> :ok
        value -> positive_value!(module, field, value)
      end
    end)

    built
  end

  @doc """
  Returns `built` if each of `fields` is `nil` or a non-blank string, and raises
  `ArgumentError` naming module, field and value otherwise.

  For the identifying text of a funds-moving or addressing field (an address, a network, an
  asset, an id). A blank string is no name at all and an atom or number is not the venue's
  text; both used to build, and an address with an empty network is the one the deposit is
  lost to.
  """
  @spec text!(struct(), [atom()]) :: struct()
  def text!(%module{} = built, fields) when is_list(fields) do
    each_present(built, fields, fn field, value ->
      unless is_binary(value) and String.trim(value) != "" do
        raise_shape!(module, field, value, "a non-blank string")
      end
    end)
  end

  @doc """
  Returns `built` if each of `fields` is `nil` or a plain map (not a struct), and raises
  `ArgumentError` otherwise. For the free-form maps (`details`, `line_items`, `metrics`) whose
  contents are the venue's own but whose container is not.
  """
  @spec maps!(struct(), [atom()]) :: struct()
  def maps!(%module{} = built, fields) when is_list(fields) do
    each_present(built, fields, fn field, value ->
      unless is_map(value) and not is_struct(value) do
        raise_shape!(module, field, value, "a map")
      end
    end)
  end

  @doc """
  Returns `built` if each of `fields` is `nil` or a `Date`, and raises `ArgumentError`
  otherwise. A `DateTime` or a string there sorts and compares wrongly in the consumer.
  """
  @spec dates!(struct(), [atom()]) :: struct()
  def dates!(%module{} = built, fields) when is_list(fields) do
    each_present(built, fields, fn field, value ->
      unless is_struct(value, Date), do: raise_shape!(module, field, value, "a Date")
    end)
  end

  @doc """
  Returns `built` if each of `fields` is `nil` or a `DateTime`, and raises `ArgumentError`
  naming module, field and value otherwise.

  For a time whose field name `new!/3` cannot recognise as one. `new!/3` holds `:venue_time`,
  `:timestamp`, `:as_of`, `:active_from` and every `*_at` to this rule by name; a field typed
  `DateTime.t()` outside that vocabulary (`StakingReward`'s `:period_start` and `:period_end`,
  which cannot join the global rule because a filing's same-named fields are `Date`s) is named
  here by its type instead. A `Date`, a string or an epoch integer there built, and then
  crashed `DateTime.compare/2` in the consumer. A `NaiveDateTime` is refused by `new!/3` first.
  """
  @spec datetimes!(struct(), [atom()]) :: struct()
  def datetimes!(%module{} = built, fields) when is_list(fields) do
    each_present(built, fields, fn field, value ->
      unless is_struct(value, DateTime), do: raise_shape!(module, field, value, "a DateTime")
    end)
  end

  @doc """
  Returns `built` if each of `fields` is `nil` or a proper list of non-blank strings, and
  raises `ArgumentError` otherwise. `nil` and `[]` stay different answers ("not fetched" and
  "fetched, empty"); anything else, a bare string included, is neither.
  """
  @spec symbol_lists!(struct(), [atom()]) :: struct()
  def symbol_lists!(%module{} = built, fields) when is_list(fields) do
    each_present(built, fields, fn field, value ->
      unless symbol_list?(value), do: raise_shape!(module, field, value, "a list of strings")
    end)
  end

  defp symbol_list?([]), do: true

  defp symbol_list?([head | tail]),
    do: is_binary(head) and String.trim(head) != "" and symbol_list?(tail)

  defp symbol_list?(_other), do: false

  defp each_present(built, fields, check) do
    Enum.each(fields, fn field ->
      case Map.fetch!(built, field) do
        nil -> :ok
        value -> check.(field, value)
      end
    end)

    built
  end

  # **The offending value in a message is always bounded.** A decoder hands these constructors
  # whatever it parsed, and a venue body of megabytes (or a caller-supplied map holding
  # anything) became a megabyte exception message, copied into every log line and crash report
  # that carried it. Five items and 40 printable bytes name the value; a small value reads
  # exactly as plain `inspect/1` printed it.
  #
  # **Cut after rendering as well as inside `inspect/2`.** `Decimal`'s `Inspect` ignores
  # `:printable_limit` and prints every digit (verified in Decimal 3.2.0), and the
  # `{price, quantity}` levels of a book are tuples of them, so `inspect/2`'s own limits do not
  # bound a Decimal with twenty thousand digits. The rendering is therefore clipped to
  # `@shown_chars`; a value that prints shorter than that is untouched.
  @shown_chars 200

  @doc false
  @spec show(term()) :: String.t()
  def show(value) do
    text = inspect(value, limit: 5, printable_limit: 40)

    if byte_size(text) > @shown_chars,
      do: String.slice(text, 0, @shown_chars) <> "...",
      else: text
  end

  defp raise_shape!(module, field, value, wanted) do
    raise ArgumentError,
          "#{inspect(module)}.new/1: field #{inspect(field)} holds " <>
            "#{show(value)} — must be #{wanted} or nil"
  end

  defp positive_value!(module, field, value) do
    if Decimal.compare(value, 0) != :gt do
      raise ArgumentError,
            "#{inspect(module)}.new/1: field #{inspect(field)} is #{show(value)} — it must " <>
              "be above zero; zero or a negative here is a decode bug (a venue's 0 for " <>
              "\"none\" belongs as nil)"
    end

    :ok
  end

  defp non_negative_value!(module, field, value) do
    if Decimal.compare(value, 0) == :lt do
      raise ArgumentError,
            "#{inspect(module)}.new/1: field #{inspect(field)} is #{show(value)} — a size, " <>
              "quantity or volume is never negative; a negative one is a decode bug"
    end

    :ok
  end

  @doc """
  Returns `built` if each of `fields` is `nil` or a map whose values are all `Decimal`s or
  integers, and raises `ArgumentError` naming module, field and value otherwise.

  For `%{String.t() => Decimal.t()}` fields (`VolumeProfile.buy_at_price`,
  `StakingBalance.by_provider`). A field holding something other than a map is refused.
  """
  @spec decimal_map_values!(struct(), [atom()]) :: struct()
  def decimal_map_values!(%module{} = built, fields) when is_list(fields) do
    Enum.each(fields, fn field ->
      case Map.fetch!(built, field) do
        nil -> :ok
        map when is_map(map) and not is_struct(map) -> decimal_values!(module, field, map)
        other -> raise_not_decimal!(module, field, other, "a map of Decimals")
      end
    end)

    built
  end

  defp decimal_values!(module, field, map) do
    Enum.each(map, fn {_key, value} -> decimal!(module, field, value) end)
  end

  @doc """
  Raises `ArgumentError` naming `module`, `field` and `value` unless `value` is a `Decimal`
  or an integer; returns `:ok` otherwise.

  The element-level check for a type that walks a nested structure itself (order book
  levels, option strikes). `nil` is NOT accepted here.
  """
  @spec decimal!(module(), atom(), term()) :: :ok
  def decimal!(_module, _field, %Decimal{}), do: :ok
  def decimal!(_module, _field, value) when is_integer(value), do: :ok

  def decimal!(module, field, value),
    do: raise_not_decimal!(module, field, value, "a Decimal (or an integer)")

  defp raise_not_decimal!(module, field, value, wanted) do
    raise ArgumentError,
          "#{inspect(module)}.new/1: field #{inspect(field)} holds " <>
            "#{show(value)} — must be #{wanted}; a decoder " <>
            "that passes a string or a map through builds a struct that raises inside " <>
            "Decimal.compare/2 in the consumer's process"
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
            "#{inspect(module)}.new/1: field #{inspect(field)} is #{show(value)} — must " <>
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
              "#{inspect(module)}.new/1: field #{inspect(field)} is #{show(value)} — " <>
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
  #
  # **One walk, not two.** The NaN/exponent/NaiveDateTime scan and the float scan used to be
  # separate traversals, so every field of every constructed struct was walked twice and an
  # order book's levels twice over. `refuse_value!/4` carries `floats?` and does both in one
  # pass; it is `false` once the walk enters a plain map (see the float note below).
  defp refuse_unrepresentable!(module, attrs_map) do
    Enum.each(attrs_map, fn {field, value} ->
      refuse_non_datetime!(module, field, value)
      refuse_identity!(module, field, value)
      refuse_value!(module, field, value, true)
    end)
  end

  # **`:symbol` is a non-blank binary and `:provider` an atom or binary, wherever they are
  # not `nil`.** Every type's typespec says `symbol: String.t()` and `provider: atom()`, and
  # nothing enforced either: `symbol: 5`, `symbol: :btc_usd` or `symbol: ""` built, then
  # matched no subscription and no `Map.get` in the consumer, and a `provider` of `42` or a
  # map was never any venue's name. A binary provider is accepted because eight types state
  # `atom() | String.t()` and the rest are leniently read the same way here. `nil` is
  # `new!/3`'s presence check.
  defp refuse_identity!(_module, _field, nil), do: :ok

  defp refuse_identity!(module, :symbol, value) do
    unless is_binary(value) and String.trim(value) != "" do
      raise ArgumentError,
            "#{inspect(module)}.new/1: field :symbol is #{show(value)} — must be a " <>
              "non-blank string"
    end
  end

  defp refuse_identity!(module, :provider, value) do
    unless is_atom(value) or is_binary(value) do
      raise ArgumentError,
            "#{inspect(module)}.new/1: field :provider is #{show(value)} — must be an " <>
              "atom (or a string)"
    end
  end

  defp refuse_identity!(_module, _field, _value), do: :ok

  # **A time field holds a `DateTime` or `nil`, and nothing else.** Every time in this family
  # is a `DateTime` (`observed_at`, `venue_time`, `timestamp`, `as_of`, every `*_at`), and the
  # scan above refused only a `NaiveDateTime`: `observed_at: "2026-10-14T10:00:00Z"` and
  # `venue_time: 1_760_000_000` built, and a consumer that compared them with
  # `DateTime.compare/2` or `DateTime.diff/3` crashed in its own process. `nil` passes because
  # presence is `new!/3`'s job. `period_start` and `period_end` are not in this rule: a
  # filing's are `Date`s. `StakingReward`'s are `DateTime`s and hold themselves to it with
  # `datetimes!/2`; they built from a `Date`, a string or an epoch integer before that.
  @time_fields [:venue_time, :timestamp, :as_of, :active_from]

  # A `NaiveDateTime` is left to `refuse_value!/4`, which names it.
  defp refuse_non_datetime!(_module, _field, nil), do: :ok

  defp refuse_non_datetime!(module, field, value)
       when not is_struct(value, DateTime) and
              not is_struct(value, NaiveDateTime) and is_atom(field) do
    if time_field?(field) do
      raise ArgumentError,
            "#{inspect(module)}.new/1: field #{inspect(field)} is #{show(value)} — every " <>
              "time in this family is a DateTime or nil; decode the time before building"
    end
  end

  defp refuse_non_datetime!(_module, _field, _value), do: :ok

  defp time_field?(field) when field in @time_fields, do: true
  defp time_field?(field), do: field |> Atom.to_string() |> String.ends_with?("_at")

  # **A float is refused too, but only where no type could mean one.** No `Types.*` field is
  # typed `float()`; every number is a `Decimal` or an integer, and a float in one is a venue
  # decoder that let `Jason` turn `"0.1"`-style JSON numbers into binary floats (`0.1` is
  # `0.1000000000000000055511151231257827…`), after which every digit past the 17th is gone
  # and the value still prints as plausible. Scanned at the top level and inside lists and
  # tuples (the `{price, quantity}` levels of an order book). NOT inside plain maps: the
  # free-form `term()` payloads (`details`, `line_items`, `metrics`) are the venue's own and
  # may hold any JSON value.
  defp refuse_value!(module, field, value, true) when is_float(value) do
    raise ArgumentError,
          "#{inspect(module)}.new/1: field #{inspect(field)} holds float #{inspect(value)} " <>
            "— every number in this family is a Decimal (or an integer), and a float has " <>
            "already lost digits; decode the venue's number as a Decimal"
  end

  defp refuse_value!(module, field, %Decimal{coef: coef}, _floats?) when coef in [:NaN, :inf] do
    raise ArgumentError,
          "#{inspect(module)}.new/1: field #{inspect(field)} is #{inspect(coef)} — not a " <>
            "number any field of this type can carry"
  end

  # **An absurd exponent is refused too.** `Decimal.parse("1e5000")` is a well-formed
  # `Decimal` with `exp: 5_000`, and `Decimal.add/2`, `sub/2` and `compare/2` align the
  # two operands' exponents by multiplying a coefficient by `10^(difference)` with no bound:
  # a single such value in a `price` makes `TopOfBook.mid/1`, `crossed?/1` or
  # `VolumeProfile.point_of_control/1` build a number of hundreds of megabytes, stalling or
  # killing the CONSUMER's process, with no error naming the venue. No real quantity needs
  # more than a few dozen digits either side of the point, so the bound is generous.
  defp refuse_value!(module, field, %Decimal{exp: exp}, _floats?)
       when abs(exp) > @max_decimal_exponent do
    raise ArgumentError,
          "#{inspect(module)}.new/1: field #{inspect(field)} is a Decimal with exponent " <>
            "#{exp} — outside +/-#{@max_decimal_exponent}, which no real quantity needs and " <>
            "which makes later arithmetic allocate a number of that many digits"
  end

  defp refuse_value!(module, field, %NaiveDateTime{}, _floats?) do
    raise ArgumentError,
          "#{inspect(module)}.new/1: field #{inspect(field)} is a NaiveDateTime — every " <>
            "time in this family is a DateTime, and a time with no zone cannot be placed"
  end

  defp refuse_value!(module, field, values, floats?) when is_list(values),
    do: refuse_list!(module, field, values, floats?)

  defp refuse_value!(module, field, value, floats?) when is_tuple(value),
    do: refuse_tuple!(module, field, value, floats?, tuple_size(value))

  # Plain maps too, keys and values: `VolumeProfile.buy_at_price`, `OptionChain.expiries`
  # (Decimal strikes as keys) and `StakingBalance.by_provider` carry Decimals inside maps,
  # and a NaN there passed the scan and then raised in `Decimal.compare/2` or `add/2` inside
  # the consumer (`VolumeProfile.point_of_control/1`). Structs are skipped, as above.
  defp refuse_value!(module, field, value, _floats?)
       when is_map(value) and not is_struct(value) do
    Enum.each(value, fn {key, inner} ->
      refuse_value!(module, field, key, false)
      refuse_value!(module, field, inner, false)
    end)
  end

  defp refuse_value!(_module, _field, _value, _floats?), do: :ok

  # Elements by index: no `Tuple.to_list/1` copy for each `{price, quantity}` level.
  defp refuse_tuple!(_module, _field, _tuple, _floats?, 0), do: :ok

  defp refuse_tuple!(module, field, tuple, floats?, index) do
    refuse_value!(module, field, elem(tuple, index - 1), floats?)
    refuse_tuple!(module, field, tuple, floats?, index - 1)
  end

  # Walked by hand because `Enum.each/2` raises `FunctionClauseError` on an improper list,
  # which names Enumerable and not the field a decoder built the tail of.
  defp refuse_list!(_module, _field, [], _floats?), do: :ok

  defp refuse_list!(module, field, [head | tail], floats?) do
    refuse_value!(module, field, head, floats?)
    refuse_list!(module, field, tail, floats?)
  end

  defp refuse_list!(module, field, _improper_tail, _floats?) do
    raise ArgumentError,
          "#{inspect(module)}.new/1: field #{inspect(field)} holds an improper list — every " <>
            "list in this family is proper, and a tail that is not a list cannot be scanned"
  end
end
