@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// The live camera in S09's door sheet: an `AVCaptureSession` with a QR-only metadata output and
/// a preview layer. The session starts and stops on its own queue, never the main thread. It
/// stops when the sheet goes away and after the first read that `onRead` takes as a door code.
/// A payload is handed over as text and nothing else: it is never opened.
///
/// The sheet gives it its label, hint and size.
struct DoorScannerView: UIViewRepresentable {
    let onRead: @MainActor (String) -> Bool

    func makeCoordinator() -> Scanner {
        Scanner()
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        context.coordinator.onRead = onRead
        context.coordinator.attach(to: view.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.onRead = onRead
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: Scanner) {
        coordinator.stop()
    }

    /// A view whose layer is the camera preview.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        // The layer class above makes this cast always succeed.
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    /// The capture session and its QR reader.
    ///
    /// `@unchecked Sendable`: the session is configured, started and stopped only on `queue`,
    /// and `onRead` and `done` are touched only on the main thread, where the metadata delegate
    /// is called.
    final class Scanner: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "dawri.door-scanner")
        var onRead: (@MainActor (String) -> Bool)?
        private var done = false

        func attach(to layer: AVCaptureVideoPreviewLayer) {
            layer.session = session
            // One serial queue, so a stop asked for while this runs always comes after it.
            queue.async { [self] in
                configure()
                session.startRunning()
            }
        }

        func stop() {
            done = true
            queue.async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        }

        private func configure() {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard let camera = CameraDoorScanner.camera,
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input)
            else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
        }

        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            let payloads = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            MainActor.assumeIsolated {
                guard !done, let onRead else { return }
                for payload in payloads where onRead(payload) {
                    // The first door code ends the scan. Anything else keeps it going, silently.
                    stop()
                    return
                }
            }
        }
    }
}
