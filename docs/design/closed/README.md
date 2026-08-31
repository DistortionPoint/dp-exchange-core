# Closed design documents

**Read-only history.** Everything here is a plan that reached `Implemented` — all
checklist items done *and* a retrospective appended — and was moved out of
`docs/design/` as the last step of its close.

## Why the move is part of closing, not tidying

A scan of `docs/design/` should show **only open work**: the queue of plans that still
need attention. A finished plan left there is indistinguishable from an unfinished one at
a glance, and the glance is what the directory is for. So the `git mv` is in the closing
routine (`../README.md`, "Closing a plan"), not a housekeeping afterthought.

Filenames keep their date prefix, which preserves chronology and keeps prior inbound links
working.

## Reading one of these

**A closed plan describes the world as it was.** Its bootstrap section, its "current
state" audit, its outstanding questions — all of it was true on the date in the filename
and may be false now. Where a section would mislead a reader who arrived without that
context, it carries an archive banner saying so rather than being trimmed: the original
text is the record, and the retrospective is measured against it.

**Start at the retrospective.** It is the last numbered section, it is written at close,
and it is the only part that describes what actually happened rather than what was
intended.

## What lives here

| Document | Closed | Outcome |
|---|---|---|
| `2026-08-26_exchange-adapter-package-family.md` | 2026-08-31 | Six packages published — `dp_exchange_core` plus five venues. 84/84 tasks. |

## What does not live here

- **Open plans** — `docs/design/`.
- **Idea docs** — `docs/design/ideas/`. No date prefix, and deleted when the work lands
  rather than archived. A closed plan may *feed* an idea doc; it does not move one here.
- **Anything still being worked on.** If a plan here turns out to have open work, it goes
  back to `docs/design/` and its status returns to `Implementing`. That has happened once,
  and the plan above records why: seven contract gaps were documented and deferred, and a
  recorded gap is not a completed task.
