import SwiftUI
import CoreLocation

struct CaptureFlow: View {
    let pin: LitterPin
    let location: CLLocation?

    @Environment(\.dismiss) private var dismiss
    @State private var photo: UIImage?
    @State private var detection: LitterDetection?
    @State private var type: String
    @State private var isSaving = false
    @State private var failed = false
    /// Gemini's reason when the photo isn't the litter the drone saw here.
    @State private var rejection: String?
    /// The litter lifted out of the photo (Gemini box → SAM on device), with Tallo's white sticker border.
    @State private var cutout: UIImage?

    /// Front-camera shot taken right after the photo; shown inset on the Social post.
    let selfie: UIImage?

    /// Litter that isn't on the map yet (the + button): logged straight away, no review screen,
    /// as a new doc at where you're standing, with whatever type Gemini sees.
    private var isNew: Bool { pin.id.hasPrefix(LitterPin.newPrefix) }

    @State private var scanStatus = ""
    /// The whole scan (Gemini's sighting, the place) so saving can reuse it instead of asking again.
    @State private var scan: PickupScan.Result?

    /// `prepared`: the scan already ran in Home's camera card, so go straight to review (or saving).
    init(pin: LitterPin, location: CLLocation?, photo: UIImage? = nil, selfie: UIImage? = nil,
         prepared: PickupScan.Result? = nil) {
        self.pin = pin
        self.location = location
        self.selfie = selfie
        _type = State(initialValue: pin.type)
        _photo = State(initialValue: photo)
        _detection = State(initialValue: prepared?.detection)
        _cutout = State(initialValue: prepared?.cutout)
        _scan = State(initialValue: prepared)
    }

    /// Photo-library path (no camera): same scan, shown full screen.
    private func process(_ image: UIImage) async {
        photo = image
        // The type stays the drone's; Gemini checks the photo against it when they log it.
        guard let result = await PickupScan.run(image, expectedType: pin.type, location: location ?? pin.location,
                                                status: { scanStatus = $0 }) else {
            dismiss()
            return
        }
        if let lifted = result.cutout {
            scanStatus = "Got it!"
            cutout = lifted
            try? await Task.sleep(for: .seconds(1.1)) // let the lift-out land
        }
        detection = result.detection
        scan = result
        if isNew {
            PickupSaver.dropIntoCollection(pin: pin, scan: result, photo: image, location: location)
            dismiss()
        }
    }

    var body: some View {
        Group {
            if let detection, !isNew {
                review(detection)
            } else if photo != nil {
                LitterScanOverlay(photo: photo, cutout: cutout, status: scanStatus)
                    .ignoresSafeArea()
            } else {
                ImagePicker { image in
                    Task { await process(image) }
                } onCancel: {
                    dismiss()
                }
                .ignoresSafeArea()
            }
        }
        .task {
            // Photo already taken by the inline camera on Home (normally already scanned there).
            if let photo, detection == nil { await process(photo) }

        }
    }

    private func review(_ detection: LitterDetection) -> some View {
        VStack(spacing: 20) {
            PageTitle("Log litter")
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(uiImage: detection.annotated)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxHeight: 320)

            HStack(spacing: 16) {
                Group {
                    if let cutout {
                        // The sticker: just the litter, white border, no background.
                        Image(uiImage: cutout)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(uiImage: detection.crop)
                            .resizable()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .frame(width: 90, height: 90)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LitterType.displayName(type))
                        .font(.custom("MoreSugarRegular", size: 24))
                    Text("+\(pin.points) pts")
                        .font(.custom("CheeseMilky", size: 22))
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
                Spacer()
            }

            Spacer()

            if let rejection {
                Text(rejection)
                    .font(.custom("MoreSugarRegular", size: 15))
                    .foregroundStyle(Color.litter)
                    .multilineTextAlignment(.center)
            } else if failed {
                Text("Couldn't save, try again")
                    .font(.custom("MoreSugarRegular", size: 15))
                    .foregroundStyle(Color.litter)
            }

            Button {
                Task { await save(detection) }
            } label: {
                Text(isSaving ? "Checking..." : "Log it")
                    .font(.custom("MoreSugarRegular", size: 22))
                    .foregroundStyle(Color.appBackground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.white, in: Capsule())
            }
            .disabled(isSaving)

            Button("Retake") {
                self.detection = nil
                photo = nil
                rejection = nil
            }
            .font(.custom("MoreSugarRegular", size: 17))
            .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }

    private func save(_ detection: LitterDetection) async {
        isSaving = true
        failed = false
        rejection = nil
        defer { isSaving = false }
        switch await PickupSaver.save(pin: pin, type: type, photo: photo, detection: detection,
                                      cutout: cutout, selfie: selfie, location: location,
                                      sighting: scan?.sighting, place: scan?.place) {
        case .saved(let savedType):
            type = savedType
            dismiss()
        case .rejected(let reason):
            rejection = reason
        case .failed:
            failed = true
        }
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onPick(image)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

extension UIImage {
    func downscaled(maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(size.width, size.height))
        guard scale < 1 else { return self }
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        // Scale 1: the renderer otherwise defaults to the screen's (3x), so a "400" cutout came out
        // 1200px — big enough to push the litter doc past Firestore's 1 MB and fail the save.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}
