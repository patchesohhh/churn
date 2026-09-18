# Churn — iOS bank-bonus tracker — Project Instructions

Native SwiftUI + Core Data app for tracking cash bonuses from bank account
opening promotions ("churning"), including a dual-income household's direct
deposit scheduling. Solo indie project, MVP scope, no backend — **all data
is user-entered and stored locally in Core Data.** No API integration, no
CloudKit sync, no StoreKit paywall in this build — those are explicitly
deferred to a later phase.

Xcode project: `ChurnApp/ChurnApp.xcodeproj`, target `ChurnApp`.
Uses Xcode's modern **synchronized file groups**
(`PBXFileSystemSynchronizedRootGroup`) — any `.swift` file placed under
`ChurnApp/ChurnApp/` is automatically included in the app target. No
`project.pbxproj` edits needed to add files. A `ChurnAppTests` unit test
target already exists (added to `project.pbxproj` during foundation setup,
with a shared `ChurnApp` scheme) — test files go in `ChurnApp/ChurnAppTests/`
and are auto-included the same way; no further pbxproj edits needed.

Source docs live in `docs/project notes/` (originally `.rtf`, converted to
`.txt` — read the `.txt` versions). They describe an 8-week plan; this build
compresses to a 2-day MVP. When the docs conflict with this file, **this
file wins** — it reflects scope decisions made after the docs were written.

## Architecture

- **MVVM-ish, hybrid Core Data access** (see UI Summary doc for full
  rationale): views use `@FetchRequest` directly for lists. `ChurningStore`
  (`Store/ChurningStore.swift`) is a single `@Observable` object, injected
  once at app entry, that holds ONLY calculations shared across multiple
  views (YTD earnings, pending bonus total, all-time earnings, eligibility
  checks). It does not cache data, does not replace `@FetchRequest`, does
  not manage saves — views save to Core Data directly.
- **Low file coupling.** Structure code so a person (or agent) fixing one
  view only needs to open 2-3 files, not the whole codebase. Prefer a new
  small file over adding an unrelated responsibility to an existing one.
- **Reuse visual/UI elements liberally** — this is the one place where the
  low-coupling rule bends. Build a real component library
  (`Views/Components/`) and reuse it: custom buttons, cards, charts, badges,
  money-formatting text, empty states. Don't re-implement the same card
  layout three times across three feature folders.
- **Native elements over custom ones.** Use system components and modern
  materials wherever they fit: `.glassEffect()` / Liquid Glass containers,
  native `Button`, `Menu`, `Toggle`, `DatePicker`, `Form`, `List` with swipe
  actions, SF Symbols. Don't hand-roll a control iOS already ships.
- **No third-party dependencies.** Apple frameworks only (SwiftUI, Core
  Data, UserNotifications, Foundation).
- **No DTOs.** Nothing here talks to an API yet.

## Data model

Core Data entities (see `Models/ChurnDataModel.xcdatamodeld` once built):

- **Person** — one row per household earner (2 for this user: dual income).
  Pay structure, paycheck amount, next paycheck date, max concurrent DD
  accounts allowed by employer, default/home bank, a display color for UI
  differentiation. Added beyond the original docs — the docs referenced
  "Person 1/2 config" in Settings without ever defining the entity.
- **Account** — a bank account being churned: bank name, type, opening
  date, bonus amount/structure/requirements, min balance, expected/actual
  bonus date, status, close date, eligibility window (12/24 mo), notes.
  Belongs to a `Person`.
- **DirectDeposit** — one scheduled/posted paycheck allocation to an
  Account. Added beyond the original docs (flagged there as a likely-needed
  entity that was never defined) — required for Home's paycheck preview,
  the Calendar view, and per-account pay-date history.
- **Reminder** — check bonus / close account / update DD / meet
  requirement / custom. Belongs to an `Account`.
- **Offer** — a bank offer entered manually by the user (bank, bonus,
  requirements, expiration, favorite flag). Not backed by any bundled JSON
  or API in this build — pure user CRUD.

**Explicitly cut from the documented schema:** `TaxYear` (compute tax
estimate on the fly from Account data instead of caching it — one line of
math doesn't need its own entity). The rich backend `Offer`/marketplace
schema in `potential database structure.txt` is Phase 2+ and should not be
implemented now — if you're looking at that file for the `Offer` entity,
you're reading the wrong doc; use the simpler Core Data schema instead.

### Foundation is built — read this before writing any view or service code

`Models/ChurnDataModel.xcdatamodeld`, `Models/Entities/{Person,Account,
DirectDeposit,Reminder,Offer}.swift`, `Models/PersistenceController.swift`,
and `Models/Enums.swift` already exist. Use them as-is; don't redefine
entities or enums. A few deliberate deviations from the spec above — these
are the real API surface, not the aspirational one:

- **Soft-delete flag is `isArchived`, not `isDeleted`** on `Account` and
  `Reminder` — `NSManagedObject` already reserves `isDeleted`. Filter with
  `isArchived == NO`.
- **Money is `NSDecimalNumber`, not `Decimal`**, at the Core Data attribute
  level (Core Data doesn't support scalar `Decimal`). Don't touch the raw
  `NSDecimalNumber` properties directly — every entity has a typed
  `...Decimal: Decimal` computed accessor (e.g. `account.bonusAmountDecimal`,
  `person.paycheckAmountDecimal`) for get/set. Use those. Still no `Double`
  anywhere.
- **Enum-backed String attributes have typed accessors** — don't read/write
  the raw String columns directly. Use `person.payFrequencyValue`,
  `account.accountTypeValue` / `.bonusStructureValue` / `.accountStatusValue`,
  `deposit.statusValue`, `reminder.reminderTypeValue`.
- **To-many relationships have sorted array accessors** for `ForEach`:
  `person.accountsArray` / `.directDepositsArray`, `account.remindersArray`
  / `.directDepositsArray`, `offer.accountsArray`.
- Handy computed flags: `account.hasBonusPosted`, `reminder.isOverdue`,
  `offer.isExpired`.
- `Reminder.account` delete rule is **nullify** (not cascade as originally
  spec'd) — deleting a single reminder must not delete its account. The
  account→reminders cascade (delete account → its reminders go) is what's
  actually implemented and is the correct direction.
- `Offer.eligibilityRestrictionMonths` / `.monthsToMaintain` are `NSNumber?`
  — read via `?.int16Value` (0 is a meaningful distinct value from unset).
- **Codegen is manual**, not Xcode automatic — if you ever add an attribute
  to the `.xcdatamodeld`, you must add the matching `@NSManaged` property in
  `Models/Entities/` yourself.
- `PersistenceController.preview` is seeded via `SampleData.populate(in:)`
  (2 people, 4 accounts — one per status, 4 direct deposits, 3 reminders,
  2 offers) — reuse this in every `#Preview` and test rather than building
  ad hoc fixtures.

### Component library is built — reuse these, don't rebuild them

`Views/Components/` already has (all with `#Preview`s, all built on native
SwiftUI/materials):

- `MoneyText(amount: Decimal, size: .large|.medium|.small = .medium, color: Color? = nil)`
- `StatCard(label:amount:subtitle:valueColor:trend:)` (money) and
  `GenericStatCard(label:value:subtitle:valueColor:)` (non-money values)
- `SectionHeaderView(title:subtitle:actionTitle:action:)`
- `StatusBadge(status: AccountStatus)` and
  `GenericStatusBadge(text:color:systemImageName:)`
- `EmptyStateView(systemImageName:title:message:actionTitle:action:)` (built
  on native `ContentUnavailableView`)
- `AccountCard(account: Account, compact: Bool = false)` — use `compact: true`
  on Home, full style on the Accounts tab. **Don't build a second account
  card.**
- `PrimaryButtonStyle` via `.buttonStyle(.primary)` /
  `.buttonStyle(.primary(fullWidth:))` — only for CTAs `.borderedProminent`
  doesn't cover; use plain `.borderedProminent` otherwise.
- `AccountStatus.color: Color` now exists on the enum (added alongside
  `displayName`) — `Models/Enums.swift` now imports SwiftUI, not just
  Foundation.

**Any `#Preview`/view file that touches Core Data types (`.viewContext`,
`.fetch`, `Account`, etc.) needs an explicit `import CoreData`** alongside
`import SwiftUI` — this project has Swift's member-import-visibility
upcoming feature enabled, so the implicit re-export other projects rely on
doesn't happen here. This bit both the foundation and the component agent;
don't be the third.

## Testing — required, this is how progress gets verified without a human at the wheel

- Every non-trivial piece of logic (Core Data validation, `CalculationService`
  functions, view models if any) gets an XCTest. Tests must be runnable
  headlessly via:
  ```
  xcodebuild -project ChurnApp/ChurnApp.xcodeproj -scheme ChurnApp \
    -destination 'platform=iOS Simulator,name=iPhone 17 (27)' test
  ```
- Before marking any task done, run the build (`xcodebuild ... build`) and
  the test suite and confirm both are green. Don't hand off broken code.
- Use an in-memory `NSPersistentContainer` (`PersistenceController.preview`
  or a dedicated test helper) for all tests — never touch the real store.

## Previews — required on every view

Every SwiftUI `View` file gets one or more `#Preview` blocks using
realistic sample data (an in-memory Core Data context, not the live store),
so a human can open the file in Xcode and see/tweak it without running the
full app. Prefer multiple previews per view when there's meaningfully
different state to show (e.g. empty state vs. populated, light vs. dark).

## Code style

Optimize file layout for AI parsing/maintenance (predictable structure,
one primary type per file, clear section `// MARK:` comments) but be
generous with comments aimed at a human reader — explain *why*, not just
what, especially around Core Data relationship delete rules, calculation
logic, and anywhere this build deliberately diverges from the source docs.

## File structure (target)

```
ChurnApp/ChurnApp/
  MyApp.swift                  — app entry, injects PersistenceController + ChurningStore
  ContentView.swift            — root TabView (5 tabs)
  Models/
    ChurnDataModel.xcdatamodeld
    PersistenceController.swift
    Enums.swift                — AccountType, AccountStatus, BonusStructure,
                                  ReminderType, DirectDepositStatus, PayFrequency
  Store/
    ChurningStore.swift
  Services/
    CalculationService.swift   — pure functions, Foundation only
    NotificationService.swift
  Views/
    Home/
    Calendar/                  — flat/grouped list stub, NOT the full Gantt chart (out of scope)
    Accounts/
    Offers/
    Settings/
    Components/                — reusable: StatCard, MoneyText, SectionHeaderView,
                                  StatusBadge, EmptyStateView, button styles, etc.
ChurnAppTests/                 — XCTest target (create if missing)
```

## Round 2 changes (post-first-pass feedback) — read before touching Models/ or onboarding

The app's center of gravity shifted after the first pass: this is a
**paycheck-routing app first, bonus-tracker second.** The user's own words:
"the overall focus of this app should be routing money from the employer's
Direct Deposit function to the proper bank accounts." Concretely:

- **`Bank` entity** (new) — id, name, createdAt. Represents Chase/Wells
  Fargo/SoFi/etc. as a real row, not a free-text string, so "am I eligible
  for this offer based on my last bonus from this bank" is a real
  relationship lookup instead of fuzzy string matching.
  **Additive, not a replacement:** `Account.bankName: String` and
  `Offer.bankName: String` stay exactly as they are (everything built in
  round 1 reads them) — add `Account.bank: Bank?` and `Offer.bank: Bank?`
  (both nullify) alongside. A Bank picker component finds-or-creates a
  `Bank` row by case-insensitive name match and keeps `bankName` in sync
  when one is selected. `CalculationService.isEligible` should prefer
  `account.bank`-relationship matching when both accounts have a `Bank`
  set, falling back to the existing bankName string match for
  legacy/no-bank-set accounts — don't drop the fallback, don't require a
  migration.
- **`Account.isHomeAccount: Bool`** (new, default false) — the account(s)
  that persist as the "home base" everything else routes around. Multiple
  allowed (the user has checking + savings at two different banks) — don't
  add a single-home-account constraint.
- **`Paycheck` entity** (new) — id, person (to-one `Person`, cascade —
  deleting a person deletes their paycheck history), payDate (Date),
  totalAmountDecimal (typed accessor over `NSDecimalNumber`, same pattern
  as every other money field), createdAt/updatedAt. Represents one income
  event: "$2,400 from Person A on Sep 30."
  **`DirectDeposit` gets a new `paycheck: Paycheck?` relationship (cascade
  from Paycheck's side — deleting a paycheck deletes its split rows).**
  Keep `DirectDeposit.account` and `DirectDeposit.person` exactly as they
  are (nullify, unchanged) — don't remove or repurpose them, existing views
  (Home, Calendar, AccountDetailView) already read them directly and this
  is additive, not a rename.
  A paycheck's **unallocated remainder** = `totalAmountDecimal - sum(deposit.amountDecimal for deposits where deposit.paycheck == self)`.
  This is *computed*, never stored, and the UI should present it as
  "→ [home account]" rather than requiring the user to manually create a
  DirectDeposit row for it.
- **Last-4-only, already correct at the schema level** (`Account.accountNumberLast4`)
  — this round is about UI emphasis, not a data model change: make it a
  prominent, clearly-labeled field (not buried as an optional detail), and
  it's the field a user cross-references against the last 4 shown on their
  physical paystub when assigning a DirectDeposit split to an account.
- **Onboarding entry point changes.** First run (no `Person` exists yet)
  should offer "Add Paycheck" as the primary CTA, which opens
  `PersonSetupView` — income profile (pay frequency, amount, next date)
  comes before any bank account exists. After a person is saved, the
  natural next step is assigning that paycheck's split across accounts
  (the new Paycheck-creation flow) — not "add a bank account" as the first
  thing a new user sees.
- **`HomeView` must always render the earnings carousel**, even at $0 —
  never fall back to a full-screen empty state that hides it. Only the
  sub-sections (Active Promotions, Maintaining) get their own empty states.
  Showing what looks like an "add bank account" wall on first launch reads
  as the app being about bank data instead of money coming in — it should
  read as the latter from the first screen.
- **Calendar's empty state text is "No Paychecks Scheduled"** (was "No
  Direct Deposits Scheduled") and the view should group by `Paycheck`
  (payDate + person + total, with its DirectDeposit splits underneath and
  the computed remainder), not a flat list of individual DirectDeposit rows.

### Round 2 schema is built — actual API surface

- **`Bank`**: `id`, `name`, `createdAt`. `bank.accountsArray` (newest
  `openingDate` first), `bank.offersArray` (newest `createdAt` first).
- **`Paycheck`**: `id`, `payDate`, `totalAmountDecimal` (typed, like every
  other money field), `createdAt`/`updatedAt`. `paycheck.person: Person`
  (non-optional). `paycheck.directDepositsArray: [DirectDeposit]` (sorted).
  `paycheck.allocatedAmountDecimal` / `paycheck.unallocatedAmountDecimal`
  (both **computed**, never stored — the latter can go **negative** on
  over-allocation, deliberately, so the UI can flag it rather than
  silently clamp). `person.paychecksArray: [Paycheck]` (newest first).
- **Delete rules** (deviates from the original ask in one place, on
  purpose — same shape as the existing `Reminder.account` precedent):
  `Person.paychecks` is the **cascade** side (delete a person → their
  paychecks go), `Paycheck.person` is nullify. `Paycheck.directDeposits`
  is cascade (delete a paycheck → its splits go); deleting one split
  leaves the paycheck and its siblings untouched.
- **`Account.bank: Bank?`**, **`Account.isHomeAccount: Bool`** (default
  false, no single-home constraint — multiple allowed).
  **`Offer.bank: Bank?`**. **`DirectDeposit.paycheck: Paycheck?`** —
  `DirectDeposit.account`/`.person` are unchanged, still there, still how
  every existing view reads a deposit's destination/owner.
- **`CalculationService.isEligible` new signature** (backward compatible —
  no existing call site needed to change):
  ```swift
  static func isEligible(person: Person, bankName: String, bank: Bank? = nil, asOf date: Date = Date()) -> Bool
  ```
  Prefers `Bank`-relationship matching (by `objectID`) when both sides
  have a `Bank` set; falls back to the original case-insensitive
  `bankName` string match otherwise — pass `bank:` whenever you have one
  available (e.g. from the Bank picker).
- Seed data (`SampleData.populate`): 3 `Bank` rows (Chase/Wells
  Fargo/SoFi), the Chase sample account is `isHomeAccount = true`, two
  sample `Paycheck`s (one fully allocated, one partially — exercises the
  unallocated-remainder UI state), and at least one account/offer
  deliberately left bank-less to keep the string-fallback path exercised
  in previews.

## Round 3 changes — read before touching Models/ or any Views/ file listed below

- **Home accounts without a promotion.** Many home accounts (the user's
  literal case: checking/savings they already had before ever opening a
  bonus account) never run a bonus at all. Decision: add
  **`Account.isChurnAccount: Bool` (default true)** rather than making any
  existing field optional — this keeps every existing accessor
  (`bonusAmountDecimal`, `bonusStructureValue`, etc.) exactly as it is, so
  round 1/2 code doesn't ripple-break. `isChurnAccount` and `isHomeAccount`
  are independent — a home account *can* also be running a promo. In the
  add/edit form: default `isChurnAccount` to **false** the moment a *new*
  account is marked `isHomeAccount` (most home accounts have no promo);
  the user can still flip it on to add bonus info to a home account that
  happens to have one. When off, churn fields (bonus amount/structure/
  requirements, expected/actual date, eligibility window, offer link) are
  hidden and not required — save with sane defaults (0 / `.lumpSum` / ""
  / nil / 12) rather than validating them.
  **`AccountDetailView` for `isHomeAccount && !isChurnAccount`** shows only:
  bank name, account type, last-4, and the current total being direct
  deposited into it (sum of `DirectDeposit.amountDecimal` where
  `account == self` and `statusValue == .scheduled`) — no bonus/timeline/
  requirements sections.
- **`Offer.offerTitle` is now optional** (was required). Fall back to
  displaying the bank name where a title would have shown if it's
  nil/empty.
- **`Paycheck.remainderAccount: Account?`** (new, to-one, nullify) — which
  home account gets the unallocated remainder for *this* paycheck.
  Defaults to the paycheck's person's own home account if they have one
  set; user can override to any home account (not restricted to their
  own — a couple may route to a shared/joint account). The split-account
  picker in `AddEditPaycheckView` **excludes home accounts** — home
  accounts only ever receive the automatic remainder, never an explicit
  DD line item.
- **Calendar becomes a projected, effectively-open-ended list**, not just
  persisted `Paycheck` rows: for each `Person`, repeat their most recent
  `Paycheck`'s split pattern forward from `nextPaycheckDate` at their
  `payFrequency` for a bounded window (document whatever window you pick,
  e.g. next 12 occurrences per person — a `List` can't truly be infinite,
  this is the practical stand-in, and it's an explicit placeholder for
  the eventual Gantt chart, not the final visualization).
  **Promotion-end awareness, using data that already exists — no new
  schema for this:** in the projection, exclude any account whose
  `actualBonusDate != nil` (its bonus already posted, so the promo
  requirement is done) from receiving a projected split; redirect that
  split's amount into the projected remainder instead. Real, persisted
  `Paycheck`s are unaffected by this — it's a display-only projection
  rule for the *not-yet-created* future entries.
  Projected (not-yet-real) entries aren't editable directly — tapping one
  should offer to materialize it into a real `Paycheck` (which then opens
  the normal edit flow).
- **Paychecks stay editable after the fact** (already true via
  `AddEditPaycheckView(person:paycheck:)` in edit mode from round 2) —
  this round just needs to confirm nothing added an artificial
  past-date restriction, since accurate bookkeeping after the DD
  allocation didn't get swapped in time is the whole point.
- **Home tab's earnings carousel goes native-paged**: center-aligned,
  loops at the ends, no page dots, adjacent items peek in at the screen
  edges. Build it on `ScrollView(.horizontal)` +
  `.scrollTargetBehavior(.viewAligned)` + `.scrollTargetLayout()` +
  `.scrollPosition(id:)` (the "native carousel" the user means) — not
  `TabView(.page)`, which is what round 1 used and doesn't support
  peeking edges or hiding dots as cleanly.
- **Home's "View Full Schedule" button** needs to actually switch to the
  Calendar tab. `ContentView`/`MyApp` gained a small shared
  `AppTabSelection` (`@Observable`, injected via `.environment`) for
  exactly this — any view can set `appTabSelection.selected = .calendar`
  instead of the app needing a NavigationPath that crosses tab
  boundaries (which SwiftUI's `TabView` doesn't support directly).
- **Accounts list gets richer**: show opening date, expected bonus date,
  and a simple elapsed-time progress bar (opening → expected date) per
  churn account (skip the progress bar for non-churn accounts — there's
  no timeline to show). Add filtering (status, owner/person, calendar
  year) and sorting (opening date, expected/finish date, reward amount,
  person) — a filter sheet or menu, your call on the exact UI.

### Round 3 schema is built — actual API surface

- **`Account.isChurnAccount: Bool`** (default `true` — every pre-existing
  row/test still reads `true`, no ripple). Independent of `isHomeAccount`.
  No existing Account field was made optional.
  `Account.remainderForPaychecksArray: [Paycheck]` — the inverse of
  `Paycheck.remainderAccount` (newest `payDate` first).
- **`Offer.offerTitle: String?`** (now optional) — **use
  `offer.displayTitle: String` at every display site, never read
  `offerTitle` directly in a view.** It falls back to `bankName` when the
  title is nil, empty, or whitespace-only. Saving a titleless offer stores
  `nil`, not `""`.
- **`Paycheck.remainderAccount: Account?`** (to-one, optional, nullify
  both directions — deleting either side leaves the other untouched).
- `AppTab` enum (`.home`/`.calendar`/`.accounts`/`.offers`/`.settings`)
  and `AppTabSelection` (`@Observable`, `var selected: AppTab`) exist at
  `ChurnApp/AppTabSelection.swift`, injected via `.environment` from
  `MyApp`. `ContentView`'s `TabView` is bound to it — set
  `appTabSelection.selected = .calendar` from anywhere to switch tabs.
- `CalculationService.accountsOpenedThisYear`/`accountsClosedThisYear`
  now filter to `isChurnAccount == true` (opening/closing a home account
  isn't churning activity). `ytdEarnings`/`pendingBonusesTotal` were
  deliberately left as-is — a non-churn account's placeholder $0 bonus
  already makes filtering there a no-op.
- Seed data: a 5th sample account, `allySavings` (home, non-churn,
  Jordan's), and `jordanPaycheck.remainderAccount = allySavings` (the
  partially-allocated sample) — `alexPaycheck` deliberately keeps a nil
  `remainderAccount` so previews cover the "no destination set" state too.

## Round 4 changes — read before touching Home/Calendar/Settings/Offers/Accounts or Services/

- **Carousel centering bug.** The round 3 carousel (`Views/Home/HomeView.swift`,
  `earningsCarousel`) uses a `GeometryReader` to manually compute
  `cardWidth`/`sidePadding` and applies `.safeAreaPadding(.horizontal:)` +
  `.scrollTargetBehavior(.viewAligned)`. In practice it doesn't center —
  the previous card's trailing ~2/3 shows on the left and the current
  card is squeezed into the right third. Likely cause: `.viewAligned`
  snaps an item's *leading* edge to the content area's leading inset by
  default — it doesn't automatically center an item just because the
  leading/trailing insets are equal. Apple's documented pattern for a
  "one item centered, neighbors peeking" carousel uses
  `.containerRelativeFrame(.horizontal, count:span:spacing:)` for the
  item width instead of manual `GeometryReader` math — try that approach
  first. **Whoever fixes this must visually verify with a simulator
  screenshot before calling it done — a green build proves nothing about
  whether it actually looks centered.**
- **Calendar projection must not require an existing real `Paycheck`.**
  Round 3's projection only generated future entries for a person who
  already had at least one real, persisted `Paycheck` (to repeat its
  split pattern) — which is backwards from the actual intent: the whole
  point of `Person` setup (net pay + one pay date + frequency) is to
  project indefinitely *from that alone*, before the user has ever logged
  a real paycheck. Fix: when a person has zero real paychecks, project
  using `person.paycheckAmountDecimal` as the total with **100% going to
  the remainder** (no explicit splits — there's no pattern to repeat yet).
  Once they have at least one real paycheck, keep repeating its most
  recent split pattern as before. This is also why person #2's schedule
  wasn't showing — they likely have zero logged paychecks yet, which is
  the exact case that must now work.
- **Historical immutability — this is a hard invariant, not just a
  round-4 fix.** A real, persisted `Paycheck`'s `totalAmountDecimal` and
  its `DirectDeposit` splits are a snapshot taken at creation/edit time.
  **Nothing may ever recompute or overwrite a past `Paycheck` from
  current `Person`/`Account` data** — e.g. a `Person`'s pay raise must
  only affect *future* projected/new paychecks, never rewrite a paycheck
  that already happened. This was already true structurally (nothing
  reads `person.paycheckAmountDecimal` to redraw an existing `Paycheck`),
  but treat it as a rule to actively preserve, not an accident to
  maintain.
- **Deleting a `Person` is a soft delete (`Person.isArchived: Bool`,
  default false), not a real Core Data delete.** The user needs to still
  see a deleted person's past paychecks and direct deposits — flipping
  `Person.paychecks`/`Paycheck.person` to nullify-and-optional to survive
  a hard delete would ripple through every place that currently reads
  `paycheck.person.name` as non-optional (Home, Calendar, Paycheck views)
  for comparatively little benefit over just archiving. Archived persons
  should stop appearing in "current" pickers (new account's person
  picker, new paycheck's person picker/quick-action) and stop generating
  new projected paychecks in Calendar, but their historical
  `Person`/`Paycheck`/`DirectDeposit`/`Account` rows are untouched and
  still fully visible. "Delete Person" in `PersonSetupView` sets this
  flag (with a confirmation explaining it keeps history intact) rather
  than calling `context.delete(person)`.
- **"Open Account" from an `Offer`.** `OfferDetailView` gets a button
  that opens `AddEditAccountView` pre-filled from the offer (bank,
  `bonusAmountDecimal`, `bonusStructureValue`, `bonusRequirements`,
  `eligibilityRestrictionMonths`, and `account.offer = offer` so the link
  persists) — the user only has to supply the account number's last 4 and
  the opening date (and a person, if not inferable) to finish.
- **Automatic notifications, first pass — additive alongside the
  existing manual `Reminder` feature (not a replacement — user confirmed
  keep both).** Derive notification triggers from data that already
  exists rather than requiring the user to create anything:
  - DD series complete for an account (its `directDepositProgress`
    reaches `total`, or `actualBonusDate` gets set) → "time to close it"
    style notification.
  - N days before a person's `nextPaycheckDate` (or their next projected
    paycheck) → "have you updated your direct deposit?" — **only if**
    the relevant data doesn't already show it's been handled (e.g.
    don't nag if this period's `DirectDeposit` rows already exist/are
    updated).
  These are scheduled/refreshed automatically (e.g. on relevant Core
  Data saves), not something the user sets up — that's the whole point
  versus the manual `Reminder` feature, which stays available for
  anything the automatic rules don't cover.

### Round 4 is built — actual API surface

- **Carousel fix**: the working combination is `.containerRelativeFrame(.horizontal, count: 5, span: 4, spacing: 12)` for each card's width *plus* `GeometryReader`-computed `sidePadding = width / 10` applied via `.safeAreaPadding(.horizontal:)` — dropping the `safeAreaPadding` (relying on `containerRelativeFrame` alone) left the content flush against the leading edge. Both pieces are required together.
- **`Person.isArchived: Bool`** (default false, `byIsArchived` fetch index — same pattern as `Account`/`Reminder`). "Delete Person" in `PersonSetupView` (edit mode only) sets this rather than deleting; confirmation copy explains history is kept. Filter active people with `isArchived == NO`. **Wired this round**: `AddEditAccountView`'s person picker (via a `pickerPeople` computed property — active people plus the currently-assigned owner even if since archived, so editing never blanks an account's owner), `HomeView`'s person fetch (so archiving the only person correctly re-enters first-run state), `CalendarView`'s person fetch (stops new *projected* entries for an archived person — their real, separately-fetched `Paycheck` history is untouched). `AddEditPaycheckView` needed no change — it takes `person:` as a required init param rather than owning its own picker.
- **`AddEditAccountView(account:prefillFrom:)`** — new `prefillFrom: Offer? = nil` param (existing `AddEditAccountView(account:)` call sites all still compile, default nil). Pre-fills bank, bonus amount, requirements, eligibility months from the offer; leaves last-4/opening date/person blank; sets `isChurnAccount = true`, `isHomeAccount = false`; sets `account.offer` on save. `Offer` has no bonus-structure/minimum-deposit/months-to-maintain equivalent on `Account`, so those aren't mapped — `bonusStructure` stays at its `.lumpSum` default. `OfferDetailView` has an "Open Account" button that presents it.
- **`Services/AutomaticNotificationService.swift`** (new, additive alongside the existing manual `Reminder`/`NotificationService` feature): `refreshNotifications(context:)` evaluates two trigger rules and reschedules automatically — cancel-then-reschedule against stable per-entity identifiers (`"close-account-<uuid>"` / `"update-dd-<uuid>"`) makes it idempotent. Wired via `AutomaticNotificationService.start(context:)`, called once from `PersistenceController.init`, which observes `.NSManagedObjectContextDidSave` and re-runs the refresh after every save — no manual trigger needed.
  - **Close-account trigger**: `account.actualBonusDate != nil` (primary signal), or `CalculationService.directDepositProgress(for:)` reaching `completed >= total` with `total > 0` (fallback) — and not already `.closed`/archived.
  - **Update-DD trigger**: within 5 days of a person's (projected) next pay date, unless a `DirectDeposit` already exists within a few days of that date (the "already handled" check — deliberately conservative, since a false nag is worse than an occasional missed one).
  - This is an explicit first pass, not the full notification system — extend the two-trigger pattern as more signals get identified.

## Round 5 changes — bug fixes from real device testing

- **Tab navigation resets on leave, not on return.** Every tab root now
  binds its `NavigationStack` to a path owned by `AppTabSelection`
  (`homePath`/`calendarPath`/`accountsPath`/`offersPath`/`settingsPath`)
  instead of an implicit/local one. `ContentView` resets a tab's path the
  moment `.onChange(of: tabSelection.selected)` fires for the tab being
  left — so switching away and back always lands on that tab's root,
  instead of SwiftUI's default of leaving a pushed detail view sitting
  there. **Any new pushed view on a tab root must go through that tab's
  path** (the existing `.navigationDestination(for:)` pattern already
  does this automatically — nothing changes about how you push, only
  about how the stack resets).
- **Paycheck delete crash — diagnosed.** `PaycheckDetailView.delete()`
  calls `viewContext.delete(paycheck)` + `save()` *before* `dismiss()`.
  Since `paycheck` is an `@ObservedObject`, the deletion's
  `objectWillChange` fires a `body` re-render before `dismiss()` takes
  effect, and `paycheck.payDate`/`paycheck.person.name` get accessed on a
  now-deleted managed object — crash. Fix at the ordering/guarding level
  (dismiss before delete, or guard `body` against a deleted/faulted
  object), not by touching what gets deleted.
- **PersonSetupView "set up first paycheck?" — two bugs, one root cause.**
  The confirmation dialog's `isPresented` is a custom `Binding` whose
  `set` nils `savedPerson` as a side effect of the dialog dismissing —
  this races against the "Set Up First Paycheck" button's own action, so
  by the time `.sheet(isPresented:) { if let savedPerson { ... } }`
  evaluates, `savedPerson` can already be nil → blank sheet. Fix: capture
  the person into its own state (e.g. `.sheet(item:)` instead of
  `isPresented` + `if let`), decoupled from the dialog's dismiss-binding.
  Second bug, same neighborhood: dismissing the "set up first paycheck?"
  dialog by tapping *outside* it (not choosing a button) doesn't dismiss
  `PersonSetupView` itself — the add-person form is still sitting there,
  fully filled in, Save still enabled, and `save()`'s add-mode branch
  unconditionally creates a new `Person` — so a second tap of Save
  creates a duplicate. Fix by guarding against a second create once a
  person has already been saved in this session (disable Save, or make
  a second save update the already-created person instead of inserting
  another).
- **Calendar showing both a real paycheck and its own projection.** Once
  a projected occurrence is materialized into a real `Paycheck`, the
  projection generator has no way to know that date/person combination
  is now "real" — it keeps generating a projected entry for the same
  slot alongside the real one. Fix: the projection loop must skip any
  occurrence whose date+person already has a matching real `Paycheck`.
- **Open Account from Offer doesn't navigate anywhere after save.** Per
  the user: after confirming, they expect to land on the Accounts tab
  with the new account visible at the top. Use `AppTabSelection` (same
  mechanism as Home's "View Full Schedule") to switch to `.accounts`
  after a successful prefilled save, and confirm `AccountsListView`'s
  default sort actually surfaces a brand-new account at the top (it
  should, sorted by `openingDate` — verify the new account's
  `openingDate` default and the sort direction agree).

## Explicitly out of scope for this build

- Vertical Gantt chart with visual DD connectors (Calendar tab ships as a
  simple list instead)
- CloudKit sync
- StoreKit subscription/paywall
- Any bundled/API-sourced offer data — offers are 100% manual entry
- Offer marketplace/crowdsourcing/verification backend
- DD allocation optimizer / recommendation algorithm
- Real-time multi-device sharing between the two people in a household
