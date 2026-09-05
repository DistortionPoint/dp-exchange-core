defmodule DpExchange.Core.Types.NewsItem do
  @moduledoc """
  One news item, as the venue published it.

  ## The text is the venue's, and is not summarised here

  `:summary` is whatever the venue supplied. This layer does not shorten, translate or
  rewrite it: a normalisation that altered the text would change what a caller acted on
  while leaving every field looking correct.

  `:url` is the item's own address where the venue gives one. Following it is the caller's
  decision and this package never does it.

  ## `:symbols` is what the venue tagged, not what the story is about

  Tagging is the venue's, and venues tag differently — some by mention, some by relevance
  model. A caller filtering by symbol is filtering by the venue's judgement, and that is
  worth knowing before building an alert on it.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:id, :provider]
  defstruct [:id, :headline, :summary, :url, :source, :symbols, :published_at, :provider]

  @type t :: %__MODULE__{
          id: String.t(),
          headline: String.t() | nil,
          summary: String.t() | nil,
          url: String.t() | nil,
          source: String.t() | nil,
          symbols: [String.t()] | nil,
          published_at: DateTime.t() | nil,
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)
end
