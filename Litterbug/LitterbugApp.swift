//
//  LitterbugApp.swift
//  Litterbug
//
//  Created by Ethan Harbinger on 11/7/26.
//

import SwiftUI
import CoreData
import MapboxMaps

@main
struct LitterbugApp: App {
    let persistenceController = PersistenceController.shared

    init() {
        MapboxOptions.accessToken = Secrets.mapboxToken
        let fonts = ["otf", "ttf"].flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
        for url in fonts {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
