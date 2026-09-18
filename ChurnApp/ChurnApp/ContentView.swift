//
//  ContentView.swift
//  ChurnApp
//
//  Root 5-tab layout per CLAUDE.md's Navigation Structure spec. Each tab's
//  root view owns its own NavigationStack (see Home/Accounts/Calendar/
//  Offers/Settings), so this file only wires tab selection — no shared
//  navigation state lives here.
//

import CoreData
import SwiftUI

struct ContentView: View {
    @Environment(AppTabSelection.self) private var tabSelection

    var body: some View {
        @Bindable var tabSelection = tabSelection

        TabView(selection: $tabSelection.selected) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppTab.home)

            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(AppTab.calendar)

            AccountsListView()
                .tabItem { Label("Accounts", systemImage: "building.columns.fill") }
                .tag(AppTab.accounts)

            OffersListView()
                .tabItem { Label("Offers", systemImage: "tag.fill") }
                .tag(AppTab.offers)

            SettingsView()
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
                .tag(AppTab.settings)
        }
    }
}

#Preview("Populated") {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environment(AppTabSelection())
}

#Preview("Empty") {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
        .environment(AppTabSelection())
}
