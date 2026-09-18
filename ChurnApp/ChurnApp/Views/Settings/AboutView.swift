//
//  AboutView.swift
//  ChurnApp
//
//  Static "about" content — app purpose, a short how-it-works blurb, and a
//  version placeholder. Filler content by design (per the task spec): a
//  native Form of Text, no Core Data access, nothing to keep in sync.
//

import SwiftUI

struct AboutView: View {

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "banknote.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("Churn")
                        .font(.title2.weight(.bold))
                    Text("Bank Bonus Tracker")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .listRowBackground(Color.clear)

            Section("What It Does") {
                Text("Churn helps a household track cash bonuses from bank account opening promotions. It keeps tabs on every account's bonus requirements, direct deposit schedule, and eligibility window, so nothing falls through the cracks while you chase multiple offers at once.")
            }

            Section("How It Works") {
                Text("Set up each household earner's paycheck schedule in Settings, then add accounts as you open them — bonus amount, requirements, and expected payout date. Churn projects your direct deposits against each person's pay schedule, reminds you before deadlines, and totals up what you've earned and what's still pending.")
            }

            Section("Your Data") {
                Text("Everything you enter is stored locally on this device using Core Data. There's no account, no server, and no syncing — the app works entirely offline.")
            }

            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("About")
        .toolbarTitleDisplayMode(.inline)
    }

    /// Reads the real bundle version/build when available, falling back to
    /// a placeholder in previews or if Info.plist keys aren't populated yet.
    private var appVersion: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        if let shortVersion, let build {
            return "\(shortVersion) (\(build))"
        }
        return "1.0.0"
    }
}

// MARK: - Previews

#Preview("Light mode") {
    NavigationStack {
        AboutView()
    }
}

#Preview("Dark mode") {
    NavigationStack {
        AboutView()
    }
    .preferredColorScheme(.dark)
}
