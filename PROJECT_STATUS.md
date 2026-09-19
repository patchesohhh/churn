# Churn — Project Status

*Last updated: 2026-09-19, pausing active development here.*

This document is the human-readable pause point: what exists, why it's built
the way it is, and what's next. `CLAUDE.md` is the companion document — it's
written for whoever (human or AI) resumes writing code, with the exact
schema/API surface and per-round implementation notes. This file is the
narrative version: read this first to get oriented, then `CLAUDE.md` when
you're actually about to touch code.

---

## What Churn is

An iOS app for a dual-income household that churns bank account signup
bonuses. The founder's own numbers: ~$7k earned in 2024, ~$4k projected for
2025, tracked by hand in a spreadsheet before this app existed.

**The vision shifted meaningfully during the build**, and that shift is the
most important thing to understand about the current codebase:

- **It started as a bank-account bonus tracker.** The original planning docs
  (`docs/project notes/`) describe an app organized around bank accounts:
  add an account, track its bonus, get reminded to close it.
- **It became a paycheck-routing app.** After the first working build, the
  user's own framing was: "the overall focus of this app should be routing
  money from the employer's Direct Deposit function to the proper bank
  accounts." Bonus-tracking didn't go away, but it's now downstream of the
  real object of interest — a paycheck, and where its money goes. Home
  accounts that never run a bonus (the checking/savings you already had
  before you ever started churning) are first-class, not an edge case.
- **The eventual "secret sauce" is automatic notifications.** Not a
  reminders app the user has to maintain — one that watches the data it
  already has (bonus requirements, direct deposit history, pay schedules)
  and tells you "your bonus requirements are done, close this account" or
  "you get paid in 5 days, have you updated your DD?" without being asked.
  A first pass of this exists; it's the area with the most obvious room to
  grow next.

---

## What's built (5 rounds of work, all merged to `main`)

**Foundation** — Core Data model (`Person`, `Account`, `Bank`, `Paycheck`,
`DirectDeposit`, `Reminder`, `Offer`), a persistence stack with seeded
preview data, and a `ChurnAppTests` unit test target. 134 tests, all green.

**Five tabs, all functional:**
- **Home** — earnings carousel (YTD/pending/all-time, native center-aligned
  looping carousel), active promotions, upcoming paychecks, a "Maintaining"
  section for accounts past their bonus, and the first-run "Add Paycheck"
  entry point.
- **Calendar** — a merged real + *projected* paycheck schedule. Real
  paychecks you've logged, plus generated future occurrences based on each
  person's pay cadence, so you can see where money is headed before you've
  logged anything. Projections stop routing to an account once its bonus
  has posted, and materializing a projected entry turns it into a real,
  editable paycheck. This view is explicitly a placeholder for the
  vertical Gantt-chart visualization from the original spec — not the
  final form.
- **Accounts** — full CRUD, filtering (status/owner/year) and sorting
  (date/reward/person), a progress bar toward the expected bonus date, and
  a reduced detail view for home accounts that aren't running a bonus.
- **Offers** — manual entry (no backend/API — by design, see below), with
  an "Open Account" button that pre-fills a new account from the offer.
- **Settings** — per-person pay profile (frequency, amount, next date), a
  household tax estimate, and soft-delete ("archive") for a person that
  preserves their history.

**Cross-cutting systems:**
- A `Bank` entity so eligibility checks ("when did I last get a bonus from
  this bank") are a real relationship lookup, not string-matching bank
  names — with a string fallback kept for anything not yet linked.
- `Paycheck` as a first-class entity: one income event, split across
  accounts via `DirectDeposit` rows, with an unallocated remainder that
  routes to a chosen home account (support for multiple home accounts —
  e.g. checking + savings at different banks).
- A shared per-tab navigation-reset system, so switching tabs and coming
  back always shows that tab's root instead of wherever you left off.
- `AutomaticNotificationService` — first pass, two triggers (close-this-
  account, update-your-DD-before-payday), self-rescheduling on every data
  change, no manual setup required. The pre-existing manual `Reminder`
  feature stays available alongside it.

---

## Decisions worth knowing the reasoning for

**Additive-only schema, almost always.** Every round after the first added
new entities/fields rather than changing existing ones, specifically so
each round's UI work (usually 4-6 parallel-built features) couldn't break
what the previous round already had working. The one deliberate exception
was a genuine bug fix (`AccountsListView`'s sort direction). This is why,
e.g., `Account.isChurnAccount` exists as a new flag rather than making
`bonusAmount` optional — the latter would have rippled into every view that
already reads it as non-optional.

**Soft deletes over hard deletes, consistently.** `Account.isArchived`,
`Reminder.isArchived`, `Person.isArchived` — none of these are ever really
removed from Core Data. This was explicit for `Person`: deleting your only
household earner must not take their paycheck history with them, and a
hard delete with cascading relationships would have. Archiving sidesteps
the whole problem and matches the pattern the codebase already had.

**No backend, ever, in this build.** All data — offers, banks, paychecks —
is user-entered and local-only. This was an explicit instruction, not a
shortcut: the original planning docs describe a future crowdsourced offer
database, and that's intentionally not started. `docs/project notes/potential
database structure.txt` describes that future backend schema; it is not
what the current `Offer`/`Bank` entities implement, and reading it as a
spec for current work would be a mistake.

**Multi-agent build process.** This was built by fanning out well-scoped,
file-disjoint tasks to parallel Claude subagents each round, with schema
changes going through a higher-effort pass (Opus) and UI work through a
faster one (Sonnet), and a human-equivalent integration/verification pass
after each round (real build + full test run, not just trusting agent
self-reports — this caught real issues, like a missing `import CoreData`
and a genuinely miscentered carousel). `CLAUDE.md` is what made this
tractable: every round's decisions and API surface got written there
*before* the next round's agents started, specifically so parallel agents
working on different features didn't need to coordinate directly with each
other.

---

## Known gaps / next steps

Roughly in the order they'd probably get picked up:

- **`SettingsView`'s person list doesn't filter archived people** — noted
  as low-priority during the `Person.isArchived` work and never circled
  back to. Every other picker (Accounts, Home, Calendar) does filter.
- **Automatic notifications are a first pass, not the full system.** Two
  triggers exist. Natural next ones: an offer expiring soon, a DD series
  about to complete (not just already complete), a paycheck that's overdue
  to be logged.
- **The Calendar projection's date math is approximate**, especially for
  semimonthly pay (a flat 15-day step stands in for actual semimonthly
  timing, which doesn't divide evenly). Fine for a rough forecast, not
  precise enough to trust for anything date-critical.
- **No CloudKit sync, no StoreKit paywall, no offer backend** — all
  explicitly out of scope for this build (see `CLAUDE.md`'s "Explicitly
  out of scope" section), not forgotten.
- **The Calendar tab is a placeholder for a vertical Gantt chart** — the
  original spec's visualization (colored bars per bank, visual connectors
  between consecutive DDs to the same account) was never attempted; the
  grouped-list-with-projections is a deliberately simpler stand-in.
- **Two of round 5's bug fixes (the paycheck-delete crash, the
  PersonSetupView race condition) were verified at the code/Core-Data
  level, not with a live interactive repro** — this environment has no
  `idb`/tap-automation tool and no XCUITest target, only unit tests.
  Worth an actual hands-on pass in Xcode before trusting those fully.
- **No real-device testing at all** — everything so far has run on the
  iOS 27 simulator only.

---

## Where things live

- `CLAUDE.md` — build conventions, full schema/API reference, and a
  round-by-round log of scope decisions and deviations. The primary
  reference for resuming implementation work.
- `docs/project notes/` — the original pre-build planning docs (market
  research, UI spec, architecture directive, database structure for a
  *future* backend). Historical context; several of these are superseded
  by decisions made during the build (particularly the "bank-first" framing
  and the backend database schema) — `CLAUDE.md` wins wherever they
  conflict.
- `ChurnApp/ChurnApp.xcodeproj` — open this in Xcode. Scheme `ChurnApp`,
  currently built/tested against the iOS 27 simulator (`iPhone 17 (27)`).
