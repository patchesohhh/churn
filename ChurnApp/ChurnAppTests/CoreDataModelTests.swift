//
//  CoreDataModelTests.swift
//  ChurnAppTests
//
//  Exercises the Core Data schema itself: save/fetch round-trips for every
//  entity, the delete rules (which are easy to get wrong and expensive to fix
//  after data exists), and attribute-level validation.
//
//  Every test gets its own empty in-memory stack — never the app's real store.
//

import CoreData
import XCTest
@testable import ChurnApp

@MainActor
final class CoreDataModelTests: XCTestCase {

    private var controller: PersistenceController!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        controller = PersistenceController(inMemory: true)
        context = controller.viewContext
    }

    override func tearDown() {
        context = nil
        controller = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makePerson(name: String = "Alex") -> Person {
        let person = Person(context: context)
        person.id = UUID()
        person.name = name
        person.payFrequency = PayFrequency.biweekly.rawValue
        person.paycheckAmount = NSDecimalNumber(string: "2000.00")
        person.maxConcurrentDirectDeposits = 2
        person.createdAt = Date()
        person.updatedAt = Date()
        return person
    }

    private func makeAccount(bank: String = "Chase", bonus: String = "300.00") -> Account {
        let account = Account(context: context)
        account.id = UUID()
        account.bankName = bank
        account.accountType = AccountType.checking.rawValue
        account.openingDate = Date()
        account.bonusAmount = NSDecimalNumber(string: bonus)
        account.bonusStructure = BonusStructure.lumpSum.rawValue
        account.bonusRequirements = "One DD of $500+."
        account.accountStatus = AccountStatus.open.rawValue
        account.eligibilityMonths = 24
        account.isArchived = false
        account.createdAt = Date()
        account.updatedAt = Date()
        return account
    }

    private func makeReminder(for account: Account) -> Reminder {
        let reminder = Reminder(context: context)
        reminder.id = UUID()
        reminder.title = "Check bonus"
        reminder.reminderType = ReminderType.checkBonus.rawValue
        reminder.dueDate = Date().addingTimeInterval(86_400)
        reminder.isCompleted = false
        reminder.isArchived = false
        reminder.createdAt = Date()
        reminder.account = account
        return reminder
    }

    private func makeDirectDeposit(for account: Account, person: Person?) -> DirectDeposit {
        let deposit = DirectDeposit(context: context)
        deposit.id = UUID()
        deposit.scheduledDate = Date()
        deposit.amount = NSDecimalNumber(string: "1500.00")
        deposit.status = DirectDepositStatus.scheduled.rawValue
        deposit.sequenceNumberInSeries = 1
        deposit.isFirstToBank = true
        deposit.createdAt = Date()
        deposit.updatedAt = Date()
        deposit.account = account
        deposit.person = person
        return deposit
    }

    private func makeOffer() -> Offer {
        let offer = Offer(context: context)
        offer.id = UUID()
        offer.bankName = "SoFi"
        offer.offerTitle = "SoFi $300"
        offer.bonusAmount = NSDecimalNumber(string: "300.00")
        offer.requirements = "$5,000 in DDs."
        offer.directDepositRequired = true
        offer.isActive = true
        offer.isFavorite = false
        offer.createdAt = Date()
        offer.updatedAt = Date()
        return offer
    }

    private func count<T: NSManagedObject>(_ type: T.Type, _ entityName: String) throws -> Int {
        try context.count(for: NSFetchRequest<T>(entityName: entityName))
    }

    // MARK: - Round trips

    func testPersonRoundTrip() throws {
        let person = makePerson(name: "Jordan")
        person.colorTag = "purple"
        person.defaultBankName = "Ally"
        try context.save()

        let request = NSFetchRequest<Person>(entityName: "Person")
        request.predicate = NSPredicate(format: "name == %@", "Jordan")
        let fetched = try XCTUnwrap(context.fetch(request).first)

        XCTAssertEqual(fetched.name, "Jordan")
        XCTAssertEqual(fetched.payFrequency, PayFrequency.biweekly.rawValue)
        XCTAssertEqual(fetched.paycheckAmountDecimal, Decimal(string: "2000.00"))
        XCTAssertEqual(fetched.maxConcurrentDirectDeposits, 2)
        XCTAssertEqual(fetched.colorTag, "purple")
    }

    func testAccountRoundTripAndPersonRelationship() throws {
        let person = makePerson()
        let account = makeAccount(bank: "SoFi", bonus: "450.00")
        account.person = person
        try context.save()

        let fetched = try XCTUnwrap(context.fetch(NSFetchRequest<Account>(entityName: "Account")).first)
        XCTAssertEqual(fetched.bankName, "SoFi")
        XCTAssertEqual(fetched.bonusAmountDecimal, Decimal(string: "450.00"))
        XCTAssertEqual(fetched.person?.name, "Alex")
        // Inverse must be maintained automatically by Core Data.
        XCTAssertEqual(person.accounts?.count, 1)
    }

    func testDirectDepositRoundTrip() throws {
        let person = makePerson()
        let account = makeAccount()
        account.person = person
        let deposit = makeDirectDeposit(for: account, person: person)
        deposit.sequenceNumberInSeries = 3
        try context.save()

        let fetched = try XCTUnwrap(context.fetch(NSFetchRequest<DirectDeposit>(entityName: "DirectDeposit")).first)
        XCTAssertEqual(fetched.amountDecimal, Decimal(string: "1500.00"))
        XCTAssertEqual(fetched.sequenceNumberInSeries, 3)
        XCTAssertTrue(fetched.isFirstToBank)
        XCTAssertEqual(fetched.account?.bankName, "Chase")
        XCTAssertEqual(fetched.person?.name, "Alex")
    }

    func testReminderRoundTrip() throws {
        let account = makeAccount()
        let reminder = makeReminder(for: account)
        reminder.notificationIdentifier = "churn.reminder.abc"
        try context.save()

        let fetched = try XCTUnwrap(context.fetch(NSFetchRequest<Reminder>(entityName: "Reminder")).first)
        XCTAssertEqual(fetched.title, "Check bonus")
        XCTAssertEqual(fetched.reminderType, ReminderType.checkBonus.rawValue)
        XCTAssertEqual(fetched.notificationIdentifier, "churn.reminder.abc")
        XCTAssertFalse(fetched.isCompleted)
        XCTAssertEqual(fetched.account.bankName, "Chase")
    }

    func testOfferRoundTripAndAccountLink() throws {
        let offer = makeOffer()
        offer.eligibilityRestrictionMonths = NSNumber(value: 24)
        offer.monthsToMaintain = NSNumber(value: 3)
        offer.minimumDeposit = NSDecimalNumber(string: "25.00")
        let account = makeAccount()
        account.offer = offer
        try context.save()

        let fetched = try XCTUnwrap(context.fetch(NSFetchRequest<Offer>(entityName: "Offer")).first)
        XCTAssertEqual(fetched.offerTitle, "SoFi $300")
        XCTAssertEqual(fetched.eligibilityRestrictionMonths?.int16Value, 24)
        XCTAssertEqual(fetched.monthsToMaintain?.int16Value, 3)
        XCTAssertEqual(fetched.minimumDeposit, NSDecimalNumber(string: "25.00"))
        XCTAssertEqual(fetched.accounts?.count, 1)
    }

    // MARK: - Delete rules
    //
    // These encode the deliberate ownership model:
    //   Person  --cascade--> Account --cascade--> Reminder / DirectDeposit
    //   Offer   --nullify--> Account  (offers are reference data, they outlive
    //                                  any account opened from them)

    func testDeletingPersonCascadesToAccounts() throws {
        let person = makePerson()
        let account = makeAccount()
        account.person = person
        _ = makeAccount(bank: "Citi")
        try context.save()

        XCTAssertEqual(try count(Account.self, "Account"), 2)

        context.delete(person)
        try context.save()

        // Only the account owned by that person goes away.
        let remaining = try context.fetch(NSFetchRequest<Account>(entityName: "Account"))
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.bankName, "Citi")
    }

    func testDeletingPersonCascadesToDirectDeposits() throws {
        let person = makePerson()
        let account = makeAccount()
        account.person = person
        _ = makeDirectDeposit(for: account, person: person)
        try context.save()

        context.delete(person)
        try context.save()

        XCTAssertEqual(try count(DirectDeposit.self, "DirectDeposit"), 0)
    }

    func testDeletingAccountCascadesToRemindersAndDirectDepositsButNotOffer() throws {
        let person = makePerson()
        let offer = makeOffer()
        let account = makeAccount()
        account.person = person
        account.offer = offer
        _ = makeReminder(for: account)
        _ = makeDirectDeposit(for: account, person: person)
        try context.save()

        XCTAssertEqual(try count(Reminder.self, "Reminder"), 1)
        XCTAssertEqual(try count(DirectDeposit.self, "DirectDeposit"), 1)

        context.delete(account)
        try context.save()

        XCTAssertEqual(try count(Reminder.self, "Reminder"), 0, "Reminders are owned by their account.")
        XCTAssertEqual(try count(DirectDeposit.self, "DirectDeposit"), 0, "Direct deposits are owned by their account.")
        XCTAssertEqual(try count(Offer.self, "Offer"), 1, "Offers are reference data and must survive.")
        XCTAssertEqual(try count(Person.self, "Person"), 1, "Deleting an account must not delete its owner.")
        XCTAssertEqual(offer.accounts?.count ?? 0, 0, "Offer's inverse should be nullified.")
    }

    func testDeletingOfferNullifiesAccountLink() throws {
        let offer = makeOffer()
        let account = makeAccount()
        account.offer = offer
        try context.save()

        context.delete(offer)
        try context.save()

        XCTAssertEqual(try count(Account.self, "Account"), 1, "Deleting an offer must not delete the account.")
        XCTAssertNil(account.offer)
    }

    func testDeletingDirectDepositDoesNotDeleteAccountOrPerson() throws {
        let person = makePerson()
        let account = makeAccount()
        account.person = person
        let deposit = makeDirectDeposit(for: account, person: person)
        try context.save()

        context.delete(deposit)
        try context.save()

        XCTAssertEqual(try count(Account.self, "Account"), 1)
        XCTAssertEqual(try count(Person.self, "Person"), 1)
    }

    /// The source docs described `Reminder.account` as a *cascade* to-one,
    /// which would delete the whole account whenever a reminder was dismissed.
    /// This build uses nullify on that side instead; the cascade lives on
    /// `Account.reminders`. This test locks that decision in.
    func testDeletingReminderDoesNotDeleteAccount() throws {
        let account = makeAccount()
        let reminder = makeReminder(for: account)
        try context.save()

        context.delete(reminder)
        try context.save()

        XCTAssertEqual(try count(Account.self, "Account"), 1)
    }

    // MARK: - Validation

    /// `Account.bonusAmount` has a model-level minimum of 0, so a negative
    /// bonus is rejected at save time. (Core Data truncates fractional bounds
    /// on Decimal attributes, so a strict "> 0" rule can't live in the model;
    /// entry forms enforce that.)
    func testAccountRejectsNegativeBonusAmount() {
        let account = makeAccount()
        account.bonusAmount = NSDecimalNumber(string: "-5.00")

        XCTAssertThrowsError(try context.save()) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSCocoaErrorDomain)
            XCTAssertEqual(nsError.code, NSValidationNumberTooSmallError)
        }
        context.rollback()
    }

    /// `Account.eligibilityMonths` is capped at 24 — the longest restriction
    /// window any real offer uses.
    func testAccountRejectsOutOfRangeEligibilityMonths() {
        let account = makeAccount()
        account.eligibilityMonths = 48

        XCTAssertThrowsError(try context.save()) { error in
            XCTAssertEqual((error as NSError).code, NSValidationNumberTooLargeError)
        }
        context.rollback()
    }

    /// A `Reminder` is meaningless without the account it refers to, so the
    /// relationship is required at the model level.
    func testReminderRequiresAnAccount() {
        let reminder = Reminder(context: context)
        reminder.id = UUID()
        reminder.title = "Orphan"
        reminder.reminderType = ReminderType.custom.rawValue
        reminder.dueDate = Date()
        reminder.isCompleted = false
        reminder.isArchived = false
        reminder.createdAt = Date()

        XCTAssertThrowsError(try context.save()) { error in
            // A required to-one relationship reports as a missing mandatory property.
            XCTAssertEqual((error as NSError).code, NSValidationMissingMandatoryPropertyError)
        }
        context.rollback()
    }

    /// Non-optional string attributes must actually be set before saving.
    func testAccountRequiresBankName() {
        let account = makeAccount()
        account.setValue(nil, forKey: "bankName")

        XCTAssertThrowsError(try context.save()) { error in
            XCTAssertEqual((error as NSError).code, NSValidationMissingMandatoryPropertyError)
        }
        context.rollback()
    }

    // MARK: - Save helper

    func testSaveContextHelperIsANoOpWithoutChanges() throws {
        XCTAssertFalse(context.hasChanges)
        XCTAssertNoThrow(try controller.saveContextThrowing())
    }

    func testSampleDataPopulatesAnArbitraryContext() throws {
        XCTAssertTrue(SampleData.populate(in: context))
        XCTAssertEqual(try count(Person.self, "Person"), 2)
        // Five as of round 3: the four status-per-account rows plus the
        // non-churn joint savings home account.
        XCTAssertEqual(try count(Account.self, "Account"), 5)
    }
}
