# Schwab developer-portal capture (raw)

Saved browser pages from `developer.schwab.com`, added by the architect during the Schwab
extraction.

**These were moved here out of `docs/guides/` on 2026-08-31, and the reason is packaging.**
`mix.exs` ships `docs/guides` inside the Hex tarball, so leaving 7.6 MB of saved HTML, JS
and CSS there would have published it as part of `dp_exchange_core` — and Core ships no
venue-specific anything. That file's own comment block records the last time something
large went into the tarball unnoticed (a 4.4 MB PLT), which is why this was checked before
publishing rather than after.

`docs/reference/` is not in `files:`, so nothing here ships. The files are kept because they
are a raw capture that cost a login to obtain.

**The curated version lives in `dp_exchange_schwab`**, at
`docs/reference/schwab/` — both OpenAPI documents, both prose documents, the 17 User Guides
and `portal-product-landscape.md`. Prefer that; this is the unprocessed original.
