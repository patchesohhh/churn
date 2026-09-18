//
//  OffersListView.swift
//  ChurnApp
//
//  Offers tab root: every bank offer the user has manually entered (no
//  bundled JSON/API — see CLAUDE.md). Favorited offers surface first, then
//  active offers soonest-to-expire, so the offers actually worth acting on
//  land at the top without the user having to sort/filter anything.
//

import CoreData
import SwiftUI

struct OffersListView: View {

    // Favorites first, then soonest-expiring active offers, then everything
    // else alphabetically by bank — keeps "act on this soon" offers visible
    // without a separate filter UI.
    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Offer.isFavorite, ascending: false),
            NSSortDescriptor(keyPath: \Offer.isActive, ascending: false),
            NSSortDescriptor(keyPath: \Offer.expirationDate, ascending: true),
            NSSortDescriptor(keyPath: \Offer.bankName, ascending: true),
        ]
    )
    private var offers: FetchedResults<Offer>

    @Environment(\.managedObjectContext) private var viewContext

    @State private var isPresentingAddOffer = false

    var body: some View {
        NavigationStack {
            Group {
                if offers.isEmpty {
                    EmptyStateView(
                        systemImageName: "tag",
                        title: "No Offers Saved",
                        message: "Save a bank offer to track it before you apply.",
                        actionTitle: "Add Offer"
                    ) {
                        isPresentingAddOffer = true
                    }
                } else {
                    List {
                        ForEach(offers) { offer in
                            NavigationLink(value: offer) {
                                OfferRow(offer: offer)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    toggleFavorite(offer)
                                } label: {
                                    Label(
                                        offer.isFavorite ? "Unfavorite" : "Favorite",
                                        systemImage: offer.isFavorite ? "star.slash" : "star.fill"
                                    )
                                }
                                .tint(.yellow)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(offer)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Offers")
            .navigationDestination(for: Offer.self) { offer in
                OfferDetailView(offer: offer)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresentingAddOffer = true
                    } label: {
                        Label("Add Offer", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingAddOffer) {
                AddEditOfferView(offer: nil)
            }
        }
    }

    private func toggleFavorite(_ offer: Offer) {
        offer.isFavorite.toggle()
        offer.updatedAt = Date()
        PersistenceController.shared.saveContext()
    }

    private func delete(_ offer: Offer) {
        viewContext.delete(offer)
        PersistenceController.shared.saveContext()
    }
}

// MARK: - Row

/// One offer's summary line: bank/title, bonus, and an expiration badge when
/// relevant. Kept private to this file since nothing else needs a bare offer
/// row.
private struct OfferRow: View {

    let offer: Offer

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if offer.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                    }
                    Text(offer.bankName)
                        .font(.subheadline.weight(.semibold))
                }
                Text(offer.offerTitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let badge = expirationBadge {
                    badge
                } else if !offer.isActive {
                    GenericStatusBadge(text: "Inactive", color: .gray, systemImageName: "pause.circle.fill")
                }
            }

            Spacer()

            MoneyText(amount: offer.bonusAmountDecimal, size: .medium, color: .green)
        }
        .padding(.vertical, 4)
    }

    /// Orange inside two weeks, red once it's actually expired. Nil when
    /// there's no expiration date or it's comfortably far off — no badge
    /// clutter for offers that aren't time-pressured yet.
    private var expirationBadge: GenericStatusBadge? {
        guard offer.isActive, let expirationDate = offer.expirationDate else { return nil }
        let days = CalculationService.daysUntil(expirationDate)

        if days < 0 {
            return GenericStatusBadge(text: "Expired", color: .red, systemImageName: "xmark.circle.fill")
        } else if days <= 14 {
            return GenericStatusBadge(
                text: days == 0 ? "Expires today" : "Expires in \(days)d",
                color: .orange,
                systemImageName: "exclamationmark.triangle.fill"
            )
        }
        return nil
    }
}

// MARK: - Previews

#Preview("Populated") {
    OffersListView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}

#Preview("Empty") {
    OffersListView()
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
}

#Preview("Dark mode") {
    OffersListView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .preferredColorScheme(.dark)
}
