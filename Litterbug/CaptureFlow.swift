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

    init(pin: LitterPin, location: CLLocation?, photo: UIImage? = nil) {
        self.pin = pin
        self.location = location
        _type = State(initialValue: pin.type)
        _photo = State(initialValue: photo)
    }

    private func process(_ image: UIImage) async {
        photo = image
        let result = await LitterDetector.detect(in: image)
        if let suggested = result?.suggestedType {
            type = suggested
        }
        detection = result
        if result == nil { dismiss() }
    }

    var body: some View {
        Group {
            if let detection {
                review(detection)
            } else if photo != nil {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.appBackground)
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
            // Photo already taken by the inline camera on Home.
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
                Image(uiImage: detection.crop)
                    .resizable()
                    .frame(width: 90, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(LitterType.displayName(type))
                    .font(.custom("MoreSugarRegular", size: 24))
                    .foregroundStyle(.white)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LitterType.all, id: \.self) { option in
                        Button(LitterType.displayName(option)) {
                            type = option
                        }
                        .font(.custom("MoreSugarRegular", size: 15))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundStyle(type == option ? Color.appBackground : .white)
                        .background(type == option ? Color.white : Color.white.opacity(0.15), in: Capsule())
                    }
                }
            }

            Spacer()

            if failed {
                Text("Couldn't save, try again")
                    .font(.custom("MoreSugarRegular", size: 15))
                    .foregroundStyle(Color.litter)
            }

            Button {
                Task { await save(detection) }
            } label: {
                Text(isSaving ? "Saving..." : "Log it")
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
        guard let jpeg = detection.crop.jpegData(compressionQuality: 0.7) else { return }
        isSaving = true
        failed = false
        let place = await placeName(for: location ?? pin.location)
        do {
            try await FirestoreClient.shared.update("litter", id: pin.id, fields: [
                "status": .string("cleaned"),
                "type": .string(type),
                "place": .string(place),
                "photo": .bytes(jpeg),
                "bboxX": .double(detection.box.minX),
                "bboxY": .double(detection.box.minY),
                "bboxSize": .double(detection.box.width),
                "cleanedAt": .timestamp(.now),
                "cleanedBy": .string(AccountStore.shared.currentID),
            ])
            dismiss()
        } catch {
            failed = true
        }
        isSaving = false
    }

    private func placeName(for location: CLLocation) async -> String {
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        return placemark?.areasOfInterest?.first ?? placemark?.name ?? "Nearby"
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
