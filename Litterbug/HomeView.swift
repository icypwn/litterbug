import Combine
import AVFoundation
import SwiftUI
@_spi(Restricted) import MapboxMaps

enum MapMode {
    case doodle, standard, threeD

    var viewport: Viewport {
        switch self {
        case .doodle, .standard: .followPuck(zoom: 17, bearing: .constant(0))
        case .threeD: .followPuck(zoom: 18, bearing: .constant(-20), pitch: 60)
        }
    }
}

struct HomeView: View {
    @State private var mode: MapMode = .threeD
    @State private var viewport: Viewport = MapMode.threeD.viewport
    @State private var tracker = LocationTracker.shared
    @State private var store = LitterStore.shared
    @Environment(\.isTabActive) private var isTabActive
    @State private var mapLoaded = false
    @State private var refreshSpins = 0
    @State private var isRefreshing = false
    @State private var captureTarget: LitterPin?
    @State private var route: [CLLocationCoordinate2D] = []
    @State private var routePinID: String?
    @State private var cameraPin: LitterPin?
    @State private var camera = Camera()
    @State private var capturedPhoto: UIImage?
    @State private var capturedSelfie: UIImage?
    /// The inline scan after the shutter (Tallo-style): frozen shot + scan line, then the cutout lifts out.
    @State private var scanPhoto: UIImage?
    /// True from the instant the shutter is tapped: freezes the preview and shows the scan right away,
    /// before the full-res photo (scanPhoto) has even come back.
    @State private var scanning = false
    @State private var scanCutout: UIImage?
    @State private var scanStatus = ""
    @State private var preparedScan: PickupScan.Result?


    private static let pickupRadius: CLLocationDistance = 9.144 // 30 ft

    private var nearestPins: [(LitterPin, CLLocationDistance)] {
        guard let here = tracker.location else { return [] }
        return Array(store.pins
            .map { ($0, $0.location.distance(from: here)) }
            .sorted { $0.1 < $1.1 }
            .prefix(20))
    }

    /// The closest piece you're near enough to photograph, if any.
    private var pickupPin: LitterPin? {
        guard let (pin, distance) = nearestPins.first, distance <= Self.pickupRadius else { return nil }
        return pin
    }


    /// Bottom list: always draw the route to the piece (the map's pick-up button handles the camera).
    private func routeTo(_ pin: LitterPin) {
        guard let here = tracker.location else { return }
        Task { await showRoute(from: here.coordinate, to: pin) }
    }

    private func shoot(_ pin: LitterPin) {
        // Re-check at the shutter: you may have walked away since opening the camera.
        guard let here = tracker.location, pin.location.distance(from: here) <= Self.pickupRadius else {
            cameraPin = nil
            return
        }
        // Simulator has no camera: fall back to the photo-library picker.
        guard Camera.isAvailable else {
            cameraPin = nil
            captureTarget = pin
            return
        }
        // Freeze + scan line now; the photo itself lands a few tenths of a second later.
        scanCutout = nil
        scanStatus = "Finding the litter…"
        scanning = true
        Task {
            guard let image = await camera.capture() else {
                scanning = false
                return
            }
            // Scan in the camera card: the frozen shot and a sweeping line while Gemini + SAM work.
            scanPhoto = image
            let result = await PickupScan.run(image, expectedType: pin.type, location: tracker.location ?? pin.location) { scanStatus = $0 }
            guard let result else {
                scanPhoto = nil
                scanning = false
                scanStatus = ""
                return
            }
            if let cutout = result.cutout {
                scanStatus = "Got it!"
                scanCutout = cutout
                try? await Task.sleep(for: .seconds(1.1)) // let the lift-out land before moving on
            }
            // + button: no review — straight to Collection, where the sticker gets stuck on.
            if pin.id.hasPrefix(LitterPin.newPrefix) {
                PickupSaver.dropIntoCollection(pin: pin, scan: result, photo: image, location: tracker.location)
                cameraPin = nil
                scanPhoto = nil
                scanning = false
                scanCutout = nil
                return
            }
            capturedPhoto = image
            preparedScan = result
            cameraPin = nil
            scanPhoto = nil
            scanning = false
            scanCutout = nil
            captureTarget = pin
        }
    }

    private func showRoute(from here: CLLocationCoordinate2D, to pin: LitterPin) async {
        routePinID = pin.id
        // Walking directions snap to paths, which turns short trips across grass into big loops.
        // Under ~300 ft just draw a straight line.
        let direct = CLLocation(latitude: here.latitude, longitude: here.longitude).distance(from: pin.location)
        let path = direct < 91 ? [] : ((try? await WalkingRoute.fetch(from: here, to: pin.coordinate)) ?? [])
        guard routePinID == pin.id else { return }
        // Bookend with the real endpoints so the line reaches you and the litter even off-path.
        route = [here] + path + [pin.coordinate]
        withViewportAnimation(.easeOut(duration: 0.8)) {
            viewport = .overview(
                geometry: LineString(route),
                bearing: 0,
                pitch: mode == .threeD ? 40 : 0,
                geometryPadding: .init(top: 60, leading: 50, bottom: 60, trailing: 50),
                // Very close pieces (under ~100 ft) get to zoom right in so the line is visible.
                maxZoom: direct < 30 ? 20.5 : 18
            )
        }
    }

    /// The map's own idea of where you are (it drives the follow-me camera): the demo spot, or real GPS.
    private static let locationModel: LocationDataModel = {
        if LocationTracker.usesDemoSpot {
            return LocationDataModel(location: Just([Location(clLocation: LocationTracker.demoSpot)]).eraseToAnyPublisher())
        }
        return LocationDataModel(location: AppleLocationProvider().onLocationUpdate.eraseToAnyPublisher())
    }()

    private static let doodleStyle: MapStyle = {
        guard let url = Bundle.main.url(forResource: "DoodleStyle", withExtension: "json"),
              let json = try? String(contentsOf: url, encoding: .utf8) else { return .standard }
        return MapStyle(json: json)
    }()

    private static let ornaments: OrnamentOptions = {
        var logo = LogoViewOptions()
        logo.visibility = .hidden
        var attribution = AttributionButtonOptions()
        attribution.visibility = .hidden
        return OrnamentOptions(
            scaleBar: ScaleBarViewOptions(visibility: .hidden),
            compass: CompassViewOptions(visibility: .hidden),
            logo: logo,
            attributionButton: attribution
        )
    }()

    private var mapStyle: MapStyle {
        switch mode {
        case .doodle: Self.doodleStyle
        case .standard: .standard(show3dObjects: false)
        case .threeD: .standard(show3dObjects: true)
        }
    }

    private func switchTo(_ newMode: MapMode) {
        mode = newMode
        withViewportAnimation(.easeOut(duration: 0.8)) {
            viewport = newMode.viewport
        }
    }

    @MapContentBuilder
    private var mapContent: some MapContent {
        // Real puck stays (it drives followPuck) but is invisible: GL-rendered pucks always sit
        // under view annotations, so the visible dot is a view annotation added after the pins.
        Puck2D().opacity(0)
        if route.count > 1 {
            PolylineAnnotation(lineCoordinates: route)
                .lineColor(UIColor(Color.litter))
                .lineWidth(6)
                .lineJoin(.round)
        }
        ForEvery(store.pins) { pin in
            MapViewAnnotation(coordinate: pin.coordinate) {
                PinView(pin: pin, ready: mapLoaded)
                    .onTapGesture { routeTo(pin) }
            }
            .allowOverlap(true)
            .allowOverlapWithPuck(true)
        }
        if let here = tracker.location {
            MapViewAnnotation(coordinate: here.coordinate) {
                UserDot()
            }
            .allowOverlap(true)
            .allowOverlapWithPuck(true)
            .allowHitTesting(false)
            .priority(1)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PageTitle("Litterbug")
                Spacer()
                StreakBadge(days: store.streak)
            }

            ZStack {
            Map(viewport: $viewport) { mapContent }
            .locationDataModel(Self.locationModel)
            .mapStyle(mapStyle)
            .onMapLoaded { _ in mapLoaded = true }
            .ornamentOptions(Self.ornaments)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    if viewport.followPuck == nil {
                        RecenterButton {
                            withViewportAnimation(.easeOut(duration: 0.6)) {
                                viewport = mode.viewport
                            }
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                    // Log litter that isn't on the map: same camera, no review step.
                    MapCircleButton(image: "add") {
                        guard let here = tracker.location else { return }
                        route = []
                        routePinID = nil
                        cameraPin = .unlogged(at: here)
                    }
                    .accessibilityLabel("Log litter that isn't on the map")
                    MapCircleButton(image: "refresh", rotation: Double(refreshSpins) * 360) {
                        guard !isRefreshing else { return }
                        isRefreshing = true
                        withAnimation(.easeInOut(duration: 0.6)) { refreshSpins += 1 }
                        Task {
                            await store.reload()
                            isRefreshing = false
                        }
                    }
                }
                .padding(12)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewport.followPuck == nil)
            }
            .overlay(alignment: .bottom) {
                Group {
                    if let pin = pickupPin {
                        PickupPillButton(icon: Image("camera"), title: "Pick up \(LitterType.displayName(pin.type).lowercased())") {
                            route = []
                            routePinID = nil
                            cameraPin = pin
                        }
                        .id("pickup")
                    } else if let nearest = nearestPins.first?.0 {
                        PickupPillButton(icon: Image(systemName: "shoeprints.fill"), title: "Locate item") {
                            routeTo(nearest)
                        }
                        .id("walk")
                    }
                }
                .padding(.bottom, 14)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.7, anchor: .bottom).combined(with: .opacity),
                    removal: .scale(scale: 0.9, anchor: .bottom).combined(with: .opacity)
                ))
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.58), value: pickupPin?.id)
            .animation(.spring(response: 0.42, dampingFraction: 0.58), value: cameraPin == nil)
            if cameraPin != nil {
                ZStack {
                    Color.black
                    if Camera.isAvailable {
                        CameraPreview(session: camera.session, frozen: scanning)
                    } else {
                        VStack(spacing: 8) {
                            Image("camera")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 44, height: 44)
                            Text("No camera on Simulator")
                                .font(.custom("MoreSugarRegular", size: 17))
                        }
                        .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .overlay {
                    if scanning {
                        LitterScanOverlay(photo: scanPhoto, cutout: scanCutout, status: scanStatus)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if !scanning {
                    Button {
                        cameraPin = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.appBackground)
                            .frame(width: 40, height: 40)
                            .background(WobblyCircle().fill(.white))
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    }
                }
                .task {
                    if Camera.isAvailable, await AVCaptureDevice.requestAccess(for: .video) {
                        camera.start()
                    }
                }
                .onDisappear { camera.stop() }
                // Eases in over the map rather than snapping (the outer animation keys on cameraPin).
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.85), value: cameraPin == nil)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxHeight: .infinity)
            .padding(.top, 12)

            // Two full rows plus the top of a third, which fades out at the bottom and runs into the
            // gap above the tab bar (the tab bar draws on top). Net footprint is unchanged: 10 + 150 − 16.
            VStack(spacing: 10) {
                if let cameraPin {
                    ShutterButton { shoot(cameraPin) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                        // Nothing to press while the shot is being scanned.
                        .opacity(scanning ? 0.3 : 1)
                        .disabled(scanning)
                } else {
                let pins = nearestPins
                if pins.isEmpty {
                    Text(tracker.location == nil ? "Finding you…" : "No litter nearby 🎉")
                        .font(.custom("MoreSugarRegular", size: 17))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(Array(pins.enumerated()), id: \.element.0.id) { index, item in
                            let (pin, distance) = item
                            NearbyRow(pin: pin, distance: distance, from: tracker.location, inRange: distance <= Self.pickupRadius) {
                                routeTo(pin)
                            }
                            .modifier(PopIn(delay: 0.1 + Double(min(index, 2)) * 0.07))
                            // Rows only partly in view (the next one scrolling in) are faded.
                            .scrollTransition(.interactive) { content, phase in
                                content.opacity(phase.isIdentity ? 1 : 0.45)
                            }
                        }
                    }
                    // Room for the rows' 2pt outline, which the scroll view would otherwise clip.
                    .padding(3)
                }
                .scrollBounceBehavior(.basedOnSize)
                // Don't hard-clip the sides: rows overshoot a little when they spring in, and their
                // outline ends got sliced. The mask does the clipping instead — straight edge on top,
                // fade on the bottom, and 20pt of slack on each side.
                .scrollClipDisabled()
                .padding(-3)
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 40)
                    }
                    .padding(.horizontal, -20)
                    // Reach up into the 10pt gap under the map so the first row's outline isn't sliced
                    // when it springs in or the list bounces; stops 2pt short of the map.
                    .padding(.top, -8)
                }
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.58), value: cameraPin == nil)
            .frame(height: 150, alignment: .top)
            .padding(.top, 10)
            .padding(.bottom, -16)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            KeyCatcher(actions: [
                "1": { switchTo(.doodle) },
                "2": { switchTo(.standard) },
                "3": { switchTo(.threeD) },
                UIKeyCommand.inputLeftArrow: { PinStyle.shared.step(-1) },
                UIKeyCommand.inputRightArrow: { PinStyle.shared.step(1) },
            ])
        }
        .background(Color.appBackground)
        .onAppear {
            tracker.start()
        }
        .task(id: isTabActive) {
            guard isTabActive else { return }
            await store.poll()
        }
        .onChange(of: store.pins.map(\.id)) { _, ids in
            if let id = routePinID, !ids.contains(id) {
                route = []
                routePinID = nil
            }
        }
        .fullScreenCover(item: $captureTarget, onDismiss: { capturedPhoto = nil; capturedSelfie = nil; preparedScan = nil }) { pin in
            CaptureFlow(pin: pin, location: tracker.location, photo: capturedPhoto, selfie: capturedSelfie, prepared: preparedScan)
        }
    }
}

enum WalkingRoute {
    private struct Response: Decodable {
        struct Route: Decodable {
            struct Geometry: Decodable { let coordinates: [[Double]] }
            let geometry: Geometry
        }
        let routes: [Route]
    }

    static func fetch(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> [CLLocationCoordinate2D] {
        var url = URLComponents(string: "https://api.mapbox.com/directions/v5/mapbox/walking/\(from.longitude),\(from.latitude);\(to.longitude),\(to.latitude)")!
        url.queryItems = [
            URLQueryItem(name: "geometries", value: "geojson"),
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "access_token", value: MapboxOptions.accessToken),
        ]
        let (data, _) = try await URLSession.shared.data(from: url.url!)
        let coords = try JSONDecoder().decode(Response.self, from: data).routes.first?.geometry.coordinates ?? []
        return coords.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
    }
}

struct NearbyRow: View {
    let pin: LitterPin
    let distance: CLLocationDistance
    let from: CLLocation?
    let inRange: Bool
    let action: () -> Void

    private var bearing: Double {
        guard let from else { return 0 }
        let lat1 = from.coordinate.latitude * .pi / 180, lat2 = pin.lat * .pi / 180
        let dLon = (pin.lon - from.coordinate.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x) * 180 / .pi
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                let style = PinStyle.shared.current
                style.image(for: pin)
                    .resizable()
                    .scaledToFit()
                    .frame(width: style.fill == nil ? 28 : style.iconSize, height: style.fill == nil ? 28 : style.iconSize)
                    .foregroundStyle(style.fill == nil ? .white : style.icon)
                    .frame(width: 34, height: 34)
                    .background(style.fill ?? .clear, in: Circle())
                    .overlay(Circle().stroke(style.fill == nil ? .clear : (style.colored ? .white : Color.ink), lineWidth: 2))
                Text(LitterType.displayName(pin.type))
                    .font(.custom("MoreSugarRegular", size: 17))
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image("direction")
                        .resizable()
                        .frame(width: 15, height: 15)
                        .rotationEffect(.degrees(bearing))
                    Text(Measurement(value: distance, unit: UnitLength.meters)
                        .formatted(.measurement(width: .abbreviated, usage: .road)))
                }
                .font(.custom("MoreSugarRegular", size: 15))
                .opacity(inRange ? 1 : 0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct UserDot: View {
    var body: some View {
        Circle()
            .fill(Color(red: 0.2, green: 0.5, blue: 1.0))
            .frame(width: 20, height: 20)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}

struct PickupPillButton: View {
    let icon: Image
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                Text(title)
                    .font(.custom("MoreSugarRegular", size: 22))
            }
            .foregroundStyle(Color.appBackground)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(.white, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }
}

struct StreakBadge: View {
    let days: Int

    var body: some View {
        HStack(spacing: 4) {
            Image("streak")
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
            Text("\(days)")
                .font(.custom("MoreSugarRegular", size: 16))
                .contentTransition(.numericText())
                // MoreSugar's digits sit high in their line box; drop them onto the flame's center.
                .offset(y: 1.5)
        }
        .foregroundStyle(.white)
        .padding(.leading, 9)
        .padding(.trailing, 12)
        // Total height matches the "Litterbug" title.
        .frame(height: 26)
        // Same white 2pt capsule outline as the litter rows.
        .overlay(Capsule().stroke(.white, lineWidth: 2))
        .animation(.spring, value: days)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(days)-day streak")
    }
}

struct MapCircleButton: View {
    let image: String
    var rotation: Double = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(image)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(Color.appBackground)
                .rotationEffect(.degrees(rotation))
                .frame(width: 44, height: 44)
                .background(WobblyCircle().fill(.white))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
        }
        .buttonStyle(.plain)
    }
}

struct RecenterButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image("recenter")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(Color.appBackground)
                .frame(width: 44, height: 44)
                .background(WobblyCircle().fill(.white))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
        }
        .buttonStyle(.plain)
    }
}

struct WobblyCircle: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        let steps = 120
        for i in 0...steps {
            let angle = Double(i) / Double(steps) * 2 * .pi
            let wobble = 1 + 0.012 * sin(angle * 3 + 0.6) + 0.008 * sin(angle * 5 + 1.9)
            let point = CGPoint(
                x: center.x + cos(angle) * radius * wobble * 0.97,
                y: center.y + sin(angle) * radius * wobble * 0.97
            )
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

struct PopIn: ViewModifier {
    let delay: Double
    /// False: appear in place with no pop (e.g. the sticker that was just slammed into Collection).
    var enabled = true
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown || !enabled ? 1 : 0.85)
            .opacity(shown || !enabled ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(delay)) {
                    shown = true
                }
            }
    }
}

struct PinView: View {
    let pin: LitterPin
    /// False until the map has drawn, so the pop isn't spent while the map is still blank.
    let ready: Bool
    @State private var appeared = false

    private var tilt: Double {
        Double(pin.id.unicodeScalars.reduce(0) { $0 + Int($1.value) * 7 } % 17 - 8)
    }

    var body: some View {
        let style = PinStyle.shared.current
        Group {
            if let fill = style.fill {
                style.image(for: pin)
                    .resizable()
                    .scaledToFit()
                    .frame(width: style.iconSize, height: style.iconSize)
                    .foregroundStyle(style.icon)
                    .frame(width: 34, height: 34)
                    .background(fill, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .overlay(Circle().inset(by: -2.5).stroke(style.colored ? .white : Color.ink, lineWidth: 2))
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 1, y: 2)
            } else {
                style.image(for: pin)
                    .resizable()
                    .scaledToFit()
                    .frame(width: style.colored ? 36 : 30, height: style.colored ? 36 : 30)
                    .foregroundStyle(style.icon)
            }
        }
            .rotationEffect(.degrees(tilt))
            .scaleEffect(appeared ? 1 : 0.1)
            .onAppear { if ready { pop() } }
            .onChange(of: ready) { _, isReady in if isReady { pop() } }
    }

    private func pop() {
        guard !appeared else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.45).delay(.random(in: 0.05...0.35))) {
            appeared = true
        }
    }
}

extension Color {
    static let ink = Color(red: 0.23, green: 0.21, blue: 0.19)
    static var litter: Color {
        let style = PinStyle.shared.current
        return style.colored ? .ink : (style.fill ?? .appBackground)  // white route line would vanish on the map
    }
}

/// Pin color preview: ←/→ on a hardware keyboard cycles these (simulator).
@Observable
final class PinStyle {
    static let shared = PinStyle()

    struct Option {
        let name: String
        let fill: Color?   // nil = bare icon, no circle or shadow
        let icon: Color
        var colored = false   // use the full-color litter-*-color assets instead of tinting

        func image(for pin: LitterPin) -> Image {
            Image(colored ? "\(pin.symbol)-color" : pin.symbol)
        }
        var iconSize: CGFloat { colored ? 27 : 22 }
    }

    static let options: [Option] = [
        Option(name: "Colored", fill: .white, icon: .ink, colored: true),
        Option(name: "Colored, no background", fill: nil, icon: .ink, colored: true),
        Option(name: "Orange", fill: Color(red: 1.0, green: 0.36, blue: 0.2), icon: .white),
        Option(name: "Mint", fill: Color(red: 0.6, green: 0.91, blue: 0.78), icon: .appBackground),
        Option(name: "Pink", fill: Color(red: 0.93, green: 0.36, blue: 0.56), icon: .white),
        Option(name: "Darker green", fill: Color(red: 0.06, green: 0.2, blue: 0.15), icon: .white),
        Option(name: "Icons only", fill: nil, icon: .appBackground),
        Option(name: "Tan", fill: Color(red: 0.84, green: 0.73, blue: 0.55), icon: .appBackground),
        Option(name: "Light blue", fill: Color(red: 0.62, green: 0.82, blue: 0.96), icon: .appBackground),
        Option(name: "Yellow", fill: Color(red: 0.95, green: 0.76, blue: 0.31), icon: .appBackground),
    ]

    #if DEBUG
    // Launch with `-pinStyle N` to open on a given style.
    var index = min(max(UserDefaults.standard.integer(forKey: "pinStyle"), 0), PinStyle.options.count - 1)
    #else
    var index = 0
    #endif
    var current: Option { Self.options[index] }

    func step(_ delta: Int) {
        index = (index + delta + Self.options.count) % Self.options.count
    }
}

#Preview {
    HomeView()
}
