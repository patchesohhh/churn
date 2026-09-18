//
//  EmptyStateView.swift
//  ChurnApp
//
//  Icon + title + message (+ optional action) for empty lists — "no
//  accounts yet", "no reminders", "no offers saved". Reused across every
//  list-based tab so empty states look and behave identically app-wide.
//

import SwiftUI

struct EmptyStateView: View {

    let systemImageName: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        // `ContentUnavailableView` is the system-native way to express this
        // exact pattern (icon/title/description/action) and gets free
        // platform-consistent spacing and Dynamic Type behavior — building
        // this on top of it rather than a hand-rolled VStack is the
        // "native elements over custom ones" rule from CLAUDE.md in action.
        if let actionTitle, let action {
            ContentUnavailableView {
                Label(title, systemImage: systemImageName)
            } description: {
                Text(message)
            } actions: {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label(title, systemImage: systemImageName)
            } description: {
                Text(message)
            }
        }
    }
}

// MARK: - Previews

#Preview("No accounts, with action") {
    EmptyStateView(
        systemImageName: "banknote",
        title: "No Accounts Yet",
        message: "Add a bank account to start tracking a bonus.",
        actionTitle: "Add Account"
    ) {}
}

#Preview("No reminders, no action") {
    EmptyStateView(
        systemImageName: "bell.slash",
        title: "No Reminders",
        message: "You're all caught up — nothing needs your attention."
    )
}

#Preview("No offers") {
    EmptyStateView(
        systemImageName: "tag",
        title: "No Offers Saved",
        message: "Save a bank offer to track it before you apply.",
        actionTitle: "Add Offer"
    ) {}
}

#Preview("Dark mode") {
    EmptyStateView(
        systemImageName: "banknote",
        title: "No Accounts Yet",
        message: "Add a bank account to start tracking a bonus.",
        actionTitle: "Add Account"
    ) {}
    .preferredColorScheme(.dark)
}
