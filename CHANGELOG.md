# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Status: EXPERIMENTAL

Stated here rather than only per-release, because a reader arriving at a specific
version needs it as much as one reading the top.

This package has not run in production. While it is `0.x` the API may change without a
major version — pin three-part (`~> 0.1.0`). Coverage is uneven by design: fakes and
live public endpoints are well covered, order placement and authenticated flows are
not.

**Whenever an endpoint moves to `:proven`, the entry that does it states the evidence** —
which venue, what was run against it, and when. "Marked proven" with no evidence is not
an acceptable changelog line.

## [Unreleased]

### Changed

- **`usage-rules/adapter.md` states the `Balance` rule the type now enforces.** `:balance` may
  honestly be `nil` and `:currency` may not — two enforced keys that are not the same kind of
  required, and reading them as if they were is how a package reports an unusable value as
  success. The contract changed in 0.3.5 and the document a consuming agent reads did not say
  so, which left the rule discoverable only from `new/1` raising.

  It records what each `nil` means for a caller: an unstated total is a real answer and must
  be read as unknown rather than zero, with `available_balance` beside it often still real; an
  unstated currency is not an answer at all, and a venue package that cannot name the asset
  must refuse the row. Assertion 24 holds every venue to the second half.

## [0.3.10] - 2026-09-12

### Fixed

- **Three checker test suites failed whenever two `mix test` runs of this package
  overlapped.** `UnwiredFixture` names each fixture directory from
  `System.unique_integer/1`, which is unique within a VM and restarts near 1 in the next, so
  two runs generate the identical `beam_2`, `beam_3`, … names. `test_helper.exs` then made
  that fatal rather than merely confusing: it wiped `tmp/unwired_check_test` **wholesale**
  before `ExUnit.start/0`, so a second run's start-up deleted directories the first run's
  tests were still writing into —

      ** (File.Error) could not write to file ".../tmp/unwired_check_test/beam_2/
         Elixir.Outsider1.beam": no such file or directory

  — in whichever of `UnwiredCheckTest`, `LinkSafetyCheckTest` or
  `CredentialRedactionCheckTest` happened to be mid-fixture. It read as a rare flake because
  it needed two runs to overlap; it is a deterministic collision.

  Each run now owns a pid-named subtree (`UnwiredFixture.run_root/0`) and `test_helper.exs`
  wipes only its own, which keeps the stale-beam guarantee that wipe exists for and cannot
  reach another run's files. `run_root/0` is a function, not a module attribute: an attribute
  is evaluated at COMPILE time and would bake in the compiling VM's pid, handing every later
  run the same directory — the exact collision being removed.

- **Two `PollingFeed` tests waited exactly one poll interval for a synchronisation message.**
  Both set `interval_ms: 500` and then `assert_receive ..., 500`, so the wait for a message
  the first poll produces had zero margin for scheduler jitter — despite a comment claiming
  the wait made the ordering deterministic. They held on a quiet machine and failed under
  load with *"Found message matching `:fetch_started` after 500ms"*: the message arrived,
  just late.

  Raised to 5s. Waiting longer cannot weaken either claim — that `status/1` and `coverage/1`
  answer *while* a fetch hangs — because how long the hang takes to begin is scheduling, not
  behaviour. Pinning it to the poll interval was measuring the harness.

  Both were found by running two suites against each other, which is now the recorded way to
  surface this class in this package: a timing assertion that holds when quiet and fails
  under load is the same shape as the rate-limiter bucket race fixed in 0.3.6.

### Changed

- **Every fake call in the conformance suite now builds its arguments through
  `endpoint_args/2`.** Assertions 12 and 21 still hand-built theirs. Both happened to carry
  `credentials:`, so neither was among the assertions found inert in 0.3.9 — but hand-building
  is precisely what made 14 and 23 inert on four venues out of five, and a mechanism that some
  call sites use and others do not is one drift away from the same defect. A venue's
  `endpoint_opts` and `endpoint_symbols` now reach every fake call the suite makes.

  Assertion 21 still chooses its own timeframe, because an unserved width is the whole
  question it asks; its symbol and opts come from the venue's declarations like everything
  else.

- **`docs/reference/core/assertion-coverage.md` records a completed mutation sweep.** All
  seven fake-driven assertions were broken on purpose — the exact property each one claims —
  against every venue the assertion applies to, and every break produced a failure. Nothing
  was found still inert, which is the result worth writing down: it is what stops the next
  reader repeating thirty experiments to learn it.

  The table records which venues each assertion applies to and why the counts differ, since
  assertion 23's uneven 3/3/3/2/1 matches each venue's own `capabilities/0` exactly — that is
  what "runs where it should and nowhere else" looks like when it is visible. Two legitimate
  skips remain, both declared rather than inferred from an opaque refusal.

## [0.3.9] - 2026-09-12

### Fixed

- **Assertions 14 and 23 had only ever run on one venue out of five.** Both build a call to
  the venue's fake for a PUBLIC-shaped endpoint — `get_top_of_book/2`, `get_price/2`,
  `get_order_book/2` — whose argument shape carries no credential position, so the only
  place a credential can travel is `opts`. Both passed a hand-built `[symbol, []]`. Every
  venue declaring `credential_benefit: :required` therefore answered
  `{:error, {:missing_credentials, _}}`, and each assertion's own
  `_refused_or_unsupported -> :ok` clause took that for an answer. Only `dp_exchange_gemini`,
  which needs no credential, ever executed them.

  **Measured, not inferred.** Setting a fake's `observed_at` to `nil` — the precise defect
  assertion 14 exists to catch — and running `dp_exchange_schwab`'s contract suite against
  the published Core 0.3.8 reports **0 failures**. Against this change, all five fail, with
  counts matching each venue's own capability declaration exactly: 3 for the venues serving
  all three endpoints, 2 for `dp_exchange_schwab` (no order book), 1 for
  `dp_exchange_robinhood` (no `get_price/2`, no order book).

  Both now build their arguments through `endpoint_args/2`, and `arg_value(:opts, _)` carries
  `credentials:` via `Keyword.put_new/3` — so a venue's own `endpoint_opts` still wins, and
  assertion 17's deliberately-emptied credential is not fought.

- **The same `_refused_or_unsupported -> :ok` clause closed in assertion 24 was left open in
  14 and 23.** Fixed in one place and not the others, which is the "fix applied where it was
  found rather than where it applies" this family keeps paying for — committed here, in the
  suite whose job is to stop exactly that. A refusal from an endpoint `capabilities/0`
  declares active now fails in all three, naming both honest remedies.

### Added

- **`endpoint_symbols:` on `use DpExchange.Core.AdapterContract`**, a
  `%{{name, arity} => symbol}` for the endpoint whose coverage is narrower than
  `sample_pairs:`. `dp_exchange_webull` serves an order book for US stocks and ETFs and
  refuses one for a crypto pair — deliberately, since the venue publishes no crypto depth
  endpoint — and all of its sample pairs are crypto, so assertion 23's `get_order_book/2`
  arm could only ever see that refusal.

  The alternative was to keep treating the refusal as a skip, which is how these assertions
  came to run on one venue in five. Naming a symbol the endpoint actually serves makes the
  assertion run instead, which is the point of having it.

## [0.3.8] - 2026-09-12

### Fixed

- **Assertion 24 accepted a refusal as a pass.** Its helper ended
  `_refused_or_unsupported -> :ok`, and that one clause is how three packages passed an
  assertion that never executed on them: their fakes refused an account-scoped call the
  suite made with no account, and the refusal was taken for an answer. `endpoint_opts`
  (0.3.7) removed the reason for that refusal, so a refusal now means something is genuinely
  out of step — `capabilities/0` says the endpoint is active and the venue's own fake says
  otherwise — and it fails, naming both honest remedies: declare the endpoint `:unsupported`,
  or declare what the fake needs in `endpoint_opts:`.

  Verified by renaming a venue's `endpoint_opts:` key so Core stops seeing it, which
  reproduces the pre-0.3.7 state exactly: the suite now fails there instead of passing.

### Changed

- **`docs/reference/core/assertion-coverage.md` brought current, and given a second axis.**
  It was the map the next audit starts from, and it had drifted into pointing at three
  problems that no longer exist while missing the newest assertion: it said 23 groups
  (24 now), and it still reported as open both the `dp_exchange_coinbase` `has_staking`
  finding and the "tier 1 dials out" finding on assertions 12 and 14. Both are fixed —
  re-verified in source and by running all five contract suites, which reach no venue
  hostname at all — and are now marked closed in place rather than edited away, since the
  tables are a record of what the audit found on the day.

  **The new part is the axis the original audit did not have.** Every status in that file
  answers "does an assertion exist?", which is not the same question as "does it run on
  every venue?" — and the difference had been hiding real absence behind green runs. The
  file now opens by saying so, and records the method that found it: break what an assertion
  checks and require the suite to go red, on every venue rather than on the first. Two of
  the five would have told you nothing.

## [0.3.7] - 2026-09-12

### Added

- **Assertion 24: a `Balance` names the asset it is a balance of.** `Types.Balance` enforces
  `:currency` and its `new/1` refuses a `nil` there, but **no venue decoder in this family
  calls `new/1`** — every one builds the struct literally, which `Types.Validate`'s own
  moduledoc explicitly permits — so that check had never run anywhere, and four of the five
  packages read `currency` straight out of the venue's JSON by key with nothing between. All
  four were fixed in their own packages; this is the assertion that stops the fifth, or a
  sixth, reintroducing it. The suite's own rule is why it belongs here: *"Every gap found
  becomes a new assertion here. A gap fixed only in one venue's fake is a gap the next venue
  will reintroduce."*

  `:balance` is deliberately not checked — `Types.Balance` states it may honestly be `nil`
  while `:currency` may not, and an assertion covering both would force
  `dp_exchange_coinbase` to discard a real `available_balance` to report an absence
  honestly.

### Fixed

- **Three venue packages were passing fake-driven assertions that never ran.** Several
  assertions call an active endpoint through the venue's fake with `opts: []`, and on an
  account-scoped venue every one of those calls is refused before it reaches the behaviour
  under test: `dp_exchange_webull` needs an `:account_id`, `dp_exchange_robinhood` an
  `:account_number`, `dp_exchange_schwab` an `:account_hash`. The assertions took that
  refusal as a legitimate answer and skipped — a green test proving nothing, which is worse
  than a red one.

  Caught by deliberately breaking each venue's fake against the new assertion 24: two
  packages went red and three stayed green. It was never confined to 24. **Assertion 17 —
  the credential gate — has been passing for the wrong reason on those same three venues
  since it was written**: it strips the credential and expects a failure, and what it got
  was the missing account.

  `use DpExchange.Core.AdapterContract` now takes `endpoint_opts:`, a
  `%{{name, arity} => keyword()}` of what a venue's own endpoints need before its fake will
  answer. The key is the venue's, not Core's — a table of `:account_id` / `:account_number`
  / `:account_hash` in here would be exactly the venue-specific knowledge this contract
  exists to keep out of Core. Assertion 17's stripped-credential args carry those same opts
  alongside the emptied credential, so the only thing missing from the call is the one thing
  it is testing.

## [0.3.6] - 2026-09-11

### Fixed

- **`Types.Balance` required a non-nil `:balance` that every package in the family
  knowingly produces.** Its `new/1` checked the full `@enforce_keys`, and its typespec said
  `balance: Decimal.t()`. `dp_exchange_coinbase` derives the total from the venue's
  available and hold figures and carries `nil` when either is missing — deliberately, on
  the recorded ground that "available 1, total unknown" and "total equals available" are
  different claims — and `dp_exchange_gemini` has its own recorded decision to carry `nil`
  rather than destroy a page over one malformed row. The type denied both.

  Nothing caught the contradiction because **no venue decoder calls `new/1`**: all five
  build the struct literally, 85 call sites between them, so the constructor's check has
  never run in this family. A rule nothing enforces and every package violates is not a
  rule, it is a wrong statement in the contract.

  `:balance` is now `Decimal.t() | nil` and out of the non-nil check, with the moduledoc
  saying when a `nil` is honest. `@enforce_keys` still guards its *presence*, so a decoder
  that never sets the field is still caught — stating an absence and omitting one are
  different mistakes.

  **`:currency` stays required, and now means it.** A balance attributable to no asset
  cannot be sized, booked or reconciled by anyone, and unlike a missing quantity there is no
  "the venue declined to say" reading — a holdings row names its asset, so a `nil` there is
  a decode reading the wrong key, exactly what `Types.Validate`'s moduledoc exists for. The
  four venue packages that read this field from venue JSON now refuse such a row; see their
  own changelogs.

  Same shape of decision, and the same reason, as `Types.Order`'s already-narrowed
  `@required_non_nil`: state what is true rather than a stricter rule the packages then
  quietly violate.

- **Three rate-limiter tests raced the bucket they were measuring.** Each ended by asserting
  the bucket was empty, against a bucket that refills continuously: at `per_ms: 1_000` with
  `limit: 3` a token returns every ~333ms, so the closing `check/3` was only refused if the
  acquires ahead of it finished inside that window. They normally did. On a loaded
  `async: true` run they sometimes did not — caught failing once in six consecutive
  full-suite runs, passing the other five.

  The same flake `dp_exchange_coinbase`'s limiter test carried and was fixed for: **any "the
  bucket is empty now" assertion races a refilling bucket**, and no change to the code under
  test removes it, because the race is in the assertion. Widened to `per_ms: 100_000`, which
  puts every refill interval here past nine seconds while keeping the non-terminating
  division (`100000/3` is 33333.333…) that each test actually exists to pin. Verified with
  six consecutive clean full-suite runs.

## [0.3.5] - 2026-09-11

### Fixed

- **A flaky test of my own making, from 0.3.4: the dead-subscriber benchmark asserted
  `timed(unpruned) > timed(pruned)`.** That is a wall-clock comparison between two small
  numbers, and it holds while the machine is quiet and inverts under load — it passed in
  isolation every single time and failed inside the full suite under `--cover`, where twenty
  async tests are competing for the same cores.

  This is precisely what this suite's own `wait_until/1` comment says about sleeps: a test
  that fails against code which is working correctly is worse than no test, because it
  teaches the reader to distrust the suite. Writing one two releases after quoting that
  comment at someone else's test is worth recording rather than quietly rewriting.

  The property is real — `deliver/4` walks the whole set and calls `Process.alive?/1` per
  entry per message, measured at 0.095 µs per fan-out against a clean set and 22.8 µs against
  one carrying a thousand dead pids. But the **magnitude is a measurement**, and it belongs in
  a comment and a changelog, where it already was. What belongs in an assertion is the
  **mechanism**, which is exact: the work per message is one liveness check per entry, so the
  cost *is* the size of the set. The test now counts that — 41 entries walked before pruning,
  1 after, same delivery result — instead of timing it.

  Found by clean-building every repo in the family, which is a habit that came out of
  `dp_exchange_webull` 0.4.14: an incremental build is not a quieter build, it is one that
  has already told you and moved on. No hidden warnings turned up anywhere; this failure did.

  The two other `:timer.tc` assertions in the family were examined and **left alone**. They
  are a different shape: bimodal checks with wide margins — "is this instant, or did it sleep
  the configured minute" at 60× margin in this package, 10× in `dp_exchange_schwab` — rather
  than a comparison between two similar small durations. Changing them would be motion with
  no defect behind it.

## [0.3.4] - 2026-09-11

### Fixed

- **A malformed `:limits` crashed the rate limiter on its first request instead of failing
  at start.** `reserve/3` destructures `%{limit: _, per_ms: _, burst: _}`, so an entry
  missing any of the three raised a `MatchError` **inside the GenServer**. A supervisor then
  restarts it, the next request crashes it again, and what a consumer sees is a crash loop
  whose message names `reserve/3` rather than the configuration that is actually wrong.

  **This is a real trap, not a hypothetical one, because two of Core's own types do not
  compose.** `Capabilities.ceiling` declares `:burst` **optional**; this module's
  `t:limit/0` declares it **required**. So every venue in the family has to write its own
  little `to_limit/1` to bridge them — all five happen to do it correctly — and a consumer
  wiring `DefaultRateLimiter` up directly against a `capabilities/0` ceiling, which is the
  obvious thing to do and the shape that reads as correct, got the crash loop instead of an
  error.

  `init/1` now validates every entry and raises with a message naming the provider, the
  required shape, and *why* the ceiling it was probably given lacks `:burst`.

  **Raising rather than defaulting `burst` to `limit` is deliberate**, even though that is
  what `@default_limit` itself does and what four of the five venues chose. Burst tolerance
  is how far a caller may run ahead of the smooth rate; picking one silently hands a consumer
  a throughput characteristic it did not choose and cannot see — the same objection
  `Fanout.max_queue_len!/2` already records for a back-pressure bound. A ceiling is a claim
  about a venue, and this module is not the place to invent half of one.

  A `limit:` of `0` stays legal and is tested: it is a real declaration — a registration that
  granted no throughput, which `dp_exchange_schwab` relies on being able to express — and
  must not be confused with a missing value.

  Found while probing the limiter by hand to settle an unrelated flaky test, with
  `%{limit: 10, per_ms: 1_000}` — the exact shape `capabilities/0` returns.

## [0.3.3] - 2026-09-11

### Fixed

- **A dead subscriber's pid was never removed from a feed's subscriber set, and the hot path
  paid for it linearly.** `Fanout.resolve/1` skips a dead subscriber at send time, so no
  *events* accumulated for it — which is what `Core.Venue`'s `unsubscribe/2` doc asks for,
  and it was true. What accumulated was the **pid**. No venue in the family monitored a
  subscriber or pruned one, so a supervised consumer that restarts left its old pid behind
  on every restart, for the life of the feed.

  That is not a rounding error, because `deliver/4` walks the whole set and calls
  `Process.alive?/1` on every entry, once per message. Measured:

  | dead pids in set | µs per fan-out |
  |---|---|
  | 0 | 0.095 |
  | 50 | 0.956 |
  | 200 | 4.301 |
  | 1000 | 22.842 |

  Linear, and at a thousand accumulated pids each message costs roughly **240×** what it
  should. `dp_exchange_coinbase`'s `level2` channel measured 4258 frames in the window that
  produced this family's coverage incident; at that size the dead entries alone are about
  97 ms of liveness checks inside the one process every subscriber's data flows through —
  and it only ever grows.

  `Fanout.watch/2` monitors a subscriber so a feed can drop it on `:DOWN`, and
  `Fanout.forget/2` cleans up on both `:DOWN` and an explicit unsubscribe. The venue side
  ships in each venue's own release against this version.

  **A registered name is deliberately not monitored.** A pid that has died is gone
  permanently, so removing it is always right. A name is not a process: `subscribe/2` accepts
  one precisely so a consumer can restart under it, and a monitor on a name fires when the
  *current holder* dies. Pruning on that would silently unsubscribe a consumer whose
  supervisor is about to bring it straight back — data loss with nothing to notice it by,
  which is worse than the leak. A name cannot leak anyway: the set holds one atom however
  many times the process behind it restarts.

## [0.3.2] - 2026-09-11

### Fixed

- **A compile warning in a test file never failed a build, and five were sitting in this
  package's own output.** CI ran `mix compile --warnings-as-errors`, which compiles `lib/`
  only — test files are compiled by `mix test`, which had no such flag. So every warning
  from a test file was permanent and green.

  Found by running `script/check_dependency_floor.sh` by hand and reading what scrolled
  past. That checker had never executed once: it is scheduled weekly for Monday and landed
  on a Tuesday, so no cron had come around, and the token available here cannot
  `workflow_dispatch`. A checker nobody has ever seen run is a checker nobody has proved
  works — running it found a different defect than the one it was written for, which is
  argument enough for running it.

  Two of the five were **real defects in the shared conformance suite**:

  `venue_does_not_serve/0` and `coverage_by_kind/1` are **optional** callbacks, guarded by
  `function_exported?/3` and then called directly — so every venue package that does not
  implement one got a compile warning out of a macro it did not write. The
  `venue_does_not_serve/0` site had a mitigation (`venue = @venue`, then calling through the
  variable) and a comment claiming it worked. **It stopped working and the comment did
  not**: Elixir 1.18 tracks the binding through, so the warning had come back and the
  comment still said it could not. `coverage_by_kind/1` had no mitigation at all. Both are
  now `apply/3` with a scoped `credo:disable-for-next-line`, which is the honest expression
  of "this module is not knowable at compile time" rather than a trick that happens to
  suppress a message.

  The other three were the compiler **specialising a generic suite on whichever fake happens
  to be compiling**. `Core.ReferenceVenue`'s fake always returns `{:ok, _}` from
  `get_symbols/1` and always sets `venue_time`, so the `{:error, {:query_required, _}}`
  branch was reported as "this clause will never match" and `is_nil(top.venue_time)` as a
  "comparison between distinct types" — for branches that are live in the packages that need
  them (`dp_exchange_schwab` genuinely answers `{:query_required, _}`, and a venue that
  publishes no BBO time is the case `Types.Quote`'s 0.2.0 split exists for). Left alone,
  every future venue with a simple fake would inherit mystery warnings from a shared macro.

### Changed

- **CI runs `mix test --cover --warnings-as-errors`.** Together with the existing
  `mix compile --warnings-as-errors`, no warning now survives anywhere in the build —
  `lib/` and test files both.

  The argument is not tidiness. A handful of permanent warnings is exactly the noise a
  genuinely wrong one hides behind, and in this family a "clause will never match" in the
  conformance suite could be an assertion that cannot fail. Verified by injecting an unused
  function into a test file and confirming the run aborts, then removing it — a gate nobody
  has watched fail is a gate nobody has proved, which is the same mistake as the checker
  that had never run.

## [0.3.1] - 2026-09-11

### Removed — BREAKING

- **`DpExchange.Core.DataProvider` is deleted. It was a second, competing definition of the
  venue interface — 24 callbacks, zero implementers — and every shape in it is one this
  family has since fixed.** Its own moduledoc called it *"a unified interface for
  interacting with different trading venues"*, so a venue author who found it first would
  have built, plausibly and entirely wrongly:

  | `Core.DataProvider` said | The real contract says | Why the difference matters |
  |---|---|---|
  | `decimal_string :: String.t()` | `Decimal` in every `Core.Types.*` | string arithmetic, silently |
  | `provider: String.t()` | `provider: atom()` | every match on `:coinbase` fails |
  | `balance_data` with **no timestamp** | `Types.Balance` `@enforce_keys` it | "no way to tell a current balance from a stale one" — its own moduledoc |
  | `price_data` with one `timestamp` | `venue_time` + `observed_at` since 0.2.0 | the split issue #31 asked for |
  | `{:error, String.t()}` everywhere | `{:refused, term()}` vs `{:error, term()}` | the permanent/transient distinction a caller acts on |
  | `get_order_book` → `{:ok, map()}` | `{:ok, Types.OrderBook.t()}` | a bare map cannot enforce anything |

  Nothing referenced it. `Core.Venue` and `Core.AdapterContract` never mentioned it, and no
  venue package named it outside one stale comment. It shipped in the Hex tarball anyway,
  which is the whole problem: a contract a consumer can read is a contract a consumer can
  believe.

  **How it survived:** it was ported wholesale from the host application on 2026-08-27
  (`docs/design/closed/2026-08-26_exchange-adapter-package-family.md`, item 1.5 — "776 lines
  across the three"), alongside the contract that replaced it, and nothing ever removed the
  one that lost. And `test/dp_exchange/core/behaviours_test.exs` asserted it declared exactly
  24 callbacks — a green test pinning a dead contract, which is `Core.UnwiredCheck`'s own
  line ("a test is not a caller") applied to a behaviour instead of a function.

- **`DpExchange.Core.FeedBehaviour` is deleted too — a fourth restatement of the contract,
  with signatures that matched nothing.** `start_feed/2` existed in no venue. Its
  `update_symbols/2` was wrong for `dp_exchange_webull`, which takes credentials per call
  like every other endpoint in this family and so needs `update_symbols/3`. A behaviour
  whose shape contradicts all five implementations is not a hook waiting to be used;
  adopting it would have meant changing five working venues to match a module nobody had
  ever run.

  **Its moduledoc was the valuable part and it is kept**, carried into `Core.Venue`'s
  `route()` typedoc where the real `coverage/1` lives: the poll set guessing which pairs a
  subscription covered, Webull's "3 messages per second per connection" rationed by a module
  that could not see it (151 pairs delivering nothing, reading as a quiet market), and a
  venue with **no socket at all** described to the user in socket terms. That last one is
  why `:stream` names a push rather than a socket, and why `:internal_poll` is a first-class
  answer instead of an absence.

  It also removes a duplicate definition of `route()` — the same three atoms declared in two
  modules, free to drift.

### Added

- **A behaviour-adopters ledger, so the next orphan is visible the day it is written.**
  `behaviours_test.exs` now enumerates every module in this package that declares a
  `@callback` — read from the compiled beams, because `@callback` inside a `quote` (which
  `Core.AdapterContract` uses heavily) is not a behaviour declaration and a grep cannot tell
  them apart — and asserts each has an entry naming who implements it.

  An entry of `:none` is allowed and is not a loophole: it is a visible, reviewable claim
  that a contract exists with nobody on the other end, which is exactly the state two
  modules sat in undetected. A new behaviour with no entry fails the build.

  This is the third instance in as many releases of *declared in Core, implemented by
  nobody* — after `subscribe/2`'s back-pressure paragraph (0.2.6) and the entire telemetry
  spec (0.2.7). The pattern is now checked rather than re-found.

### Changed

- **This release is `0.3.x`, not `0.2.x`.** Removing a public module is breaking even when
  nothing implements it, and a minor bump is how this family says so. Venue packages pinned
  `~> 0.2.8` will not resolve it until their floors are raised — which is the pin doing its
  job, not a problem to route around.

## [0.2.8] - 2026-09-11

### Added

- **The polling route reports a link too, so a polling venue is not permanently "down" on a
  fleet dashboard.** `Core.PollingFeed` now emits `[:dp_exchange, :link, :event]` per
  delivered payload, and `:link, :up` / `:link, :down` mapped onto the `notice_state` latch
  it already had — so the telemetry inherits that latch's once-per-crossing property and
  cannot storm on a long outage. `:link, :down` is the feed crossing into
  delivering-nothing, which is the closest true statement a poller can make about a route it
  does not hold open.

  Without this, `dp_exchange_robinhood` — which only polls — and `dp_exchange_schwab`'s
  fallback poll would emit no link events at all, and a dashboard reading
  `[:dp_exchange, :link, …]` across the family would show them disconnected forever. See
  `Core.Telemetry`'s "Why the category is `:link` and not `:ws`": what carries the route is
  package-internal, and a consumer should not have to know which venues hold a socket.

- **`Telemetry.link_event/2`, for a route that cannot measure wire size.** A poll has no
  frame — `PollingFeed` receives a decoded body and hands on a `Core.Types.*` struct — so
  there is no point at which a byte count means what `link_event/3`'s does on a socket.
  `:bytes` is therefore **absent**, not zero. Absent and zero are different claims and only
  one of them is true here: a consumer summing `:bytes` across a mixed fleet gets the
  streaming venues' throughput correctly, instead of a total silently depressed by every
  polling venue reporting a confident zero.

## [0.2.7] - 2026-09-11

### Fixed

- **The telemetry spec had nine documented event names and nothing in the family emitted a
  single one.** `Core.Telemetry`'s first line said these are the events "every venue package
  emits". There was not one `:telemetry.execute/3` call anywhere — not in Core, not in any
  of the five venues — for the whole time the spec existed.

  That is worse than an error would have been. `:telemetry.attach/4` against a name nobody
  emits **succeeds**, so a consumer wired a dashboard to `[:dp_exchange, :request, :stop]`,
  got no error, and saw an empty panel — which reads as *a venue with no traffic*, not as *a
  spec nothing implements*. A metric that stays plausible while only its meaning is wrong,
  in the layer least likely to be questioned.

  Found by reading the contract and grepping for anything that honoured it — the same way,
  and in the same week, as the identical hole in `Core.Venue.subscribe/2`'s back-pressure
  paragraph. Two for two on things Core declared and nobody built: **a guarantee written in
  a doc and nowhere else is not a guarantee, it is a plan.**

  `Core.HttpClient` now emits `[:dp_exchange, :request, :start | :stop | :exception]` from
  `make_http_request/5` — the one place a request actually leaves the process, so a new
  endpoint cannot forget it — and `Core.DefaultRateLimiter` emits
  `[:dp_exchange, :rate_limit, :hit | :acquire]`. Both are shared by all five venues, so
  this covers every REST call and every metered request in the family. The `[:dp_exchange,
  :link, …]` events belong to a venue's own socket and ship in each venue's next release,
  against this version.

### Added

- **`Core.Telemetry` gained the emitters themselves**, rather than leaving five packages to
  name events by hand. Five chances to write `:link_up` instead of `[:dp_exchange, :link,
  :up]`, and the drift would be invisible: the wrong name emits successfully and never
  reaches a handler. It also keeps `:telemetry` a dependency of Core alone — a venue calling
  `:telemetry.execute/3` directly would be using a transitive dependency it never declared.

  `Telemetry.endpoint/1` strips a URL's query string for `:endpoint` metadata. A security
  decision, not tidiness: telemetry metadata reaches logs, aggregators and third-party
  exporters, and the query string is the one part of a URL that can carry a token. No venue
  in this family signs in the query today, but `endpoint` is emitted on every request from
  every venue present and future, and "none of them do that yet" is not a property a
  consumer's log retention should depend on.

### Changed

- **`make_http_request/5` carries the HTTP status out alongside the result.** Every error
  branch had already turned it into prose — `{:error, "Server error (503): …"}` keeps the
  status only inside a message string — so `:stop` would have reported `nil` for a 503.
  Recovering it by parsing that string back out would be the string-matching the same
  function's own 4xx comment objects to, one layer further along. Carried explicitly
  instead, so a 503 reports 503 and a connection refusal reports `nil`: without that a
  dashboard cannot tell a venue that is erroring from a venue that is unreachable, which are
  different outages needing different responses.

- **A rate-limit hit is emitted from `check/3`, not only `acquire/3`.** `Core.HttpClient`
  uses `check/3` unless `rate_limit_blocking: true`, and that option defaults to **false**.
  Emitting only from `acquire/3` would have meant the default configuration of the whole
  family reported no rate-limit hits at all — a metric reading zero because nothing counts,
  which looks exactly like a metric reading zero because nothing is being throttled.

  A venue's own 429 and this limiter's own wait both emit `[:dp_exchange, :rate_limit,
  :hit]`, deliberately. A consumer's first question is "am I being throttled"; answering it
  from two different event names would mean every dashboard has to know both or be quietly
  wrong. `retry_after_ms` is always milliseconds, including where the venue's header is in
  seconds — a panel summing a mixture of the two is wrong by a factor of a thousand without
  ever looking wrong.

## [0.2.6] - 2026-09-10

### Added

- **`DpExchange.Core.Fanout` — back-pressure, which the contract had promised since it was
  written and no package provided.** `Core.Venue`'s `subscribe/2` doc said *"a venue pushing
  faster than its subscriber consumes drops oldest beyond a stated bound and emits a
  `:degraded` notice saying so"*. All five venues fanned out with a bare `send/2`, in five
  identical private `fan_out/2` functions, none of which had ever looked at a subscriber's
  mailbox. A consumer reading the contract was told back-pressure was handled and declared;
  neither half was true.

  The exposure is not theoretical. `dp_exchange_coinbase`'s `level2` channel measured 4258
  delta frames in the window that produced this family's coverage incident. A subscriber
  that stalls for thirty seconds against a stream like that accumulates a mailbox in the
  hundred-thousands and the node dies — with no notice, no log line, and `coverage/1`
  reporting perfect health throughout, because the feed *was* delivering.

  `deliver/4` checks each subscriber's `:message_queue_len` and declines to add to a queue
  already at the bound (default 10_000, per venue via `:max_queue_len`). It reports only
  **transitions** — `:dropping` the first time a subscriber is found over, `:resumed` the
  first time it is found back under — because a notice per dropped message would arrive at
  the rate of the stream the consumer already cannot keep up with. The pair is what lets a
  consumer bracket exactly the window it must reconcile from a pull endpoint.

  Notices are deliberately **not** subject to the bound: the notice announcing that a
  subscriber is being dropped must not be the first casualty of that same subscriber being
  dropped.

### Changed

- **`coverage/1`'s neighbouring back-pressure paragraph said "drops oldest", which is not
  implementable and is part of why nothing implemented it.** A sender cannot remove a
  message from another process's mailbox — the receiver owns its queue. What a sender can do
  is decline to add to a queue already past its bound, and that is also the better trade for
  this data: a quote arriving while a consumer is thirty thousand messages behind is
  worthless by the time it would be read, and the frames it would push out are no fresher.
  The contract now states the achievable guarantee, and records that an unimplementable
  sentence does not stay a wording problem — it becomes the reason a real guarantee is
  missing.

- **The bound is checked on every message to every subscriber, because checking is cheaper
  than the send it guards.** Measured before it was written: `Process.info/2` for
  `:message_queue_len` costs 0.029 µs against `send/2`'s 0.097 µs, and is unchanged at
  0.028 µs against a 100_000-message backlog — it reads a counter the process already
  maintains rather than walking the queue. At 0.3x the cost of the send, sampling the check
  or latching it for N messages would have been complexity bought for nothing.

- **`resolve/1` is shared.** All five venues had written the same pid-or-registered-name
  resolution privately. It moves here because `deliver/4` and a venue's notice path have to
  agree on what counts as a reachable subscriber.

## [0.2.5] - 2026-09-10

### Documentation

- **`coverage/1` now says what it means across a transport reconnect, because all four
  streaming venues had it wrong in the same way at once.** Every streaming socket in the
  family returns `{:reconnect, state}` from `handle_disconnect/2`, so the socket *process*
  survives a transport drop — no `EXIT` fires, and every delivery-record reset path in
  every venue was keyed on a process death. Between a drop and a successful resubscribe,
  `coverage/1` answered `:stream` for symbols arriving from nowhere; where the reconnect
  restored the socket but the venue silently failed to restore some symbols — the
  325-subscribed/174-delivering shape this callback was written for — those symbols
  answered `:stream` indefinitely, on frames observed before the disconnect.

  The `@doc` now states that observation is **scoped to the current transport session**: on
  `:link_down` a venue narrows coverage by the symbols that link carried, the same way it
  already narrows on the socket's process death and on `unsubscribe/2`. A consumer sees a
  brief, truthful dip bracketed by the `:link_down`/`:link_up` pair that exists for it.

  It also separates the two routes, which had silently diverged: `Core.PollingFeed` applies
  a staleness window and is right to, because a poll that missed its own interval is
  genuinely not delivering; **a stream deliberately does not**, because an illiquid pair may
  honestly not print for hours and on `dp_exchange_schwab` overnight silence is correct
  rather than a fault. On a stream, coverage means *observed at least once since this
  connection came up* — never "recently".

  Documentation only in this package; the venue-side behaviour ships in each venue's own
  release. Design: `docs/design/2026-09-10_coverage-across-a-reconnect.md`, which also
  records why this rule **cannot** be carried by a `Core.AdapterContract` assertion — the
  suite is fake-driven, a fake has no socket to drop, and driving a venue's real tree is the
  dead end assertion 18 already documented.

## [0.2.4] - 2026-09-10

### Documentation

- **`streamable`, `authenticated_streamable` and `historical_timeframes` had no stated
  meaning for a venue serving more than one asset class.** They are flat lists with no class
  dimension, and two opposite readings were available — "every path serves this" or "some
  path serves this". Nothing in the contract said which, so a venue author had to guess.

  **The rule is now written down: a value belongs in the list if the venue serves it on any
  path this package reaches — a union, not an intersection.** Both multi-asset venues had
  already chosen that reading independently, which is exactly how the ambiguity stayed
  invisible: they agreed by coincidence, not because the contract said so.

  **What makes a union honest is the second half of the rule**, and it is stated with it:
  the per-call path must **fail closed** for a combination it does not serve. Declare `1w`
  because your equity bars serve it and then return a `1d` bar when a caller asks for `1w` on
  crypto, and you have built the substitution this family exists to stop.
  `dp_exchange_webull` is cited as the worked example — it declares `1w`/`1M` for the equity,
  option and futures bars and answers `{:error, {:unsupported_timeframe, _}}` for a crypto
  category.

  The limitation is recorded rather than implied: a consumer cannot ask "which widths for
  crypto" or "is the book streamable for options", and gets the venue-wide answer plus an
  honest refusal. Two confirmed instances — `dp_exchange_webull`'s `1w`/`1M`/`1y`, and
  `dp_exchange_schwab`'s inability to declare `:order_book` for options alone, which is one
  of the two reasons `OPTIONS_BOOK` stays unwired. Closing it means an asset-class dimension
  on a published type for a gap no consumer has reported hitting, so the instances are
  recorded for whoever weighs that next rather than the change being made speculatively.

  Also in `usage-rules/adapter.md`, since a venue author reads that before writing a
  declaration.


## [0.2.3] - 2026-09-10

### Fixed

- **No published version was attributable to a changelog entry (dp-exchange-core issue
  #32).** Every entry in this repository's `CHANGELOG.md` sat under `## [Unreleased]` — in
  the **published tarball**, since `CHANGELOG.md` ships inside it — so a consumer could not
  tell which version introduced a breaking change, or whether they had already taken one.

  That mapping is load-bearing here rather than cosmetic. This family signals a breaking
  change with a **minor bump**, and those changes are repeatedly a refusal tuple or struct
  gaining a field: invisible to the compiler, and invisible to a test that pins the old
  shape. The reporting consumer's written upgrade procedure is *"read `CHANGELOG.md` for a
  `### Changed — BREAKING` section, then grep for every clause matching the old shape"* —
  which needs version → change. Without it, `### Changed — BREAKING` says *that* the shape
  changed and never whether they already have it.

  They gave two incidents from the same three days, and the difference between them is the
  whole argument: `dp_exchange_gemini` 0.1.42's refusal-shape change was found **after
  shipping**, by reading a fix comment, while `dp_exchange_webull` 0.4.0's was caught
  **before** — because that entry happened to name the version in its prose.

  **Two halves, because fixing only one would have let it recur immediately:**

  - **Going forward**, the release pipeline cuts a `## [x.y.z] - YYYY-MM-DD` heading itself,
    in the publish job and **before `mix hex.publish`** — a heading added after the upload
    would describe a tarball nobody can read.
  - **Retroactively**, the accumulated block now sits under a `## [<version>] and earlier`
    heading. Attributing each of ~1,600 lines to the exact release that carried it is
    archaeology; this restores the one fact a consumer needs from it — that none of it is
    pending — which is what the reporter suggested.

  The issue measured five packages, from their `deps/`. `dp_exchange_schwab` has the same
  defect and is not one of their dependencies, so it could not appear in their table: six
  instances, all fixed here.


## [0.2.2] and earlier - 2026-09-10

**Everything below this line is published.** Entries were accumulated under
`[Unreleased]` from the first release to `0.2.2`, so no reader could tell shipped work
from pending — dp-exchange-core issue #32. Attributing each entry to the exact version
that carried it would be archaeology across hundreds of releases; this heading restores
the one fact a consumer actually needs from it, which is that none of it is pending.

Releases from here on cut their own `## [x.y.z]` heading at publish time, so this is
the last block that will ever need a range.

### Added

- **Assertion 23 — venue time and observed time.** `Quote` and `OrderBook` gained
  `:venue_time` and `:observed_at` in 0.2.0, and **nothing checked that `:venue_time` stays
  honest**. Assertion 14 already made exactly this check for `TopOfBook`, which carried both
  fields from the start; 23 extends it to the two types that just gained them, for
  `get_price/2` and `get_order_book/2`.

  This is a gap the 0.2.0 change created, found by auditing it rather than by it failing.

  It is deliberately **not** the "comprehensive endpoint → expected-struct map" that
  `docs/reference/core/assertion-coverage.md` considered and declined: two named callbacks
  whose return type the contract already fixes, with no hand-maintained list to rot. Both
  gate on `Capabilities.active?/2`, so a venue declaring either `:unsupported` is skipped
  rather than failed — `dp_exchange_robinhood` declares both, and passes by exemption.

  **What it catches**: a decode bug with a plausible shape — a raw epoch integer, a
  `NaiveDateTime`, or a venue string left unparsed in `:venue_time`.

  **What it cannot catch, and the coverage map now says so**: a venue putting its own local
  clock in `:venue_time`. No assertion can — a `DateTime` from `DateTime.utc_now/0` is
  indistinguishable from one the venue sent. That is held by the type's documentation and by
  review, and implying otherwise would make the coverage map worse than useless.

  A third test is structural: neither type may regrow a `:timestamp` field. Same reasoning as
  `TopOfBook has no price field` — a field with no defined meaning gets filled from whichever
  value is nearest to hand, which is the ambiguity the split removed.

### Removed — BREAKING

- **`Core.Types.Quote` and `Core.Types.OrderBook` no longer have `:timestamp`.** It is
  replaced by **`:venue_time`** (the venue's own, `nil` where the venue publishes none) and
  **`:observed_at`** (when this package read it, always present) — the shape
  `Core.Types.TopOfBook` has had from the start.

  **Why it had to break.** `:timestamp` was documented as "the venue's own… never invented",
  and two packages could not keep that promise, because the frames they decode carry no
  venue time at all: `dp_exchange_schwab`'s `LEVELONE_*` quotes, and `dp_exchange_gemini`'s
  partial-depth books (the vendor's own AsyncAPI requires only `[lastUpdateId, bids, asks]`
  there, where `BookTicker` requires `E`). With one field their only options were to lie or
  to drop real data, and they lied — a read time in a field a consumer was told was the
  venue's.

  **What it costs a consumer, and what it buys them.** Every call site reading `.timestamp`
  on these two types changes. In exchange they can express a policy they previously could
  not: store `:venue_time` as the point time where the venue dated the frame, and where it
  did not, store `:observed_at` **and record that you did** — so a mis-bucketed value is
  attributable rather than invisible.

  That framing is the consumer's, from issue #31, and it is a better argument than the one
  the design document made. Their monitoring never used this field (liveness runs off their
  own receipt clock), so the staleness hazard the plan led with could not reach them. But
  `Quote.timestamp` is their InfluxDB point time and candles bucket off it — so a lagging
  venue with a substituted read time puts ticks in the wrong candle, feeding indicators and
  strategy evaluation, and nothing flags it because the freshness checks are deliberately
  looking elsewhere.

  **`:observed_at` is mandatory** on both types, at the consumer's request. That is what
  makes a strictly-honest nullable `:venue_time` affordable: everyone always has a usable
  time, so `nil` can mean "the venue did not date this" without forcing a caller to invent a
  fallback — which would be this same substitution, relocated into consumer code.

  **Not a licence to fill `:venue_time` from a local clock.** The rule that field carries is
  unchanged and absolute: whatever the venue gave us, or `nil`.
  `dp_exchange_schwab`'s Streamer book is the model — it reads the venue's `snapshot_time`
  and fails closed when absent.

  `Trade`, `Fill`, `Balance` and `OrderBookDelta` are **unchanged** and keep a single
  `:timestamp`. A sweep confirmed every `Candle` and `Trade` construction in all five venues
  derives its time from a venue field, and `OrderBookDelta` fails closed without the venue's
  `E`. There is no divergence to fix there, and widening a breaking change past the defect
  it exists for is how a migration becomes unaffordable.

  Design, options and retrospective:
  `docs/design/closed/2026-09-09_venue-time-and-observed-time.md`. Announced as issue #31 and
  answered by the consumer the same day.


### Documentation

- **The venue-time design document moved `Draft` → `In Review`, and the consumer has been
  told.** `docs/design/2026-09-09_venue-time-and-observed-time.md` records that `Quote` and
  `OrderBook` carry a single `:timestamp` and so cannot say "the venue did not date this",
  which two packages currently resolve by putting a read time in a field the contract
  documents as the venue's own.

  Filed as issue #31 with the blast radius measured (19 `lib/` files, 27 test files, 69
  construction sites across six repositories) and the three options costed. The one question
  that decides between them is put to the consumer directly: **does anything measure
  staleness from `Quote.timestamp`, or is it carried and stored?** If nothing does, the
  cheapest honest option becomes viable; if something does, the field is actively misleading
  them today and the fix is worth its cost.

  Nothing lands until they have had a chance to answer, and when it does it is a **minor
  bump across the family in one batch**, not a patch — so a consumer pinning three-part, as
  `usage-rules.md` instructs, receives it only when they choose it. Both type moduledocs and
  both offending call sites are already labelled in the meantime.

### Documentation

- **`Core.Types.Quote` and `Core.Types.OrderBook` now record where their own rule is not
  kept.** `Quote`'s doc says `:timestamp` is "the venue's own… never invented: a quote whose
  freshness we cannot state is a quote we must not return." Two venue packages break it, and
  neither is a decoding mistake: `dp_exchange_schwab`'s `LEVELONE_*` quotes carry the
  frame's arrival time, and `dp_exchange_gemini`'s partial-depth books carry the local clock.
  Both venues genuinely publish no time for those frames — Gemini's own AsyncAPI proves it,
  requiring `[lastUpdateId, bids, asks]` for `OrderBookSnapshot` where `BookTicker` requires
  an `E`.

  **The gap is in this contract, not only in those packages.** `TopOfBook` can say "the
  venue did not stamp this" because it carries `:venue_time` and `:observed_at` separately;
  `Quote` and `OrderBook` have one field, so a venue that publishes no time can only lie or
  drop the data. `dp_exchange_schwab`'s Streamer *book* is the counter-example that proves
  the rule is keepable where the venue cooperates — it reads `snapshot_time` and fails closed
  without it.

  Recorded in both moduledocs rather than only in a design document, because a reader of the
  contract deserves to know where it is not being kept.

- **New design document: `docs/design/2026-09-09_venue-time-and-observed-time.md`.** Closing
  the gap means changing a published type that a live consumer decodes at every call site —
  19 `lib/` files and 27 test files across six repositories, 69 construction sites, delivered
  automatically by the release pipeline on merge. This project's rules reserve that for a
  written plan, and this is a decision where the cheapest option for us is the most expensive
  one for the consumer.

  Three options are costed: refuse the undated data (deletes the last traded price from
  Schwab's stream), give `Quote`/`OrderBook` what `TopOfBook` already has (breaking), or add
  `:venue_time` alongside `:timestamp` (non-breaking but redundant, and redundancy rots). The
  recommendation is the second, sequenced deliberately rather than landed unannounced.

  One open question was closed in the same pass: **every `Candle` and `Trade` construction in
  all five venues derives its time from a venue field.** None reaches for the local clock, so
  the substitution is confined to the two named sites rather than being a family-wide habit —
  which bounds both the data loss of option A and the migration of option B.

### Documentation

- **`usage-rules/adapter.md` gains "If your vendor publishes an index, diff it".** The
  vendor-change design doc concluded that across five vendors a *changelog* diff caught
  nothing and an **index diff** was the only mechanism that ever fired. That conclusion has
  now produced three real findings — a rate-limit table on `developer.webull.com` published
  for weeks behind a five-times-too-permissive ceiling; a WebSocket channel withdrawn from
  `developer.gemini.com` with no changelog entry; and Coinbase's rate-limit pages, recorded
  as "could not be located", sitting in the vendor's own `sitemap.xml` the whole time.

  Every venue package now carries `script/check_endpoint_inventory.sh`, weekly and
  non-blocking. The section records what to compare, in order of preference: a
  machine-readable specification where the vendor publishes one (Gemini alone today), a
  sitemap whose pages are one-per-endpoint otherwise (Coinbase, Webull), and — for a vendor
  that answers `403` to an anonymous reader (Schwab) — nothing, which is a distinct class
  rather than a degraded one.

  It also records the two rules that separate a check from a rubber stamp: **fix the claim
  before updating the record**, because updating the inventory first destroys the only
  evidence anything changed; and **diff the specification, never the rendered page**.

- **And the rule the Gemini finding forced: absent from the documentation is not absent from
  the venue.** When something vanishes, what has been established is that the vendor stopped
  *publishing* it, not that the venue stopped *serving* it — Gemini has diverged from its own
  documentation in both directions. So a withdrawal is a reason to **label** a claim, not
  automatically to delete it: deleting asserts a new negative, and an unverified negative is
  a substitution exactly like an invented value.

### Documentation

- **`usage-rules/adapter.md` gains "Never do blocking work in a process that owes a
  reply".** This is the failure this family has paid for most often, and every instance
  looked different until they were lined up: #16 and #23 (work on the reply path in a
  venue's feed), then #28, where `Core.PollingFeed` ran its fetch in a task and then
  *blocked on that task* — the task bounded a hang and did nothing for the mailbox, so a
  read-only `coverage/1` timed out, the exit propagated out of the venue `Feed`'s
  `handle_call/3`, and a live venue went from 61 pairs to 0 and stayed there.

  Writing the rule down came with sweeping the family for it, and the sweep found **three
  more instances that had not failed in production yet** — a Streamer bootstrap (signed
  HTTP *plus* a WebSocket connect) inline in `handle_call/3`, a whole-catalogue HTTP fetch
  inline in `handle_info/2`, and a socket connect inline in `handle_call/3`. All three are
  fixed in their own packages.

  The section carries the three mistakes that are easy to make while fixing it: a task that
  bounds a hang does **not** unblock a mailbox (that *was* #28); `start_link` links to its
  caller, so a socket opened inside a task dies with the task — fetch in the task, connect
  in the GenServer; and exceptions must be converted **inside** the task, because
  `Task.async/1` links and an unconverted raise arrives as an `{:EXIT, …}` with no clause
  for it, leaving anything parked on that task unanswered forever.

  It also records the read-side rule the same sweep produced — every venue now passes
  `@call_timeout` on `coverage/1`/`status/1`, not just on writes, because a health check
  left on `GenServer.call/2`'s implicit five seconds turns any legitimately busy moment
  into an exit and a dead consumer process — and the honesty rule for what a degraded read
  may claim: an empty coverage map plus a `:link_down` notice, never a remembered one.

### Documentation

- **`usage-rules/auth.md` gains "Credentials are redacted in `child_spec/1` — bypass it and
  they are not".** The consumer who verified the issue #29 fix went looking for their
  canary in their own supervisor's state afterwards and found it: their supervision code
  builds the child spec itself, for a legitimate reason (a `Core.PollingFeed`-shaped facade
  defaults `subscriber` to `self()`, which resolves to the *supervisor* when `start_link/1`
  runs inside `init/1`, so a different delivery target can only be set at `start_link`
  time). On that path `child_spec/1` never runs, their supervisor stores the raw map, and
  OTP renders the live key on the next crash. **Upgrading does not fix it, because nothing
  from any package is on that path.**

  No code change was needed or made — `wrap/1` and `wrap_opt/1` were already public, which
  is all that path required. What was missing was anyone saying so. Assertion 22 asks
  whether `child_spec/1`'s own rendering leaks, answers correctly, and is structurally
  unable to see a spec a consumer built; the section says that explicitly, and tells a
  consumer on that path to write the consumer-side version of the assertion — including
  the control case, since a canary test with no proof that an unwrapped map *does* leak
  proves nothing.

  It also records the case that actually bit them, which is a step further out than the
  original bug: a host **reshaping** a credential (mapping its own `api_key`/`api_secret`
  into a venue's `app_key`/`app_secret`) and returning a bare map re-introduces the leak in
  its own code, downstream of anything a package can reach. Their own canary test caught
  that on its first run — on Webull, the venue whose keys had actually leaked, which was
  still leaking after the upgrade through their code rather than ours.

### Fixed

- **A read-only `coverage/1` could kill a venue's feed — issue #28.** `Core.PollingFeed`
  ran its fetch inside a task and then **blocked on that task** inside `handle_info`. The
  task bounded a hang; it did nothing at all for the mailbox. With `@min_fetch_timeout_ms`
  at 30 seconds against `GenServer.call/2`'s 5-second default, a `coverage/1` or `status/1`
  arriving during an ordinary in-flight fetch was not unlucky — it was a **guaranteed**
  timeout. In `dp_exchange_robinhood` that exit propagated out of the venue `Feed`'s own
  `handle_call/3` and killed it; the feed restarted from the static opts its supervisor
  holds, which never carry a consumer's later `subscribe/3`, and coverage went **61 pairs
  to 0 and stayed there** — with the process alive, idle and passing every liveness probe.
  Asking whether the venue was healthy is what made it unhealthy.

  The fetch result now arrives as a **message**: `handle_info` starts the task and returns
  immediately, so `coverage/1` and `status/1` answer from state at any point during a
  fetch. **Concurrency is deliberately still one** — a tick arriving while a fetch is in
  flight is queued rather than started, which is exactly what the mailbox did when the
  fetch was synchronous. Letting ticks overlap would have quietly multiplied a venue's
  request rate the moment a fetch grew slower than its interval, and an unexamined
  multiplier on request volume is a defect class this family has already paid for.
  Rescheduling still happens only after a job finishes, so there is at most one pending job
  per symbol and the queue cannot grow without bound.

  Reported against `dp_exchange_robinhood 0.2.21` / `dp_exchange_core 0.1.72` by a consumer
  running the venue live, with the `Neighbours` block of the crash report showing the
  called process inside `bounded_fetch/2` at the moment the call arrived.

- **The test that should have caught it was the reason nobody did.** The existing hang test
  used a 100 ms `:fetch_timeout_ms`, so `status/1` returned as soon as the fetch was
  abandoned and the test read the recorded failure — while the call was still *blocking*
  for the whole timeout. It is rewritten to use a timeout **longer** than
  `GenServer.call/2`'s own default, so a regression cannot return a value at all: it exits,
  and the test fails instead of passing for the wrong reason. A second test covers
  `coverage/1`, which is the call a consumer's health check actually makes.

### Added

- **Assertion 22 — credential redaction in `child_spec/1`** (issue #29). A supervisor
  stores the `{module, :start_link, [opts]}` MFA its child spec names, and OTP writes that
  argument list through `inspect/1` into the `Start Call:` line of the report it logs on
  **any** child termination. A raw `%{api_key: ..., private_key: ...}` map therefore prints
  its values in full into ordinary application logs — the artifact most likely to be
  shipped to an aggregator, attached to a bug report or quoted in a ticket. A consumer
  found live keys exactly this way and nearly pasted them into a GitHub issue while
  reporting an unrelated bug.

  **This is the assertion that assertion 19 says it cannot make.**
  `Core.CredentialRedactionCheck` proves every *struct* a package defines redacts on
  inspect, and its own moduledoc already recorded that it would not have caught the defect
  as it actually shipped — where the value never became a struct at all. Assertion 22 asks
  the only question a consumer cares about: having handed the venue a secret the documented
  way, is that secret visible in what the supervisor stores? It passes every secret key
  name in the family at once, so it needs no per-venue list, and `Kernel.struct/2` drops
  keys a venue's own struct does not declare — an unrecognised key is gone, not merely
  unprinted.

  It caught `Core.ReferenceVenue` — this repository's own example of what a venue looks
  like — on its first run, which is now fixed and carries the redacting struct as the
  reference shape.

### Changed

- **The purity check (2.10) was policing more than it claimed.** It scans
  `_build/#{Mix.env()}/lib/dp_exchange_core/ebin/*.beam`, and in `:test` this project's own
  `elixirc_paths/1` also compiles `test/support` into that same directory — so a check
  named "nothing in `lib/` reaches for the host application" was quietly also checking test
  scaffolding. Surfaced when the reference venue grew an `@derive {Inspect, ...}` and the
  test failed reporting `Inspect.Any` "in lib/", where no such reference exists. It now
  filters by each beam's own `:compile_info` source path. Filtering is the repair rather
  than widening `allowed_prefixes`: the allow-list is what gives this check teeth for code
  that actually ships, and adding an entry to satisfy a module that never ships would blunt
  it for the ones that do.

### Documentation

- **`docs/design/ideas/detecting-vendor-api-change.md` is implemented and closed**, as
  `docs/design/closed/2026-09-09_detecting-vendor-api-change.md` with a retrospective. The
  document spent five phases gathering evidence about which change-detector is worth
  building; the evidence chose, and what shipped into all five venue packages is
  `script/check_doc_sources.sh` plus a committed `doc-sources.tsv` — status and redirect
  destination per cited vendor documentation URL, recorded on the day a person read it,
  checked weekly and non-blocking. No changelog watcher and no content differ: across the
  whole sample a changelog diff caught **nothing**, and an index diff was the only
  mechanism that ever fired.

  `dp_exchange_core` itself gets no manifest and no job — it cites no vendor documentation
  page, because it talks to no exchange. A no-op weekly run would be noise.

  The instrument found a real defect on its first run rather than the baseline it was meant
  to record: a `404` on a page `dp_exchange_webull` cited, which led to a rate ceiling five
  times too permissive against that venue's own per-endpoint table, on a venue whose
  documented penalty is `429` and then IP-level blocking. The retrospective carries the
  full chain, including the finding that matters most here — **"the vendor changed" and "we
  were wrong" share a mechanism, a claim nobody re-read**, which is why the check has a
  `manual` class for venues no machine can verify (Schwab answers `403` to anonymous
  readers) and why those rows go STALE past 180 days. That closes a gap this repository
  named at Phase 5 and could not close: `Capabilities` has carried `measured_at` all along
  and nothing ever read that age.

- **`docs/design/ideas/credential-gate-fixed-callback-list.md` moved to
  `docs/design/closed/2026-09-07_credential-gate-fixed-callback-list.md`.** It had been
  marked resolved on 2026-09-07 and left sitting in `ideas/` — a file whose whole purpose
  is to record state, recording the wrong one. Content unchanged beyond the status line and
  a note recording the two-day gap.

### Fixed

- **`AdapterContract` no longer dials a live venue on an ordinary `mix test` run.**
  Assertion 14's `get_top_of_book/2` check and two of assertion 12's checks —
  "catalog_access matches how get_symbols/1 behaves without a query" and "the
  order-shape claims match what the facade actually answers" (`preview_order/3`,
  `replace_order/4`) — called `@venue` directly instead of `@fake`, contradicting the
  `@fake` attribute's own comment ("Assertion 12's active-endpoint direction runs
  against this and never against the real venue") and this family's tier-2 rule ("never
  on a schedule"). Flagged as an "incidental, pre-existing, out-of-scope finding" in the
  assertion-20/21 entry below; this is that fix.

  All four now assert `@fake` is present (failing loudly, matching assertion 17's own
  pattern, rather than skipping silently — every one of the five venue packages already
  supplies `fake:`) and call the fake instead of the real venue. The order-shape check
  was a second defect beyond the two originally reported: it called `preview_order/3`
  and `replace_order/4` unconditionally, with no active/inactive guard at all, so any
  venue implementing either for real (`dp_exchange_coinbase`, `dp_exchange_schwab`,
  `dp_exchange_webull`) dialed a signed, order-shaped write endpoint on every run.

  **Reproduced and verified against all five venue packages** with a `path:` dependency
  on this Core, `mix test --trace` (forces synchronous execution so `Core.HttpClient`'s
  `Logger.debug("HTTP Request: ...")` line lines up with the test that triggered it),
  reverted after each: before this fix, `dp_exchange_gemini` dialed
  `api.gemini.com/v1/symbols` and `.../v1/pubticker/btcusd`; `dp_exchange_robinhood`
  dialed `trading.robinhood.com/api/v2/crypto/trading/trading_pairs/`;
  `dp_exchange_webull` dialed `api.webull.com/trading/instruments/crypto/profiles/list`;
  `dp_exchange_coinbase` dialed `api.coinbase.com/api/v3/brokerage/products`. After the
  fix, zero live requests on all four, 0 test failures on all four (Gemini 775,
  Robinhood 240, Webull 743, Coinbase 682 tests). `dp_exchange_schwab` made no live
  request either before or after — it escapes only because `preview_order/3` and
  `get_symbols/1` both refuse locally (missing `account_hash`, missing credentials)
  before building a request under the specific arguments this suite passes, not because
  the old code was safe; it is one implementation change away from the same defect the
  other four had.

### Added

- **A conformance-coverage audit — mapping every `Core.Venue` callback, `Capabilities`
  field and `Notice` kind against the 19 existing assertion groups — closes three real
  gaps: `Capabilities.new/1` gains a `has_staking`/staking-endpoint agreement check, and
  `AdapterContract` gains assertion 20 ("subscribed push shape") and assertion 21
  ("historical timeframe discipline"). The full inventory — covered, partial,
  deliberately declined — lives in `docs/reference/core/assertion-coverage.md`.**

  **`has_staking` must now agree with the six staking endpoints it summarises**
  (`get_staking_rates/1`, `get_staking_balances/1`, `get_staking_rewards/1`,
  `get_staking_history/1`, `stake/3`, `unstake/3`), the same "Kind 2 redundant field
  must agree with the endpoints it summarises" rule `validate_orders!/1` already applies
  to `supports_order_preview`/`supports_order_replace`/`supports_multi_leg_orders`.
  **Found live on `dp_exchange_coinbase` during this audit**: `has_staking` was never
  declared in its `capabilities/0` (defaulting to `false`) while `stake/3` and
  `unstake/3` are real, active calls against Coinbase Prime — a caller branching on
  `has_staking` alone would conclude the venue does not stake at all. Confirmed by
  pointing that package's `mix.exs` at this Core with a `path:` dependency and running
  its own contract test: 23 of 42 tests fail, all from this one raise inside
  `capabilities/0`. Reported for that package's own review; not fixed here, and no
  `path:` dependency was committed — `mix.exs` was reverted immediately after. Keyed on
  an EXPLICIT `:proven`/`:experimental`
  entry in `endpoints`, never on `active?/2`'s undeclared-is-experimental default, so a
  declaration that has nothing to do with staking (the overwhelming majority of fixtures
  and tests in this family) is unaffected. **Downstream: every venue package's own test
  suite re-runs this the moment it depends on this version**, since assertion 2 already
  rebuilds every venue's declaration through `Capabilities.new/1`.

  **Assertion 20, "subscribed push shape"**: `subscribe/2`'s own doc makes an
  unconditional claim — the payload is a `DpExchange.Core.Types.*` struct, tagged with
  `runtime_id/0` — that nothing checked before now. Assertion 16 (internal wiring)
  catches a decoder with no caller, but a decoder that IS wired and simply never gets
  called before the raw response reaches the sink passes every other assertion. Fake-only,
  so it never dials out.

  **Assertion 21, "historical timeframe discipline"**: `get_historical_prices/4`'s own
  doc states this family's own named recurring failure mode verbatim ("The venue rejects
  a timeframe it does not serve rather than substituting the nearest one") and nothing
  checked it before now. Picks a width from `Timeframe.nameable/0` the venue's own
  `historical_timeframes` does not name and asks the fake for it; the answer must not be
  `{:ok, _}` (`dp_exchange_robinhood` declares the endpoint `:unsupported` entirely and
  the check is a no-op there). Fake-only.

  Both 20 and 21 pass on all five real venue packages — verified the same way as the
  `has_staking` finding above, a `path:` dependency run and reverted per venue — with
  `dp_exchange_coinbase`'s 23 failures being entirely the `has_staking` finding, not
  these two. See `docs/reference/core/assertion-coverage.md`'s "Five-venue verification"
  section for the full table, including an incidental, pre-existing, out-of-scope finding
  from the same runs: two OLDER assertions (14 and part of 12) call the real venue
  module directly for `get_top_of_book/2` and `get_symbols/1`, so an ordinary `mix test`
  on Gemini, Robinhood and Webull today makes real calls to each venue's public API
  despite `test_helper.exs` excluding `:tier2` specifically to prevent that.

  `usage-rules/testing.md` and `docs/guides/building-an-exchange-package.md`'s assertion
  counts move from 19 to 21; `usage-rules/adapter.md` gains sections for both new
  assertions next to assertion 19's.

- **`usage-rules/adapter.md` gains a "Dependency floors are a claim exactly like a
  capability" section, and every venue package gains
  `script/check_dependency_floor.sh` plus a weekly `floor-check.yml` workflow.** Four
  real instances of the same defect shipped in one week: a `mix.exs` `~>` requirement
  that compiles and passes CI (which always resolves the *newest* allowed version) while
  permitting an older, still-allowed version the code does not actually run against —
  `dp_exchange_webull`/`websockex` (twice — the first correction, `~> 0.4` → `~> 0.5`,
  was itself still wrong; `send_frame/3` needs `0.5.1`, not `0.5.0`),
  `dp_exchange_webull`/`dp_exchange_core` (`no_venue_contact`, needs 0.1.68), and
  `dp_exchange_gemini`/`dp_exchange_core` (`Types.OrderBookDelta`, needs 0.1.53). A
  per-API pinning test guards a floor against being lowered again; it cannot catch a
  floor that was wrong when written, because it only knows what its author already
  thought to check. The script resolves every dependency a venue declares *without*
  `only:` down to the exact floor its own requirement names, then runs
  `mix compile --warnings-as-errors` plus the package's own `AdapterContract`
  conformance test against that pinned set — deliberately not the full `mix test`
  (`dp_exchange_coinbase`'s `feed_test.exs` was found, in the course of this work, to
  depend on the real live venue — a separate, pre-existing issue, filed, not fixed, here)
  and deliberately not extended to dev/test-only tooling (`credo` at its own declared
  floor, `1.7.0`, does not compile under Elixir 1.18 at all — a bug in a years-old
  release unrelated to this family, which would make the check permanently red for a
  reason that has nothing to do with any package's floor). Runs weekly plus
  `workflow_dispatch`, never on `push`/`pull_request` and never in `ci.yml`'s `publish`
  job's `needs:` chain, because a fresh resolve floats each pinned dependency's own
  *transitive* tree to whatever is newest on Hex today — a red run can be caused by an
  unrelated package's release, not by this repository, and this family has already
  relearned once that a check people learn to ignore is worse than none. Full writeup,
  evidence and the decisions not taken (a frozen lockfile; a full test run) in
  `docs/design/closed/2026-09-08_dependency-floor-check.md`.

- **`AdapterContract` gains assertion 19, "credential redaction" — a struct defined in a
  package's own `lib/` holding a secret-named field must redact it under `inspect/1`.**
  Found live in four of five venue packages on 2026-09-07: `Feed`/`Socket` held
  `:credentials` as a bare map for their entire lifetime, and OTP's default crash report
  prints a process's state in full on termination — a plain map prints every key it
  holds, secrets included. Proven by crashing an equivalent process holding
  `%{api_key: "...", api_secret: "..."}` as a bare state field and reading the log back.
  A second leak was found the same way: a `FunctionClauseError`'s stacktrace prints the
  actual arguments a failed clause was called with, so a bad call handing the same raw
  map to a function whose every clause failed to match printed it too.
  `Process.flag(:sensitive, true)` was tried and ruled out — it changes what
  `:sys.get_state/1`/`:dbg` can see, not how a crash report or a stacktrace is formatted.
  Fixed identically in four repos, by wrapping the credential in a struct whose `Inspect`
  is derived with `except:` naming every secret field, at the point it enters a
  long-lived process: `dp_exchange_coinbase` `4d00669` (`api_key`, `api_secret`),
  `dp_exchange_webull` `80eaf02` (`app_key`, `app_secret`, `access_token`),
  `dp_exchange_schwab` `336cbd8` (`access_token`, `refresh_token`, `client_id`,
  `client_secret`), `dp_exchange_robinhood` `cfc4861` (`api_key`, `private_key`).
  `dp_exchange_gemini` needed no fix — it signs and discards inside stateless pipelines
  and holds no credential in process state at all.

  **Verified behaviourally, not by looking for `@derive` in a venue's source.**
  `DpExchange.Core.CredentialRedactionCheck` instantiates a real copy of every struct a
  package's `lib/` defines (`struct/2`, never `struct!/2`, so `@enforce_keys` on an
  unrelated field never blocks construction) with a distinctive value in each
  secret-named field, and searches the actual rendered `inspect/1` output for it. A
  hand-written `defimpl Inspect, for: YourStruct` that never mentions `@derive` at all
  passes exactly as validly as the derived form every real fix used, because this checks
  what a struct prints, never how it was made to print that way. Every module under test
  is already loaded by construction — this only ever runs from inside the same
  `mix test` invocation that compiled the package being checked, so nothing here starts a
  fresh process or touches a network.

  **The secret-name list has fifteen entries**: `api_key`, `api_secret`, `app_key`,
  `app_secret`, `secret`, `password`, `passphrase`, `token`, `access_token`,
  `refresh_token`, `client_secret`, `private_key`, `signature`, `authorization`,
  `bearer` — matched against a struct field's own name exactly, never a substring, so
  `token_type` is not caught by `token`. Twelve are `DpExchange.Core.Notice`'s own
  `@credential_keys`, reused rather than reinvented — the same question ("is this name,
  alone, secret-shaped") already answered there for a different purpose. Three extend it
  because a real, shipped `Credentials` struct in this family has a field by that name
  and `Notice`'s list did not cover it: `app_key`/`app_secret`
  (`dp_exchange_webull`) and `client_secret` (`dp_exchange_schwab`). **`client_id` is
  deliberately excluded** even though Schwab's own struct redacts it too — an OAuth
  `client_id` is a public identifier by the convention the spec itself follows, and
  treating it as inherently secret would be exactly the "too broad" failure mode that
  gets a check disabled. Verified against every `defstruct` in all five venues' actual
  `lib/` before the list was finalised: none collides with any of the twelve
  `Notice`-derived names.

  **Be honest about what this does not catch: the original defect was a raw map, never a
  struct, and this check would not have caught it as it actually shipped.**
  `Feed`/`Socket`, pre-fix, held `Keyword.get(opts, :credentials)` directly in state — an
  opaque value never constructed as a literal anywhere in either module's own compiled
  code. A struct-field check locks the fix in; it cannot reach back to the shape of the
  bug before the fix existed. Two static, map-shaped versions of a broader check were
  considered and rejected as the enforceable maximum instead: (1) "a process-behaviour
  module's compiled code contains a map literal with a secret-named key" does not reach
  the real pre-fix defect at all (the offending modules never constructed the map as a
  literal) and fires constantly on completely correct code — every venue's `Auth` module
  builds a transient map or keyword list with a secret-named key to hand to an HTTP
  client or a signer, never storing it; (2) "reads `:credentials` from start options and
  stores it without first passing it through a wrapping call" is closer to the real
  shape but only detectable by assuming every future fix uses a sibling module
  conventionally named `*.Credentials` with a `wrap/1` function — encoding an
  implementation convention into a Core assertion the same way `AdapterContract`'s own
  "no assertion may name a socket, a channel string, a transport module or a polling
  interval" already forbids in the transport direction. Both fail the test this family
  already applies to a candidate assertion — would it survive contact with real, correct
  code across all five venues without being disabled — so the struct-field check is
  documented as the narrower thing that is enforceable, not manufactured as broader
  coverage this contract does not actually have.

  Proven against a reconstructed pre-fix shape in `test/dp_exchange/core/
  credential_redaction_check_test.exs` (a struct with no `Inspect` override at all,
  fails; the same struct with `@derive {Inspect, except: [...]}` added, passes; a
  hand-written `defimpl Inspect` that redacts, passes; one that does not, still fails; a
  plain map holding the same secret-named key, never flagged, proving the documented
  limitation directly rather than only in prose) — no venue repo was touched to prove
  this. **Verified against all five real venues**, each pointed at this Core checkout
  with a temporary `path:` dependency, `mix test` run, then reverted before anything was
  committed: all five pass today — `dp_exchange_coinbase` (676 tests),
  `dp_exchange_webull` (735 tests), `dp_exchange_schwab` (495 tests),
  `dp_exchange_robinhood` (236 tests), `dp_exchange_gemini` (772 tests) — all 0 failures,
  because all five already carry today's fix (or, for Gemini, never needed one).

  This package's own `mix.exs` gains `consolidate_protocols: Mix.env() != :test`: the new
  check's own test fixtures compile a struct's `Inspect` implementation at test runtime
  via `Code.compile_string/2`, after `mix test`'s default protocol consolidation has
  already baked a dispatch table that does not know that implementation exists yet — a
  real venue package never hits this, since its `Credentials` module compiles as part of
  the ordinary `mix compile` pass, before consolidation runs.

  **Assertion count is now nineteen.** `usage-rules/testing.md`, `usage-rules/adapter.md`
  (a dedicated section next to assertion 18's) and
  `docs/guides/building-an-exchange-package.md` updated.

  **Affects all five venue packages on their next Core bump**, and every future one.
  Inert today for all five — four already carry their own independent fix, and Gemini
  never needed one — so this assertion exists to stop a *sixth* venue (or a regression in
  one of the five) reintroducing the exact shape found on 2026-09-07, not to fail
  anything that ships today.

- **`AdapterContract` gains assertion 18, "link safety" — a process behaviour
  (`GenServer`, `:gen_statem`, `GenStateMachine`, `WebSockex`) that links a child it
  starts must also call `Process.flag(:trap_exit, true)`.** Found live in four of five
  venue packages on 2026-09-07, all independently: `Feed.init/1` never trapped exits, and
  `Socket.start_link/1` (or `PollingFeed.start_link/1`) ran from inside a `Feed`
  callback, which links the child to `Feed` itself rather than to a supervisor. An
  abnormal exit on that link was therefore untrappable and crashed `Feed`, and the
  venue's `Supervisor` restarted it from its **static start opts** — every `subscribe/2`
  a consumer had made since boot, gone in the same instant. One socket dying anywhere
  took the whole feed's subscription state with it. Fixed identically in all five repos
  by trapping exits before anything gets linked: `dp_exchange_coinbase` `e77b542`,
  `dp_exchange_gemini` `66acd3b`, `dp_exchange_webull` `d0c54a8`, `dp_exchange_schwab`
  `90dddc6`, `dp_exchange_robinhood` `51ad189`.

  **Deliberately static, not the behavioural "start the tree and kill a linked child"
  test that was designed first.** That design was rejected on evidence, not on general
  principle: starting a venue's real (non-fake) tree is not reliably network-free.
  `dp_exchange_schwab`'s `Feed` dials its Streamer unconditionally from `init/1`'s own
  `{:continue, :connect}`, regardless of whether any symbol has ever been subscribed —
  confirmed by starting its real tree under the local Core path dependency below and
  reading the request that goes out. The only way to prevent that dial without opening a
  real socket is to inject an already-open stand-in through an option each venue happens
  to expose for its own tests (`:socket` here, differently named or absent on
  `dp_exchange_robinhood`, which has no socket concept at all) — which is exactly what
  this suite's own rule forbids: no assertion may name a socket, a channel string, a
  transport module or a polling interval. There is also no reliable, venue-agnostic way
  to *locate* "the feed" once a tree is running — `DpExchange.Core.FeedBehaviour` exists
  for exactly that and has zero adopters across the five.

  `DpExchange.Core.LinkSafetyCheck` instead reads each candidate module's own compiled
  abstract code — the same `:beam_lib` technique `Core.UnwiredCheck` already uses for
  assertion 16 — for two facts, module-wide rather than per-callback (the five real
  fixes disagree on which callback creates the link and which calls
  `Process.flag(:trap_exit, true)`, so the invariant is checked against the module as a
  whole): a link-creating call (`start_link` on any target, `Process.link/1`, or
  `spawn_link`, any arity) and the trap_exit guard. Neither is ever a process; nothing
  here starts, so nothing here can dial out, for any venue present or future.
  `start_link/1`, `start_link/2`, `child_spec/1` and `child_spec/2` are excluded as the
  *source* of a link — the same two names assertion 16 already excludes, and for the
  same reason: found running this check against the real, compiled
  `dp_exchange_coinbase`, `Socket.start_link/1` (`use WebSockex`) delegates to
  `WebSockex.start_link/4` to bootstrap itself, a call literally named `start_link` on
  every process-behaviour module in the family, always — that link belongs to whoever
  calls `Socket.start_link/1`, not to `Socket`.

  Proven against a reconstructed pre-fix shape in `test/dp_exchange/core/
  link_safety_check_test.exs` (a `GenServer` linking a socket from `handle_call/3` with
  no `trap_exit`, fails; the same shape with `Process.flag(:trap_exit, true)` added,
  passes) — no venue repo was touched to prove this. **Verified against all five real
  venues**, each pointed at this Core checkout with a temporary `path:` dependency, `mix
  test` run, then reverted before anything was committed: all five pass today —
  `dp_exchange_coinbase` (668 tests), `dp_exchange_gemini` (771 tests),
  `dp_exchange_webull` (725 tests), `dp_exchange_schwab` (484 tests — the one venue
  whose real tree is not network-free, and the reason this assertion is static: it
  passed without ever starting a process, so nothing in it could have dialed out),
  `dp_exchange_robinhood` (228 tests) — all 0 failures, because all five already carry
  today's fix.

  **Assertion count is now eighteen.** `usage-rules/testing.md`,
  `usage-rules/adapter.md` (a dedicated section next to assertion 17's) and
  `docs/guides/building-an-exchange-package.md` updated.

  **Affects all five venue packages on their next Core bump**, and every future one.
  Inert today for all five — each already carries its own independent fix — so this
  assertion exists to stop a *sixth* venue (or a regression in one of the five)
  reintroducing the exact shape found on 2026-09-07, not to fail anything that ships
  today.

- **`AdapterContract` gains assertion 17, "credential gate" — on a venue declaring
  `credential_benefit: :required`, no active credentialed endpoint's `fake:` may answer
  `{:ok, _}` when called with credentials stripped.** Found independently in two venue
  packages the same week: `dp_exchange_robinhood`'s fake answered `{:ok, _}` from six
  credentialed functions (`get_balances/2`, `get_accounts/2`, `place_order/3`,
  `cancel_order/3`, `get_order/3`, `get_orders/2`) regardless of what credentials they
  were given, on a venue where **every request is signed and there is no anonymous
  endpoint** — the fake was lying about the most basic property of the venue. A separate
  fake/real error-shape divergence was found the same day in `dp_exchange_gemini`. Tier 1
  in-process fakes are the only tier that runs on every CI run and the only one most
  consumers ever exercise, so a fake more capable than the real venue silently certifies
  consumer code that forgot to supply credentials.

  Fake-only — it never dials the real venue, so it carries none of the risk a
  live-network assertion would — and gated strictly on `credential_benefit: :required`,
  not run unconditionally: a venue declaring `:no_difference` or `:higher_ceiling` may
  legitimately serve some of these endpoints without a credential, and asserting a
  refusal there would invent a rule the venue never claimed. `test_connection/2` and
  `get_rate_limit_status/2` are excluded from the gate on any venue, `:required` or not
  — both callbacks document `credentials() | nil` on purpose, and answering plain
  reachability with none at all is the documented behaviour, not the defect this
  assertion exists to catch.

  **Deliberately does not assert real/fake refusal-shape equality**
  (`call_on(@venue, stripped) == call_on(@fake, stripped)`), which was the second,
  stronger proposal and would also have caught Robinhood's `{:refused,
  :missing_credentials}` vs. the real venue's `{:error, {:missing_credentials,
  :robinhood}}`. That check is only safe while every venue's auth check fails locally
  before any HTTP dial-out — true today, but Core would be assuming an invariant about a
  venue it has not reviewed, and a conformance assertion that can make a live network
  call under some future venue's implementation is a worse failure mode than the gap it
  would close. Verified against the real generated assertion, not only a manual
  replica: temporarily setting `credential_benefit: :required` on `ReferenceVenue` (whose
  `get_balances/2` ignores its credentials argument, correctly, for its real
  `:higher_ceiling` declaration) makes assertion 17 fail with `{:get_trade_history, 2}
  answered {:ok, _} with credentials stripped`, confirming the check fires on real
  generated code before being reverted; `contract_teeth_test.exs` carries the permanent
  regression fixtures (`Broken.CredentialGate.NeverChecks` and `.Conforming`).

  **Assertion count is now seventeen.** `usage-rules/testing.md` and
  `docs/guides/building-an-exchange-package.md` updated; `usage-rules/adapter.md` gains a
  dedicated section next to assertion 16's.

  **Potentially breaking for any venue package declaring `credential_benefit: :required`
  whose fake does not already gate every credentialed endpoint on its `credentials`
  argument.** Of the five, this specifically means `dp_exchange_robinhood` (the venue
  this defect was found in) will exercise this assertion for real on its next Core bump;
  whether it still fails depends on whether that package's own fake fix has landed by
  then. The other four venues do not currently declare `credential_benefit: :required`
  (per this repo's own review of their `capabilities/0`), so this assertion is inert for
  them today and only bites if one of them adopts `:required` without also gating its
  fake.

### Changed

- **Assertion 17's gate widened from a fixed list of eleven callback names to every
  active endpoint on a `credential_benefit: :required` venue, minus a two-name
  exemption.** The assertion count does not change — this widens 17, it does not add a
  new one.

  The narrow gate (`@credentialed`, unchanged as a name — it still governs argument
  SHAPE for every assertion that builds call args, positional vs. `opts`) could only ever
  see a callback that takes credentials as its own first positional argument. A callback
  that reads a credential out of `opts` instead — `get_option_chain/2`, `get_news/1`,
  `get_corporate_events/1` and `quantization/1` are the ones a venue that signs every
  request actually uses this shape for — was invisible to it no matter how its fake
  answered with no credential. `dp_exchange_webull` and `dp_exchange_schwab` each found
  and hand-fixed exactly this defect in their own fakes on 2026-09-07, the same day
  assertion 17 first shipped, and both said the durable fix belonged here — this closes
  that blind spot rather than leaving it as a documented limitation.

  **The rule now enforced**: `:required` means every active endpoint needs a credential,
  so the assertion checks all of them — `Venue.behaviour_info(:callbacks)` minus
  `child_spec/1` and `start_link/1` (excluded via the same `answerable?/1` this suite
  already uses elsewhere; calling `start_link` on even a fake risks starting a real
  process, which no assertion here should ever do) minus `@credential_gate_exempt`,
  which names exactly two: `test_connection/2` and `get_rate_limit_status/2`. Both are
  exempt for the same, unchanged reason — their own callback doc types the credential
  `credentials() | nil`, a statement from the CONTRACT itself, not a venue's
  implementation choice, that a missing credential is expected there, because both mean
  "can I reach the venue at all" rather than "give me this venue's data". Every callback
  that can answer `{:ok, _}` at all is now checked; a callback whose return type can
  never match that pattern (`capabilities/0`, `coverage/1`, `subscribe/2` and the rest of
  the streaming surface, which return a bare map or `:ok`/`{:error, _}` rather than a
  `result()` tuple) passes trivially by construction, which costs nothing and needed no
  separate exclusion.

  **Stripping now actually strips `opts`, not only the positional argument.** The
  previous version sent `[]` for every `:opts` position, credentialed shape or not — the
  same `[]` `endpoint_args/2` already sends for an ordinary call, so an opts-carried
  credential was never exercised at all, stripped or not, and a check built on it would
  have proven nothing. `stripped_arg_value(:opts)` now sends `[credentials: %{}]`, an
  EXPLICIT empty credential, so a venue whose facade reads
  `Keyword.get(opts, :credentials, %{})` is actually exercised with a value it has to
  branch on rather than a key its own code may never have read at all.

  **Verified against all five real venues**, each pointed at this Core checkout with a
  temporary `path:` dependency, `mix test` run, then reverted before anything was
  committed. Only the three venues declaring `credential_benefit: :required` can
  exercise this assertion at all:

    * `dp_exchange_schwab` (495 tests) — **0 failures.** Every newly-included endpoint,
      including `market_status/1` (which this venue's fake correctly gates on a
      credential, since the real venue's market-hours endpoint is itself authenticated),
      already refuses without one.
    * `dp_exchange_webull` (736 tests) — **1 new failure**: `{:market_status, 1}`
      answers `{:ok, :open}` unconditionally, because this venue is crypto-only and the
      real facade never calls out for it at all — `market_status/1`'s own contract doc
      says crypto venues answer `:open` always, so nothing about *this* endpoint reads
      `opts` or dials the venue, credentialed or not.
    * `dp_exchange_robinhood` (236 tests) — **1 new failure**, the identical shape:
      `{:market_status, 1}` answers `{:ok, :open}` unconditionally for the same
      crypto-only reason.

  `dp_exchange_coinbase` (`:higher_ceiling`) and `dp_exchange_gemini` (`:no_difference`)
  do not declare `:required`, so assertion 17 does not run for either and both pass
  unchanged (679 and 772 tests respectively, 0 failures) — confirming the widening
  touches only the `:required` path and nothing else in either package.

  **`market_status/1` on the two crypto venues is reported here as a finding, not fixed
  in this change.** Whether it belongs on a per-venue exemption list, or whether Webull's
  and Robinhood's `credential_benefit: :required` overstates a venue where at least one
  endpoint is genuinely credential-free by design, is a call for each venue's own
  maintainers — this package does not fix venue repos from inside a Core change, and an
  argued, NAMED exception belongs in that venue's own review, not folded silently into
  this assertion's exempt list on Core's say-so alone.

  **Breaking for `dp_exchange_webull` and `dp_exchange_robinhood` on their next Core
  bump**, until each resolves the `market_status/1` finding above. Not breaking for
  `dp_exchange_schwab`, `dp_exchange_coinbase` or `dp_exchange_gemini` — all three pass
  today exactly as they did before this change.

  `usage-rules/adapter.md`'s assertion 17 section rewritten to describe the widened rule
  and both exemptions by name.

- **The `market_status/1` finding left open by the widening above is resolved — not by
  adding it to `@credential_gate_exempt`.** `dp_exchange_schwab`'s real `market_status/1`
  calls an authenticated `/markets` endpoint and its fake correctly refuses without a
  credential; a name-based exemption (the same mechanism `test_connection/2` and
  `get_rate_limit_status/2` use) would have silenced that protection to accommodate two
  venues where the callback currently answers without ever touching one — the exact
  "decorative check" this suite exists to avoid.

  Added a second, narrower exemption instead, scoped to what `market_status/1`'s own
  callback doc actually claims ("crypto venues answer `:open`"): the credential gate now
  also skips this one callback when `@venue.asset_classes() == [:crypto]`. Crypto has no
  exchange-mandated trading session for a credential to gate, so the claim is true of the
  asset class, not fetched from the venue — a fact no credential can change. A venue
  serving anything else stays gated on `market_status/1` exactly as before.

  **Verified against the same three `:required` venues** that exercised the widening,
  pointed at this Core checkout with a temporary `path:` dependency, `mix test` run, then
  reverted before anything was committed:

    * `dp_exchange_schwab` — unaffected; `asset_classes/0` is not `[:crypto]`, so
      `market_status/1` is checked exactly as before, and its fake already passes.
    * `dp_exchange_robinhood` — now passes without any code change on its side: its
      `asset_classes/0` is `[:crypto]`, so the new exemption reaches its unconditional
      `{:ok, :open}` and the finding closes. Its own repo still records a stated reason
      for that answer, per its own review.
    * `dp_exchange_webull` — still fails, correctly: `asset_classes/0` is `[:crypto,
      :equity, :option, :future, :event_contract]`, not `[:crypto]`, so the new exemption
      does not reach it and `market_status/1` remains gated. Resolved in that package's
      own repo by declaring the endpoint `:unsupported` — its OpenAPI documents no
      market-status or trading-calendar call, and the one such endpoint Webull publishes
      anywhere belongs to a separate Broker API product this package cannot reach.

  A teeth test added to `contract_teeth_test.exs` pins both directions with fixture
  venues: a crypto-only `:required` venue answering `market_status/1` unconditionally
  must NOT be flagged, and the identical fixture serving one more asset class must be.

  `DpExchange.Core.Venue`'s `market_status/1` doc and `usage-rules/adapter.md`'s
  assertion 17 section both updated to state the resolution and its reasoning.

- **A second assertion 17 finding, this one a false positive that drove a wrong fix
  downstream: `dp_exchange_webull`'s `get_fees/2` legitimately answers `{:ok, _}` with
  credentials stripped, because it makes no venue call at all — it returns a flat
  crypto spread rate captured from the venue's own published pricing
  (`source: :published_rate`).** Neither exemption above covers it: it is not a
  `test_connection/2`-style reachability check (name-based), and it is not exempt by
  asset class (`market_status_crypto_exempt?/2`'s ground) — Webull is not crypto-only.
  Assertion 17's then-unqualified rule flagged it anyway, and a 2026-09-06 sweep on
  `dp_exchange_webull` "fixed" the finding by gating `get_fees/2` behind a credential
  it never used, reasoning that the real path "had never run through `Auth.headers/2`"
  — true, and the reason there was nothing to gate. That broke a real consumer who
  resolves venue fees to score candidate strategy genomes before any account is
  attached, no credential existing at that point by design: an assertion driving a
  wrong fix is worse than no assertion.

  **`Capabilities` gains `no_venue_contact`, a list of `{name, arity}` a venue declares
  when a specific active endpoint's real implementation never builds a request to the
  venue** — the same per-endpoint shape `endpoints` already uses, so it cannot rot into
  one more hand-maintained name list the way `@credentialed` did. `no_venue_contact?/2`
  reads it; assertion 17 now also skips an endpoint declared there. This is narrower
  than `credential_benefit`, which is a claim about the venue in general — declaring an
  endpoint here is a claim the venue package must be able to point at real code to back,
  and a wrong declaration defeats the same protection a wrong `credential_benefit`
  would. Full argument in `Capabilities`'s own moduledoc and `AdapterContract`'s "17.
  credential gate" comment.

  **Verified against all five venue packages**, each pointed at this Core checkout with
  a temporary `path:` dependency, `mix test` run, then reverted before anything was
  committed: `dp_exchange_coinbase`, `dp_exchange_gemini`, `dp_exchange_robinhood` and
  `dp_exchange_schwab` are unaffected (none declares `no_venue_contact` and assertion 17
  behaves exactly as before). `dp_exchange_webull` needs its own fix — `get_fees/2`
  ungated on both `Rest` and `Fake`, and `{:get_fees, 2}` added to its
  `no_venue_contact` declaration — landed in that package's own repo.

  Teeth tests added to `contract_teeth_test.exs` pinning both directions with fixture
  venues: a `:required` venue whose endpoint is declared in `no_venue_contact` and
  answers unconditionally must NOT be flagged, and the identical fixture with the
  endpoint undeclared must be.

- **`PollingFeed`'s own test suite no longer sleeps a guessed duration to synchronise on
  a timer-driven poll cycle.** Ten `Process.sleep/1` calls used purely as a wait-then-
  assert device are replaced with `assert_receive` on a message the module already sends
  (`on_notice`, which `delivering_nothing?/2` fires on the very first failed tick for
  every single-symbol fixture these tests use, or `on_refusal`) or a synchronous
  `PollingFeed.status/1` / `coverage/1` call issued right after the event under test —
  a `GenServer.call` cannot reply until every message queued ahead of it has been
  handled, so a reply is itself deterministic proof the feed processed the prior event
  (and did not crash doing it) rather than a bet that a fixed number of milliseconds was
  enough. Three `Process.sleep/1` calls are unchanged and were never a synchronisation
  device: two `Process.sleep(:infinity)` calls and one `Process.sleep(20)` are the
  simulated venue latency and hang under test, inside the `fetch` functions passed
  *into* `PollingFeed`, not a wait on its output. Verified with no new flakes across
  eight consecutive runs plus three additional seeds. No `wait_until`-style bounded-retry
  helper was needed in the end — every case had a real message or a synchronous call to
  wait on instead, which this suite's own preference (a real observable over polling for
  one) already ranks above a retry loop.

### Fixed

- **`Timeframe.nameable/0` was missing `1y`, the same way it was once missing `1w` and
  `1M`.** `dp_exchange_webull`'s stock, option and futures bars genuinely serve a yearly
  candle alongside the weekly and monthly ones (`Rest.get_stock_bars/5`, tested against
  the venue's own `timespan` enum), but `Capabilities.new/1` raised on `1y` the way it
  used to raise on `1w`/`1M` before those were added — the exact under-declaration this
  module's own moduledoc already records twice over. Webull carried
  `@core_unnameable_widths ~w(1y)`, subtracted from its `historical_timeframes`
  declaration with a comment naming this exact gap as a Core limitation rather than an
  under-declaration on its own part.

  `@unbucketable` is now `~w(1w 1M 1y)` — a year is not a fixed number of seconds any
  more than a month is, and `seconds/1`/`aligned?/2`/`boundary/2` treat it exactly as
  they already treat the other two: no boundary rule, never rejected as invalid.
  `known/0` is unaffected; only `nameable/0` (and therefore what `Capabilities.new/1`
  will accept in `historical_timeframes`) widens.

  **Additive, not breaking**: every existing valid `historical_timeframes` declaration
  remains valid, since `nameable/0` only grew. **Unblocks `dp_exchange_webull`**
  declaring its eleventh width — its `@core_unnameable_widths` workaround and the
  subtraction using it are removable once it takes this version.

- **`AdapterContract`'s assertion 12 ("an active endpoint does not answer
  :not_supported") only checked endpoints EXPLICITLY present in `capabilities().endpoints`
  — an endpoint never mentioned there at all slipped past it, even though
  `Capabilities`'s own moduledoc makes an absent entry active too ("anything not named in
  the map is `:experimental` — the only honest default").** `Capabilities.endpoints_at/2`
  iterates only the map's explicit entries by design (its own `@doc` says "every endpoint
  DECLARED at maturity"), so `Capabilities.endpoints_at(caps, :proven) ++
  Capabilities.endpoints_at(caps, :experimental)` — the set the assertion used to check —
  never contained an endpoint a venue simply never declared. A venue implementing a stub
  that returns `{:error, :not_supported}` for, say, `get_fx_rate/3`, while never entering
  `{:get_fx_rate, 3}` into `endpoints` at all, is under-declaring by silence rather than by
  a wrong value — and passed the exact check built to catch under-declaring, because that
  check only ever looked at what was explicitly written down. `core_endpoints/0`'s own
  "every core endpoint carries an explicit maturity" test closes this for the ~16 endpoints
  named there; it does not touch the other ~70 a venue is free to leave undeclared.

  Fixed by enumerating `Venue.behaviour_info(:callbacks)` and asking
  `Capabilities.active?/2` directly, rather than enumerating `endpoints_at/2`'s two lists.
  `active?/2` already applies the documented undeclared-is-experimental default, so this
  closes the gap without changing what "active" means — it changes what gets CHECKED
  against that meaning. `DpExchange.Core.ReferenceVenue` declares every single callback
  explicitly (see `endpoint_maturities/0`), so Core's own conformance run is unaffected;
  `Broken.SilentlyUnsupported` in `contract_teeth_test.exs` reproduces the gap and proves
  the fix closes it.

  **Potentially breaking for all five venue packages** (`dp_exchange_coinbase`,
  `dp_exchange_gemini`, `dp_exchange_robinhood`, `dp_exchange_schwab`,
  `dp_exchange_webull`): any of them relying on the documented undeclared-default for a
  peripheral endpoint while that endpoint's implementation genuinely answers
  `{:error, :not_supported}` will now fail this assertion in their own CI, where it
  previously passed silently. That failure is correct — it is exactly the under-declaring
  defect assertion 12 exists to catch — and the fix is to declare the endpoint
  `:unsupported` explicitly, not to weaken the check.

- **`PollingFeed`'s `:fetch_all` path crashed the whole feed process on a `{:refused, _}`
  return — the one outcome `fetch_all_and_publish/1`'s case statement did not match —
  instead of recording one refused symbol.** `dp_exchange_robinhood`'s `Feed` moduledoc
  documented this exact gap as the reason it stayed on per-symbol `:fetch` rather than
  adopt this venue's own documented repeatable-query bulk endpoint (`?symbol=BTC-USD&
  symbol=ETH-USD` in one signed request): "a `{:refused, _}` returned from `:fetch_all`
  does not match either clause `fetch_all_and_publish/1` handles and would crash this
  feed's process instead of recording one refused symbol." Verified by reproducing it: a
  `fetch_all` returning `{:refused, _}` raised `CaseClauseError` inside `handle_info`,
  taking the GenServer down.

  `t:PollingFeed.fetch_all/0` — previously undocumented as a type at all — now names a
  third outcome, `{:refused, refusals}` where `refusals :: [{symbol, reason}]`, the batch
  analogue of `fetch`'s own `{:refused, reason}`: each named symbol is reported once
  through `on_refusal`, exactly as the per-symbol path already does, instead of being
  retried forever as an ordinary `{:error, reason}` would be.

- **`PollingFeed`'s `:fetch_all` path could deliver `{:ok, []}` forever without ever
  tripping the "delivered NOTHING" escalation.** `record_success(state, false)` — the
  clause a zero-event bulk response routed through — was a silent no-op: it never called
  `delivering_nothing?/2`, so a bulk venue answering successfully with an empty result set
  every cycle (a bad credential filtered to nothing server-side, for one) produced no log
  line and no `on_notice`, the exact silent-failure shape this module's moduledoc names as
  the reason the escalation exists at all. `{:ok, []}` now routes through
  `record_failure/3` with reason `:empty_response`, so it is counted, logged and escalated
  the same as any other empty cycle. `record_success/2`'s now-unreachable `false` clause is
  removed; every remaining call site always delivered something, so it is `record_success/1`.

- **`HttpClient`'s retry backoff hardcoded `4 - attempts_left`, assuming the default
  `retry_attempts` of 3.** `retry_attempts` is a documented, caller-configurable option;
  configuring it to 4 or more starts `attempts_left` above 4, so `4 - attempts_left` goes
  negative on the very first retry and `Process.sleep/1` raises `FunctionClauseError` — in
  the CALLING process, uncaught, since this library does not supervise its callers. The
  same failure shape this module's moduledoc already records for `retry_attempts: nil`
  (`4 - nil` via Erlang term ordering), reachable here for a valid, in-range, documented
  integer instead. No existing test used `retry_attempts` above the default, so nothing
  caught it. Fixed by scaling the backoff from attempts actually made
  (`retry_attempts - attempts_left + 1`) rather than a constant tied to the default — always
  `>= 1` regardless of configuration, and numerically identical to the old formula's own
  output at the default of 3.

- **`Notice.new/3` validated `kind` against the closed vocabulary but never validated
  `severity`**, despite `severity` being documented as equally closed ("not a log level — a
  call to action"). `Notice.new(:link_down, :v, severity: :critical)` silently built a
  `%Notice{severity: :critical}` outside its own `t:Notice.severity/0` typespec. `severity`
  is now checked against `[:info, :warning, :error]`, raising `ArgumentError` the same way
  an unknown `kind` already did.

- **`Notice.new/3` read `:severity`, `:at` and `:details` with `Keyword.get/3`, which does
  not substitute its default for a PRESENT-and-`nil` value — the same trap
  `DpExchange.Core.Config.opt/3`, `PollingFeed` and `HttpClient` have each paid for
  separately.** A caller forwarding its own options (or computing a value and getting
  `nil` back in an edge case) could produce `severity: nil` (a struct violating its own
  typespec, previously unvalidated besides), `at: nil` (violating `@enforce_keys`' own
  non-nil promise, the same way a `Core.Types.*` decode bug does — see `Types.Validate`),
  or `details: nil` (raising "must be a map, got nil" for what is, from a forwarding
  caller's side, simply an unset optional field). All three now read through
  `DpExchange.Core.Config.opt/3`: an explicit `nil` falls back to the same default an
  absent key already used.

- **`Core.Types.Trade.new/1` accepted an explicit `broken: nil`, bypassing the struct's own
  documented default (`false`) and typespec (`boolean()`, never `boolean() | nil`).**
  `:broken` is deliberately not `@enforce_keys`'d — an omitted value should default to
  `false`, and that part worked — but `@enforce_keys` guards presence, not `nil` (see
  `Types.Validate`), so a PRESENT `broken: nil` (the shape a JSON decode produces from a
  venue field that came back `null`) reached the struct unchanged. `nil` and `false` are
  both falsy in a bare `if`, which is exactly why nothing had noticed; a `case` matching
  `true` and `false` with no third clause does not get that courtesy, and `:broken` is the
  field a phantom high or low rides in on. `new/1` now normalises an explicit `nil` to
  `false` — this type's own moduledoc already says `false` means "the venue said not
  broken **or said nothing**," so this is the documented policy applied consistently
  rather than a new judgement call.

- **`Core.Types.StakingBalance`'s `:by_provider` defaulted to `nil` via a bare `defstruct`
  entry, though its typespec is a bare map (`%{optional(String.t()) => Decimal.t()}`, never
  `| nil`) and its own moduledoc states "empty means the venue does not break the position
  down" — a promise only true if `%{}` is what a caller actually gets.** Both an omitted
  `:by_provider` and an explicit `by_provider: nil` produced `%StakingBalance{by_provider:
  nil}`, a value nothing downstream could safely `Map.get/2` or iterate the way the
  typespec promises. `defstruct` now defaults `by_provider: %{}`, and `new/1` normalises an
  explicit `nil` to `%{}` the same way, consistent with `Trade.broken`'s fix above.

- **`DpExchange.Core.Config.resolve_snapshot/3` hardcoded
  `Application.get_env(:dp_exchange_core, key, default)` regardless of what a caller
  passed, despite its own moduledoc claiming it falls back to application env "exactly as
  `get/3` does" — and `get/3` takes `app` as an argument.** A venue package snapshotting
  one of its OWN seams (`DpExchange.Core.Config.snapshot/1`, which is app-agnostic —
  process-scoped overrides are keyed only by `key`) and resolving it inside its own
  GenServer would have had this function consult **Core's** application
  env instead of its own, silently never finding a value its consumer configured no
  matter how it was set. Found with no live caller yet — every known consumer
  (`dp_exchange_schwab`'s poller) reapplies a snapshot with `put_override/2` in a loop
  rather than calling this — so the mismatch between the documented behaviour and the
  hardcoded app went unnoticed. Fixed before a first caller could inherit it.

  **Breaking, in signature only:** `resolve_snapshot/3` is now `resolve_snapshot/4`,
  taking `app` as its second argument (`resolve_snapshot(snapshot, app, key, default)`),
  matching `get(app, key, default)`'s own order. No known caller in any of the five venue
  packages uses this function today, so the practical impact is expected to be zero, but
  a positional call written against the old three-argument form will not compile against
  this version.

- **`Core.Instrument.new/1` built its struct with plain `struct!/2` rather than
  `Types.Validate.new!/3`, so an explicit `symbol: nil` — `@enforce_keys` guards presence,
  not `nil` — built an `%Instrument{symbol: nil}` violating its own `symbol: String.t()`
  typespec, the one field this whole type exists to attach base/quote/status/type to.**
  Every `Core.Types.*` struct already routes its `new/1` through `Validate.new!/3`;
  `Instrument` (outside the `Core.Types.*` namespace, but carrying the identical
  `@enforce_keys`-guards-presence-not-nil shape) did not. Fixed to match the family
  convention.

### Added

- **`Core.AdapterContract` gains assertion 16, "internal wiring" — every internal
  export must have a caller inside the package's own `lib/`, catching the family's
  single most-repeated defect: a mechanism built, documented, and never wired.** Six
  instances in one week, every one shipped green because a test called the function
  directly and coverage stayed high: `rate_limit_blocking` plumbed through
  `Core.HttpClient` but never set by the caller (`dp_exchange_robinhood` issue #16,
  `dp_exchange_webull` issue #23 — three separate option allowlists, a fix stopping at
  the first still passed every test asserting the keyword was present —
  `dp_exchange_coinbase` issue #26); `FrameSender`'s retry path in
  `dp_exchange_coinbase`, reported but never retried (issue #22); `dp_exchange_schwab`'s
  `subscribe_notices/1` facade, discarding `opts[:to]` instead of reaching `Feed`'s
  notice registry; `dp_exchange_schwab`'s `Auth.refresh/2`, zero call sites in `lib/`
  while `Socket` held a token good for 30 minutes and `websockex` reconnected with no
  delay of its own.

  `DpExchange.Core.UnwiredCheck` is the engine: it reads `:xref`'s real call graph
  (`E`, the same OTP tool assertion 7's purity check already reads `imports` chunks
  through), not a grep — a captured `&Mod.fun/1` and a literal `apply(Mod, :fun, args)`
  both count as real usage. Excludes, without a hand-maintained allowlist: the facade
  and fake (`@venue`/`@fake`, already bound for every other assertion), every behaviour
  a module declares (read from its own `:attributes` chunk and that behaviour's own
  `behaviour_info(:callbacks)` — `GenServer`, `WebSockex`, `Supervisor`,
  `DpExchange.Core.Venue`, or any other), `child_spec/1`, `child_spec/2` and
  `start_link/1` on every module regardless of declared behaviour, and every
  compiler-injected export. A default-argument function (`def f(a, b \\ x)`, which
  compiles to both `f/1` and `f/2`) is treated as one unit named at its highest arity,
  wired the moment either arity has a caller from outside the pair — found necessary by
  running this check against real code: `dp_exchange_schwab`'s pre-fix
  `Feed.subscribe/2` and `Auth.headers/1` were each the unused lower-arity half of a
  function whose higher arity every real caller already used explicitly, and reporting
  each arity independently would have flagged both as noise.

  Verified against the real defect: reconstructing `dp_exchange_schwab` at the commit
  before both fixes landed (`c2f19b9`, parent of `09b8d1f` and `bf2e241`), the check
  flags `Auth.refresh/2`, `Auth.needs_refresh?/2` and `Feed.subscribe_notices/2` by
  name, with file and line — the exact mechanisms issue #16/#22's family and the
  Schwab incidents left unwired. Run against all five venue packages as they stand
  today, every one currently has at least one real finding — mostly `def`-exposed
  getters over a module attribute that production code reads directly instead
  (harmless but genuinely dead), plus a few worth a closer look:
  `dp_exchange_webull`'s `MqttPacket.disconnect/0` and `MqttPacket.subscribe/2`, and
  `dp_exchange_schwab`'s `Auth.needs_refresh?/2` and `StreamerProtocol.logout/2` —
  `needs_refresh?/2` remains unwired even after `bf2e241`, which wired `refresh/2` but
  not the function that was supposed to decide when to call it. Fixes are tracked
  separately, per venue.

  Documented in `usage-rules/adapter.md` next to the `rate_limit_blocking` section it
  follows the same shape as.

- **`PollingFeed` gains `:on_notice` — a feed that knows it has delivered nothing now
  says so on a channel a consumer can act on, not only in a log line, per
  DpCryptoManagement's issue #21.** `PollingFeed` already detected this condition and
  named it in its own words — `Logger.warning("... has delivered NOTHING in 154
  consecutive attempts ...")` — and stopped there. Issue #21 was found only because a
  human went grepping logs for that literal sentence; issue #22 took days for the same
  reason on a different venue. A `Logger.warning` is not a signal a supervising process
  can subscribe to.

  `:on_notice` is an injected function, the same shape `:on_refusal` already is, called
  with a `%Core.Notice{kind: :coverage_change}` the instant the feed crosses INTO the
  delivering-nothing state, and a `severity: :info` recovery notice the instant it
  crosses back OUT — a consumer that learns a feed died and never learns it recovered is
  only half-served. `:coverage_change` was chosen over inventing a new kind: it is the
  same kind `dp_exchange_coinbase` uses for the sibling case (a channel subscribe that
  exhausted its retries without ever becoming delivery), and "subscribed intent not
  becoming delivery" is exactly what a feed delivering nothing is. It fires once per
  transition, never once per failed tick and never once per sweep while an outage
  continues — the existing "delivered NOTHING" log line still repeats every sweep by
  design, so a consumer wanting only that repetition still has it; the notice channel is
  additive, not a replacement. `details` carries the feed's `label`, the consecutive
  failure count, and the last error — never a credential or a raw payload;
  `Core.Notice.new/3` refuses credential-shaped keys outright and would raise if it
  carried one.

  Defaults to a no-op, so every existing caller of `PollingFeed.start_link/1` is
  unaffected. Wiring Robinhood's and Schwab's own feeds to fan this out to their
  `subscribe_notices/1` subscribers is a follow-up once this ships — Core has to publish
  first, since both packages depend on it from Hex.

- **`coverage_by_kind/1` — the Core half of splitting `coverage/1` by data kind, per
  DpCryptoManagement's issue #22.** `coverage/1` is correct and unchanged: it counts any
  payload for a symbol as delivering, a `Types.OrderBook` exactly as much as a
  `Types.Quote`. That is why Coinbase's `level2` channel delivering over 11,000 frames for
  406 symbols while `ticker` was dark for all but 5 still reported `coverage/1` as `:stream`
  for all 406 — truthfully, and uselessly, because "one kind dark, another healthy" and
  "everything healthy" produce the identical map. Verified by running it: `coverage after
  ONLY an OrderBook (no ticker quote): %{"XLM-USD" => :stream}`. See
  `docs/design/2026-09-05_coverage-by-data-kind.md` for the fuller account, including why
  the consumer's own two proposed fixes (`:subscribed_pending`, a `delivering/1`
  companion) would not have caught this: both split subscribed from delivering, and this
  defect was never about that axis.

  `@callback coverage_by_kind(keyword()) :: %{Capabilities.data_kind() => %{symbol() =>
  route()}}` reuses the existing `data_kind()` vocabulary rather than inventing a parallel
  one, and is added to `Venue.@optional_callbacks` **required to be optional**: a venue
  package depends on Core from Hex, so a required callback here would mean every venue
  instantly failing completeness the moment this version publishes — the exact cross-repo
  coupling that caused a premature-deploy incident once already and delayed the
  `:gfw`/`:gfm` wiring behind a Core release before that. `required_callbacks/0` is
  unchanged; `peripheral_endpoints/0` classifies it irreplaceable and not load-bearing.

  `AdapterContract` gains assertion group 15, asserted **only** when a venue exports the
  callback (`Code.ensure_loaded?/1` then `function_exported?/3` — the former is what stops
  the latter spuriously reporting `false` for a merely-unloaded module): the union of
  symbols across every kind must equal `coverage/1`'s own key set exactly, and every kind
  key must be one the same venue's own `capabilities().streamable` declares. An absent
  callback asserts nothing — a venue that has not adopted yet is not a failure, and the
  moduledoc says so in the `if` guard's own comment so nobody "fixes" it into a hard
  requirement later. `ReferenceVenue` deliberately does not implement it, so Core's own
  conformance run (`AdapterContractTest`) is the regression proof that the suite stays
  green against a non-adopting venue; three fixtures in `contract_teeth_test.exs` replicate
  the assertion's exact computation against a conforming fake and two deliberately broken
  ones (a union that drops a symbol, a kind not declared in `streamable`), the same pattern
  assertions 1, 4 and 12 already use in that file.

  The moduledoc's own group count was wrong before this landed — it said "Thirteen groups"
  while `assertions/0` already listed fourteen, a drift caught while adding the fifteenth.
  Corrected alongside every other place in this repo that names a callback or assertion
  count (`README.md`, `usage-rules.md`, `usage-rules/adapter.md`, `usage-rules/testing.md`,
  `usage-rules/feeds.md`, `docs/guides/building-an-exchange-package.md`) — 87 callbacks
  became 88, fourteen assertion groups became fifteen.

  `usage-rules/feeds.md` and `usage-rules.md` both document the failure this callback
  exists to make visible, not only the callback's shape — a consuming agent reading either
  now learns that `coverage/1` alone cannot distinguish a half-dead feed from a healthy
  one, which is the whole reason this shipped.

  Venue adoption (Coinbase, Gemini, Webull, Schwab, Robinhood) is tracked separately in
  the design doc's checklist and is not part of this change — Core ships first, by design.

- **`Types.OrderBookDelta` — the Core half of "packages pass streamed data on; they do not
  maintain books", per `docs/design/2026-09-06_stop-maintaining-books-in-packages.md`.**
  `Types.OrderBook` is a full, sorted snapshot and Core had no incremental type at all, so a
  venue streaming deltas had exactly one option: fold every one into a book it held itself
  and hand the whole thing back. `dp_exchange_coinbase`'s `Socket` did this — a full book per
  symbol, measured at ~22,800 bid and ~21,100 ask levels for `BTC-USD` on a consumer's live
  node, rebuilt on every `l2_data` frame, inside a socket process that was starving its own
  `:send_timeout` because it was never idle. That was market state duplicated in the one
  place that could least afford it, while the host receiving it was already streaming the
  same data into its own store.

  `OrderBookDelta` carries `symbol`, `levels`, the venue's own `timestamp`, its `sequence`
  where it publishes one (`nil` where it does not, exactly as `OrderBook`'s does) and
  `provider`, with a validating `new/1` built on `Types.Validate` like every other type in
  the directory. `levels` is `[{side, price, quantity}]` — `OrderBook.level/0`'s
  `{price, quantity}` pair with the changed side prepended — kept as one flat list in the
  venue's own order rather than split into per-side lists, because a single delta frame
  changes both sides in one venue-ordered message and splitting it would either drop that
  order or invent one never sent. **A `quantity` of zero means the level ceased to exist, not
  a price of zero — carried through unchanged, never resolved here**, exactly the meaning
  already documented at Coinbase's own `apply_book_row/2`.

  This does not reintroduce the incident that made `Socket` build a book in the first place —
  a caller reading one `l2_data` delta as though it were the whole book "would see a handful
  of prices and nothing else." The fix is the distinct type, not accumulated state: a caller
  cannot mistake an `%OrderBookDelta{}` for an `%OrderBook{}`, because the struct name says
  which one it is holding.

  **`:order_book` stays the right `data_kind()` for a delta stream — no new kind was added.**
  `coverage_by_kind/1` answers "which kind of data is arriving", not "in what shape"; a host
  asking whether book data is arriving does not care whether the next message is a snapshot
  or a delta, and the struct type itself is what already tells a caller which shape it holds.
  Adding a kind is not free — it is a closed vocabulary every venue declares against — and
  this distinction was never what `coverage_by_kind/1` was built to make.

  **Reconnect reconciliation is now the host's job, documented rather than left inferred**
  (`usage-rules/feeds.md`, new "An order book stream delivers deltas, not a maintained book"
  section): a package holding no book has nothing to wipe on reconnect, so the fact that
  deltas after one are not contiguous with deltas before it is now visible instead of
  silently absorbed. The existing `:link_down`/`:link_up` notices bracket where the gap
  falls, and `:sequence` on both types lets a host confirm contiguity — consistent with this
  family's existing rule that a notice is a prompt to re-read, never the record: the correct
  response to `:link_up` is to re-pull `get_order_book/2` and resume from there, not to keep
  applying deltas across a gap nothing can fill back in.

  **This is additive to Core** — nothing existing changes shape. It exists to *enable* a
  breaking change in `dp_exchange_coinbase`, tracked separately: that package will stop
  building and delivering a full `OrderBook` per delta and start passing `OrderBookDelta`
  straight through, once it depends on this version.

### Fixed

- **Six false claims in shipped documentation, corrected against the code.** Nothing tests
  prose, and all six were the same shape: a statement about the family that was true when it
  was written and rotted silently.
  - `usage-rules/testing.md` and `docs/guides/building-an-exchange-package.md` both said the
    conformance suite has **fifteen** assertion groups. It has had **sixteen** since
    assertion 16 ("internal wiring") landed, as `assertions/0` and `AdapterContract`'s own
    moduledoc already said. The identical drift is recorded once before, at fourteen.
  - `usage-rules/feeds.md`'s per-venue table had three of five `streamable` rows wrong:
    Coinbase is `[:quotes, :order_book]` (not `[:quotes]`), Webull is
    `[:quotes, :top_of_book, :trades]` (not `[:quotes]`), and Robinhood is `[:top_of_book]`
    — deliberately **not** `[:quotes]`, because that venue publishes no last-trade data to
    poll for.
  - `usage-rules/money-movement.md` showed Coinbase as a blank row. `transfer_internal/4`
    is live there, and so are `list_payment_methods/2` and `get_payment_method/3`; only
    withdrawal and everything around it is `:unsupported`. "Gemini is the only venue that
    moves money through its API" is now stated as what is actually true — the only one whose
    API moves funds **off** the venue.
  - `Capabilities`' `supports_order_preview` comment said only Schwab declares it. Coinbase
    and Webull declare it too.
  - `docs/guides/building-an-exchange-package.md` said no venue checked so far has a working
    sandbox. Gemini's does, and `usage-rules/environments.md` has said so, measured, since
    2026-08-28.
  - `docs/reference/core/negative-claims.md` said Core makes no claim about what a venue
    serves. Four of its shipped tables do exactly that, unchecked by any test; the audit
    section now names them as the place a venue fact goes wrong in Core.

- **The `nil`-vs-absent `Keyword.get` trap, closed as a class rather than one incident at a
  time (C1).** `polling_feed.ex`'s `:start_delay_ms` already carried a fix and an incident
  comment; the same trap was open at every other default-bearing option in `PollingFeed`,
  `HttpClient` and `DefaultRateLimiter` — reachable because every venue forwards its own
  `opts` unchanged by family convention, so a key the caller never set arrives as `key: nil`
  rather than absent, and `Keyword.get(opts, key, default)` only substitutes `default` for
  an ABSENT key. `interval_ms: nil` crashed `Process.send_after/3` and restarted the feed
  straight into the same crash; `on_refusal: nil` raised `BadFunctionError`; `symbols: nil`
  raised inside `MapSet.new/1`. **`HttpClient`'s `retry_attempts: nil` was worst**: Erlang
  term ordering sorts `nil` above every integer, so `nil > 1` is `true`, and a forwarded
  `nil` silently entered the retry branch and died computing `4 - nil` — an `ArithmeticError`
  raised directly in the *calling* venue process, which this library does not supervise.
  Fixed with one shared helper, `DpExchange.Core.Config.opt/3`, applied at every reachable
  site across the three modules (not only the four originally named) — a present-and-`nil`
  value is now treated the same as an absent one everywhere a default applies, and an
  explicit `false` is still honoured, because `opt/3` deliberately does not use `||`.

- **`PollingFeed` — a hung fetch wedged the entire feed, silently (C2).** `fetch`/`fetch_all`
  ran synchronously inside `handle_info` with no timeout boundary; `safely/1` caught a raise
  or an `exit`, not a call that simply never returns. Verified with a fetcher doing
  `Process.sleep(:infinity)`: `status/1` and `coverage/1` never answered, every symbol went
  dark, and nothing was logged — which defeats this module's own headline design, since its
  moduledoc exists specifically to make a silently-broken feed loud. Every fetch now runs
  inside a bounded, disposable `Task` (`bounded_fetch/2`, `Task.async` + `Task.yield` +
  `Task.shutdown`), and a hang past `:fetch_timeout_ms` becomes an ordinary fetch failure —
  retried next tick, counted toward `failures_since_ok`, escalated by the existing "delivered
  NOTHING" warning. The default timeout is derived from the poll interval and clamped
  between 30s and 60s: a floor above `HttpClient`'s own 30s per-request default, so a short
  interval cannot self-sabotage an entirely ordinary retrying HTTP call, and a ceiling so a
  venue polled once an hour cannot wedge this feed for an hour.

- **`DefaultRateLimiter` — `timeout: nil` silently disabled the wait ceiling (C3).**
  `acquire/3` read `:timeout` with a plain `Keyword.get/3`, so a forwarded
  `timeout: nil` — reachable from `HttpClient`, whose `limiter_opts/1` forwards `:timeout`
  verbatim — produced `wait_ms > nil`, which Erlang term ordering makes **always false**.
  "Fail closed after N ms" silently became "wait however long it takes". Verified live
  against an exhausted bucket. Covered by the same `DpExchange.Core.Config.opt/3` fix as
  C1, and asserted with its own regression test: an exhausted bucket with `timeout: nil`
  now refuses near-instantly (the refusal is decided on the server, before any sleep)
  rather than sleeping out a near-minute wait in the caller.

- **`HttpClient` under-recorded real venue usage (C4).** `record/3` — the call that fills
  the bucket `acquire/3` and `check/3` measure against — was only reached from the
  `{:ok, response}` branch of the request pipeline. A retried 5xx and a venue 429 both
  genuinely reached the wire and genuinely consumed the venue's quota, and neither was
  recorded — the same mechanism as the incident already recorded in this module's own
  moduledoc ("395 calls per 60s against a documented 300, while the budget panel read
  83/240"): the missing calls there were exactly the retried and rate-limited ones this
  closes. Every outcome of a request that actually reaches `make_http_request/5` — success,
  retry, 429, or a permanent 4xx — is now recorded exactly once, right after the request is
  made and before the result is inspected; a request refused by the limiter itself, before
  anything left the process, is still not recorded.

- **`Types.*` — `@enforce_keys` guarded presence, not `nil` (C5).** `%Candle{open: nil, high:
  ..., low: ..., close: ..., ...}` built without complaint despite `open`'s typespec
  declaring `Decimal.t()`, never `Decimal.t() | nil` — exactly what a JSON decode bug on a
  renamed venue key produces, and the failure only surfaced later, deep inside `Decimal`,
  far from where the bad data entered. Every `Types.*` module now exposes a validating
  `new/1`, built on a new shared helper, `DpExchange.Core.Types.Validate`, that checks every
  field named in the module's own `@enforce_keys` for `nil` as well as presence and raises
  `ArgumentError` naming the offending field. `Types.Order` is the one deliberate exception:
  its own moduledoc documents that six of its seven enforced keys legitimately admit `nil`
  ("the venue's word, or nothing"), so its `new/1` narrows the check to `:provider` alone,
  the one field that was never meant to be `nil`. Struct literals (`%Candle{...}`) are
  unchanged and remain valid for internal and test use; `new/1` is the path a venue's own
  decoder should prefer.

- **`CanonicalPair` trusted caller-supplied quote ordering (C6).** The moduledoc requires a
  venue's `quotes` list to be given longest-first; nothing enforced it, and the module's own
  round-trip invariant does not catch a misordering — concatenation round-trips
  byte-for-byte regardless of where the cut landed. Verified: `quotes: ["USD", "BUSD"]`
  mis-split `"ETHBUSD"` into `"ETHB-USD"`. `quotes` is now sorted by length, descending,
  inside `CanonicalPair` itself before any suffix match is attempted, so a caller cannot get
  the ordering wrong any more, whatever order it hands in.

### Added

- **`time_in_force` vocabulary extended with `:gfw` and `:gfm` — "good for week" and "good
  for month" (C7).** Real Robinhood values, confirmed in the vendor's own OpenAPI schema
  (both the order request and response schemas, enum `["gtc","gfd","gfw","gfm"]`), with no
  slot in this contract's vocabulary before now. Purely additive: existing venues declaring
  a subset of `supported_time_in_force` are unaffected. Robinhood could not use the new
  values until this shipped to Hex, so wiring `Robinhood.to_order/1` and `order_config/2`
  was sequenced as a follow-up rather than done in the same batch — the cross-repo atom
  coupling is what caused a prior premature-deploy incident. That follow-up has since
  landed: `dp_exchange_core` 0.1.45 published these atoms, and `dp_exchange_robinhood`
  now decodes all four vendor values and raised its dependency floor to `~> 0.1.45` so it
  cannot compile against a Core lacking them.

- **`DpExchange.Core.FakeInjection` — deterministic failure injection and a
  credential-free wiring mode for a venue's `Fake` — DpCryptoManagement's issue #14.**
  None of the four venue `Fake`s exposed a `configure/1`-shaped seam for exercising a
  consumer's own retry/circuit-breaker code, or a way to skip a `Fake`'s venue-faithful
  credential check to test pure dispatch/decode logic. Built on `Core.Config`'s existing
  process-scoped override machinery rather than a new mechanism — the exact `async: true`
  isolation guarantee every other seam in this family already has.

  Deterministic by design: outcomes are queued explicitly and popped in order, never a
  probability. Per-symbol targeting composes with whole-call injection — a
  symbol-specific queue is checked first, and a symbol-targeted failure can never affect
  a different symbol's call, matching this family's established rule that one bad symbol
  must not fail a whole batch. Function-level targeting was deliberately left out: the
  feature this replaces asked for one global knob, and no filed need asked for more.

  This ships the shared mechanism only; the four `Fake`s adopt it one at a time in their
  own packages, starting with Robinhood. See
  `docs/design/2026-09-04_webull-sharding-and-fake-injection.md` §3.6/§3.7.

- **The conformance suite now asserts coverage rather than accepting it as a claim** (O4).
  Three new assertions, and the one worth naming exists because the drift it hunts had just
  happened: a venue package declared six streamable kinds while its socket was written,
  tested and **never called by the facade**. Four of the six reached no subscriber by any
  route, and every test passed for a release — the socket's own tests exercise its callbacks
  directly, and nothing asked what a consumer receives.

  - **Every absence has a recorded cause.** An endpoint named in `venue_does_not_serve/0`
    must actually be declared `:unsupported`. The mislabel goes both ways and both are
    defects: a venue's own absence filed as a backlog item invents work that cannot be done,
    and a backlog item filed as the venue's absence hides a capability a consumer could have
    had. **Robinhood shipped four of the first kind and no test failed** — nothing fails when
    a comment is wrong.
  - **`streamable` names only kinds this contract has a word for.** A structural check cannot
    prove delivery, but it can refuse a vocabulary the contract does not define, which is
    where over-declaration usually starts.
  - **A streamed kind is not contradicted by its own package.** A kind declared streamable
    while the same package's `venue_does_not_serve/0` says the venue has no such data at all
    is a contradiction that cannot be true in either direction.

  All five venue packages pass the three today; they were run against each before this
  landed.

### Fixed

- **`Notice.reject_credentials!/1` could exhaust the VM's atom table from venue-derived
  input (C8).** It normalised every `details` key with `String.to_atom/1` before comparing
  it against the credential vocabulary. Atoms are never garbage collected and the atom
  table is finite; `details` maps are built by venue packages from venue-supplied content
  (a channel name, a raw payload key, a symbol) with nothing in the contract bounding their
  keys, so a venue varying that content could walk the table to exhaustion and kill the
  whole node — through a guard whose entire purpose is to make notices safe. Fixed by
  deriving a string set from `@credential_keys` once, at compile time, and comparing every
  incoming key as a downcased string; no atom is ever created from caller input. Same
  `DOS.BinToAtom` class `Core.FakeInjection` was already built to avoid. The raised error
  still names the offending keys exactly as before.

- **`PollingFeed` crashed when a caller forwarded `start_delay_ms: nil`.** Robinhood's and
  Schwab's own `Feed` wrappers both build this option with
  `Keyword.get(opts, :start_delay_ms)` and no default of their own — a present key with a
  `nil` value whenever their caller never set one. `Keyword.get/3`'s own default only
  substitutes for an ABSENT key, not a present-and-nil one, so `state.start_delay_ms` ended
  up `nil` and crashed in `Process.send_after/3`. Fixed at this layer with `|| @default`,
  so every venue's `Feed` is covered rather than each patching its own pass-through.

- **A stray zero-byte `lib/dp_exchange/x.new` was shipping in the tarball.** It arrived as a
  redirect artefact in `cf03c21` and had been published in every release since. Found by
  doing what `mix.exs`'s own comment block says to do — inspecting `mix hex.build` output
  before publishing — which is the same check that caught the 4.4 MB PLT. Nothing warns about
  either; the only defence is reading the file list.

### Documentation

- **Three new guides, and the first is the one this plan most needed.**
  `usage-rules/auth.md` states the split once, plainly — **storage is the host's, *use* is
  the package's** — and then does the thing nothing in the family did: **a per-venue table**.
  Schwab is three-legged OAuth with a one-time-use refresh token on a seven-day sliding
  window; Gemini is HMAC *or* OAuth, sharing a refresh URL with the host's own code exchange
  and separated only by `grant_type`; Coinbase and Robinhood are Ed25519; Webull has two
  token systems, one of which returns `200` with a token that does not work until a person
  enters an SMS code.

  A host integrating two venues implements two different things, and until now nothing said
  so. It also carries the **restart-versus-refresh** decision table: a host that does not
  know that distinction loses sessions silently and has no operator action available.

- **`usage-rules/money-movement.md`** — the group where a defect moves funds, and the only
  one that can never be tested here. Preconditions in order, with the reason each is not
  style advice: the network is required and never defaulted because funds sent to a chain the
  venue does not credit are gone; `memo_required: nil` means the venue did not say, not that
  no memo is needed; a retry without an idempotency key withdraws twice, which is why this
  family always sends one rather than waiting to be asked.

- **`usage-rules/environments.md`** — running live and demo in one supervision tree, resolved
  **per process** rather than per node. Records what each venue actually offers: Gemini's demo
  is a full exchange with test funds, Webull's UAT has REST and **no broker at all**, and the
  other three have nothing.

- **The four existing guides are rewritten around the surface that shipped.** `feeds.md` now
  covers four pushing venues and one polling behind the same facade; `symbols.md` covers
  venues whose symbol is not a pair, where the work is refusal rather than transformation;
  `testing.md` states which of the four tiers each capability group can actually reach, and
  which cannot be reached at all; `adapter.md` covers the options surface, the two-list split
  for absences, and the negative-claim audit as a required artefact.

- **`docs/reference/core/negative-claims.md`** — Core's negatives are about the contract and
  the ecosystem rather than a venue, and they are audited the same way. Every one holds. The
  packaging claim needed correcting: 7.5 MB of saved Schwab portal HTML sat in `docs/guides/`,
  which **is** in `files:`, and would have published inside a package whose whole premise is
  that it ships nothing venue-specific.

- **`README.md` states what the contract covers** — 87 callbacks by group — and indexes the
  seven guides. `AGENTS.md` points at them.

### Added

- **`place_orders/3`** — several orders in one request, which closes OQ8.

  **It is not `place_order/3` in a loop.** A batch is one request the venue accepts or
  rejects as a unit; N calls are N partial outcomes a caller has to reconcile, and the
  reconciliation is exactly what goes wrong when the third of five fails. A venue that
  publishes a batch endpoint gives a consumer an atomicity it cannot build from the
  single-order call, which is why this is a callback rather than a helper a consumer writes.

  **A partial batch is the shape to expect, not the exception.** Venues validate per order
  and return per order, so the result is a list the same length as the request — each entry
  either an order or the venue's refusal of that one. Collapsing it into a single ok-or-error
  is the failure this callback is documented against: a caller told "the batch failed" when
  four of five were placed has four positions it does not know about.

  Venues cap the size — Webull at 50 — and a request over the cap is refused by the venue
  rather than split by a package. Splitting turns one atomic request into several and quietly
  undoes the only reason to call it.

### Changed

- **`Types.Order`'s `:symbol` and `:id` now admit `nil`**, joining the four that already
  did.

  Robinhood acknowledges a cancel request without describing the order it cancelled: there
  is an id and nothing else. Inventing a symbol to satisfy a type would put a guess where
  the venue was silent, which is the one thing this type's enforced-but-nullable keys exist
  to prevent. The keys stay enforced so a constructor must decide; the types admit `nil` so
  the decision can be "the venue did not say".

- **`asset_classes/0`'s vocabulary widened** from `[:crypto, :equity]` to
  `[:crypto, :equity, :option, :future, :event_contract]`, and the conformance suite's
  known-classes assertion with it.

  The narrower list was not a decision about scope — it was the set of classes any package
  had reached so far, frozen into an assertion. The first package to serve option endpoints
  could not declare it without failing conformance, and **a class a venue serves but cannot
  declare is a class the host cannot route to.** `asset_classes/0` is a statement about a
  package today; the contract now says so where it is declared.

### Added

- **`place_orders/3`** — several orders in one request, which closes OQ8.

  **It is not `place_order/3` in a loop.** A batch is one request the venue accepts or
  rejects as a unit; N calls are N partial outcomes a caller has to reconcile, and the
  reconciliation is exactly what goes wrong when the third of five fails. A venue that
  publishes a batch endpoint gives a consumer an atomicity it cannot build from the
  single-order call, which is why this is a callback rather than a helper a consumer writes.

  **A partial batch is the shape to expect, not the exception.** Venues validate per order
  and return per order, so the result is a list the same length as the request — each entry
  either an order or the venue's refusal of that one. Collapsing it into a single ok-or-error
  is the failure this callback is documented against: a caller told "the batch failed" when
  four of five were placed has four positions it does not know about.

  Venues cap the size — Webull at 50 — and a request over the cap is refused by the venue
  rather than split by a package. Splitting turns one atomic request into several and quietly
  undoes the only reason to call it.

- **Three more account-and-funding callbacks**: `get_payment_method/3`,
  `get_notional_balances/3` and `list_custody_fees/2`.

  **`get_payment_method/3` exists because a listing is a snapshot.** A funding source's
  verification state changes without the account doing anything — a bank closes, a card
  expires, a venue suspends a rail. Picking the row out of an earlier
  `list_payment_methods/2` result reads a status that may have been true an hour ago, and
  moving fiat against it is the failure that produces.

  **`get_notional_balances/3` is not `get_balances/2` in another unit.** The quantity is the
  venue's ledger; the notional figure beside it is the venue's *valuation* of that quantity
  at a rate the venue chose and does not have to publish. Two venues will disagree about the
  notional value of the same holding and both be right about the balance. Rows stay the
  venue's own maps so the two numbers cannot be read as one — the valuation is the one that
  is only ever an estimate. Reconcile positions with `get_balances/2`; this is for reporting.

  **`list_custody_fees/2` explains a balance reduction with no trade behind it.** Custody
  fees are periodic and come straight out of the balance, so a consumer reconciling against
  fills alone finds a gap it cannot account for. An empty list means the venue charged
  nothing in the window asked for — it never means the venue does not charge. A venue with
  no custody product returns `{:error, :not_supported}`, which is what tells the two apart.

- **Six money-movement callbacks**: `list_payment_methods/2`, `add_payment_method/2`,
  `transfer_internal/4`, `request_approved_address/4`, `remove_approved_address/3` and
  `get_transactions/2`.

  **`transfer_internal/4` is not `withdraw/5`.** Nothing leaves the venue, no chain is
  involved and no address is required. Conflating them is dangerous **in both directions**:
  a caller reaching for `withdraw/5` for an internal move pays a network fee it did not need
  to, and one reaching for this expecting an external transfer sends nothing anywhere.

  **`request_approved_address/4` is the most consequential write in this contract** — an
  address on the allowlist is one funds can be sent to. It *requests* rather than grants:
  venues hold new entries under a time lock, and **a successful response is not permission
  to withdraw**. Removal is separate and generally immediate, which is the asymmetry to
  expect — a venue is slow to widen what funds may reach and quick to narrow it.

  **A payment method being listed does not mean it is usable**, and a newly added one is
  pending: venues verify a bank account out of band and the API call only starts that.
  `details` stays the venue's own shape, because bank details differ by country and a
  normalised struct would be wrong for every country but one.

  **`get_transactions/2` is wider than both `get_trade_history/2` and `get_transfers/2`** —
  fees, interest, dividends and adjustments alongside deposits and fills. Summing it is not
  a balance; `get_balances/2` is the authority and this is the explanation.


- **`list_networks/2` and `list_fee_promos/1`.**

  **`list_networks/2` is what `get_deposit_address/3` needs before it can be called.** That
  callback takes a network, and nothing else in the contract said which networks a venue
  accepts for an asset. **Guessing one produces an address on a chain the venue does not
  credit, and funds sent there are gone** — the single most expensive mistake available in
  this surface. It answers both directions, because venues publish both and they are
  different questions: which networks carry an asset, and which assets a network carries.

  Rows stay the venue's own maps. **Network naming is not standardised** — one venue's
  `ethereum` is another's `ERC20` — and normalising here would invent a vocabulary no venue
  accepts back.

  **`list_fee_promos/1` is not `get_fees/2`.** That returns the schedule applying to a
  credential; this is a public list of symbols where the venue charges something other than
  its published schedule. A caller computing cost from the schedule alone is wrong for
  exactly the symbols on this list.


- **`get_fx_rate/3` and `Types.FxRate`.** Gemini publishes `GET /v2/fxrate/{pair}/{ts}` and
  the family had no shape for it.

  **It is not a rate the venue trades at.** Gemini's own documentation says it *"does not
  offer foreign exchange services"* and that the endpoint is *"for historical reference
  only"*; the number comes from a third party the venue names. So `:source` and `:benchmark`
  are carried alongside the rate, and `:provider` — the venue relaying it — is a **separate
  field**. Collapsing them would make a Gemini-relayed BCB rate indistinguishable from one
  Gemini computed itself, and only the second would be the venue's own claim. **Two venues
  relaying the same pair at the same instant can legitimately disagree**, and a caller
  reconciling them needs to know it is comparing sources rather than finding a bug.

  `:as_of` is the instant asked for, echoed by the venue. A rate without it is a number with
  no time attached, which is not a rate.


- **`get_trades/2` — the public tape.** `Types.Trade` already existed and nothing could
  return it; two venues publish the tape and the family had no callback for it.

  **It is not `get_trade_history/2`**, which returns the credential's own fills. The tape is
  everyone's executions and has no order of yours behind it — answering one with the other
  hands a caller a filtered view of the market and calls it the market.

- **`Types.Trade` gains `:broken`, defaulting to `false`.** Exchanges bust erroneous prints,
  and **a broken trade did not stand**: its price is not a price the market traded at.
  Leaving one in a series puts a phantom high or low into every range, breakout and
  volatility figure built on it, and none of them will error. `get_trades/2` excludes them
  unless `opts[:include_broken]` says otherwise — hiding them entirely would conceal that
  the exchange made a correction.

  The moduledoc now also records what `:side` means: venues report **the taker's** side, so
  Gemini's `buy` means an ask was removed by an incoming buy order. A package mapping that
  to "the maker was selling" inverts every entry while every number stays real.

- **`get_auction_imbalance/2` and `get_volume_profile/3`, with `Types.AuctionImbalance` and
  `Types.VolumeProfile`.** Two equity-microstructure capabilities Webull publishes that the
  family had no facade or shape for.

  **An auction imbalance is not a quote or a book.** During an auction the continuous book
  stops being the price; what matters is how much can be matched, how much cannot, and
  where it would clear — three numbers a `Quote` has nowhere to put. A caller reading a
  continuous quote at 15:59 is reading a book that is not where the close will happen.
  `opts[:auction]` is required, because the opening and closing auctions are different
  auctions with different windows.

  **The imbalance side is carried as the venue sent it, unmapped.** Venues publish the
  direction as a code and the tables differ — Webull documents `imbalance_side` with the
  example `"2"` and does not say what 2 means. Guessing it backwards tells a caller there
  is unmatched buying when there is selling: wrong, entirely plausible, and at the one
  moment of the day with the most volume behind it.

  **A volume profile is not a candle with extra fields.** A candle's single volume number
  cannot say that of 1,000 shares 600 lifted the ask and 400 hit the bid, nor at which
  prices each happened, and neither type is derivable from the other. `:delta` is the
  venue's own figure and is **not** recomputed from the totals: a venue that classifies
  some prints as neither aggressive buy nor sell reports numbers that do not reconcile, and
  that gap is information about its classifier rather than a fault to paper over.

  **`get_auction_imbalance/2` returns a list**, newest first, because the venue publishes a
  *series*: the imbalance updates every few seconds through the auction window, and how it
  moved is the point. `opts[:history]` selects the published series where a venue serves
  the snapshot and the series separately — the same shape `get_orders/2` uses for resting
  versus closed orders. **A series entry may carry less than a snapshot**: Webull's NOII
  bars publish the three prices and the time and *not* the quantities or the side, which
  come back `nil` — the venue did not publish them there, rather than the imbalance being
  zero.


- **`:event_contract` in the instrument-type vocabulary.** Webull lists event contracts as a
  tradable instrument type and the vocabulary had no term for one, so a package serving them
  had to declare something untrue.

  **It is not an option and not a future.** There is no strike, no underlying to deliver,
  and the payoff is a step at 0 or 1 rather than a curve — declaring one as `:option` would
  hand a caller a Greeks-shaped hole where the instrument has no Greeks.

- **`convert/4` and `get_trade_volume/2` on `Venue`.** Two more Gemini endpoints with no
  facade.

  **`convert/4` is not a shorthand for `quote_conversion/4` plus `commit_conversion/2`,
  and the difference is who carries the price risk.** The two-step form shows a rate and
  holds it: the caller sees the number before anything moves. `convert/4` executes at
  whatever the venue's price is on arrival and the caller learns the rate from the result.
  A package cannot manufacture the first from the second — quoting a rate it computed
  itself and calling it held would be a promise the venue never made — so a venue declares
  each independently. Gemini's `/v1/wrap/{symbol}` is the one-step form.

  **`get_trade_volume/2` is the account's own volume, not the market's**, and not
  `get_trade_history/2` summed. The venue's aggregation is what its fee tiers are computed
  from; reproducing it means every fill over the reporting window — one request per symbol
  on a venue that requires one — and the result would still be this package's arithmetic
  rather than the venue's ledger. Where they disagree, the venue's decides what a caller
  is charged.

- **`cancel_all_orders/2` on `Venue`.** Gemini publishes two bulk cancels and the family had
  no facade for either.

  **`opts[:scope]` is required and has no default.** `:session` cancels what this
  credential's session opened; `:account` cancels everything the account has open,
  including orders placed by another key or by a person at the venue's own web interface.
  A default would make the wider, destructive reading the answer to a question nobody
  asked, and the narrower one would silently leave orders running. The caller states it.

  It is not `get_orders/2` plus `cancel_order/3` in a loop: that is N requests with N
  partial outcomes and cannot reach an order that appeared between the listing and the
  cancels.

  Returns `%{cancelled: [id], rejected: [id]}`. **A non-empty `rejected` is not a failed
  call** — the venue answered and some orders were already gone.

- **`preview_replace/4` and `close_position/3` on `Venue`.** Both are Coinbase endpoints
  the family had no facade for, and both are the kind that cannot be assembled from the
  calls that already exist.

  **`preview_replace/4` is not `preview_order/3` with an order id.** The venue prices an
  amendment against the resting order's own state, including whatever of it has already
  filled. A caller who asks what a fresh order would cost is asking a different question
  and getting a different number. Without it the choice is committing to an irreversible
  amendment blind, or cancel-then-place — which reopens the window `replace_order/4`
  exists to close.

  **`close_position/3` is not `get_positions/1` plus `place_order/3`.** The size a caller
  computes is the size as of the caller's last read; the venue's is the size now. On a
  position that moved in between, the caller's arithmetic leaves a residue or overshoots
  into a position the other way. Only the venue flattens to exactly zero, which is why it
  returns an `Order` — it *is* an order, placed on the caller's behalf with a side and size
  the caller never states.

  Both are peripheral, both record which of the two tests they fail, and every venue that
  does not serve them returns `not_supported()` as before.

### Changed





- **`Types.Order`'s `side`, `order_type`, `quantity` and `status` admit `nil` in the
  typespec.** They always could in practice — a venue sending a status this package does
  not recognise has produced `nil` since the beginning — and the typespec said otherwise,
  which meant dialyzer accepted the wrong thing and rejected the right one.

  Coinbase's `close_position/3` is where it surfaced: the venue never states the side of a
  closing order, and the type left no way to say so. The keys stay enforced, so a
  constructor must still decide; the types now allow that decision to be "the venue did not
  say".

- **BREAKING: `Core.Types.Quote` no longer carries `:bid` and `:ask`.** They are order book
  data — resting orders — and `Quote` is trade data. Every venue package in the family was
  filling them, and one read `price || ask` from a best-bid/ask endpoint, producing a quote
  whose `price` was a resting order. Every value was real; only the meaning was wrong.

  A caller wanting the top of the book calls `get_top_of_book/2`. A caller wanting what
  traded calls `get_price/2`. Neither can stand in for the other.

- `Core.Types.Quote`'s `:timestamp` guarantee is unchanged and now load-bearing: **the
  venue's own, used as-is**. Observation time lives on `TopOfBook.observed_at`, in a field
  that says what it is.

### Added
- **Options.** `Types.OptionContract` (identity only — no prices), `Types.OptionGreeks`
  (model output, with the theoretical value named `:model_price` because it is the field
  most easily mistaken for a price), `Types.OptionChain` (**two-dimensional**, expiry →
  strike → `{call, put}`, a one-sided strike keeping `nil` rather than a missing key), and
  `Types.OrderLeg`. Callbacks `get_option_chain/2`, `get_option_expirations/2`,
  `get_option_greeks/2`.

  A chain row carrying bid, ask, last, mark and theoretical value offers five plausible
  prices and no help choosing, so it is split three ways: identity here, book on
  `TopOfBook`, last trade on `Quote`. **`:multiplier` of `nil` does not mean 100.** A venue
  that cannot trade multi-leg must **refuse**, never decompose — a caller left holding one
  filled leg has naked risk it never chose.

- **BREAKING: `get_historical_prices/4` returns `[Types.Candle.t()]`**, not
  `[Types.Quote.t()]`. It declared quotes, and the venue packages returned **bare untyped
  maps** with their own key sets — so the declared type was false and nothing compared one
  venue's candles to another's.

  `Types.Candle` names its time field **`:opened_at`**, because venues disagree about
  whether a bar is stamped at its open or its close and the difference is one whole
  interval — a series joined across both conventions is misaligned by a day with every
  value correct. `coherent?/1` catches a malformed bar at the boundary. `:volume` is `nil`
  when unpublished, never `0`.

- **`Types.Order` gains `:time_in_force` and `:legs`.** `Capabilities.supported_time_in_force`
  declared what a venue accepts while the order type had no field for it, so a caller
  reading an order back could not tell an IOC that expired from a GTC still working.
- **Derivatives.** `Types.Funding` (settled `:amount` kept apart from `:estimated_amount` —
  a real response has them 40% apart) and `Types.ContractStats` (mark and index are separate
  prices, and neither is a traded price), with `get_funding/2` and `get_contract_stats/2`.
- **Conversions.** `Types.Conversion` plus `quote_conversion/4`, `commit_conversion/2` and
  `get_conversion/2` — the facade's only two-step write. `:expires_at` is the point:
  committing an expired quote can fill at the *current* rate, which looks like success.
  `expired?/2` returns `nil` when no expiry was stated — unknown, not valid.
- **Portfolios.** `Types.Portfolio` and `list_portfolios/1`. A portfolio is an **address**,
  not a value; balances, orders and positions are addressed with `portfolio: id` in `opts`
  rather than by adding a parameter to forty signatures.
- **Money movement, write side.** `Types.DepositAddress`, `Types.ApprovedAddress`,
  `Types.Withdrawal`, and `get_deposit_address/3`, `list_approved_addresses/1`,
  `estimate_withdrawal_fee/4`, `withdraw/5`.

  **`withdraw/5` is the only operation in this contract that cannot be undone.** The
  allow-list is first-class: `ApprovedAddress.usable?/2` returns `nil` for a pending address
  with no stated activation, because venues delay first use precisely so a stolen account
  cannot add an address and drain it. `DepositAddress.memo_required` is **tri-state** — a
  deposit missing a required memo is credited to nobody, so `nil` must never be defaulted to
  `false`. `:network` is enforced on both.
- **`Core.Types.Position`** and **`get_positions/1`** — exposure, distinct from a balance and
  not derivable from one. `:side` is explicit and `:quantity` always positive, because
  venues disagree about how to say "short" and a guessed sign convention yields a position
  that is exactly backwards while every number stays plausible. Realised and unrealised P&L
  are separate and never summed. **`:liquidation_price` of `nil` means the venue did not
  say, not that the position is safe.**
- **`data_kind` gains `:top_of_book`, `:candles` and `:positions`.** Measured against
  Gemini's AsyncAPI and Schwab's Streamer service list: all three are streamed by a venue in
  the family and had no kind. `:top_of_book` is deliberately not `:order_book` — venues
  stream them on separate channels because one carries a level and the other a book.
  `t:data_kind/0` records the full channel-to-kind mapping so it can be checked rather than
  trusted.
- **Custodial staking.** Six callbacks — `get_staking_rates/1`, `get_staking_balances/1`,
  `get_staking_rewards/1`, `get_staking_history/1`, `stake/3`, `unstake/3` — and a
  `has_staking` capability flag, which earlier notes recorded as shipped and which did not
  exist.

  **Custodial only.** A venue that returns an *unsigned transaction* for the caller to sign
  and broadcast is doing something else, and one venue publishes both. A caller believing it
  had staked when it holds an unsigned transaction nobody signed is the most expensive form
  of this family's recurring failure.

  Four types, shaped by the venues' published schemas:
  - `Types.StakingBalance` — keeps `staked`, `available_to_trade` and
    `available_for_withdrawal` **apart**; a real response has the whole position redeemable
    and none of it tradable. `by_provider` is carried, not summed: a redemption is addressed
    to a provider.
  - `Types.StakingRate` — percentages only, `rate_pct` and `apy_pct` both named. One venue
    publishes basis points, a simple percentage and an APY for the same position;
    `bps_to_pct/1` lives here so the 100× conversion is done once.
  - `Types.StakingReward` — carries its accrual period and the rate *at accrual*.
  - `Types.StakingTransaction` — carries the unbonding progression `amount` /
    `amount_paid_so_far` / `amount_remaining`. **`settled?/1` returns `nil` when the venue
    reports no progress** — unknown, not complete.
- **`Core.Types.TopOfBook`** — best bid and ask, with **no `price` field**. `bid_size` and
  `ask_size` are optional (`nil` means *not published*, never zero); `venue_time` is the
  venue's own or `nil`, since several BBO endpoints publish none; `observed_at` is required.
  `mid/1`, `spread/1` and `crossed?/1` are functions, not fields — a mid is derived, and a
  caller has to ask for it rather than find it sitting there looking like venue data.
- **`get_top_of_book/2`** on the `Venue` behaviour, registered in `peripheral_endpoints/0`.
- **Conformance assertion 14, "top of book is not a price"** — asserts the returned struct
  is a `TopOfBook`, that `observed_at` is set, that `venue_time` is the venue's or `nil`,
  and that `TopOfBook` has no `price` field and cannot grow one.

### Changed
- **`preview_order/3` and `replace_order/4` are now `Venue` callbacks**, and required
  rather than optional. §6.1's rule is that the facade is one fixed set, never extended
  per venue, and optionality is reserved for callbacks where requiring them would be pure
  ceremony. These two are not: whether a venue can preview an order, and whether it can
  amend one atomically, are things a consumer routes on — and `replace_order/4` is a claim
  about **risk**, since its absence means cancel-then-place, which opens a window in which
  no order is live.

  **Not a breaking change, because there is nothing to break yet.** No consumer implements
  this behaviour outside the family, and all five venue packages were updated in the same
  change. A venue that serves neither returns `Venue.not_supported()` and declares
  `supports_order_preview: false` / `supports_order_replace: false`. Once the host adopts
  these packages, adding a required callback *would* be breaking and would take the
  `0.2.0` seed §7.2 describes — that signal is deliberately not spent here.

### Added
- **Five capability fields and two facade callbacks**, closing every contract gap Schwab
  found. Each existed because a venue could not say something true about itself.
  - `ceiling` gained an optional **`:scope`** (`:credential | :account | :application`),
    and `:limit` became `non_neg_integer`. Both matter: a limiter keyed by credential
    **silently over-permits** a venue that counts per account, and a registration granted
    zero throughput is legal and is **not** `:unsupported` — the endpoint exists and the
    venue serves it; that application cannot use it, and the remedies differ.
  - **`supported_sessions`** — which trading session an order may name. `[]` is the
    continuous-market case and stays the default. `[:regular]` alone **raises**: it says
    nothing, and a consumer would build a session selector with one option.
  - **`supports_order_preview`**, **`supports_order_replace`**, **`supports_multi_leg_orders`**
    — all raise if claimed while `place_order/3` is `:unsupported`.
  - **`catalog_access`** (`:enumerable | :query_only`) — whether the catalogue can be
    listed at all. `:query_only` raises if `get_symbols/1` is `:unsupported`, because
    "searchable only" and "not served at all" are different facts.
  - **`preview_order/3`** and **`replace_order/4`** as **required** facade callbacks.
    Required rather than optional: the facade is one fixed set, and optionality is for
    ceremony. Both are peripheral, and `replace_order/4`'s reason states the risk —
    absence means cancel-then-place, which works and opens a window with no order live.
- **Four order types**: `:trailing_stop`, `:trailing_stop_limit`, `:market_on_close`,
  `:limit_on_close`. Real types Schwab accepts that Core had no word for, so a venue
  serving them had to under-declare — the safe direction, and still a lie.
- **Eight instrument types**: `:option`, `:future`, `:future_option`, `:index`,
  `:mutual_fund`, `:bond`, `:forex`, `:cash_equivalent`. `[:spot, :perp]` was the whole
  vocabulary while every venue was crypto; an option is not a spot instrument, so an
  equities broker declared `[:spot]` plus a comment saying that understated it. **A
  declaration that needs a comment to be true is what this struct exists to prevent.**
- Two conformance assertions: the order-shape claims must match what the facade answers,
  and `catalog_access` must match how `get_symbols/1` behaves without a query.

### Documentation

- **`usage-rules/adapter.md` never mentioned `DpExchange.Core.Config.opt/3`,
  `Types.<T>.new/1` or the `:gfw`/`:gfm` addition to `supported_time_in_force` — all
  three shipped in this same
  `[Unreleased]` section (C1, C5, C7 above), and a package author reading only the guide
  that ships in the Hex tarball would never learn any of them exist.** Fixed by adding: a
  "domain vocabularies are closed lists" section naming the full current
  `supported_order_types` and `supported_time_in_force` vocabularies, including `:gfw`/
  `:gfm` and why they were added; a "prefer `Types.<T>.new/1`" section carrying the same
  `@enforce_keys`-guards-presence-not-`nil` explanation the code's own moduledoc gives,
  plus the `Types.Order` exception; and a section on the forwarded-`opts`
  `nil`-vs-absent trap naming `DpExchange.Core.Config.opt/3` as the fix, next to the
  existing "opts is the
  venue's own vocabulary" discussion it extends. Found by auditing this package's own
  consumer docs the same way the family-wide sweep audited the other five packages'.

- **`README.md`'s family table said five of six packages were "not yet published."** All
  six are live on Hex — checked against Hex's package API 2026-09-05, every one of
  `dp_exchange_core`, `dp_exchange_coinbase`, `dp_exchange_gemini`, `dp_exchange_webull`,
  `dp_exchange_robinhood` and `dp_exchange_schwab` returns `200`. Corrected to "published,
  experimental," with a line stating that publication is not proof of maturity — read
  `capabilities/0` for that, not this table.

- **Two stale assertion-count claims.** `usage-rules/testing.md` said "Thirteen assertion
  groups"; `docs/guides/building-an-exchange-package.md` said "28 assertions." Neither
  matches `DpExchange.Core.AdapterContract.assertions/0`, the canonical list the suite's own
  moduledoc points readers to, which currently names 14 groups. Both corrected to cite that
  count and the function that defines it, rather than a number that drifts every time a
  group grows.

## [0.1.11] - 2026-08-31

### Fixed
- **The conformance suite refused `1w` and `1M` too.** `Capabilities.validate_history!/1`
  was fixed in 0.1.10 to check `Timeframe.nameable/0`, but `AdapterContract`'s assertion 2
  still checked `known/0` — so a venue serving weekly or monthly candles built its
  declaration successfully and then **failed Core's own conformance suite**. That is the
  worse of the two failures: the package looks correct right up until the suite it exists
  to satisfy rejects it. Second site of one defect; found running the suite against Schwab.

## [0.1.10] - 2026-08-31

### Added
- `Timeframe.nameable/0` and `Timeframe.nameable?/1` — the widths Core can read as a
  **label**, which is deliberately wider than `known/0`, the widths it can **bucket**.
  `1w` and `1M` are nameable and have no boundary rule, and never will: a weekly bar's
  start depends on which weekday the venue begins its week, and a month is not a fixed
  number of seconds.
- `max_leverage` accepts **`:per_account`** — a positive statement that the venue margins
  and the ceiling belongs to the account rather than to the venue. Reg-T forced it: a
  Schwab margin account carries five different buying powers that are not multiples of one
  another, and a cash account at the same venue carries none of them, so no scalar is true.
  `nil` with `supports_margin: true` still raises, because `nil` means "nobody said" — and
  the error now names `:per_account`, so a venue author discovers the option instead of
  inventing a number. Without it the only ways to ship were to declare
  `supports_margin: false`, which is false, or to invent a multiplier.

### Fixed
- `Capabilities` no longer refuses a venue that serves weekly or monthly candles.
  `validate_history!/1` checked `historical_timeframes` against `Timeframe.known()`,
  which is the set Core can *bucket* — so declaring `1w` raised, even though
  `Timeframe` already documents both as deliberately unbucketable and instructs callers
  to read "no boundary rule" as "cannot check" rather than "invalid". Core contradicted
  itself: `aligned?/2` tolerates an unmodelled width, `boundary/2` passes it through,
  and `Capabilities` rejected it outright. A venue serving a real weekly candle had two
  options, under-declare or not ship. It now checks `Timeframe.nameable/0`; a width Core
  cannot name at all, such as `3m`, is still refused. Found deriving Schwab's
  declaration.
- `Timeframe` now models `10m` (600 seconds). Its absence was **not** neutral:
  `aligned?/2` returns `true` for a width it cannot model — "no rule" must not read as
  "invalid" — so every 10-minute candle passed the authenticity check unexamined, and
  `boundary/2` was a no-op on it. Found deriving Schwab's declaration, where
  `/pricehistory` serves 1, 5, 10, 15 and 30-minute widths. Unlike `1w` and `1M`, which
  are deliberately absent because their boundaries are not fixed, 600 seconds is not
  ambiguous and there was no reason to leave it unmodelled.

## [0.1.9] - 2026-08-28

### Fixed
- `HttpClient.request/5`'s spec no longer advertises `{:error, :rate_limited,
  retry_after: seconds}`. **It never returned it.** Both rate-limit paths convert to a
  two-element error before returning, each deliberately and for a recorded reason — a
  venue 429 because a three-element tuple reaching a two-element `case` crashed 152
  collector tasks in one night, and our own limiter's refusal because the two used to
  share wording and a self-inflicted throttle was read as a flaky venue for weeks. The
  spec was corrected rather than the behaviour. This is the fourth wrong-spec defect
  found by a venue package, and it does the same damage as the others: dialyzer reports
  a caller's correct handling of the advertised shape as unreachable dead code.

### Added
- `HttpClient` accepts `raw_status: true`, returning `{:ok, response}` for a 4xx instead
  of flattening status and body into a message string. The contract makes
  `{:refused, reason}` permanent and `{:error, reason}` possibly transient, and a venue
  states which in its 4xx body — Gemini names `InvalidSymbol`, `InvalidParameterValue`.
  Without this a venue package has to recover the distinction by string-matching, and
  `String.contains?(message, "404")` also matches a body that happens to contain "404".
  Opt-in, because the string form is what existing callers match on. 5xx is unaffected: a
  server error is not a venue's considered answer.
- `Capabilities` ceilings may now carry an optional `:burst` — the depth a venue lets a
  caller run ahead of its rate before queueing. Found by the Gemini extraction: a GCRA
  limiter takes three parameters and this type carried two, so a venue that **publishes**
  its burst depth had nowhere to declare it and the package had to hardcode the number
  beside the declaration — the exact drift the struct exists to prevent. Gemini is the
  first venue in the family to publish one ("a burst rate of five additional requests
  that are queued"). Optional rather than required, because a venue that publishes no
  burst must not be made to invent one, and absence is distinguishable from a declared
  value. A present `:burst` must be a positive integer; zero is a limiter that never
  lets anything through.
- Repo foundation: toolchain pin, `.gitignore`, formatter, credo, license, `mix.exs`,
  config layout, CI workflow, design-docs scaffolding.
