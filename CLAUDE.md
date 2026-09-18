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

## Explicitly out of scope for this build

- Vertical Gantt chart with visual DD connectors (Calendar tab ships as a
  simple list instead)
- CloudKit sync
- StoreKit subscription/paywall
- Any bundled/API-sourced offer data — offers are 100% manual entry
- Offer marketplace/crowdsourcing/verification backend
- DD allocation optimizer / recommendation algorithm
- Real-time multi-device sharing between the two people in a household
