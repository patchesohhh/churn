//
//  SettingsView.swift
//  ChurnApp
//
//  Root Settings screen: household earner (Person) management, a rollup
//  tax estimate, and the About row. Native grouped List/Form per CLAUDE.md's
//  "native elements over custom ones" rule — no custom card chrome here.
//

import CoreData
import SwiftUI

struct SettingsView: View {

    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Person.name, ascending: true)])
    private var people: FetchedResults<Person>

    /// Every non-archived account across both household earners — needed to
    /// compute the tax summary, which is a household-wide figure rather
    /// than a per-person one.
    @FetchRequest(
        sortDescriptors: [],
        predicate: NSPredicate(format: "isArchived == NO")
    )
    private var accounts: FetchedResults<Account>

    var body: some View {
        NavigationStack {
            List {
                peopleSection
                taxSummarySection
                aboutSection
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - People

    private var peopleSection: some View {
        Section {
            ForEach(people) { person in
                NavigationLink {
                    PersonSetupView(person: person)
                } label: {
                    PersonRow(person: person)
                }
            }

            NavigationLink {
                PersonSetupView(person: nil)
            } label: {
                Label("Add Person", systemImage: "person.badge.plus")
            }
        } header: {
            Text("People")
        } footer: {
            // Dual-income is the expected/seeded use case, but nothing here
            // hard-blocks a third row — see CLAUDE.md: Person has no
            // enforced cap. Simplicity over defensive UX.
            Text("Add each household earner whose paychecks fund your churning accounts — typically two for a dual-income household.")
        }
    }

    // MARK: - Tax summary

    private var taxSummarySection: some View {
        Section {
            HStack {
                Text("Estimated Tax Liability")
                Spacer()
                MoneyText(amount: estimatedTaxLiability, size: .medium, color: .orange)
            }
        } header: {
            Text("Tax Summary")
        } footer: {
            Text("A flat 25% of this year's posted bonuses, set aside as a rough estimate of what you'll owe — bank bonuses are taxable interest income. Not tax advice.")
        }
    }

    /// This year's posted-bonus earnings across every account for every
    /// person, run through `CalculationService`'s flat-rate estimate. A
    /// household-wide figure (not per-person) since the docs describe a
    /// single combined tax summary, not two separate ones.
    private var estimatedTaxLiability: Decimal {
        let earnings = CalculationService.ytdEarnings(accounts: Array(accounts))
        return CalculationService.estimatedTaxLiability(earnings: earnings)
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutView()
            } label: {
                Label("About Churn", systemImage: "info.circle")
            }
        }
    }
}

// MARK: - Person row

/// Name + pay frequency summary for a single household earner, tinted with
/// their `colorTag` so the two people are distinguishable at a glance —
/// same visual language the rest of the app uses for per-person context.
private struct PersonRow: View {

    let person: Person

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(swatchColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        var parts = [person.payFrequencyValue.displayName]
        if let bank = person.defaultBankName, !bank.isEmpty {
            parts.append(bank)
        }
        return parts.joined(separator: " · ")
    }

    private var swatchColor: Color {
        guard let name = person.colorTag else { return .accentColor }
        switch name {
        case "blue": return .blue
        case "purple": return .purple
        case "green": return .green
        case "orange": return .orange
        case "pink": return .pink
        case "teal": return .teal
        case "red": return .red
        case "indigo": return .indigo
        default: return .accentColor
        }
    }
}

// MARK: - Previews

#Preview("Populated") {
    SettingsView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}

#Preview("Empty") {
    SettingsView()
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
}

#Preview("Dark mode") {
    SettingsView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .preferredColorScheme(.dark)
}
