@preconcurrency import AVFoundation
import SwiftUI

/// Whether S09's door sheet can show a camera preview. Anything but `available` and
/// `needsPermission` means the sheet shows the typed code field only, which always works.
enum CameraAccess: Sendable, Equatable {
    /// Allowed, and the phone has a camera.
    case available
    /// Not asked yet. Asking happens only when the patient opens the door sheet.
    case needsPermission
    /// Refused or restricted in Settings.
    case denied
    /// No camera, as on the simulator, or this build has no scanner.
    case unavailable

    /// The sheet shows a preview for these, asking first for `needsPermission`.
    var mayScan: Bool { self == .available || self == .needsPermission }
}

/// The camera behind S09's door code sheet. It reports and asks for access, and gives the preview
/// that reads QR codes. What it reads goes to the sheet as text, which checks it with
/// `DoorScan.code(fromPayload:)`. Nothing it reads is ever opened as a link.
protocol DoorScanner: Sendable {
    /// What the sheet can show now, without asking.
    func access() async -> CameraAccess
    /// Asks for the camera if it has not been asked, and returns the answer.
    func requestAccess() async -> CameraAccess
    /// The live preview, once access is `available`. `onRead` gets each QR payload as text,
    /// on the main actor, and returns true when it was a door code, which stops the camera.
    @MainActor func preview(onRead: @escaping @MainActor (String) -> Bool) -> AnyView
}

/// A build with no scanner. The sheet shows the typed field only.
struct NoDoorScanner: DoorScanner {
    func access() async -> CameraAccess { .unavailable }
    func requestAccess() async -> CameraAccess { .unavailable }
    @MainActor func preview(onRead: @escaping @MainActor (String) -> Bool) -> AnyView {
        AnyView(EmptyView())
    }
}

/// The phone's back camera through `AVFoundation`. No camera, as on the simulator, is
/// `unavailable`. The permission prompt appears only from `requestAccess`, which the sheet calls
/// when the patient opens it.
struct CameraDoorScanner: DoorScanner {
    init() {}

    func access() async -> CameraAccess {
        guard Self.camera != nil else { return .unavailable }
        return Self.access(AVCaptureDevice.authorizationStatus(for: .video))
    }

    func requestAccess() async -> CameraAccess {
        guard Self.camera != nil else { return .unavailable }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .notDetermined else { return Self.access(status) }
        return await AVCaptureDevice.requestAccess(for: .video) ? .available : .denied
    }

    @MainActor func preview(onRead: @escaping @MainActor (String) -> Bool) -> AnyView {
        AnyView(DoorScannerView(onRead: onRead))
    }

    /// The back wide camera, or nil when the phone has none.
    static var camera: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
    }

    private static func access(_ status: AVAuthorizationStatus) -> CameraAccess {
        switch status {
        case .authorized: .available
        case .notDetermined: .needsPermission
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }
}
