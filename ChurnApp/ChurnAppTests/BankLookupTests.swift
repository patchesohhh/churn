//
//  BankLookupTests.swift
//  ChurnAppTests
//
//  Covers `BankLookup.findOrCreate`, the find-or-create rule the `BankPicker`
//  component (Views/Components/BankPicker.swift) relies on: a case-insensitive
//  name match against existing `Bank` rows, creating a new row only when none
//  matches. Every test gets its own empty in-memory stack.
//

import CoreData
import XCTest
@testable import ChurnApp

@MainActor
final class BankLookupTests: XCTestCase {

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

    private func count(of entityName: String) throws -> Int {
        try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entityName))
    }

    func testFindOrCreate_noExistingBank_createsANewRow() throws {
        let bank = BankLookup.findOrCreate(name: "Chase", in: context)
        try context.save()

        XCTAssertEqual(bank.name, "Chase")
        XCTAssertEqual(try count(of: "Bank"), 1)
    }

    func testFindOrCreate_exactNameMatch_returnsExistingRowRatherThanCreating() throws {
        let first = BankLookup.findOrCreate(name: "SoFi", in: context)
        try context.save()

        let second = BankLookup.findOrCreate(name: "SoFi", in: context)

        XCTAssertEqual(first.objectID, second.objectID)
        XCTAssertEqual(try count(of: "Bank"), 1)
    }

    /// The whole point of the case-insensitive match: "chase", "CHASE" and
    /// "Chase" must all resolve to one row, not three.
    func testFindOrCreate_caseInsensitiveMatch_returnsExistingRow() throws {
        let original = BankLookup.findOrCreate(name: "Chase", in: context)
        try context.save()

        let lower = BankLookup.findOrCreate(name: "chase", in: context)
        let upper = BankLookup.findOrCreate(name: "CHASE", in: context)

        XCTAssertEqual(lower.objectID, original.objectID)
        XCTAssertEqual(upper.objectID, original.objectID)
        XCTAssertEqual(try count(of: "Bank"), 1)
    }

    /// A match preserves the original row's casing — matching is
    /// case-insensitive, but the first-typed display name isn't overwritten.
    func testFindOrCreate_caseInsensitiveMatch_preservesOriginalCasing() throws {
        BankLookup.findOrCreate(name: "Wells Fargo", in: context)
        try context.save()

        let match = BankLookup.findOrCreate(name: "WELLS FARGO", in: context)

        XCTAssertEqual(match.name, "Wells Fargo")
    }

    func testFindOrCreate_differentNames_createSeparateRows() throws {
        BankLookup.findOrCreate(name: "Chase", in: context)
        BankLookup.findOrCreate(name: "Ally", in: context)
        try context.save()

        XCTAssertEqual(try count(of: "Bank"), 2)
    }

    func testFindOrCreate_trimsWhitespaceBeforeMatchingAndStoring() throws {
        let original = BankLookup.findOrCreate(name: "Discover", in: context)
        try context.save()

        let match = BankLookup.findOrCreate(name: "  Discover  ", in: context)

        XCTAssertEqual(match.objectID, original.objectID)
        XCTAssertEqual(try count(of: "Bank"), 1)
    }

    func testFindOrCreate_newRow_getsAnIdAndCreatedAt() {
        let bank = BankLookup.findOrCreate(name: "US Bank", in: context)

        XCTAssertNotNil(bank.id)
        XCTAssertNotNil(bank.createdAt)
    }
}
