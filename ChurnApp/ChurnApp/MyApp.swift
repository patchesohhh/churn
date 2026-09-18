//
//  MyApp.swift
//  ChurnApp
//
//  App entry point. Injects the single Core Data managed object context
//  used by every @FetchRequest in the app (see Models/PersistenceController.swift).
//  No ChurningStore is injected here -- per CLAUDE.md, views call
//  Services/CalculationService.swift directly with their own fetched data;
//  a shared store is only worth adding once a calculation is proven to be
//  reused identically across multiple views.
//

import CoreData
import SwiftUI

@main struct MyApp: App {
    let persistenceController = PersistenceController.shared
    let tabSelection = AppTabSelection()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environment(tabSelection)
        }
    }
}
