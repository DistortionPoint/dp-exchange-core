# DpExchange.Core.UnwiredFixture writes compiled `.beam` fixtures under this package's
# own `tmp/`, named from `System.unique_integer/1` — which restarts at 1 on every VM
# boot, so a directory name from one `mix test` run is reused by the next. Wiped once,
# sequentially, before any async test can race on it: a stale `.beam` left over from a
# run before some fixture change (or before `debug_info: true` below) must never be
# picked up alongside a fresh one with the same generated name.
#
# **`run_root/0`, not the shared parent.** This used to wipe
# `tmp/unwired_check_test` wholesale, which solved the stale-beam problem for a single run
# and created a worse one across two: a second `mix test` starting up deleted the
# directories the first run's tests were still writing into, failing them with
# `(File.Error) ... no such file or directory` in whichever of the three checker suites
# happened to be mid-fixture. It read as a rare flake because it needed two runs to
# overlap. Each run now owns a pid-named subtree and wipes only its own, which keeps the
# stale-beam guarantee this wipe exists for and cannot reach another run's files.
File.rm_rf!(DpExchange.Core.UnwiredFixture.run_root())

# `mix test` compiles test files (and anything `Code.compile_string/2` compiles from
# within a test, such as the fixtures above) with `debug_info: false` by default, for
# speed. `DpExchange.Core.UnwiredCheckTest` needs real debug info in its fixtures —
# `:xref.add_module/2` refuses a beam compiled without it — so this restores the
# default `mix compile` already uses for `lib/`. Set once, globally, before any test
# runs: `Code.compiler_options/1` is VM-wide state, and toggling it per test would race
# under `async: true`.
Code.put_compiler_option(:debug_info, true)

ExUnit.start()
