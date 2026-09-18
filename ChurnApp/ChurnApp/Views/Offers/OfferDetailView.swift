//
//  OfferDetailView.swift
//  ChurnApp
//
//  Full read view for a single manually-entered offer. Edit routes to
//  AddEditOfferView(offer:) in edit mode; delete pops back to the list.
//

import CoreData
import SwiftUI

struct OfferDetailView: View {

    @ObservedObject var offer: Offer

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var isPresentingEdit = false
    @State private var isPresentingDeleteConfirmation = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(offer.bankName)
                        .font(.title3.weight(.semibold))
                    // Optional title (round 3) — falls back to the bank name.
                    Text(offer.displayTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    MoneyText(amount: offer.bonusAmountDecimal, size: .large, color: .green)
                        .padding(.top, 4)

                    HStack(spacing: 8) {
                        if offer.isFavorite {
                            GenericStatusBadge(text: "Favorite", color: .pink, systemImageName: "star.fill")
                        }
                        GenericStatusBadge(
                            text: offer.isActive ? "Active" : "Inactive",
                            color: offer.isActive ? .green : .gray,
                            systemImageName: offer.isActive ? "checkmark.circle.fill" : "pause.circle.fill"
                        )
                        if offer.isExpired {
                            GenericStatusBadge(text: "Expired", color: .red, systemImageName: "xmark.circle.fill")
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }

            Section("Requirements") {
                Text(offer.requirements)
                    .font(.body)
            }

            Section("Terms") {
                if let expirationDate = offer.expirationDate {
                    LabeledContent("Expires") {
                        Text(expirationDate, style: .date)
                    }
                }
                if let months = offer.eligibilityRestrictionMonths?.int16Value {
                    LabeledContent("Eligibility Restriction", value: "\(months) mo")
                }
                if let months = offer.monthsToMaintain?.int16Value {
                    LabeledContent("Must Maintain", value: "\(months) mo")
                }
                if let minimumDeposit = offer.minimumDeposit?.decimalValue {
                    LabeledContent("Minimum Deposit") {
                        MoneyText(amount: minimumDeposit, size: .small)
                    }
                }
                LabeledContent("Direct Deposit Required", value: offer.directDepositRequired ? "Yes" : "No")
            }

            if let offerURLString = offer.offerURL, let url = URL(string: offerURLString) {
                Section {
                    Link(destination: url) {
                        Label("View Offer", systemImage: "safari")
                    }
                }
            }

            if let notes = offer.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes)
                }
            }

            if !offer.accountsArray.isEmpty {
                Section("Accounts Opened From This Offer") {
                    ForEach(offer.accountsArray) { account in
                        HStack {
                            Text(account.bankName)
                            Spacer()
                            StatusBadge(status: account.accountStatusValue)
                        }
                    }
                }
            }
        }
        .navigationTitle(offer.bankName)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        offer.isFavorite.toggle()
                        offer.updatedAt = Date()
                        PersistenceController.shared.saveContext()
                    } label: {
                        Label(offer.isFavorite ? "Unfavorite" : "Favorite", systemImage: offer.isFavorite ? "star.slash" : "star.fill")
                    }
                    Button {
                        offer.isActive.toggle()
                        offer.updatedAt = Date()
                        PersistenceController.shared.saveContext()
                    } label: {
                        Label(offer.isActive ? "Mark Inactive" : "Mark Active", systemImage: offer.isActive ? "pause.circle" : "checkmark.circle")
                    }
                    Button {
                        isPresentingEdit = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        isPresentingDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isPresentingEdit) {
            AddEditOfferView(offer: offer)
        }
        .confirmationDialog(
            "Delete this offer?",
            isPresented: $isPresentingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                viewContext.delete(offer)
                PersistenceController.shared.saveContext()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Previews

#Preview("Favorited offer") {
    let context = PersistenceController.preview.container.viewContext
    let offer = (try? context.fetch(Offer.fetchRequest()))?.first { $0.isFavorite } ?? Offer(context: context)

    return NavigationStack {
        OfferDetailView(offer: offer)
    }
}

#Preview("Expiring-soon offer") {
    let context = PersistenceController.preview.container.viewContext
    let offer = (try? context.fetch(Offer.fetchRequest()))?.first { !$0.isFavorite } ?? Offer(context: context)

    return NavigationStack {
        OfferDetailView(offer: offer)
    }
}

#Preview("Dark mode") {
    let context = PersistenceController.preview.container.viewContext
    let offer = (try? context.fetch(Offer.fetchRequest()))?.first ?? Offer(context: context)

    return NavigationStack {
        OfferDetailView(offer: offer)
    }
    .preferredColorScheme(.dark)
}
