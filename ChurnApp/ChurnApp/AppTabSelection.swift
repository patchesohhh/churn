//
//  AppTabSelection.swift
//  ChurnApp
//
//  Shared tab-selection state, injected via .environment from MyApp. Lets
//  any view request a tab switch (e.g. Home's "View Full Schedule" button
//  jumping to Calendar) without a NavigationPath, which can't cross a
//  TabView's tab boundaries in SwiftUI.
//
//  Also owns each tab's NavigationPath. SwiftUI's TabView keeps a pushed
//  navigation stack alive when you switch away and back by default -- round
//  4 feedback was that this reads as disorienting ("I left the Accounts tab
//  mid-detail-view, came back, and it was still mid-detail-view"). Fix:
//  every tab root binds its NavigationStack to the path here instead of an
//  implicit/local one, and ContentView resets a tab's path the moment you
//  switch away from it, so returning to any tab always lands on its root.
//

import SwiftUI

enum AppTab: Hashable {
    case home
    case calendar
    case accounts
    case offers
    case settings
}

@Observable
final class AppTabSelection {
    var selected: AppTab = .home

    var homePath = NavigationPath()
    var calendarPath = NavigationPath()
    var accountsPath = NavigationPath()
    var offersPath = NavigationPath()
    var settingsPath = NavigationPath()

    /// Called from `ContentView` whenever `selected` changes, with the tab
    /// being left. Resetting on the way out (rather than on the way in)
    /// means the tab's root is already showing the instant you switch back.
    func resetPath(for tab: AppTab) {
        switch tab {
        case .home: homePath = NavigationPath()
        case .calendar: calendarPath = NavigationPath()
        case .accounts: accountsPath = NavigationPath()
        case .offers: offersPath = NavigationPath()
        case .settings: settingsPath = NavigationPath()
        }
    }
}
