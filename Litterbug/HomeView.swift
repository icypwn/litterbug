import SwiftUI
@_spi(Restricted) import MapboxMaps

enum MapMode {
    case doodle, standard, threeD

    var viewport: Viewport {
        switch self {
        case .doodle, .standard: .followPuck(zoom: 15.5, bearing: .constant(0))
        case .threeD: .followPuck(zoom: 16.5, bearing: .constant(-20), pitch: 60)
        }
    }
}

struct HomeView: View {
    @State private var mode: MapMode = .threeD
    @State private var viewport: Viewport = MapMode.threeD.viewport
    @State private var locationManager = CLLocationManager()
    @State private var store = LitterStore()

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle("Litterbug")

            Map(viewport: $viewport) {
                Puck2D()
                ForEvery(store.pins) { pin in
                    MapViewAnnotation(coordinate: pin.coordinate) {
                        PinView(pin: pin)
                    }
                    .allowOverlap(true)
                }
            }
            .mapStyle(mapStyle)
            .ornamentOptions(Self.ornaments)
            .overlay(alignment: .bottomTrailing) {
                if viewport.followPuck == nil {
                    RecenterButton {
                        withViewportAnimation(.easeOut(duration: 0.6)) {
                            viewport = mode.viewport
                        }
                    }
                    .padding(12)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewport.followPuck == nil)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxHeight: .infinity)
            .padding(.top, 12)

            AddButton {}
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 63)
                .padding(.bottom, 47)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            KeyCatcher(actions: [
                "1": { switchTo(.doodle) },
                "2": { switchTo(.standard) },
                "3": { switchTo(.threeD) },
            ])
        }
        .background(Color.appBackground)
        .onAppear {
            locationManager.requestWhenInUseAuthorization()
        }
        .task {
            await store.poll()
        }
    }
}

struct RecenterButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "location.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.appBackground)
                .frame(width: 44, height: 44)
                .background(WobblyCircle().fill(.white))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
        }
        .buttonStyle(.plain)
    }
}

struct AddButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                WobblyCircle()
                    .fill(.white)
                Image("add-trash")
                    .resizable()
                    .scaledToFit()
            }
            .frame(width: 100, height: 100)
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

struct PinView: View {
    let pin: LitterPin
    @State private var appeared = false

    private var tilt: Double {
        Double(pin.id.unicodeScalars.reduce(0) { $0 + Int($1.value) * 7 } % 17 - 8)
    }

    var body: some View {
        Image(systemName: pin.symbol)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color.litter, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .overlay(Circle().inset(by: -2.5).stroke(Color.ink, lineWidth: 2))
            .rotationEffect(.degrees(tilt))
            .shadow(color: .black.opacity(0.3), radius: 2, x: 1, y: 2)
            .scaleEffect(appeared ? 1 : 0.1)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.45).delay(.random(in: 0...0.35))) {
                    appeared = true
                }
            }
    }
}

extension Color {
    static let ink = Color(red: 0.23, green: 0.21, blue: 0.19)
    static let litter = Color(red: 1.0, green: 0.36, blue: 0.2)
}

#Preview {
    HomeView()
}
