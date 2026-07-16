import AVFoundation
import SwiftUI

/// Camera preview that only runs while the widget is on screen.
@MainActor
final class MirrorController: ObservableObject {
    @Published var denied = false
    let session = AVCaptureSession()
    /// Serializes start/stop so their execution order matches the order start()/stop()
    /// were called — a fast onAppear→onDisappear must not leave the camera running.
    private let sessionQueue = DispatchQueue(label: "com.notchdeck.mirror.session")

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        granted ? self.configureAndRun() : (self.denied = true)
                    }
                }
            }
        default:
            denied = true
        }
    }

    func stop() {
        nonisolated(unsafe) let session = session
        sessionQueue.async { session.stopRunning() }
    }

    private func configureAndRun() {
        if session.inputs.isEmpty,
           let camera = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: camera),
           session.canAddInput(input) {
            session.beginConfiguration()
            session.sessionPreset = .low
            session.addInput(input)
            session.commitConfiguration()
        }
        nonisolated(unsafe) let session = session
        sessionQueue.async { session.startRunning() }
    }
}

struct MirrorWidget: View {
    @StateObject private var controller = MirrorController()

    var body: some View {
        WidgetCell(title: "Mirror", titleIcon: "camera.fill") {
            Group {
                if controller.denied {
                    Text("Camera access is off")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                } else {
                    CameraPreview(session: controller.session)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .scaleEffect(x: -1) // mirror like a real mirror
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
