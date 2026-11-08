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

    /// BeReal-style second shot: flip the session to the front camera, take a photo, flip back.
    func captureSelfie() async -> UIImage? {
        let swapped: Bool = await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: useCamera(.front)) }
        }
        guard swapped else { return nil }
        try? await Task.sleep(for: .milliseconds(400)) // let exposure and focus settle
        let image = await capture()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                _ = useCamera(.back)
                continuation.resume()
            }
        }
        return image
    }

    /// Call on `queue`.
    private func useCamera(_ position: AVCaptureDevice.Position) -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        let added = session.canAddInput(input)
        if added { session.addInput(input) }
        session.commitConfiguration()
        return added
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
    /// While true the preview holds its last frame (the shutter freeze), the session keeps running.
    var frozen = false

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // Disabling the layer's connection stops it drawing new frames, so it shows the exact frame that
        // was up when the shutter was tapped — instantly, without waiting for the full-res photo.
        uiView.previewLayer.connection?.isEnabled = !frozen
    }

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
