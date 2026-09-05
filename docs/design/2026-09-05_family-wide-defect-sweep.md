# Family-wide defect sweep

**Status:** Implemented
**Date:** 2026-09-05

## Context

A six-package analysis sweep (one analyst per repo) run after issue #22 went quiet. Every
finding below was **independently re-verified** before being written down — against the
live venue, the vendor's own documentation, or by running the code. Findings that did not
survive that check are recorded in §4 rather than deleted, because a rejected finding is
evidence too.

The sweep was aimed at one defect class in particular, because it had already bitten twice
in one session:

> **A field name or enum value read from (or sent to) a venue that does not match the
> vendor's real schema.** It is invisible to the test suite, because the fixtures were
> written from the same wrong assumption as the code. Coinbase's `ticker["time"]` and
> Webull's lowercase `sub_types` were both this. The sweep found four more.

## 1. Objectives

- [x] Close every confirmed defect found by the sweep, across all six repos — **26 landed**
      (C1-C8, G1-G7, S1-S3, W1-W6, B1-B4, R1-R4), plus four found *during* the work that
      were not in the original sweep at all: the Gemini and Core atom-table exhaustion, the
      Schwab mutual-fund decode, and the family-wide inherited connect budget.
- [x] Add a regression test for each, written against the **vendor's documented shape**,
      never against the code's existing assumption
- [x] Leave each repo's quality gates green: `mix test` 0 failures, `mix quality` clean,
      coverage ≥ 90 — final sweep: 3,042 tests, 0 failures across the family; coverage
      93.75 / 91.04 / 90.31 / 90.90 / 90.94 / 94.69 (core / coinbase / gemini / webull /
      schwab / robinhood)
- [x] Push as ONE batch, only after every repo is complete and verified

## 2. Checklist

### Core — one defect here reaches all five venues

- [x] **C1. The `nil`-vs-absent `Keyword.get` trap, fixed comprehensively.** Fixed in
      exactly one place (`start_delay_ms`) and open in four more. Venues forward `opts`
      unchanged by convention, so `key: nil` is reachable for all of them.
      `interval_ms: nil` and `on_refusal: nil` crash the feed into a restart loop;
      `symbols: nil` fails at start; `HttpClient` `retry_attempts: nil` is worst —
      `nil > 1` is `true` in Erlang term ordering (verified), so it enters the retry
      branch and dies on `4 - nil`, killing the *calling* venue process. Fix with a single
      shared helper so this stops being fixed one incident at a time.
      **Found:** confirmed as described, plus further sites the original four did not
      name — `HttpClient`'s `timeout`, `log_requests`, `headers`, `retry_delay`,
      `raw_status`, `rate_limit_blocking` and `weight`, and `DefaultRateLimiter`'s `limits`
      and `limiter`. Fixed with one shared helper, `DpExchange.Core.Config.opt/3`
      (`Keyword.get/3` that treats a present `nil` the same as an absent key), applied at
      every reachable site across all three modules. Deliberately not `Keyword.get(opts,
      key) || default` — `||` is falsy on `false` too, and would have silently turned an
      explicit `log_requests: false` or `raw_status: false` back into its default, the same
      bug in the other direction.
- [x] **C2. `PollingFeed` — a hung fetch wedges the entire feed, silently.** `fetch` runs
      synchronously inside the GenServer callback with no timeout boundary. One hung HTTP
      call takes every symbol dark AND makes `status/1`/`coverage/1` unanswerable — which
      defeats the module's whole stated purpose (make a silently-broken feed loud).
      `safely/1` guards raises and exits, not a call that never returns.
      **Found:** confirmed exactly as described — a fetcher doing `Process.sleep(:infinity)`
      left `status/1` unanswerable. Fixed with `bounded_fetch/2`: every fetch now runs
      inside a `Task.async`, bounded by `Task.yield`/`Task.shutdown(task, :brutal_kill)`. The
      first default chosen (`:fetch_timeout_ms` tracking `interval_ms` outright, capped at
      60s) made the existing test suite flaky — a 50ms test interval gave a 50ms fetch
      timeout, tight enough that ordinary Task-spawn scheduling overhead under load
      occasionally tripped it on a fetch that was never hanging. Floored at 30s (matching
      `HttpClient`'s own default per-request timeout) so a fast interval cannot
      self-sabotage a legitimate, slower-than-a-tick HTTP round trip.
- [x] **C3. `DefaultRateLimiter` `timeout: nil` silently disables the wait ceiling.**
      `wait_ms > nil` is always `false`, so fail-closed-after-N-ms quietly becomes
      wait-forever. Reachable from `HttpClient`, which forwards `:timeout` verbatim.
      **Found:** confirmed live as described; covered by C1's `Config.opt/3` fix, with its
      own regression test asserting an exhausted bucket refuses near-instantly under
      `timeout: nil` rather than sleeping out the real wait in the caller.
- [x] **C4. `HttpClient` under-records real venue usage.** Only 2xx responses reach
      `record/3`. A retried 5xx and a 429 were both really sent and really consumed quota.
      Same mechanism as the documented "395 calls against a documented 300 while the panel
      read 83/240" incident.
      **Found:** confirmed as described. Fixed by moving `record/3` to run once per actual
      call to `make_http_request/5` — success, retry, 429, or a permanent 4xx — rather than
      only from the `{:ok, response}` branch; a request refused by our own limiter before it
      left the process is still not recorded, since nothing was put on the wire.
- [x] **C5. `Types.*` — `@enforce_keys` guards presence, not `nil`.** A `nil` in a
      required field is exactly what a decode bug produces, and the typespec says the field
      is non-nilable. Failure surfaces later, deep inside `Decimal`.
      **Found:** confirmed exactly as described (`%Candle{open: nil, ...}` builds). Fixed
      with a shared validating constructor, `DpExchange.Core.Types.Validate.new!/3`, and a
      `new/1` on every one of the 33 `Types.*` modules, checking each module's own
      `@enforce_keys` for `nil` as well as presence. `Types.Order` is the one deliberate
      exception — its moduledoc documents that six of its seven enforced keys legitimately
      admit `nil`, so its `new/1` narrows the check to `:provider` alone. Struct literals
      are untouched; `new/1` is the path a decoder should prefer.
- [x] **C6. `CanonicalPair` trusts caller-supplied quote ordering.** The moduledoc requires
      longest-first; nothing enforces it. A misordered list silently mis-splits and the
      simple round-trip invariant does NOT catch it. Sort internally.
      **Found:** confirmed live — `quotes: ["USD", "BUSD"]` mis-split `"ETHBUSD"` into
      `"ETHB-USD"`, exactly as described. Fixed by sorting `quotes` by length, descending,
      inside `CanonicalPair.to_canonical/2` before any suffix match, so caller ordering can
      no longer matter. The existing `Broken.SymbolFormat` contract-teeth fixture (built to
      demonstrate this exact bug) is now the regression test proving the fix: the same
      shortest-first mapping round-trips correctly.
- [x] **C7. Extend `time_in_force` vocabulary with `:gfw`/`:gfm`** — real Robinhood values
      with no slot today. Additive and backward compatible. Robinhood cannot use them until
      this ships, so that half is a follow-up (§3).
      **Found:** confirmed against the vendor's OpenAPI (`["gtc","gfd","gfw","gfm"]`).
      Added to `Capabilities`'s `@time_in_force` list; purely additive, no existing
      declaration is affected. Wiring `Robinhood.to_order/1` and `order_config/2` stays
      deferred per §3 until this ships to Hex.
- [x] **C8. `Notice.reject_credentials!/1` can exhaust the atom table — from venue-derived
      input, in the shared contract.** `key |> to_string() |> String.downcase() |>
      String.to_atom()` atomised every key of every notice's `details` map. Atoms are never
      garbage collected and the VM's atom table is finite (~1,048,576 by default) —
      exhausting it kills the whole BEAM node, not just one venue package. `details` is
      built by venue packages from venue-supplied content (Coinbase alone builds `details:
      %{channel: channel}` from a venue-sent channel name and `details: %{payload: ...}`
      from a raw venue payload), and nothing in the contract bounds what a venue keys a
      details map by — the same `DOS.BinToAtom` class `Core.FakeInjection` already designed
      around deliberately (one static override key, venue kept inside the map, specifically
      to avoid a per-venue dynamic atom).
      **Found:** confirmed as described; a guard whose entire purpose is to make notices
      SAFE was itself an unbounded-atom-creation path. Fixed by deriving
      `@credential_key_strings` — the string form of `@credential_keys`, computed once at
      compile time — and comparing every incoming key against that as a downcased string;
      no atom is ever created from caller input. `@credential_keys` stays the single source
      of truth. First attempt used a `MapSet` for the lookup; reverted to a plain list
      after Dialyzer failed the PLT check with a `call_without_opaque` mismatch against a
      `MapSet` literal embedded from a module attribute — twelve entries make a linear
      scan irrelevant next to that, and a plain list is what `@credential_keys` itself was
      already compared as before this fix. The raised error still names the offending keys
      exactly as before (proven by the expanded case-variant test below), so the guard's
      behaviour did not weaken.
      Checked `adapter_contract.ex:787` (`String.to_atom(dep) in declared`, in the "7.
      purity" conformance test) under the same lens: `dep` is a directory name lifted from
      `:code.which/1` on a module drawn from this package's own compiled `.beam` imports —
      developer-written source and `mix.lock`-fetched deps, never a venue payload — so the
      atoms it could ever mint were bounded by the package's own dependency tree, fixed
      before the test runs, and this was never the C8 shape of bug. Fixed anyway, not just
      commented: sobelow's `DOS.StringToAtom` flags the call shape regardless of
      confidence, and the coordinator's bar was "genuinely clean," not "clean except known
      ones" — so `declared` is now built as strings (`Atom.to_string/1` on each `mix.exs`
      dep, once) and the comparison dropped `String.to_atom/1` entirely rather than being
      asked to trust a comment next to a still-firing scanner. New tests in
      `notice_test.exs`: one proves 5,000 notices built with distinct, novel `details` keys
      grow `:erlang.system_info(:atom_count)` by fewer than 100 (would have been ~5,000
      under the old implementation); another proves the guard still raises for every key in
      `@credential_keys`, atom or string, in upper-case and mixed-case, closing the gap
      where only 6 of 12 keys and one case variant were previously exercised.

### Gemini

- [x] **G1. `get_staking_rates/1` has `asset` and `provider_id` swapped.** Re-verified live:
      `GET /v1/staking/rates` returns `{"<provider-uuid>": {"ETH": {...}, "SOL": {...}}}` —
      outer key is the provider, inner is the asset. Code assumes the reverse, so every
      `StakingRate` carries an upcased UUID as its `asset`. The vendor's OpenAPI says so
      too (`Provider UUID Keys` nesting `Currency Symbol Keys`).
      **Found:** confirmed exactly as re-verified. Fixed by keying `staking_rates/1` on the
      outer (provider) map first, inner (asset) map second — the reverse of what shipped.
      The fixture in `staking_test.exs` was keyed the same wrong way the code assumed,
      which is why the swap survived; rewritten to the captured live shape, plus a new test
      using the literal payload from this checklist entry.
- [x] **G2. Same function reads `depositLimitUsd`; the real field is `depositUsdLimit`.**
      Confirmed in the live payload. Always `nil` today.
      **Found:** confirmed; fixed alongside G1 since one live payload proved both. New test
      asserts `:deposit_limit_usd` against the real `depositUsdLimit` field.
- [x] **G3. `networks_for_asset/2` is documented "Public" and is not.** Live: `401
      MissingSecurityHeaders`. It sends no credentials and `Rest` has no way to.
      **Found:** confirmed. Fixed by removing the function from `Rest` (it can never
      succeed there — that module never signs anything, by design) and answering the asset
      direction from `Private.list_networks/2` via `signed_get/3`, the same helper the
      network direction already used correctly elsewhere in that module.
- [x] **G4. `list_networks` POSTs to a GET-only route.** Vendor documents `GET
      /v2/networks/{network}/assets`. `private.ex` has a correct `signed_get/3` helper that
      simply isn't used here. With G3 this means **both directions of network discovery are
      dead** — on the one call whose own docstring warns a wrong network means the funds
      are gone.
      **Found:** confirmed; the POST landed on a route the vendor does not serve. Fixed by
      switching the network→assets direction to `signed_get/3` alongside G3's fix, so both
      directions of `list_networks/2` are now authenticated GETs. New regression tests
      assert the request method and path for both directions.
- [x] **G5. No resubscribe after reconnect.** `handle_connect/2` only emits `:link_up`, and
      `Socket` holds no memory of what was subscribed. A drop leaves a healthy-looking
      socket delivering nothing. `Feed`'s `wanted` MapSet is written and never read.
      **Found:** confirmed by grep — `wanted` had no reader anywhere in the package. Fixed
      by adapting `dp_exchange_coinbase`'s approach: `Feed` now re-issues its `wanted` set
      on an unconditional 60-second timer rather than reacting to a detected reconnect
      (which a shared-process consumer may never observe happening).
- [x] **G6. `ensure_socket/1`'s synchronous `Socket.start_link/1` was never given a connect
      timeout budget chosen on purpose.** Found while landing G5, first recorded (wrongly)
      as "unbounded" and deferred to §3 pending a coordinator review of that premise.
      **Found:** the premise was wrong — the connect was already bounded, just by
      `websockex`'s own general-purpose defaults rather than a value this package chose.
      Measured from the vendored dependency: `WebSockex.Conn`'s
      `@socket_connect_timeout_default` is `6_000`ms and `@socket_recv_timeout_default` is
      `5_000`ms (`deps/websockex/lib/websockex/conn.ex:10-11`), both read from the `opts`
      `WebSockex.start_link/4` is given (`conn.ex:98-100`) — and `Socket.start_link/1`
      passed no opts at all, so it inherited them by accident. `Feed`/`SandboxFeed` are
      named, shared processes and this connect runs inside `handle_call`, so the real bug
      was that 6s + 5s of connect, plus one `send_frame` for the subscribe that follows (up
      to `@frame_window_ms`, 5s), is 16s against `Feed`'s own 15s `@call_timeout` — already
      over budget, wedging every other consumer's `subscribe/3`/`unsubscribe/2`/`coverage/1`
      behind it before any other overhead in that call is counted. Fixed by setting
      `:socket_connect_timeout` (3s) and `:socket_recv_timeout` (2s) explicitly in
      `Socket.start_link/1`, chosen against the same budget (3s + 2s + 5s = 10s, leaving 5s
      of `@call_timeout` headroom), both overridable through `opts` threaded from
      `Feed.start_link/1` through to `Socket.start_link/1`. No `async: true` needed — the
      earlier plan to use it, and the unverified change to `Socket.subscribe/3`'s
      immediate-failure semantics that would have required, is moot. A new
      `Socket.connect_opts/1` seam exposes the opts `start_link/1` builds so the budget and
      the override path are pinned by a test without opening a real connection.
- [x] **G7. `refusal/1` in both `Rest` and `Private` could exhaust the VM's atom table and
      kill the whole BEAM.** `String.to_atom(Macro.underscore(reason))` ran on `reason`
      straight out of the venue's JSON error body — venue- and attacker-controlled, not
      this package's. Atoms are never garbage collected and the table is finite (default
      ~1,048,576); a venue emitting an unbounded set of distinct reasons mints a permanent
      atom per value until the table is exhausted, and since these packages run *inside* a
      consumer's application, that takes the consumer's whole node down. `mix sobelow`
      (`DOS.StringToAtom`) had been reporting this the entire time and was waved through
      twice as a "pre-existing, unrelated, low-confidence warning" — none of those three,
      caught on review.
      **Found:** confirmed both call sites built an atom from unbounded venue text. Fixed
      by writing the recognised refusal vocabulary down at compile time (`@refusal_reasons`
      in `Rest`) and matching against it — the same discipline `Core.FakeInjection`
      documents for its own static override key. An unrecognised reason returns
      `{:unknown_reason, reason}` rather than minting an atom or collapsing to a bare
      `:refused`, since the list is deliberately incomplete (Gemini adds reasons without
      notice) and a caller needs the venue's own words to know what actually happened.
      `Private.refusal/1` now delegates to `Rest.refusal_reason/1` instead of carrying a
      second, independently-drifting copy of the same logic. On review the vocabulary map
      itself needed a correction: it had picked up three plausible-sounding entries
      (`RateLimit`, `EndpointNotFound`, `InsufficientFunds`) with no vendor documentation or
      live measurement behind any of them, while missing four codes Gemini's own
      documented error table actually lists (`MissingApikeyHeader`, `MissingPayloadHeader`,
      `MissingSignatureHeader`, `AmbiguousAuthentication`) — corrected to only the ten
      entries traceable to the vendor's table or a live measurement, none asserted from how
      a reason *sounds*. Regression test asserts `:erlang.system_info(:atom_count)` is
      unchanged across fifty novel reasons sent through `Rest`, plus one through `Private`
      proving the delegation runs the safe path end-to-end, because the old return value
      looked perfectly reasonable the entire time the bug was live.

### Schwab

- [x] **S1. `CHART_FUTURES` decodes under `CHART_EQUITY`'s numbering.** Re-verified in the
      vendor's own field tables: CHART_FUTURES field 1 is **Chart Time**, CHART_EQUITY
      field 1 is **Open Price**. `streamer_fields.ex` maps `"CHART_FUTURES" =>
      @chart_equity`, so a Unix-ms timestamp decodes as an open price and the real chart
      time is never found. Every futures candle fails, permanently and silently. Zero test
      coverage exercises a real CHART_FUTURES frame.

      **Found:** confirmed against the vendor's "2. CHART_FUTURES" table
      (`market-data-production.txt`, after line 2439): 0 key, 1 Chart Time (ms since
      epoch), 2 Open, 3 High, 4 Low, 5 Close, 6 Volume — no sequence, no chart day, unlike
      CHART_EQUITY's 0 key, 1 Open, 2 High, 3 Low, 4 Close, 5 Volume, 6 Sequence, 7 Chart
      Time. Added a separate `@chart_futures` map in `streamer_fields.ex` and repointed
      `@maps["CHART_FUTURES"]` at it — `to_candle/3` needed no change, since it already
      reads by atom key rather than by number. Regression: a field-map unit test
      (`streamer_test.exs`) asserting the exact vendor numbering, and an end-to-end
      decode test (`socket_test.exs`) that builds a real CHART_FUTURES frame from the
      vendor's field positions and asserts the decoded candle's open/high/low/close/volume
      and `opened_at` each match the value the vendor says that field carries. Both would
      fail against the pre-fix shared map. `dp_exchange_schwab`'s `mix test` (385, 0
      failures), `mix quality` and `mix test --cover` (90.99%) all green.
- [x] **S2. `capabilities/0` declares instrument types the code cannot route.** Declares
      `:future`, `:future_option`, `:index`, `:forex`, but `SymbolFormat.validate/1`
      rejects `/ESZ25`, `EUR/USD` and `$SPX` as "not an equity symbol" before any request
      is built. Contradicts the package's own `asset_classes/0` of `[:equity]`. This is a
      "declare what you measured" violation — either the declaration or the grammar is
      wrong, and the declaration is the one making a claim it cannot back.

      **Found:** the grammar was correct and the declaration was the false claim, exactly
      as filed. Narrowed `supported_instrument_types` to `[:spot, :option]` — the two
      shapes `SymbolFormat.validate/1` demonstrably accepts (a plain equity ticker, and a
      21-character fixed-width option symbol) and that `Rest.get_price/2`'s generic quote
      decode reads correctly for both. `:mutual_fund`, `:bond` and `:cash_equivalent` were
      dropped too, not because they were disproven but because nothing in the repo had
      ever checked them against `validate/1` or a live response — an unmeasured claim is
      the same violation in the other direction. `SymbolFormat.validate/1` was left
      untouched, per the deferral below. The stale test asserting `:future in types`
      (`capabilities_test.exs:211`) was corrected to assert the routable set against the
      real gate (`SymbolFormat.validate/1` refusing `/ESZ25`, `EUR/USD`, `$SPX`), not just
      against the declaration.

      Minor, folded in: `rest.ex`'s `get_symbol_quote/3` is the one REST function that
      skips `validate/1` and built its path with `URI.encode(native)`, whose default
      predicate leaves `/` unescaped — a `/`-bearing symbol produced a malformed
      double-slash path. Fixed by encoding with `URI.char_unreserved?/1` as the
      predicate, which escapes `/` correctly for a single path segment. Regression test
      captures the built request path for `/ESZ25` and asserts no double slash.

      **Re-examined** after S2a below closed the mutual-fund decode gap: `SymbolFormat.
      validate/1` accepts `SWPPX` and `SNSXX` (real Schwab index and money-market fund
      tickers — plain letters, spelled no differently from an equity ticker), and a
      Treasury CUSIP (`912828YY0`) is correctly refused (digits, outside `equity?/1`'s
      regex). So `:bond` stays a measured refusal, and `:mutual_fund`/`:cash_equivalent`
      moved from "never measured" to "measured routable" — added back.
      `supported_instrument_types` is now `[:spot, :option, :mutual_fund,
      :cash_equivalent]`. `capabilities_test.exs` gained tests asserting the CUSIP refusal
      and the two fund symbols' acceptance, and the full declared list against
      `Schwab.asset_classes/0`.
- [x] **S2a. A mutual fund's quote decoded as a venue error, for a payload the venue sent
      correctly.** Found while re-examining S2: `SymbolFormat.validate/1` already accepted
      mutual fund symbols, but `Rest.quoted_price/1` read only `row["lastPrice"] ||
      row["mark"]`, and the vendor's own `QuoteMutualFund` schema
      (`docs/reference/schwab/openapi/market-data-production.openapi.json`) has neither —
      nine fields only: `52WeekHigh`, `52WeekLow`, `closePrice`, `nAV`, `netChange`,
      `netPercentChange`, `securityStatus`, `totalVolume`, `tradeTime`. Every real mutual
      fund quote failed as `{:error, :unexpected_response_shape}` — the wrong-error twin
      of this family's usual defect: not a plausible wrong value, but a wrong verdict that
      sends the reader hunting a venue problem that does not exist.
      **Found:** confirmed against the committed OpenAPI schema exactly as described.
      Fixed by reading `nAV` (Net Asset Value) as the price when `lastPrice`/`mark` are
      absent — the price the fund actually transacts at, not a derived stand-in, so this
      is not the ask-for-a-price substitution the family forbids. `closePrice` (yesterday's
      NAV) is deliberately never read as a further fallback; absent `nAV` still fails
      closed exactly as the equity path does. `get_top_of_book/3` also built an all-`nil`
      `TopOfBook` for a mutual fund — `QuoteMutualFund` has no `bidPrice`/`askPrice`/
      `bidSize`/`askSize` keys at all — now refused with `{:error, :no_top_of_book}` when
      none of those keys are present, rather than nil-filling a book that does not exist.
      Regression tests in `rest_test.exs` build a `QuoteMutualFund` body from the vendor's
      field list, asserting the decoded price/volume/timestamp, the fail-closed behaviour
      with `nAV` absent, the `get_top_of_book/3` refusal, and that an equity's top of book
      is unaffected.
- [x] **S2b. A default-timeout `assert_receive` on cross-process delivery in `feed_test.
      exs`, flagged during the sweep's own gate re-runs.** `mix test --cover` showed one
      transient failure not reproduced on the next run; treated as a bug to root-cause
      per this family's own standard rather than dismissed. Root-caused by inspecting
      every `assert_receive` in the package: `test/dp_exchange/schwab/feed_test.exs` had
      six call sites doing `send(feed, msg)` to a real, live `Feed` GenServer and then
      `assert_receive` with ExUnit's default 100ms timeout, waiting on `Feed` to process
      `handle_info` and re-`send/2` to the test process — a genuine two-hop, cross-process
      wait, unlike this package's many same-process `assert_received` uses (built from a
      direct, synchronous call that already completed) which are not at risk. Under
      `--cover`'s instrumentation plus `async: true`'s 20-way concurrency, 100ms is tight
      enough to miss occasionally. Fixed by giving all six the same explicit 2,000ms
      budget the file's own bootstrap-path tests already used. Root-cause hunt: 30+ clean
      `mix test --cover` runs (seeds 1-30, 100-108, 200-230, plus a manual 12-way CPU-load
      run at host load average ~70) reproduced no failure of this shape before the fix —
      the only failure caught mid-hunt was a self-inflicted compile race from editing
      `capabilities.ex`/`capabilities_test.exs` while a background test loop shared the
      same `_build` directory, not a genuine timing bug, and is not evidence for or
      against this fix. A second clean 100-run batch (seeds 1000-1099) with no concurrent
      edits ran after the fix landed: 100/100 green (`391 tests, 0 failures` each run).
      `dp_exchange_schwab` final gates: `mix test` 391/0 failures, `mix quality` clean,
      `mix test --cover` 91.01%. Commit amended (`92afbdf`, not pushed) to fold S1/S2/
      S2a/S2b into one.

### Webull

- [x] **W1. `order_type`/`time_in_force` silently lost on round-trip.** Forward encoders
      cover all five order types and all five TIFs; reverse decoders cover 3 of 5 each.
      A caller placing or reading back a stop, trailing-stop, GTD or FOK order gets `nil`
      on a genuinely real order. `capabilities/0` declares all of them supported.
      **Found:** confirmed exactly as described — `order_type_atom/1` and `tif_atom/1`
      hand-listed 3 of 5 clauses each. Fixed by deriving the reverse maps
      (`@order_type_atoms`, `@tif_atoms`) from the same `@order_type_names`/`@tif_names`
      maps the forward encoders already used, so the two can no longer drift; a genuinely
      unknown venue value still falls through to `nil`. Exposed `order_type_name/1`,
      `tif_name/1`, `order_type_atom/1`, `tif_atom/1` publicly so `Fake.place_order/3`
      could be changed to round-trip through the real encode/decode path instead of
      echoing the caller's atom back unchanged (it previously could not have caught this
      class of bug at all). Regression tests: `order_mapping_test.exs` now asserts all
      five order types and all five TIFs decode correctly (previously only asserted 3 of
      5, and the "unknown" tests used values — `TRAILING_STOP`, `FOK` — that turned out to
      be two of the real missing ones rather than genuine unknowns); `fake_test.exs` adds
      equity `:stop`/`:trailing_stop` round-trip cases; `instrument_orders_test.exs`
      asserts the placed order's decoded fields, not just that a request was sent.
- [x] **W2. No fault isolation between a shard socket and the Feed.** `Socket.start_link/1`
      is called inside the Feed GenServer and links to it; Feed never traps exits. Any
      abnormal socket exit kills the whole Feed and every other shard's coverage — the
      opposite of the isolation the rest of the module works hard to provide.
      **Found:** confirmed — `init/1` had no `Process.flag(:trap_exit, true)`. Fixed by
      trapping exits and adding `handle_info({:EXIT, pid, reason}, state)`: a crashed
      shard socket is isolated (logged, a `:link_down` notice fanned out, any pending
      caller answered `{:error, {:shard_crashed, reason}}` rather than left to time out,
      the shard dropped and a reopen attempt sent to self at the same index with the same
      wanted symbols). A separate clause stops the Feed cleanly if its own task supervisor
      (added for W3) dies, rather than silently continuing without one. Regression test in
      `feed_test.exs` establishes a *real* link (via `:sys.replace_state/2` running
      `Process.link/1` inside the Feed process itself, so the crash is genuine, not
      simulated) and confirms the Feed survives, the other shard's bookkeeping is
      untouched, and a caller waiting on the crashed shard is answered promptly. While
      writing this test, an unrelated real shard-open attempt against the live venue with
      test credentials produced exactly this failure mode organically (a `WebSockex`
      frame error crashing the socket process) — confirming the isolation path fires on a
      real crash shape, not just a synthetic one.
- [x] **W3. Control-plane HTTP blocks the data-plane mailbox.** The unconditional 60s
      resubscribe makes up to 5 blocking HTTP round-trips **sequentially** inside one
      `handle_info`, stalling tick delivery for every shard once a minute by design.
      **Found:** confirmed at all four cited sites (`:337-367`, `:445-467`, `:509-530`,
      `:319-328` in the pre-fix file). Fixed by moving every `Subscription.subscribe/
      unsubscribe` call into a task under a `Task.Supervisor` the Feed now owns
      (`state.task_supervisor`, started in `init/1`); each call site spawns the task and
      returns immediately, and a new `handle_info({:reconcile_done, tag, result}, state)`
      family of clauses does what used to run inline once the real answer arrives. A
      caller's `subscribe/3` still does not get its `GenServer.call` reply until the real
      HTTP round trip finishes (`GenServer.reply/2`, deferred) — the observable contract
      is unchanged — but the mailbox is free to keep draining ticks while that round trip
      is in flight. The oversubscribed-retry loop that used to be `reshard/4`'s own
      recursion is now driven by the `:primary` reconcile-done clause re-invoking
      `reshard_step/4`, preserving the "retry without the caller ever seeing an
      intermediate refusal" property. Regression test in `feed_test.exs` holds a
      resubscribe's HTTP call open on a `receive` inside the stub plug and proves, via
      `Task.yield` with a bounded timeout, that a different shard's tick and a `coverage/1`
      call both complete while it is still blocked. Existing `assert_receive` timing in
      several pre-existing tests needed `test/test_helper.exs`'s
      `assert_receive_timeout` raised from the 100ms default to 1000ms, because a task
      hop off the mailbox is now genuinely part of the timing being asserted.
- [x] **W4. Shard chunking is unstable under insertion.** Sorting the whole wanted set and
      chunking means one new symbol that sorts first touches every shard, unsubscribing and
      resubscribing healthy unrelated symbols — contradicting the moduledoc's own "touch
      only what changed" claim and spending calls from the tightest budget in the family.
      **Found:** confirmed by hand-tracing `chunk_by_capacity/3` — it took no input beyond
      the freshly-sorted wanted set, so it had no way to prefer a symbol's existing shard.
      Replaced with sticky assignment (`derive_shards/3`, now taking `existing_shards`): a
      symbol already assigned keeps its shard as long as it is still wanted and still fits
      that shard's measured capacity; only genuinely new symbols, and anything just evicted
      by a capacity reduction, get placed into whichever shard (in index order) still has
      room. Regression test in `feed_test.exs` reproduces the exact shape from the
      moduledoc's simulation at small scale: two shards already full, add one symbol that
      sorts alphabetically before everything in them, assert (via a `flunk`-on-touch plug)
      that neither existing shard receives any HTTP call at all.
- [x] **W5. `endpoint-inventory.md` is stale.** It raises as open the question of whether
      the old `/openapi/...` paths still resolve. Live-probed: old paths are `404 Route Not
      Found` at the gateway, new paths reach the real backend. Code already migrated. Record
      the answer.
      **Found:** confirmed both halves independently — `documented_paths_test.exs` already
      guards that no source file calls an old path, and the live probe (unauthenticated,
      2026-09-05, `api.webull.com`) showed the exact asymmetry described: current paths
      answer from `server: WEBULL OPENAPI` with a `400` naming a missing signing header
      (reaches the real backend); old paths answer from `server: APISIX` with a `404
      Route Not Found` (never leave the gateway). Updated the doc's "paths this package
      calls" section to past tense with the probe evidence and its date, per "declare what
      you measured, not what you assume" — no code change, since the migration was already
      complete; the existing `documented_paths_test.exs` remains the regression guard for
      the code-level half of this claim.

### Coinbase

- [x] **B1. `get_top_of_book/2` can never work uncredentialed.** Hardcoded to
      `/best_bid_ask` with no public branch, unlike every sibling reader. Re-verified live:
      that path is `401`, and `/market/best_bid_ask` is `404` — there is no public form. The
      facade meanwhile claims "the same market data is served publicly." Fix the claim and
      fail clearly, rather than inventing a public path that does not exist.

      **Found:** confirmed — no public form exists, exactly as re-verified. Fixed in
      `dp-exchange-coinbase` by checking for credentials up front in
      `Rest.get_top_of_book/2` and returning `{:refused, :missing_credentials}` before any
      request goes out, rather than sending an unauthenticated request that would come
      back as an opaque `401`. Corrected the false claim in three places that all carried
      it: `DpExchange.Coinbase`'s moduledoc, the `capabilities/0` `credential_benefit`
      comment, and `usage-rules.md` (which ships inside the Hex tarball and is what a
      consuming agent reads — the design doc it was not mentioned in but carried the
      identical stale sentence). Regression tests in `rest_test.exs` and
      `order_book_test.exs` pin both the credential requirement (no request sent without
      one) and the exact requested path (`best_bid_ask`, never `/market/...`) — the prior
      only test used a canned-body plug stub that could never observe either.
- [x] **B2. `apply_book_row/2` silently drops malformed rows.** Every other decode failure
      in the module reports a `:data_quality` notice; this one returns the book unchanged
      with no signal, against the file's own stated discipline.

      **Found:** confirmed — `apply_book_row/2` returned the book unchanged on an
      unparseable `price_level` or `new_quantity` with no signal at all, unlike
      `deliver_ticker/3` and `deliver_book/3` in the same file. Fixed by threading `state`
      through into `apply_book_row/3` and reporting a `:data_quality` notice both for an
      unparseable price/quantity and for a row missing those keys entirely (the latter was
      an unreported gap in the same function, not called out in the original finding but
      the same discipline violation). The connection is still never torn down over one bad
      row. The existing test asserting the silent-drop behavior
      (`socket_test.exs`, "an unparseable price or quantity is dropped...") was the
      regression test candidate — it asserted the book stayed unchanged but never checked
      for a notice, so it passed against the buggy code; now it also asserts the
      `:data_quality` notice, and a second test covers the missing-keys case.
- [x] **B3. `endpoint-inventory.md` still lists `/best_bid_ask` and `/product_book` as not
      implemented.** Both are implemented and declared `:experimental`.

      **Found:** confirmed — the endpoint list carried no `✓` for either path and the
      Notes section still asserted both were absent, which is part of why B1's missing
      public/private branch went unnoticed for as long as it did. Corrected the endpoint
      list (`✓` added to `best_bid_ask`, `market/product_book` and `product_book`) and
      replaced the stale Notes paragraph with the newly measured B1 fact: `/best_bid_ask`
      has no public form (live-verified 2026-09-05, `401`/`404`), which is genuinely
      different from `/product_book`, whose `market/product_book` twin is real and public
      exactly like every other pair in the table.

- [x] **B4. `Socket.start_link/1` inherits WebSockex's connect/recv timeouts by
      accident, and they eat most of `Feed`'s own call budget.** No `:socket_connect_timeout`
      or `:socket_recv_timeout` is set, so WebSockex supplies its own defaults — measured
      in the vendored dependency, `deps/websockex/lib/websockex/conn.ex:10-11`:
      `@socket_connect_timeout_default 6000`, `@socket_recv_timeout_default 5000`. That
      matters specifically because `open_shard/5`'s synchronous branch calls
      `Socket.start_link/1` from **inside** `Feed`'s `handle_call/3`, and `Feed`'s own
      `@call_timeout` is `@frame_window_ms * 3` = `15_000` ms — a named, shared process,
      so every other consumer's `subscribe/2`/`unsubscribe/2`/`update_symbols/2`/
      `coverage/1` queues behind that one call. The inherited defaults alone
      (`6_000 + 5_000 = 11_000` ms) would burn roughly three-quarters of that budget on
      the TCP connect and the handshake recv alone, against an unreachable or
      black-holing venue, before a single subscribe frame is sent. The margin was never
      chosen; it was whatever the dependency happened to default to.

      **Found:** confirmed — the measured defaults and the arithmetic hold. Fixed by
      setting both explicitly in `Socket.start_link/1` at `3_000` ms each (`6_000` ms
      total), chosen deliberately against `Feed`'s `15_000` ms budget rather than
      inherited: that leaves roughly `9_000` ms of the same call for the socket to send
      at least one subscribe frame (capped at `Feed`'s own `5_000` ms
      `@frame_window_ms`) plus ordinary `GenServer` overhead. No failure semantics
      changed — `start_link/1` still returns `{:error, reason}` synchronously exactly as
      before, so the synchronous-primary-shard design (its outcome is the call's reply)
      is unchanged bit for bit; only the margin after a slow or absent venue changes. A
      caller passing either key in `opts` still overrides it (`Keyword.put_new/3`).
      The merge is factored into a small `@doc false` `connection_opts/1` — the exact
      keyword list `start_link/1` hands to `WebSockex.start_link/4` unchanged — so a
      regression test can pin the defaults and the override precedence without opening a
      real socket to observe them; five new tests in `socket_test.exs` cover both.

### Robinhood

- [x] **R1. `usage-rules.md` still documents the removed `get_price` and ask-fallback.**
      This file ships inside the Hex tarball and is what a consuming agent reads. It
      currently teaches the exact behaviour that caused issue #21. Highest-value fix here.
      `README.md` carries the same broken example.
      **Found:** confirmed as written — `usage-rules.md` said `subscribe/2` delivered
      `Quote` (it delivers `TopOfBook`), carried a `get_price/2` example that crashes
      against the current `{:error, :not_supported}` return, and a whole "The price is the
      ask" section describing the exact ask-fallback that caused issue #21 as if it were
      current behaviour. Rewrote both `usage-rules.md` and `README.md`'s example: `get_price/2`
      is now documented as unsupported with the incident named directly (so a future reader
      hits the explanation before re-filing #21), `get_top_of_book/2` documented as the real
      market-data call, and `subscribe/2` documented as delivering `TopOfBook` over the
      internal REST poll.
- [x] **R2. `usage-rules.md` claims a missing venue timestamp fails the call.** It does
      not, and per `TopOfBook`'s contract it should not — `venue_time: nil` is correct.
      Stale from the old `Quote`-based behaviour.
      **Found:** confirmed — the "Timestamps come from the venue, or the call fails"
      section was leftover prose from before the `Quote` → `TopOfBook` migration; the code
      (`Rest.top_of_book_time/1`) already swallows a missing/unparseable venue timestamp
      into `venue_time: nil` and never fails, which is what `test/dp_exchange/robinhood/rest_test.exs`
      already asserted. Replaced the section with an accurate one citing `TopOfBook`'s own
      contract. No code change.
- [x] **R3. `time_in_force` is a real vendor field claimed absent.** Confirmed in the
      vendor's own OpenAPI: the order request AND response schemas carry it, enum
      `["gtc","gfd","gfw","gfm"]`. `to_order/1` hardcodes `nil` with a comment asserting the
      venue publishes none, `order_config/2` never sets it, and `capabilities/0` leaves
      `supported_time_in_force` empty. Wire `gtc`/`gfd` now; `gfw`/`gfm` await C7.
      **Found:** confirmed. Wired `time_in_force` on `limit`, `stop_loss` and `stop_limit`
      order configs (the three the vendor's schema carries it on — `market_order_config`
      has no such field), both directions: `order_config/2` accepts `opts[:time_in_force]`
      of `:gtc` or `:day` (Core's existing atom for the venue's `gfd`, "good for day") and
      refuses `{:error, {:unsupported_time_in_force, tif}}` for anything else rather than
      silently dropping it; `to_order/1` decodes the venue's `gtc`/`gfd` back and decodes
      `gfw`/`gfm` to `nil` with a comment naming Core's not-yet-published `:gfw`/`:gfm`
      atoms as the reason (tracked below in §3). `capabilities/0` now declares
      `supported_time_in_force: [:gtc, :day]`. The `trading_test.exs` fixture that encoded
      the same wrong assumption as the code was rewritten to the vendor's real response
      shape (a `*_order_config` object carrying `time_in_force`), and five new regression
      tests were added — all five fail against the pre-fix code (verified) and pass after.
- [x] **R4. v2's own fee fields are discarded.** `fee_charged` and
      `estimated_fee_remaining` are real on `V2CryptoOrder` — the very data this package
      chose v2 to get — and `to_order/1` hardcodes `fee: nil`.
      **Found:** confirmed. `to_order/1` now decodes `fee: decimal(row["fee_charged"])`.
      `fee_currency` stays `nil` — the vendor's schema states no currency for
      `fee_charged`, and assuming the pair's quote asset would be this package's
      convention standing in for the venue's word, which is the exact substitution this
      family refuses. `estimated_fee_remaining` is a second real field on the same
      response with no slot on `Types.Order`; left undecoded with a comment saying why,
      rather than invented a place for it. Also addressed the attached minor: `get_accounts/2`
      reads only the first page of `V2AccountsResponse` despite it carrying the same
      `next`/`previous` cursors `get_symbols/2` walks — recorded as a deliberate decision
      in `Rest.get_accounts/2`'s own doc (one account per credential is this venue's common
      case) rather than silently left as an inconsistency, per the "record the decision
      explicitly" option offered; not walked, to avoid undischarged complexity against a
      case never observed.

## 3. Deliberately deferred

- **Robinhood `gfw`/`gfm`** — needs C7 published to Hex first. Cross-repo atom coupling
  mid-batch is what caused the premature-deploy incident; do it as a follow-up once Core's
  new version is out.
- **~~Schwab non-equity support~~ — NO LONGER DEFERRED, and the original reasoning was
  wrong.** This was filed as "a feature, not a defect fix". Checking it rather than
  accepting it found a real defect underneath: `SymbolFormat.validate/1` *accepts* mutual
  fund tickers (`SWPPX`, `SNSXX` — they are spelled like equities), so such a symbol reached
  the venue, got a perfectly valid `QuoteMutualFund` back, and was reported as
  `{:error, :unexpected_response_shape}` — blaming the venue for a response that was fine.
  `QuoteMutualFund` carries `nAV` and no `lastPrice`/`mark`, which `quoted_price/1` never
  read. Fixed (S2a/S2b), and `:mutual_fund`/`:cash_equivalent` are declared again now that
  they genuinely route end to end. `:bond` stays out as a *measured* refusal (a Treasury
  CUSIP is rejected by the grammar). Genuine futures/forex/index support remains real
  separate work — but that is now the only part of this that was ever a feature.
- **Coinbase `FrameSender`'s 5-second `send_frame` timeout, possibly raised.** Minor,
  adjacent finding during B1-B3: `frame_sender.ex`'s moduledoc claimed
  `WebSockex.send_frame/2` has "no way to override" its timeout, which was wrong — the
  vendored websockex 0.5.1 exposes `send_frame/3` with a timeout argument
  (`deps/websockex/lib/websockex.ex:463,469`). The factual claim was corrected in place;
  the timeout itself was deliberately left at 5s. That module's moduledoc records a real
  measured incident (a 39,804-byte opening frame, a 50-symbol batch, a self-reinforcing
  cascade that took a socket down and kept it down), and raising the timeout on the
  strength of "an override merely exists" without re-measuring against a batch anywhere
  near that size would be exactly the kind of untested confidence this family's incidents
  keep coming from. If a longer timeout is wanted, it needs its own measurement — how long
  a realistic snapshot burst actually takes to decode — before it is worth doing, and
  belongs in a design doc of its own rather than a drive-by inside a bug-fix batch.

## 4. Findings rejected on verification

- **Coinbase `Auth.jwt/2` claims are wrong** (`iss: "coinbase-cloud"`,
  `aud: ["retail_rest_api_proxy"]` vs current CDP docs and the official SDK). Rated
  high-severity by the analyst. **Refuted:** `level2` is in `@authenticated_channels` and
  goes through `Auth.jwt/2`, and DpCryptoManagement's issue #22 Test D delivered 363 real
  `OrderBook` messages on `level2` against the live venue on 2026-09-05. The JWT is accepted
  as built. Two authoritative-looking documentation sources disagreed with a live
  measurement, and the live measurement wins.

## 5. Retrospective

**26 planned defects closed, and four more found only by doing the work.** The four that
were not in the sweep are the interesting ones, because each was found by refusing to
accept a report at face value — including reports this document itself had written down.

### What the sweep was aimed at, and whether the aim was right

The sweep targeted one class: **a field name or enum value that does not match the vendor's
real schema, invisible because the fixtures encode the same wrong assumption as the code.**
That aim paid: S1 (`CHART_FUTURES` decoded under `CHART_EQUITY`'s numbering — every futures
candle dead, forever, with a green suite), G1/G2 (staking rates keyed provider-first, not
asset-first), R3 (`time_in_force` declared absent while the vendor's own request *and*
response schemas carry it), S2a (mutual fund quotes reported as venue errors). Four more
instances of a class that had already bitten twice. It is now the first thing to look for in
this family, not the last.

### The three findings that came from checking a finding

- **A "pre-existing, unrelated, low-confidence" sobelow warning was a way to kill the
  consumer's entire node.** `String.to_atom/1` on a venue's own error text, in two Gemini
  call sites and once more in Core's `Notice` — the guard whose entire purpose is to make
  notices safe. Waved through twice in one day under that framing before being checked.
  Atoms are never collected; the table is finite; these packages run inside someone else's
  application. **There is no "pre-existing" in a repo you are touching.**
- **A "transient flake that did not reproduce" was a real, deterministic bug** — six
  `assert_receive` calls using ExUnit's default 100ms for a genuine two-hop cross-process
  wait, which `--cover` instrumentation plus async concurrency occasionally exceeded.
  Root-caused and fixed only because it was refused as an explanation.
- **A "feature, not a defect" was a defect** — see §3's struck-through Schwab entry.

### Where this document was itself wrong

Worth recording, because a design doc that only lists other people's errors is not honest.

- The Gemini `@refusal_reasons` table, written by hand while fixing the atom bug, picked up
  three entries (`RateLimit`, `EndpointNotFound`, `InsufficientFunds`) chosen because they
  *sounded* like Gemini error codes, with no document and no measurement behind any of them
  — the exact unverified-plausible move this sweep exists to delete. Caught on review, and
  replaced with the four codes the vendor actually documents.
- The first regression test for that fix asserted on `:erlang.system_info(:atom_count)`,
  which is process-global in an `async: true` suite. It passed alone and failed in a full
  run: a flaky test written *while fixing a bug about not accepting flaky tests*.
- "The Gemini connect is unbounded" was wrong — it was bounded at ~11s by a dependency
  default nobody had chosen. The real finding was better than the reported one, and only
  visible by reading `deps/websockex/lib/websockex/conn.ex` instead of reasoning about it.
  That correction then generalised: **all four WebSocket venues** were inheriting the same
  accidental budget against their own 15s `@call_timeout`.

### The rejected finding matters as much as the accepted ones

§4 records a high-severity, confidently-argued claim — backed by current vendor
documentation *and* the official SDK — that Coinbase's JWT claims were wrong. It was
refuted by a live measurement from the consuming application hours earlier. **Two
authoritative documentation sources lost to one observation of the running system.** Had it
been "fixed", a working authenticated path would have been broken on paper evidence.

### For next time

- Ask what the *vendor's schema* says before asking what the code says. Fixtures are not
  evidence; they are the code's assumption wearing a costume.
- A dependency's default is a decision nobody made. Read it, then choose it.
- Every dismissal — "pre-existing", "unrelated", "flaky", "not a bug, a feature" — is a
  finding that has not been investigated yet. All four appeared in this batch. All four
  were wrong.
