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
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }

            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }

            AccountsListView()
                .tabItem { Label("Accounts", systemImage: "building.columns.fill") }

            OffersListView()
                .tabItem { Label("Offers", systemImage: "tag.fill") }

            SettingsView()
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
        }
    }
}

#Preview("Populated") {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}

#Preview("Empty") {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
}
