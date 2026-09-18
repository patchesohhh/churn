//
//  NotificationService.swift
//  ChurnApp
//
//  Thin wrapper around `UserNotifications` for scheduling/cancelling the
//  single local notification tied to each `Reminder`. Deliberately dumb:
//  it never fetches from Core Data itself, it just operates on a `Reminder`
//  object handed to it by the caller and keeps `Reminder.notificationIdentifier`
//  in sync so the app always knows which system notification (if any)
//  belongs to which reminder.
//
//  All data here is local/user-entered (see CLAUDE.md) — this is purely a
//  device-local notification, never anything server-triggered.
//

import CoreData
import Foundation
import UserNotifications

/// Wraps `UNUserNotificationCenter` for the one thing this app needs: a
/// single scheduled reminder per `Reminder` entity.
struct NotificationService {

    /// Shared instance — `UNUserNotificationCenter` itself is already a
    /// process-wide singleton, so this just gives call sites a consistent
    /// spelling (`NotificationService.shared...`) without re-fetching
    /// `.current()` everywhere.
    static let shared = NotificationService()

    private var center: UNUserNotificationCenter { .current() }

    // MARK: - Authorization

    /// Requests permission to show alerts/sounds/badges. Safe to call
    /// repeatedly — iOS only prompts the user once; subsequent calls just
    /// report back the existing decision.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // Authorization can fail (e.g. simulator quirks, restricted
            // profiles) — never crash the app over a permission prompt.
            return false
        }
    }

    /// True if the app is currently allowed to display notifications
    /// (`.authorized` or `.provisional`). Callers can check this before
    /// bothering to schedule, though `schedule(for:)` itself is also safe
    /// to call unconditionally — an unauthorized schedule request is simply
    /// dropped by the system.
    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Scheduling

    /// Schedules (or reschedules) a local notification firing at
    /// `reminder.dueDate`, and stores the generated identifier on the
    /// reminder itself so it can be cancelled/updated later.
    ///
    /// This does NOT save the managed object context — callers already save
    /// after their own edits (see the "views save to Core Data directly"
    /// architecture rule in CLAUDE.md), so saving here too would just be a
    /// redundant second write.
    ///
    /// If the reminder already has a previous notification scheduled (i.e.
    /// it's being edited), that one is cancelled first so edits never leave
    /// a stale duplicate notification behind.
    func schedule(for reminder: Reminder) async {
        // Clear out any previously-scheduled notification for this reminder
        // before creating a new one — due date/title/notes may have changed.
        if let existingIdentifier = reminder.notificationIdentifier {
            center.removePendingNotificationRequests(withIdentifiers: [existingIdentifier])
        }

        // A completed reminder, or one whose due date has already passed,
        // has nothing useful to notify about.
        guard !reminder.isCompleted, reminder.dueDate > Date() else {
            reminder.notificationIdentifier = nil
            return
        }

        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = Self.bodyText(for: reminder)
        content.sound = .default

        let triggerDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: reminder.dueDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerDateComponents, repeats: false)

        let identifier = reminder.notificationIdentifier ?? UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await center.add(request)
            reminder.notificationIdentifier = identifier
        } catch {
            // Scheduling can fail if the app isn't authorized yet, or in a
            // handful of system edge cases. Leave the reminder without a
            // notification identifier rather than crashing — the reminder
            // itself is still perfectly usable without a push.
            reminder.notificationIdentifier = nil
        }
    }

    /// Cancels the reminder's scheduled notification (if any) and clears
    /// `notificationIdentifier`. Safe to call even when nothing is
    /// scheduled. Does not save the context — see `schedule(for:)`.
    func cancel(for reminder: Reminder) {
        if let identifier = reminder.notificationIdentifier {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
        }
        reminder.notificationIdentifier = nil
    }

    // MARK: - Body text

    /// Builds the notification body from the reminder's type, account, and
    /// due date. Pulled out as a pure `static` function (no `self`, no
    /// system calls) so it's trivially unit-testable without touching
    /// `UNUserNotificationCenter` at all.
    static func bodyText(for reminder: Reminder) -> String {
        let bankName = reminder.account.bankName
        let dueDateText = Self.dueDateFormatter.string(from: reminder.dueDate)

        switch reminder.reminderTypeValue {
        case .checkBonus:
            return "Check whether your \(bankName) bonus has posted — due \(dueDateText)."
        case .closeAccount:
            return "Time to close your \(bankName) account — due \(dueDateText)."
        case .updateDirectDeposit:
            return "Update your direct deposit for \(bankName) — due \(dueDateText)."
        case .meetRequirement:
            return "Make sure you've met the requirements for \(bankName) — due \(dueDateText)."
        case .custom:
            return "\(bankName) — due \(dueDateText)."
        }
    }

    private static let dueDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
