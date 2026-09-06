# DpExchange.Core.UnwiredFixture writes compiled `.beam` fixtures under this package's
# own `tmp/`, named from `System.unique_integer/1` — which restarts at 1 on every VM
# boot, so a directory name from one `mix test` run is reused by the next. Wiped once,
# sequentially, before any async test can race on it: a stale `.beam` left over from a
# run before some fixture change (or before `debug_info: true` below) must never be
# picked up alongside a fresh one with the same generated name.
[File.cwd!(), "tmp", "unwired_check_test"] |> Path.join() |> File.rm_rf!()

# `mix test` compiles test files (and anything `Code.compile_string/2` compiles from
# within a test, such as the fixtures above) with `debug_info: false` by default, for
# speed. `DpExchange.Core.UnwiredCheckTest` needs real debug info in its fixtures —
# `:xref.add_module/2` refuses a beam compiled without it — so this restores the
# default `mix compile` already uses for `lib/`. Set once, globally, before any test
# runs: `Code.compiler_options/1` is VM-wide state, and toggling it per test would race
# under `async: true`.
Code.put_compiler_option(:debug_info, true)

ExUnit.start()
