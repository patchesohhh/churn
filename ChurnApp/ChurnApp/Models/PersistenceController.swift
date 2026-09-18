//
//  PersistenceController.swift
//  ChurnApp
//
//  The Core Data stack. Deliberately a plain `NSPersistentContainer` and NOT
//  `NSPersistentCloudKitContainer`: CloudKit sync is explicitly out of scope
//  for this build (see CLAUDE.md). All data is local, user-entered, and lives
//  in a single store.
//
//  Three entry points:
//    - `.shared`  — the real on-disk store the app runs against.
//    - `.preview` — an in-memory store pre-populated with realistic sample
//                   data, for SwiftUI `#Preview`s and unit tests.
//    - `init(inMemory:)` — for tests that want a clean, empty store.
//

import CoreData
import Foundation

/// Bundle anchor. `Bundle(for:)` needs a class defined in the same bundle as
/// the compiled Core Data model; this type exists for no other reason.
private final class ModelBundleToken {}

struct PersistenceController {

    // MARK: - Shared instances

    /// The live, on-disk stack used by the running app.
    static let shared = PersistenceController()

    /// In-memory stack seeded with sample data. Safe to use from previews and
    /// tests — it never touches the user's real store.
    static let preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        SampleData.populate(in: controller.container.viewContext)
        return controller
    }()

    // MARK: - Container

    let container: NSPersistentContainer

    /// Convenience accessor so callers don't have to reach through `container`.
    var viewContext: NSManagedObjectContext { container.viewContext }

    /// - Parameter inMemory: when true the store is written to `/dev/null`,
    ///   i.e. it exists only for the lifetime of this object. This is the
    ///   standard Apple-template trick for previews and tests.
    /// The compiled model, loaded exactly once.
    ///
    /// `NSPersistentContainer(name:)` re-loads the `.momd` on every call, which
    /// produces several `NSEntityDescription` instances per entity class. Core
    /// Data then can't decide which one `Account(context:)` means and logs
    /// "Failed to find a unique match for an NSEntityDescription". Sharing one
    /// model across every container (app store, previews, each test's store)
    /// avoids that entirely.
    private static let managedObjectModel: NSManagedObjectModel = {
        guard let url = Bundle(for: ModelBundleToken.self).url(forResource: "ChurnDataModel", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: url) else {
            fatalError("Failed to locate ChurnDataModel.momd in the app bundle.")
        }
        return model
    }()

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "ChurnDataModel",
                                          managedObjectModel: Self.managedObjectModel)

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                // A store that won't load is unrecoverable for this app — there
                // is no remote copy of the data to fall back to. Crash loudly in
                // debug so the cause is obvious during development.
                assertionFailure("Unresolved Core Data error \(error), \(error.userInfo) for store \(storeDescription)")
            }
        }

        // Views use @FetchRequest against the view context; merging changes
        // from background contexts keeps those lists live.
        container.viewContext.automaticallyMergesChangesFromParent = true
        // Last write wins on a property-by-property basis. With a single local
        // store and one user this should never actually arbitrate anything, but
        // it prevents a hard merge-conflict throw if it ever does.
        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
    }

    // MARK: - Saving

    /// Saves the view context if it has changes.
    ///
    /// Views save directly to Core Data (see the architecture notes in
    /// CLAUDE.md — there is no store object mediating writes), so this is the
    /// one shared place where save errors get handled consistently.
    ///
    /// - Returns: Discardable. Errors are logged and rethrown by
    ///   `saveContextThrowing()` if a caller needs to react to them.
    func saveContext() {
        do {
            try saveContextThrowing()
        } catch {
            // Non-fatal in release: a failed save usually means a validation
            // rule rejected user input, and the UI layer is expected to have
            // validated first. Assert in debug so it's not silently swallowed.
            assertionFailure("Failed to save Core Data context: \(error)")
        }
    }

    /// Throwing variant of `saveContext()` for callers that want to surface a
    /// validation failure to the user (e.g. a form that must stay open).
    func saveContextThrowing(_ context: NSManagedObjectContext? = nil) throws {
        let context = context ?? container.viewContext
        guard context.hasChanges else { return }
        try context.save()
    }
}

// MARK: - Sample data

/// Realistic seed data for `PersistenceController.preview` and for tests.
///
/// Kept in its own type (rather than inline in the `preview` closure) so tests
/// can populate a throwaway context of their own without going through the
/// shared `preview` singleton.
enum SampleData {

    /// Inserts two household earners, four accounts across every status, a
    /// handful of direct deposits, two reminders and two offers, then saves.
    @discardableResult
    static func populate(in context: NSManagedObjectContext) -> Bool {
        let now = Date()
        let calendar = Calendar.current

        func date(daysFromNow days: Int) -> Date {
            calendar.date(byAdding: .day, value: days, to: now) ?? now
        }

        // MARK: People

        let alex = Person(context: context)
        alex.id = UUID()
        alex.name = "Alex"
        alex.payFrequency = PayFrequency.biweekly.rawValue
        alex.paycheckAmount = NSDecimalNumber(string: "2400.00")
        alex.nextPaycheckDate = date(daysFromNow: 5)
        alex.maxConcurrentDirectDeposits = 3
        alex.defaultBankName = "Chase"
        alex.colorTag = "blue"
        alex.createdAt = now
        alex.updatedAt = now

        let jordan = Person(context: context)
        jordan.id = UUID()
        jordan.name = "Jordan"
        jordan.payFrequency = PayFrequency.semimonthly.rawValue
        jordan.paycheckAmount = NSDecimalNumber(string: "1875.50")
        jordan.nextPaycheckDate = date(daysFromNow: 9)
        jordan.maxConcurrentDirectDeposits = 2
        jordan.defaultBankName = "Ally"
        jordan.colorTag = "purple"
        jordan.createdAt = now
        jordan.updatedAt = now

        // MARK: Offers

        let sofiOffer = Offer(context: context)
        sofiOffer.id = UUID()
        sofiOffer.bankName = "SoFi"
        sofiOffer.offerTitle = "SoFi Checking & Savings $300"
        sofiOffer.bonusAmount = NSDecimalNumber(string: "300.00")
        sofiOffer.requirements = "Receive $5,000+ in qualifying direct deposits within 25 days."
        sofiOffer.expirationDate = date(daysFromNow: 60)
        sofiOffer.eligibilityRestrictionMonths = NSNumber(value: 24)
        sofiOffer.minimumDeposit = NSDecimalNumber(string: "0")
        sofiOffer.directDepositRequired = true
        sofiOffer.monthsToMaintain = NSNumber(value: 0)
        sofiOffer.offerURL = "https://www.sofi.com/banking/"
        sofiOffer.isActive = true
        sofiOffer.isFavorite = true
        sofiOffer.notes = "No monthly fee, so maintenance window is cheap."
        sofiOffer.createdAt = now
        sofiOffer.updatedAt = now

        let usBankOffer = Offer(context: context)
        usBankOffer.id = UUID()
        usBankOffer.bankName = "U.S. Bank"
        usBankOffer.offerTitle = "U.S. Bank Smartly Checking $450"
        usBankOffer.bonusAmount = NSDecimalNumber(string: "450.00")
        usBankOffer.requirements = "Two direct deposits totaling $8,000 within 90 days."
        usBankOffer.expirationDate = date(daysFromNow: 20)
        usBankOffer.eligibilityRestrictionMonths = NSNumber(value: 12)
        usBankOffer.minimumDeposit = NSDecimalNumber(string: "25.00")
        usBankOffer.directDepositRequired = true
        usBankOffer.monthsToMaintain = NSNumber(value: 3)
        usBankOffer.offerURL = "https://www.usbank.com/"
        usBankOffer.isActive = true
        usBankOffer.isFavorite = false
        usBankOffer.createdAt = now
        usBankOffer.updatedAt = now

        // MARK: Accounts

        // Bonus already posted, now just waiting out the fee-free window.
        let chase = Account(context: context)
        chase.id = UUID()
        chase.bankName = "Chase"
        chase.accountType = AccountType.checking.rawValue
        chase.openingDate = date(daysFromNow: -120)
        chase.bonusAmount = NSDecimalNumber(string: "300.00")
        chase.bonusStructure = BonusStructure.lumpSum.rawValue
        chase.bonusRequirements = "One direct deposit of $500+ within 90 days."
        chase.minimumBalance = NSDecimalNumber(string: "0")
        chase.expectedBonusDate = date(daysFromNow: -30)
        chase.actualBonusDate = date(daysFromNow: -28)
        chase.accountStatus = AccountStatus.maintaining.rawValue
        chase.eligibilityMonths = 24
        chase.accountNumberLast4 = "4412"
        chase.notes = "$12/mo fee waived with the DD — keep one paycheck routed here."
        chase.isArchived = false
        chase.createdAt = now
        chase.updatedAt = now
        chase.person = alex

        // Open and actively working toward requirements.
        let sofi = Account(context: context)
        sofi.id = UUID()
        sofi.bankName = "SoFi"
        sofi.accountType = AccountType.checking.rawValue
        sofi.openingDate = date(daysFromNow: -14)
        sofi.bonusAmount = NSDecimalNumber(string: "300.00")
        sofi.bonusStructure = BonusStructure.tiered.rawValue
        sofi.bonusRequirements = "$5,000 in direct deposits within 25 days for the full $300."
        sofi.expectedBonusDate = date(daysFromNow: 21)
        sofi.accountStatus = AccountStatus.open.rawValue
        sofi.eligibilityMonths = 24
        sofi.accountNumberLast4 = "9087"
        sofi.isArchived = false
        sofi.createdAt = now
        sofi.updatedAt = now
        sofi.person = alex
        sofi.offer = sofiOffer

        // Already finished and closed — feeds all-time earnings.
        let citi = Account(context: context)
        citi.id = UUID()
        citi.bankName = "Citi"
        citi.accountType = AccountType.savings.rawValue
        citi.openingDate = date(daysFromNow: -400)
        citi.bonusAmount = NSDecimalNumber(string: "200.00")
        citi.bonusStructure = BonusStructure.lumpSum.rawValue
        citi.bonusRequirements = "Maintain $10,000 for 60 days."
        citi.minimumBalance = NSDecimalNumber(string: "10000.00")
        citi.expectedBonusDate = date(daysFromNow: -320)
        citi.actualBonusDate = date(daysFromNow: -315)
        citi.accountStatus = AccountStatus.closed.rawValue
        citi.closedDate = date(daysFromNow: -250)
        citi.eligibilityMonths = 12
        citi.isArchived = false
        citi.createdAt = now
        citi.updatedAt = now
        citi.person = jordan

        // Not opened yet — being evaluated against an offer.
        let usBank = Account(context: context)
        usBank.id = UUID()
        usBank.bankName = "U.S. Bank"
        usBank.accountType = AccountType.checking.rawValue
        usBank.openingDate = date(daysFromNow: 7)
        usBank.bonusAmount = NSDecimalNumber(string: "450.00")
        usBank.bonusStructure = BonusStructure.recurring.rawValue
        usBank.bonusRequirements = "Two direct deposits totaling $8,000 within 90 days."
        usBank.expectedBonusDate = date(daysFromNow: 100)
        usBank.accountStatus = AccountStatus.prospecting.rawValue
        usBank.eligibilityMonths = 12
        usBank.notes = "Waiting on Jordan's DD slot to free up."
        usBank.isArchived = false
        usBank.createdAt = now
        usBank.updatedAt = now
        usBank.person = jordan
        usBank.offer = usBankOffer

        // MARK: Direct deposits

        let dd1 = DirectDeposit(context: context)
        dd1.id = UUID()
        dd1.scheduledDate = date(daysFromNow: -9)
        dd1.amount = NSDecimalNumber(string: "2400.00")
        dd1.status = DirectDepositStatus.posted.rawValue
        dd1.sequenceNumberInSeries = 1
        dd1.isFirstToBank = true
        dd1.notes = "First DD to SoFi — confirmed it posted as a real ACH payroll credit."
        dd1.createdAt = now
        dd1.updatedAt = now
        dd1.account = sofi
        dd1.person = alex

        let dd2 = DirectDeposit(context: context)
        dd2.id = UUID()
        dd2.scheduledDate = date(daysFromNow: 5)
        dd2.amount = NSDecimalNumber(string: "2400.00")
        dd2.status = DirectDepositStatus.scheduled.rawValue
        dd2.sequenceNumberInSeries = 2
        dd2.isFirstToBank = false
        dd2.createdAt = now
        dd2.updatedAt = now
        dd2.account = sofi
        dd2.person = alex

        let dd3 = DirectDeposit(context: context)
        dd3.id = UUID()
        dd3.scheduledDate = date(daysFromNow: -23)
        dd3.amount = NSDecimalNumber(string: "500.00")
        dd3.status = DirectDepositStatus.posted.rawValue
        dd3.sequenceNumberInSeries = 1
        dd3.isFirstToBank = true
        dd3.createdAt = now
        dd3.updatedAt = now
        dd3.account = chase
        dd3.person = alex

        let dd4 = DirectDeposit(context: context)
        dd4.id = UUID()
        dd4.scheduledDate = date(daysFromNow: 9)
        dd4.amount = NSDecimalNumber(string: "1875.50")
        dd4.status = DirectDepositStatus.scheduled.rawValue
        dd4.sequenceNumberInSeries = 1
        dd4.isFirstToBank = true
        dd4.createdAt = now
        dd4.updatedAt = now
        dd4.account = usBank
        dd4.person = jordan

        // MARK: Reminders

        let checkBonus = Reminder(context: context)
        checkBonus.id = UUID()
        checkBonus.title = "Check SoFi $300 bonus"
        checkBonus.reminderType = ReminderType.checkBonus.rawValue
        checkBonus.dueDate = date(daysFromNow: 21)
        checkBonus.isCompleted = false
        checkBonus.notes = "Should post within 5 business days of hitting $5k."
        checkBonus.isArchived = false
        checkBonus.createdAt = now
        checkBonus.account = sofi

        let closeChase = Reminder(context: context)
        closeChase.id = UUID()
        closeChase.title = "Close Chase checking"
        closeChase.reminderType = ReminderType.closeAccount.rawValue
        closeChase.dueDate = date(daysFromNow: 45)
        closeChase.isCompleted = false
        closeChase.notes = "6-month early-closure fee window ends first."
        closeChase.isArchived = false
        closeChase.createdAt = now
        closeChase.account = chase

        let movedDD = Reminder(context: context)
        movedDD.id = UUID()
        movedDD.title = "Update payroll to U.S. Bank"
        movedDD.reminderType = ReminderType.updateDirectDeposit.rawValue
        movedDD.dueDate = date(daysFromNow: 7)
        movedDD.isCompleted = true
        movedDD.completedDate = date(daysFromNow: -1)
        movedDD.isArchived = false
        movedDD.createdAt = now
        movedDD.account = usBank

        do {
            try context.save()
            return true
        } catch {
            assertionFailure("Failed to seed sample data: \(error)")
            return false
        }
    }
}
