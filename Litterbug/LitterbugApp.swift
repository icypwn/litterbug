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
                .background(WindowBackground())
        }
    }
}

/// Paints the window itself green, so anything that briefly shrinks away (zoom transitions) reveals
/// the app's background instead of black.
private struct WindowBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Probe() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.backgroundColor = UIColor(Color.appBackground)
        }
    }
}
