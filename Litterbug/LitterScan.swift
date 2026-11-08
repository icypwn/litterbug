import SwiftUI
import UIKit
import CoreLocation

/// The pickup scan, shared by the inline camera on Home and the photo-library path:
/// Gemini finds the litter, SAM cuts it out (Tallo's pipeline, see SubjectCutout / SAMSegmenter).
enum PickupScan {
    struct Result {
        let detection: LitterDetection
        let cutout: UIImage?
        /// Gemini's one look: what it is, whether it matches, a description. Nil if Gemini couldn't be reached
        /// (saving then falls back to PickupVerifier).
        let sighting: LitterLocator.Sighting?
        /// "Otsiningo Park" etc., looked up alongside everything else so labels are ready immediately.
        let place: String?
    }

    /// `status` gets the line shown under the scan animation as the stages move along.
    static func run(_ image: UIImage, expectedType: String, location: CLLocation,
                    status: (String) -> Void) async -> Result? {
        let t0 = ScanLog.now()
        status("Finding the litter…")
        // Everything that doesn't depend on anything else starts now, together:
        //  • SAM's image encoder (~85% of SAM's cost; Tallo's ordering) — needs only the photo,
        //  • Gemini's one look (box + type + match + description),
        //  • the place name.
        // Only SAM's cheap prompt+decode waits, on the box.
        async let prepared = SubjectCutout.prepare(image)
        async let look = LitterLocator.look(at: image, expectedType: expectedType)
        async let place = placeName(for: location)
        let detection = await LitterDetector.detect(in: image)
        let sighting = await look
        // Gemini's box, else the on-device salient-object box, so SAM always has a prompt.
        let box = sighting?.box ?? detection?.objectBox
        status("Cutting it out…")
        let lifted = await SubjectCutout.cutout(from: image, encoding: await prepared, box: box)
        ScanLog.step("pickup scan", since: t0, "cutout via \(SubjectCutout.lastMethod)")
        guard let detection else { return nil }
        return Result(detection: detection, cutout: lifted.map(sticker), sighting: sighting, place: await place)
    }

    static func placeName(for location: CLLocation) async -> String {
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        return placemark?.areasOfInterest?.first ?? placemark?.name ?? "Nearby"
    }

    /// Normalise the cutout's size, then give it a border that's a fixed share of it (~3%). A fixed 12px on a
    /// full-res phone cutout (~1500px) came out a hairline once shown small; this matches the seeded stickers.
    static func sticker(_ cutout: UIImage) -> UIImage {
        let small = cutout.downscaled(maxSide: 600)
        let side = max(small.size.width, small.size.height)
        return SubjectCutout.outlined(small, width: max(8, (side * 0.03).rounded())) ?? small
    }
}

/// What you watch between the shutter and the result — Tallo's ScanningOverlay in Litterbug's look.
/// While scanning: the frozen shot, a green wash, and a white line sweeping down it. Once the litter is
/// cut out: the shot blurs back and the sticker springs up out of it.
struct LitterScanOverlay: View {
    let photo: UIImage?
    let cutout: UIImage?
    let status: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lifted = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: cutout == nil ? 0 : 6)
                        // Rendered once into a bitmap rather than re-blurring every frame.
                        .drawingGroup()
                }
                Color.appBackground.opacity(cutout == nil ? 0.35 : 0.6)

                if cutout == nil {
                    Scanline(animate: !reduceMotion)
                        .allowsHitTesting(false)
                }

                if let cutout {
                    Image(uiImage: cutout)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: geo.size.width * 0.7, maxHeight: geo.size.height * 0.6)
                        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                        .scaleEffect(lifted ? 1 : 0.85)
                        .opacity(lifted ? 1 : 0)
                        .rotationEffect(.degrees(lifted ? -3 : 0))
                        .onAppear {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { lifted = true }
                        }
                }

                VStack {
                    Spacer()
                    Text(status)
                        .font(.custom("MoreSugarRegular", size: 18))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.appBackground.opacity(0.75), in: Capsule())
                        .overlay(Capsule().stroke(.white, lineWidth: 2))
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.25), value: status)
                        .padding(.bottom, 20)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Clear until the photo arrives, so the frozen camera preview underneath shows through.
        .background(photo == nil ? Color.clear : Color.appBackground)
    }
}

/// The sweeping line, from Tallo: Core Animation rather than a SwiftUI repeatForever, so the scan's own
/// work never queues behind per-frame view updates on the main thread.
struct Scanline: UIViewRepresentable {
    var animate: Bool

    func makeUIView(context: Context) -> ScanlineView { ScanlineView() }

    func updateUIView(_ view: ScanlineView, context: Context) {
        view.animate = animate
    }
}

final class ScanlineView: UIView {
    private static let trail: CGFloat = 110
    private static let key = "sweep"

    private let group = CALayer()
    private let gradient = CAGradientLayer()
    private let line = CALayer()

    var animate = true { didSet { if animate != oldValue { restart() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        gradient.colors = [UIColor.white.withAlphaComponent(0).cgColor,
                           UIColor.white.withAlphaComponent(0.3).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)

        line.backgroundColor = UIColor.white.cgColor
        line.cornerRadius = 1.5
        line.shadowColor = UIColor.white.cgColor
        line.shadowOpacity = 0.8
        line.shadowRadius = 8
        line.shadowOffset = .zero

        group.addSublayer(gradient)
        group.addSublayer(line)
        layer.addSublayer(group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        group.frame = CGRect(x: 0, y: 0, width: w, height: Self.trail + 3)
        gradient.frame = CGRect(x: 0, y: 0, width: w, height: Self.trail)
        line.frame = CGRect(x: 0, y: Self.trail, width: w, height: 3)
        line.shadowPath = CGPath(rect: line.bounds, transform: nil)
        restart()
    }

    private func restart() {
        group.removeAnimation(forKey: Self.key)
        guard animate, bounds.height > 0 else { return }
        let sweep = CABasicAnimation(keyPath: "transform.translation.y")
        sweep.fromValue = -Self.trail
        sweep.toValue = bounds.height
        sweep.duration = 1.5
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.isRemovedOnCompletion = false
        group.add(sweep, forKey: Self.key)
    }
}
