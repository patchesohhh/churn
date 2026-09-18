//
//  AutomaticNotificationService.swift
//  ChurnApp
//
//  Round 4, first pass: automatic, data-derived local notifications — no
//  manual `Reminder` required for the common cases. This is the app's
//  "secret sauce" per the user directly, and is additive alongside the
//  existing manual `Reminder`/`NotificationService` flow (kept as-is per
//  the user's explicit choice) — this file never touches that one.
//
//  Two trigger rules, deliberately kept to just two for this first pass
//  (see CLAUDE.md's Round 4 notes — this is explicitly not meant to cover
//  every possible notification type yet):
//    1. "Close this account" — an account's bonus requirements are done but
//       it's still open.
//    2. "Update your direct deposit" — a person's next paycheck is coming up
//       soon and nothing suggests the DD has been pointed at it yet.
//
//  Design: the *decision* logic (which accounts/persons qualify) lives in
//  pure, `static`, Foundation-only functions — same pattern as
//  `CalculationService` — so it's unit-testable without a persistent store
//  or `UNUserNotificationCenter` at all (see
//  `ChurnAppTests/AutomaticNotificationServiceTests.swift`). The scheduling
//  side effects reuse the same `UNUserNotificationCenter` conventions
//  `NotificationService` established in round 1 (a plain
//  `UNMutableNotificationContent` + calendar/time-interval trigger, best-
//  effort `try?` on `add`) rather than reinventing them — but this layer
//  talks to the notification center directly instead of going through
//  `NotificationService`, because these notifications aren't tied to a
//  `Reminder` row: there's no model object to stash a
//  `notificationIdentifier` on. Instead, identifiers are derived
//  deterministically from the triggering object's `id`
//  (`"close-account-<uuid>"` / `"update-dd-<uuid>"`). That determinism is
//  what makes `refreshNotifications` idempotent: every call cancels-then-
//  reschedules by those stable identifiers, so re-running it after any data
//  change never produces duplicates and never leaves a stale notification
//  behind for something that no longer qualifies.
//

import CoreData
import Foundation
import UserNotifications

enum AutomaticNotificationService {

    // MARK: - Tuning

    /// How many days before a person's next paycheck to nag about updating
    /// direct deposit. The user's own example, when describing this
    /// feature, used "5 days" — kept as the literal default rather than
    /// inventing a different number.
    static let daysBeforePaycheckToNag = 5

    /// Tolerance, in days, when matching an existing `DirectDeposit` row's
    /// `scheduledDate` against a *projected* next pay date to decide whether
    /// the DD has "already been handled" for that period. Needed because
    /// `nextPayDate(for:asOf:)` below uses the same approximate frequency
    /// stepping `CalendarView`'s projection uses (e.g. semimonthly's flat
    /// 15-day stand-in for "1st and 16th" — see that file), so a real,
    /// user-entered DD row a few days off from the projected date is still
    /// almost certainly the same pay period, not a different one.
    static let ddMatchToleranceDays = 4

    // MARK: - Entry point

    /// Fetches the relevant `Account`s and `Person`s, evaluates both
    /// trigger rules, and schedules/cancels local notifications so the
    /// notification center exactly reflects current data. Safe — and
    /// intended — to call repeatedly; see file header on idempotency.
    ///
    /// Not called directly by views. `start(context:)` below wires this to
    /// run automatically after every Core Data save.
    static func refreshNotifications(context: NSManagedObjectContext, asOf date: Date = Date()) async {
        let accounts: [Account]
        let persons: [Person]
        do {
            accounts = try context.fetch(Account.fetchRequest())
            persons = try context.fetch(Person.fetchRequest())
        } catch {
            // Nothing sensible to schedule against if the fetch itself
            // failed — skip this refresh rather than crashing. The next
            // save triggers another attempt.
            return
        }

        let center = UNUserNotificationCenter.current()

        // Cancel every identifier this service could ever have scheduled
        // for the *current* full set of accounts/persons before
        // rescheduling — not just the ones that still qualify. That's what
        // clears a stale notification for an account that just got closed,
        // or a person whose DD row just showed up, even though neither is
        // in the "to schedule" list below.
        let allCloseIdentifiers = accounts.map { closeAccountIdentifier(for: $0) }
        let allDDIdentifiers = persons.map { updateDDIdentifier(for: $0) }
        center.removePendingNotificationRequests(withIdentifiers: allCloseIdentifiers + allDDIdentifiers)

        guard await NotificationService.shared.isAuthorized() else { return }

        for account in accountsQualifyingForCloseTrigger(accounts: accounts) {
            await scheduleCloseAccountNotification(for: account, center: center)
        }
        for person in personsQualifyingForUpdateDDTrigger(persons: persons, asOf: date) {
            if let payDate = nextPayDate(for: person, asOf: date) {
                await scheduleUpdateDDNotification(for: person, nextPayDate: payDate, asOf: date, center: center)
            }
        }
    }

    // MARK: - Trigger 1: "Close this account"

    /// True when `account` has finished its bonus requirements but hasn't
    /// been marked closed yet.
    ///
    /// Two signals are accepted, in order of trust:
    ///   1. `account.actualBonusDate != nil` — the most reliable signal.
    ///      It's the one field the rest of the app already treats as
    ///      "the bonus definitely landed" (`Account.hasBonusPosted`,
    ///      `CalculationService.ytdEarnings`/`allTimeEarnings` all key off
    ///      it), which means it's a field the user is already in the habit
    ///      of filling in once a bonus posts.
    ///   2. `CalculationService.directDepositProgress(for:)` reaching
    ///      `completed >= total` with `total > 0` — a fallback for an
    ///      account whose DD series is fully posted but whose
    ///      `actualBonusDate` the user hasn't gotten around to setting yet.
    ///      `total > 0` guards against an account with zero tracked
    ///      deposits trivially satisfying `completed >= total` (0 >= 0).
    static func accountQualifiesForCloseTrigger(_ account: Account) -> Bool {
        guard !account.isArchived, account.accountStatusValue != .closed else { return false }
        if account.actualBonusDate != nil { return true }
        let progress = CalculationService.directDepositProgress(for: account)
        return progress.total > 0 && progress.completed >= progress.total
    }

    static func accountsQualifyingForCloseTrigger(accounts: [Account]) -> [Account] {
        accounts.filter(accountQualifiesForCloseTrigger)
    }

    // MARK: - Trigger 2: "Update your direct deposit"

    /// Projects `person`'s next upcoming pay date, starting from
    /// `person.nextPaycheckDate` and stepping forward by `payFrequencyValue`
    /// until it's no longer in the past.
    ///
    /// `nextPaycheckDate` is a field the user sets once and nothing in this
    /// app automatically advances afterward — without this step-forward, a
    /// date that's drifted into the past would silently stop this trigger
    /// from ever firing again. The stepping math is intentionally the same
    /// approximation `CalendarView`'s projection uses (`advance(_:by:)`
    /// below), **duplicated rather than imported** per CLAUDE.md's
    /// low-cross-feature-coupling rule — it's a few lines of date math, not
    /// worth a dependency between Services/ and Views/Calendar/.
    ///
    /// Returns nil for an archived person, a person with no
    /// `nextPaycheckDate` set yet, or `.irregular` pay frequency (nothing
    /// to project against, same reasoning `CalendarView` uses to skip
    /// those).
    static func nextPayDate(for person: Person, asOf date: Date = Date()) -> Date? {
        guard !person.isArchived, var candidate = person.nextPaycheckDate else { return nil }
        guard person.payFrequencyValue.paychecksPerYear > 0 else { return nil }

        let calendar = Calendar.current
        var iterations = 0
        // Caps the walk so a badly stale date can never loop forever; 730
        // steps comfortably covers even a weekly date left un-updated for
        // years.
        while calendar.startOfDay(for: candidate) < calendar.startOfDay(for: date), iterations < 730 {
            candidate = advance(candidate, by: person.payFrequencyValue)
            iterations += 1
        }
        return candidate
    }

    /// Same frequency-stepping approximation as `CalendarView.advance` —
    /// duplicated intentionally, see `nextPayDate` doc above.
    private static func advance(_ date: Date, by frequency: PayFrequency) -> Date {
        let calendar = Calendar.current
        switch frequency {
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date) ?? date
        case .biweekly:
            return calendar.date(byAdding: .weekOfYear, value: 2, to: date) ?? date
        case .semimonthly:
            return calendar.date(byAdding: .day, value: 15, to: date) ?? date
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date) ?? date
        case .irregular:
            return date
        }
    }

    /// The "already handled" check — deliberately conservative, per the
    /// task: a false "you haven't updated it" nag when the user actually
    /// has is worse than an occasional missed nag. ANY `DirectDeposit` row
    /// (any status — `.scheduled` or already `.posted`) within
    /// `ddMatchToleranceDays` of the projected pay date counts as
    /// "handled", because it means the user has already logged *something*
    /// for that pay period — exactly the signal the round-4 note called for
    /// ("don't nag if this period's `DirectDeposit` rows already exist").
    static func directDepositAlreadyHandled(for person: Person, nextPayDate: Date) -> Bool {
        let calendar = Calendar.current
        return person.directDepositsArray.contains { deposit in
            let days = calendar.dateComponents([.day], from: deposit.scheduledDate, to: nextPayDate).day ?? Int.max
            return abs(days) <= ddMatchToleranceDays
        }
    }

    /// True when `person` should get an "update your direct deposit" nag:
    /// their projected next pay date is within `daysBefore` days (inclusive)
    /// and no `DirectDeposit` row already covers that period.
    static func personQualifiesForUpdateDDTrigger(
        _ person: Person,
        asOf date: Date = Date(),
        daysBefore: Int = daysBeforePaycheckToNag
    ) -> Bool {
        guard let payDate = nextPayDate(for: person, asOf: date) else { return false }
        let daysUntilPay = CalculationService.daysUntil(payDate, from: date)
        guard daysUntilPay >= 0, daysUntilPay <= daysBefore else { return false }
        return !directDepositAlreadyHandled(for: person, nextPayDate: payDate)
    }

    static func personsQualifyingForUpdateDDTrigger(
        persons: [Person],
        asOf date: Date = Date(),
        daysBefore: Int = daysBeforePaycheckToNag
    ) -> [Person] {
        persons.filter { personQualifiesForUpdateDDTrigger($0, asOf: date, daysBefore: daysBefore) }
    }

    // MARK: - Identifiers

    /// Stable, derivable per-account identifier — same value every refresh,
    /// so cancel-then-reschedule never orphans a duplicate.
    static func closeAccountIdentifier(for account: Account) -> String {
        "close-account-\(account.id)"
    }

    /// Stable, derivable per-person identifier — see `closeAccountIdentifier`.
    static func updateDDIdentifier(for person: Person) -> String {
        "update-dd-\(person.id)"
    }

    // MARK: - Scheduling (side effects — not unit tested directly, same
    // carve-out `NotificationServiceTests` documents for `UNUserNotificationCenter`
    // plumbing; the *decision* functions above are what's tested)

    private static func scheduleCloseAccountNotification(for account: Account, center: UNUserNotificationCenter) async {
        let content = UNMutableNotificationContent()
        content.title = "Time to close \(account.bankName)!"
        content.body = "Your bonus requirements are complete."
        content.sound = .default

        // The underlying condition ("requirements complete") is already
        // true right now — unlike the paycheck trigger below, there's no
        // future date to wait for, so this fires almost immediately.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let request = UNNotificationRequest(
            identifier: closeAccountIdentifier(for: account),
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    private static func scheduleUpdateDDNotification(
        for person: Person,
        nextPayDate: Date,
        asOf date: Date,
        center: UNUserNotificationCenter
    ) async {
        let content = UNMutableNotificationContent()
        content.title = "Update your direct deposit"
        content.body = "\(person.name)'s next paycheck is coming up — have you updated your direct deposit?"
        content.sound = .default

        let idealTriggerDate = Calendar.current.date(
            byAdding: .day,
            value: -daysBeforePaycheckToNag,
            to: nextPayDate
        ) ?? nextPayDate

        let trigger: UNNotificationTrigger
        if idealTriggerDate > date {
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: idealTriggerDate
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        } else {
            // Already inside the nag window (e.g. the app was first opened
            // only 2 days before payday, past the ideal N-day trigger
            // point) — fire shortly rather than silently missing the window.
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        }

        let request = UNNotificationRequest(
            identifier: updateDDIdentifier(for: person),
            content: content,
            trigger: trigger
        )
        try? await center.add(request)
    }

    // MARK: - Auto-refresh on save

    /// Begins observing `context`'s saves and calling `refreshNotifications`
    /// after each one — this is what makes the whole feature automatic:
    /// nothing else in the app needs to remember to call this. Call once,
    /// from `PersistenceController.init` (its one-line hook).
    ///
    /// Not debounced: a plain "run after every save" is enough for this
    /// first pass — this is a single-user, local-only app (no CloudKit
    /// sync), so saves are infrequent enough that redundant refreshes cost
    /// nothing worth guarding against yet.
    static func start(context: NSManagedObjectContext) {
        NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: context,
            queue: .main
        ) { _ in
            Task {
                await refreshNotifications(context: context)
            }
        }
    }
}
