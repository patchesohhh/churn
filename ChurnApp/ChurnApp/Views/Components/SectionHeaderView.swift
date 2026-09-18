//
//  SectionHeaderView.swift
//  ChurnApp
//
//  Consistent section title (+ optional trailing action, e.g. "See All")
//  for grouping content within a screen — Home's "Active Accounts",
//  "Upcoming Reminders", etc. all use this instead of ad hoc `Text(...).font(.headline)`.
//

import SwiftUI

struct SectionHeaderView: View {

    let title: String
    /// Shown under the title when non-nil — e.g. a count or date range.
    var subtitle: String? = nil
    /// Label for a trailing action button (e.g. "See All"). When nil, no
    /// button is shown and the header is title-only.
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    // `.title3` reads as a section header without competing
                    // with a navigation title above it.
                    .font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let actionTitle, let action {
                // Native `Button` with `.borderless` reads as a link-style
                // trailing action (system-standard "See All" affordance)
                // without pulling in a custom chrome/border.
                Button(action: action) {
                    HStack(spacing: 2) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.borderless)
                .font(.subheadline.weight(.medium))
            }
        }
    }
}

// MARK: - Previews

#Preview("Title only") {
    SectionHeaderView(title: "Active Accounts")
        .padding()
}

#Preview("With subtitle") {
    SectionHeaderView(title: "Earnings", subtitle: "Year to date")
        .padding()
}

#Preview("With trailing action") {
    SectionHeaderView(title: "Upcoming Reminders", actionTitle: "See All") {}
        .padding()
}

#Preview("Subtitle + action") {
    SectionHeaderView(title: "Accounts", subtitle: "4 total", actionTitle: "See All") {}
        .padding()
}

#Preview("Dark mode") {
    SectionHeaderView(title: "Active Accounts", actionTitle: "See All") {}
        .padding()
        .preferredColorScheme(.dark)
}
