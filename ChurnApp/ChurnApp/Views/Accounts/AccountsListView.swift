//
//  AccountsListView.swift
//  ChurnApp
//
//  The Accounts tab: every non-archived Account, sorted so the accounts
//  that still need attention float to the top. Fetches directly via
//  @FetchRequest per CLAUDE.md's hybrid architecture — no store layer for
//  list data.
//

import CoreData
import SwiftUI

struct AccountsListView: View {

    // Sort choice: status first (prospecting/open need action, maintaining
    // is just waiting, closed is inert history), then most-recently-opened
    // within a status group. NSSortDescriptor can't sort by an enum's
    // "logical" order directly (it would sort alphabetically: closed,
    // maintaining, open, prospecting — wrong), so this fetch sorts by
    // `openingDate` only and the view groups/orders sections by status
    // itself below.
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Account.openingDate, ascending: false)],
        predicate: NSPredicate(format: "isArchived == NO")
    )
    private var accounts: FetchedResults<Account>

    @Environment(\.managedObjectContext) private var viewContext

    @State private var isPresentingAddAccount = false
    @State private var accountPendingDeletion: Account?

    /// Status display order: things that still need attention first, then
    /// "just waiting", then done. Matches AccountStatus's own lifecycle
    /// narrative rather than declaration order.
    private let statusOrder: [AccountStatus] = [.prospecting, .open, .maintaining, .closed]

    var body: some View {
        NavigationStack {
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
                } else {
                    List {
                        ForEach(statusOrder) { status in
                            let group = accounts.filter { $0.accountStatusValue == status }
                            if !group.isEmpty {
                                Section {
                                    ForEach(group, id: \.id) { account in
                                        NavigationLink(value: account) {
                                            AccountCard(account: account)
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
                                } header: {
                                    Text(status.displayName)
                                }
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
}

#Preview("Empty") {
    AccountsListView()
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
}

#Preview("Dark mode") {
    AccountsListView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .preferredColorScheme(.dark)
}
