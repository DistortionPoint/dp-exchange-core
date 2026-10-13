defmodule DpExchange.Core.DefaultRateLimiterDefaultNameTest do
  # `async: false` on purpose: with no options the limiter registers under the module's own
  # name, which is one name for the whole VM. Synchronous modules run after every
  # asynchronous one has finished, so nothing else can be asking for it meanwhile.
  use ExUnit.Case, async: false

  alias DpExchange.Core.DefaultRateLimiter, as: Limiter

  test "start_link/0 registers the module's own name, which the default arities find" do
    # Before it starts, the default-arity entry points fail closed rather than pass.
    assert {:error, :not_started} = Limiter.acquire(:venue, 1)
    assert {:error, :not_started} = Limiter.check(:venue, 1)
    assert {:error, :not_started} = Limiter.inspect_provider(:venue)

    pid = start_supervised!(%{id: :default_named_limiter, start: {Limiter, :start_link, []}})

    assert Process.whereis(Limiter) == pid
    assert :ok = Limiter.acquire(:venue, 1)
    assert :ok = Limiter.check(:venue, 1)
    assert {:ok, %{next_allowed_in_ms: 0}} = Limiter.inspect_provider(:venue)
  end
end
