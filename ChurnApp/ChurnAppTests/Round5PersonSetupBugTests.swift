//
//  Round5PersonSetupBugTests.swift
//  ChurnAppTests
//
//  Covers the round-5 `PersonSetupView` bug reported from live device
//  testing: (1) "Set Up First Paycheck" opening a blank modal, and
//  (2) duplicate `Person` rows that appear "stuck" when the confirmation
//  dialog is dismissed by tapping outside it instead of choosing a button.
//
//  `PersonSetupView`'s relevant state (`savedPerson`,
//  `personForPaycheckSheet`, the Save button's `.disabled` guard) is
//  `private` — there's no ViewInspector or other third-party dependency in
//  this project (CLAUDE.md: Apple frameworks only) to drive a SwiftUI view's
//  internals directly, and no XCUITest/UI-automation target is configured,
//  so this file can't literally "tap" the button. What it *can* and does
//  prove, at the Core Data level the fix and the bug both ultimately rest
//  on:
//
//  1. `Person` conforms to `Identifiable` (`Models/Entities/Person.swift`),
//     which is the hard requirement for `.sheet(item:)` — the mechanism the
//     fix switches to specifically because it doesn't depend on the
//     confirmation dialog's own dismiss-driven `isPresented` binding, unlike
//     the old `.sheet(isPresented:) { if let savedPerson { ... } }`, which
//     could see `savedPerson` already nil'd out from under it. If `Person`
//     ever stopped conforming, `.sheet(item: $personForPaycheckSheet)` in
//     `PersonSetupView.swift` would fail to compile — so a green build of
//     that file is itself part of the evidence, not just "it compiles."
//  2. The "can't delete either duplicate" symptom is NOT an `isArchived`
//     soft-delete bug — two same-named `Person` rows (the shape a duplicate
//     save would leave behind) archive completely independently of one
//     another, each stays independently visible/invisible per the
//     `isArchived == NO` predicate used everywhere. This confirms the
//     CLAUDE.md round-5 diagnosis: fixing duplicate *creation* at the source
//     (disabling Save once `savedPerson != nil`, in `PersonSetupView.swift`)
//     is sufficient — no changes needed in the archive/delete code itself.
//
//  Every test gets its own empty in-memory stack — never the app's real
//  store.
//

import CoreData
import XCTest
@testable import ChurnApp

@MainActor
final class Round5PersonSetupBugTests: XCTestCase {

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

    // MARK: - Blank-modal bug: `.sheet(item:)` requires `Person: Identifiable`

    /// The fix moves the paycheck-setup sheet from
    /// `.sheet(isPresented:) { if let savedPerson { ... } }` (racy — the
    /// confirmation dialog's dismiss-driven binding could nil `savedPerson`
    /// first) to `.sheet(item: $personForPaycheckSheet) { person in ... }`,
    /// set directly and unconditionally from the button's own action. That
    /// API requires the item type to be `Identifiable` with a stable `id`
    /// across mutation, which this test pins down directly.
    func testPersonIsIdentifiableWithStableID() throws {
        let person = makePerson(name: "Alex")
        try context.save()

        let idBeforeEdit = person.id
        person.name = "Alex Updated"
        try context.save()

        XCTAssertEqual(person.id, idBeforeEdit, "Person.id must stay stable across edits for .sheet(item:) to track the same sheet identity.")
    }

    // MARK: - Duplicate-person bug: archiving duplicates works independently

    /// Simulates the *end state* a duplicate-save bug would leave behind
    /// (two same-named, unarchived `Person` rows from the same botched "add"
    /// session) and proves each is independently visible and independently
    /// archivable — i.e. the "can't delete either one" symptom reported
    /// alongside the duplicate-creation bug isn't a separate archive-logic
    /// bug to fix; it's just what two indistinguishable-looking rows feels
    /// like in the UI until the *creation* bug is fixed at its source.
    func testDuplicatePersonsArchiveIndependently() throws {
        let first = makePerson(name: "Jordan")
        let second = makePerson(name: "Jordan")
        try context.save()

        XCTAssertNotEqual(first.objectID, second.objectID, "Sanity: these must be two distinct rows, not the same object saved twice.")

        let activeBeforeArchive = try fetchActivePeople()
        XCTAssertEqual(activeBeforeArchive.count, 2, "Both duplicate rows should be visible/active before either is archived.")

        // Archive the first duplicate only.
        first.isArchived = true
        first.updatedAt = Date()
        try context.save()

        let activeAfterFirstArchive = try fetchActivePeople()
        XCTAssertEqual(activeAfterFirstArchive.count, 1, "Archiving one duplicate must not affect the other.")
        XCTAssertEqual(activeAfterFirstArchive.first?.objectID, second.objectID)

        // Archive the second duplicate too — proves it wasn't "stuck."
        second.isArchived = true
        second.updatedAt = Date()
        try context.save()

        let activeAfterBothArchived = try fetchActivePeople()
        XCTAssertTrue(activeAfterBothArchived.isEmpty, "Both duplicates must be independently archivable — neither is stuck.")
    }

    // MARK: - Helpers

    @discardableResult
    private func makePerson(name: String) -> Person {
        let person = Person(context: context)
        person.id = UUID()
        person.name = name
        person.payFrequencyValue = .biweekly
        person.paycheckAmountDecimal = 2000
        person.maxConcurrentDirectDeposits = 2
        person.colorTag = "blue"
        person.isArchived = false
        person.createdAt = Date()
        person.updatedAt = Date()
        return person
    }

    private func fetchActivePeople() throws -> [Person] {
        let request = Person.fetchRequest()
        request.predicate = NSPredicate(format: "isArchived == NO")
        return try context.fetch(request)
    }
}
