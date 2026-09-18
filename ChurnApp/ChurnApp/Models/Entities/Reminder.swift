//
//  Reminder.swift
//  ChurnApp
//
//  A dated task attached to an account: check the bonus, close before the fee
//  hits, move a direct deposit, etc. Backed by a local UNNotificationRequest
//  when the user has granted notification permission.
//
//  See `Person.swift` for why these classes are hand-written.
//

import CoreData
import Foundation

@objc(Reminder)
public class Reminder: NSManagedObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<Reminder> {
        NSFetchRequest<Reminder>(entityName: "Reminder")
    }

    // MARK: - Attributes

    @NSManaged public var id: UUID
    @NSManaged public var title: String
    /// Raw value of `ReminderType`. Prefer `reminderTypeValue`.
    @NSManaged public var reminderType: String
    @NSManaged public var dueDate: Date
    @NSManaged public var isCompleted: Bool
    @NSManaged public var completedDate: Date?
    @NSManaged public var notes: String?
    /// Identifier of the scheduled `UNNotificationRequest`, so the app can
    /// cancel or reschedule it when the reminder changes.
    @NSManaged public var notificationIdentifier: String?
    /// Soft-delete flag — see the note on `Account.isArchived` for why this
    /// isn't called `isDeleted`.
    @NSManaged public var isArchived: Bool
    @NSManaged public var createdAt: Date

    // MARK: - Relationships

    /// Required: a reminder with no account has nothing to remind about.
    ///
    /// Delete rule is *nullify* on this side, deliberately diverging from the
    /// source docs, which described it as "required, cascade". A cascade here
    /// would mean deleting a single reminder destroys the entire account. The
    /// behaviour the docs actually wanted — delete an account, lose its
    /// reminders — is provided by the cascade on `Account.reminders`.
    @NSManaged public var account: Account
}

// MARK: - Typed accessors

extension Reminder {

    var reminderTypeValue: ReminderType {
        get { ReminderType(rawValue: reminderType) ?? .custom }
        set { reminderType = newValue.rawValue }
    }

    /// Past due and still open. Drives the red badge in reminder lists.
    var isOverdue: Bool {
        !isCompleted && dueDate < Date()
    }
}

extension Reminder: Identifiable {}
