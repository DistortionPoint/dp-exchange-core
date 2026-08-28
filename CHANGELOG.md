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
