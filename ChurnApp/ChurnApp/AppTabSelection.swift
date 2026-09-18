//
//  AppTabSelection.swift
//  ChurnApp
//
//  Shared tab-selection state, injected via .environment from MyApp. Lets
//  any view request a tab switch (e.g. Home's "View Full Schedule" button
//  jumping to Calendar) without a NavigationPath, which can't cross a
//  TabView's tab boundaries in SwiftUI.
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
}
