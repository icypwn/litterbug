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
                // Tallo's warm-up: load SAM and run one throwaway prediction now, while Home is up, so the
                // first pickup doesn't pay Core ML's deferred compute-plan build (~3s) mid-scan.
                .task(priority: .userInitiated) {
                    await SAMSegmenter.shared.warmUp()
                    #if DEBUG
                    await CutoutSelfTest.runIfRequested()
                    #endif
                }
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

#if DEBUG
/// Launch with `-cutoutTest` after dropping a photo at Documents/cutout-test.jpg: runs the pickup cutout
/// (Gemini box → SAM) on it and writes Documents/cutout-test-out.png. For checking the pipeline in the
/// Simulator, which has no camera.
enum CutoutSelfTest {
    static func runIfRequested() async {
        guard UserDefaults.standard.bool(forKey: "cutoutTest"),
              let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let image = UIImage(contentsOfFile: docs.appendingPathComponent("cutout-test.jpg").path) else { return }
        let t0 = ScanLog.now()
        async let prepared = SubjectCutout.prepare(image)
        async let look = LitterLocator.look(at: image, expectedType: "bag")
        let lifted = await SubjectCutout.cutout(from: image, encoding: await prepared, box: await look?.box)
        let sticker = lifted.map { SubjectCutout.outlined($0) ?? $0 }
        try? sticker?.pngData()?.write(to: docs.appendingPathComponent("cutout-test-out.png"))
        ScanLog.step("cutout self-test", since: t0, "via \(SubjectCutout.lastMethod) -> \(ScanLog.size(sticker))")
    }
}
#endif
