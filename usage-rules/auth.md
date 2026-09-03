# Authentication: what the host does, what the package does

**Storage is the host's. *Use* is the package's.** That one line decides every question in
this guide, and it is worth stating in the form that is actually load-bearing:

> A venue package never obtains a credential, never stores one, never reads one from the
> environment, and never decides which scheme applies. It signs, refreshes, rotates and
> revokes — with credentials handed to it, per call.

The consent leg — a browser, a login page, a person choosing which accounts to share — is
**always** the host's. There is no headless path to it at any venue in this family, and a
library that pretended otherwise would be lying about something a user has to physically do.

Everything after that consent is machine-to-machine, and that half is the package's. A
package that only signed, and handed an expired token back twice an hour, would be unusable
for anything unattended.

## The five venues do not share an auth model

A host integrating two of them implements two different things. Nothing in the facade tells
it so, which is why this table exists.

| venue | scheme | what the host must do | what the package does | session lifetime |
|---|---|---|---|---|
| **Coinbase** | Ed25519 JWT (CDP) | provision an API key in the CDP portal; hold the key name and private key | mints a short-lived JWT per request, REST and socket alike | none — every request is signed fresh |
| **Robinhood** | Ed25519 detached signature | provision a key; hold the **base64 32-byte seed** | signs one request and keeps nothing | none |
| **Gemini** | **HMAC-SHA384 *or* OAuth 2.0 — the host names which** | provision an API key, *or* register an application and run the redirect flow | signs with the named scheme; refreshes and revokes an OAuth token it is handed | OAuth access token 24 h |
| **Webull** | HMAC-SHA1 app key/secret, plus **two token systems** | provision app credentials; verify an SMS code in the Webull app for a server-to-server token; run the consent redirect for Connect | signs; creates and checks server tokens; exchanges and refreshes Connect tokens | server token **15 days, recreate not renew**; Connect access and refresh tokens have **separate expiries** |
| **Schwab** | three-legged OAuth 2.0 | put a person in front of Schwab's login page and catch the redirect | signs; **refreshes** and persists the rotation | access token **30 min**, refresh token **7 days, sliding** |

Read the column that matters for your deployment, not the row that looks familiar.

## Gemini: the package will not guess the scheme

Gemini offers API-key and OAuth authentication and they are not two spellings of one thing.
`Auth.headers/5` takes the scheme as its **first argument** and refuses anything else.

That is not pedantry. Gemini's own error table lists:

> `AmbiguousAuthentication` — 400 — Both V1 API key headers and OAuth/V2 headers were
> supplied in the same request.

A module that inspected the credentials and helpfully attached whatever it recognised would
eventually attach both, and get a 400 that reads like a signing bug. Naming the scheme makes
that unrepresentable.

**The nonce is the host's decision too.** A Gemini key is provisioned in one of two nonce
validation modes and they need differently-shaped values — seconds for time-based, a
strictly increasing integer for incremental. The package cannot see which mode a key was
provisioned in.

## Schwab: the refresh token is one-time use

This is the single most important operational fact in the family, and getting it wrong is
**unrecoverable rather than inconvenient**.

Every successful `Auth.refresh/2` **spends** the refresh token it was given and returns a
new one with a fresh seven days on it. So there is no weekly ceiling on unattended
operation: refreshing every thirty minutes rolls the seven-day window forward every thirty
minutes, forever. The clock only runs out if the package stops refreshing for a week.

Three consequences the package enforces, and one it cannot:

- **A success without a `refresh_token` in the response is `{:error, :missing_rotated_refresh_token}`**,
  not a token to keep. The old one is already dead; carrying it forward hands you a
  credential guaranteed to fail days later, far from the cause.
- **A refresh is never retried.** It is at-most-once: a timeout may mean the token was spent
  server-side and the real replacement is sitting in a response nobody read. Retries are
  forced off and cannot be re-enabled through options.
- **`refresh/2` returns the whole credential** rather than mutating anything, because the
  result must be *persisted before it is used*.
- **What the package cannot enforce: you must actually write it down.** A host that refreshes
  and crashes before storing the response has lost that account until a person logs in again.

## When a refresh is not enough — restart the whole flow

A host that does not know this distinction will silently lose sessions and not know why.
Schwab publishes the decision table; it generalises to every OAuth venue here.

| situation | remedy |
|---|---|
| access token expired or lost | **refresh** — machine-to-machine, no person |
| refresh token expired (no refresh within its window) | **restart**: full three-legged consent |
| refresh token compromised | **restart**, and treat the old grant as revoked |
| the scopes or accounts you need changed | **restart** — a refresh cannot widen a grant |
| the user revoked access | **restart** — and nothing you do in code changes that |
| the user changed credentials or two-factor settings | **restart** |

Everything in the "restart" column needs a browser and a person. **That is host work**, and
a host with no path back to it has an account that will eventually go dark with no operator
action available.

## The package/host split cannot be read off a URL

Two venues make this vivid, and both would mislead anyone reasoning from paths:

- **Gemini** refreshes at `https://exchange.gemini.com/auth/token` — a *different host* from
  every other endpoint, with a form body rather than a signed payload. It is the same URL
  the host's initial code exchange posts to. **`grant_type` is the only thing separating the
  host's leg from the package's.**
- **Webull Connect** does the same thing at `POST /oauth2/tokens/create` on its own OAuth
  host: with `code` it is the host's exchange, with `refresh_token` it is the package's
  refresh. The package refuses a call carrying neither, locally, rather than sending
  something the venue would reject.

So: the split is about *who must be present*, not about which service answers.

## Two expiries are not one expiry

Webull Connect returns `expires_in` (the access token) **and** `rt_expires_in` (the refresh
token). They are different clocks, and the second is the one that ends the session. A host
tracking only the first will be surprised at the end of the refresh token's life, with no
warning from the access token it has been dutifully renewing.

Gemini's OAuth refresh likewise returns a **new refresh token, and the old one stops
working** — the same rotation Schwab does, at a venue where it is easier to miss.

## Webull: a token that succeeds and does not work

`create_token/2` returns `200` with a token whose `status` is **`PENDING`**. It is not
usable. Verification happens through an SMS code in the Webull app, which needs a person.

The status travels unmapped — `PENDING`, `NORMAL`, `INVALID`, `EXPIRED` — because "not
usable" covers three different problems with three different remedies, and a boolean would
erase which one you have. `check_token/3` is the call that tells them apart, and it is worth
making before trusting a stored token rather than after a request fails.

## Signing failures fail closed

Where a signature cannot be produced, no package here sends an unsigned `Authorization`
header. **An unsigned token is worse than none**: it looks like a credential problem at the
venue rather than in your configuration, and sends the reader looking in the wrong place.

Robinhood applies the same rule earlier still: a private key that is not a 32-byte seed is
refused locally with `{:invalid_private_key, {:expected_32_bytes, n}}`, rather than
producing a signature the venue rejects with nothing to explain it.

## What to hold, per venue

```elixir
# Coinbase — CDP key pair
%{api_key: "organizations/…/apiKeys/…", api_secret: "-----BEGIN EC PRIVATE KEY-----…"}

# Robinhood — base64 32-byte seed, NOT a 64-byte secret key
%{api_key: "rh-api-…", private_key: "…"}

# Gemini — one or the other, and you name which
%{api_key: "account-…", api_secret: "…"}        # scheme: :api_key
%{access_token: "…"}                            # scheme: :oauth

# Webull — app credentials, plus a token when the account has 2FA
%{app_key: "…", app_secret: "…", access_token: "…"}

# Schwab — the whole rotating credential, persisted after every refresh
%{access_token: "…", refresh_token: "…", expires_at: ~U[…], client_id: "…", client_secret: "…"}
```

Pass them per call, or to `child_spec/1` for a supervised feed. Nothing is read from the
environment, and nothing is cached across calls.
