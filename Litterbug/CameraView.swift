import AVFoundation
import SwiftUI

/// Back-camera session used for the inline camera that replaces the map on Home.
nonisolated final class Camera: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "litterbug.camera")
    private var onPhoto: ((UIImage?) -> Void)?

    static var isAvailable: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    func start() {
        queue.async { [self] in
            if session.inputs.isEmpty,
               let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: device) {
                session.beginConfiguration()
                session.sessionPreset = .photo
                if session.canAddInput(input) { session.addInput(input) }
                if session.canAddOutput(output) { session.addOutput(output) }
                session.commitConfiguration()
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    func capture() async -> UIImage? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard session.isRunning else { return continuation.resume(returning: nil) }
                onPhoto = { continuation.resume(returning: $0) }
                output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        queue.async { [self] in
            onPhoto?(image)
            onPhoto = nil
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

struct ShutterButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                WobblyCircle()
                    .fill(.white)
                WobblyCircle()
                    .stroke(Color.appBackground, lineWidth: 3)
                    .padding(7)
            }
            .frame(width: 90, height: 90)
        }
        .buttonStyle(.plain)
    }
}
