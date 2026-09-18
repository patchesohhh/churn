//
//  AccountsListView.swift
//  ChurnApp
//
//  The Accounts tab: every non-archived Account, sorted so the accounts
//  that still need attention float to the top. Fetches directly via
//  @FetchRequest per CLAUDE.md's hybrid architecture — no store layer for
//  list data.
//
//  Round 3: gained filtering (status / owner / opening-year) and sorting
//  (opening date / finish date / reward amount / person). Introducing a
//  user-chosen sort supersedes round 1's fixed "group by status, newest
//  first" layout — with a sort active the list reads oddly split across
//  status sections, so the list is now a single sorted/filtered stream with
//  each row's status still visible via `AccountCard`'s badge. Default state
//  (no filters, sort = Opening Date) preserves the old newest-first
//  ordering, just without the status section headers.
//

import CoreData
import SwiftUI

struct AccountsListView: View {

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Account.openingDate, ascending: false)],
        predicate: NSPredicate(format: "isArchived == NO")
    )
    private var accounts: FetchedResults<Account>

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Person.name, ascending: true)])
    private var people: FetchedResults<Person>

    @Environment(\.managedObjectContext) private var viewContext

    @State private var isPresentingAddAccount = false
    @State private var accountPendingDeletion: Account?

    // MARK: - Filter/sort state

    /// Empty set means "no status filter" (show every status) — an explicit
    /// "all" sentinel would need to stay in sync with `AccountStatus`, this
    /// doesn't.
    @State private var selectedStatuses: Set<AccountStatus>
    @State private var selectedPersonID: NSManagedObjectID?
    @State private var selectedYear: Int?
    @State private var sortOption: SortOption = .openingDate

    /// Filters default to "show everything" for normal use. The optional
    /// presets exist only so the "no matching accounts" `#Preview` below can
    /// land directly on the empty-filtered state without a human driving
    /// the menu — not meant as caller-facing configuration.
    init(initialStatuses: Set<AccountStatus> = [], initialYear: Int? = nil) {
        _selectedStatuses = State(initialValue: initialStatuses)
        _selectedYear = State(initialValue: initialYear)
    }

    /// Sort criteria, all ascending — see CLAUDE.md round 3: opening date,
    /// "finish date" (expected bonus date; documented choice — see
    /// `AccountsListView.SortOption.finishDate`'s doc comment), reward
    /// amount, and person (by name).
    enum SortOption: String, CaseIterable, Identifiable {
        case openingDate
        case finishDate
        case rewardAmount
        case person

        var id: Self { self }

        var displayName: String {
            switch self {
            case .openingDate: "Opening Date"
            case .finishDate: "Finish Date"
            case .rewardAmount: "Reward Amount"
            case .person: "Person"
            }
        }

        var systemImageName: String {
            switch self {
            case .openingDate: "calendar"
            case .finishDate: "flag.checkered"
            case .rewardAmount: "dollarsign.circle"
            case .person: "person"
            }
        }
    }

    /// Every calendar year that appears in some account's `openingDate`,
    /// newest first — the year filter's option list. Derived from the raw
    /// fetch (not the filtered result) so picking a year never removes
    /// itself from the menu.
    private var availableYears: [Int] {
        let years = Set(accounts.map { Calendar.current.component(.year, from: $0.openingDate) })
        return years.sorted(by: >)
    }

    /// Filtered, then sorted. Filtering first keeps the sort comparator
    /// simple (no need to think about which rows are excluded).
    private var displayedAccounts: [Account] {
        let filtered = accounts.filter { account in
            if !selectedStatuses.isEmpty, !selectedStatuses.contains(account.accountStatusValue) {
                return false
            }
            if let selectedPersonID, account.person?.objectID != selectedPersonID {
                return false
            }
            if let selectedYear, Calendar.current.component(.year, from: account.openingDate) != selectedYear {
                return false
            }
            return true
        }

        switch sortOption {
        case .openingDate:
            // Round 5: was ascending (oldest first), which sank a
            // brand-new account (today's `openingDate`) to the bottom of
            // the list — the opposite of what a user expects right after
            // creating one, and the opposite of this file's header comment
            // ("accounts that need attention float to the top"). Newest
            // first instead.
            return filtered.sorted { $0.openingDate > $1.openingDate }
        case .finishDate:
            // Documented choice (CLAUDE.md leaves this to the implementer):
            // "finish date" = `expectedBonusDate`, falling back to
            // `actualBonusDate` when no expected date was ever set. Accounts
            // with neither (e.g. non-churn home accounts) sort last, since
            // there's no finish line to rank them by.
            return filtered.sorted { finishDate(for: $0) ?? .distantFuture < finishDate(for: $1) ?? .distantFuture }
        case .rewardAmount:
            return filtered.sorted { $0.bonusAmountDecimal < $1.bonusAmountDecimal }
        case .person:
            return filtered.sorted { ($0.person?.name ?? "") < ($1.person?.name ?? "") }
        }
    }

    private func finishDate(for account: Account) -> Date? {
        account.expectedBonusDate ?? account.actualBonusDate
    }

    @Environment(AppTabSelection.self) private var tabSelection

    var body: some View {
        @Bindable var tabSelection = tabSelection

        NavigationStack(path: $tabSelection.accountsPath) {
            Group {
                if accounts.isEmpty {
                    EmptyStateView(
                        systemImageName: "banknote",
                        title: "No Accounts Yet",
                        message: "Add a bank account to start tracking a bonus.",
                        actionTitle: "Add Account"
                    ) {
                        isPresentingAddAccount = true
                    }
                } else if displayedAccounts.isEmpty {
                    EmptyStateView(
                        systemImageName: "line.3.horizontal.decrease.circle",
                        title: "No Matching Accounts",
                        message: "No accounts match the current filters.",
                        actionTitle: "Clear Filters"
                    ) {
                        clearFilters()
                    }
                } else {
                    List {
                        ForEach(displayedAccounts, id: \.id) { account in
                            NavigationLink(value: account) {
                                AccountCard(account: account, showProgress: true)
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    accountPendingDeletion = account
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    archive(account)
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(.gray)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Accounts")
            .navigationDestination(for: Account.self) { account in
                AccountDetailView(account: account)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresentingAddAccount = true
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    sortMenu
                }
                ToolbarItem(placement: .secondaryAction) {
                    filterMenu
                }
            }
            .sheet(isPresented: $isPresentingAddAccount) {
                AddEditAccountView(account: nil)
            }
            .confirmationDialog(
                "Delete this account?",
                isPresented: Binding(
                    get: { accountPendingDeletion != nil },
                    set: { if !$0 { accountPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let account = accountPendingDeletion {
                        delete(account)
                    }
                    accountPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    accountPendingDeletion = nil
                }
            } message: {
                Text("This permanently removes the account and its reminders/deposits. This can't be undone.")
            }
        }
    }

    // MARK: - Sort/filter menus

    /// Menu with a checkmark-style selection, per CLAUDE.md's "native
    /// elements" preference — no custom picker UI.
    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sortOption) {
                ForEach(SortOption.allCases) { option in
                    Label(option.displayName, systemImage: option.systemImageName).tag(option)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }

    /// A `Menu` with toggles rather than a `.sheet` form — the three filter
    /// axes (status/person/year) are small enough that a menu stays quick to
    /// use without the overhead of a whole separate screen.
    private var filterMenu: some View {
        Menu {
            Menu("Status") {
                ForEach(AccountStatus.allCases) { status in
                    Toggle(status.displayName, isOn: statusBinding(status))
                }
            }

            Menu("Person") {
                Button {
                    selectedPersonID = nil
                } label: {
                    checkmarkLabel("All People", isSelected: selectedPersonID == nil)
                }
                ForEach(people, id: \.objectID) { person in
                    Button {
                        selectedPersonID = person.objectID
                    } label: {
                        checkmarkLabel(person.name, isSelected: selectedPersonID == person.objectID)
                    }
                }
            }

            Menu("Opened In") {
                Button {
                    selectedYear = nil
                } label: {
                    checkmarkLabel("Every Year", isSelected: selectedYear == nil)
                }
                ForEach(availableYears, id: \.self) { year in
                    Button {
                        selectedYear = year
                    } label: {
                        checkmarkLabel(String(year), isSelected: selectedYear == year)
                    }
                }
            }

            if hasActiveFilters {
                Divider()
                Button("Clear Filters", role: .destructive) {
                    clearFilters()
                }
            }
        } label: {
            Label(
                "Filter",
                systemImage: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
            )
        }
    }

    /// `Label` requires a real SF Symbol name — there's no "no symbol"
    /// value — so the unselected state uses a plain `Text` instead of a
    /// `Label` with an empty/invalid `systemImage`.
    @ViewBuilder
    private func checkmarkLabel(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var hasActiveFilters: Bool {
        !selectedStatuses.isEmpty || selectedPersonID != nil || selectedYear != nil
    }

    private func statusBinding(_ status: AccountStatus) -> Binding<Bool> {
        Binding(
            get: { selectedStatuses.contains(status) },
            set: { isOn in
                if isOn {
                    selectedStatuses.insert(status)
                } else {
                    selectedStatuses.remove(status)
                }
            }
        )
    }

    private func clearFilters() {
        selectedStatuses = []
        selectedPersonID = nil
        selectedYear = nil
    }

    // MARK: - Actions

    /// Soft-delete: keeps the account (and its history) around but hides it
    /// from active lists — see CLAUDE.md's `isArchived` note.
    private func archive(_ account: Account) {
        account.isArchived = true
        account.updatedAt = Date()
        save()
    }

    /// Hard delete — cascades to the account's reminders and direct
    /// deposits per the Core Data model's delete rules.
    private func delete(_ account: Account) {
        viewContext.delete(account)
        save()
    }

    /// Saves the *injected* context (which may be the live store or a
    /// preview/test in-memory one) rather than always reaching for
    /// `PersistenceController.shared`, so this view behaves correctly in
    /// previews and tests, not just the running app.
    private func save() {
        do {
            try viewContext.save()
        } catch {
            assertionFailure("Failed to save Core Data context: \(error)")
        }
    }
}

// MARK: - Previews

#Preview("Populated") {
    AccountsListView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environment(AppTabSelection())
}

#Preview("Empty") {
    AccountsListView()
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
        .environment(AppTabSelection())
}

#Preview("Filtered to no matches") {
    // Exercises the "No Matching Accounts" empty state: no seeded sample
    // account opened in 1999, so this preset filter lands directly on it.
    AccountsListView(initialYear: 1999)
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environment(AppTabSelection())
}

#Preview("Dark mode") {
    AccountsListView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environment(AppTabSelection())
        .preferredColorScheme(.dark)
}
