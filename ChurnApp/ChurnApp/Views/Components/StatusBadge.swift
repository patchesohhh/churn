//
//  StatusBadge.swift
//  ChurnApp
//
//  Small pill/capsule showing an account (or generic) status. Used on
//  AccountCard, the Accounts list, and anywhere else a status needs a quick
//  glance-able color + label instead of plain text.
//

import CoreData
import SwiftUI

/// Status pill driven by `AccountStatus`'s own `displayName`/`color`
/// (see `Models/Enums.swift`) so every screen that shows account status
/// stays visually and textually in sync automatically.
struct StatusBadge: View {

    let status: AccountStatus

    var body: some View {
        Label(status.displayName, systemImage: symbolName)
            .font(.caption.weight(.semibold))
            .labelStyle(.titleOnly)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            // `.regularMaterial` behind a tinted foreground reads as a native
            // "capsule chip" the way system badges do (e.g. Mail's unread
            // pill), rather than a hand-painted colored rectangle — it also
            // adapts automatically to light/dark without a second color set.
            .background(status.color.opacity(0.15), in: Capsule())
            .foregroundStyle(status.color)
            .overlay(
                Capsule().strokeBorder(status.color.opacity(0.35), lineWidth: 0.5)
            )
    }

    /// A tiny status dot conveys "state" faster than reading text; picked
    /// per-status rather than reusing AccountType/ReminderType's symbols
    /// since none of those map to lifecycle state.
    private var symbolName: String {
        switch status {
        case .prospecting: "circle.dashed"
        case .open: "circle.fill"
        case .maintaining: "clock.fill"
        case .closed: "checkmark.circle.fill"
        }
    }
}

/// Generic variant for status strings that aren't backed by `AccountStatus`
/// (e.g. a future "offer active/expired" badge). Kept separate rather than
/// making `StatusBadge` take a raw `(String, Color)` everywhere, so the
/// common `AccountStatus` call sites stay terse and type-safe.
struct GenericStatusBadge: View {
    let text: String
    let color: Color
    var systemImageName: String? = nil

    var body: some View {
        Group {
            if let systemImageName {
                Label(text, systemImage: systemImageName).labelStyle(.titleOnly)
            } else {
                Text(text)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
        .overlay(
            Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5)
        )
    }
}

// MARK: - Previews

#Preview("All statuses") {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(AccountStatus.allCases) { status in
            StatusBadge(status: status)
        }
    }
    .padding()
}

#Preview("In a row, real accounts") {
    let context = PersistenceController.preview.container.viewContext
    let accounts = (try? context.fetch(Account.fetchRequest())) ?? []

    return VStack(alignment: .leading, spacing: 10) {
        ForEach(accounts, id: \.id) { account in
            HStack {
                Text(account.bankName)
                Spacer()
                StatusBadge(status: account.accountStatusValue)
            }
        }
    }
    .padding()
}

#Preview("Generic status badge") {
    HStack {
        GenericStatusBadge(text: "Expiring Soon", color: .orange, systemImageName: "exclamationmark.triangle.fill")
        GenericStatusBadge(text: "Favorite", color: .pink, systemImageName: "star.fill")
    }
    .padding()
}

#Preview("Dark mode") {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(AccountStatus.allCases) { status in
            StatusBadge(status: status)
        }
    }
    .padding()
    .preferredColorScheme(.dark)
}
