//
//  LitterbugApp.swift
//  Litterbug
//
//  Created by Ethan Harbinger on 11/7/26.
//

import SwiftUI
import CoreData

@main
struct LitterbugApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
