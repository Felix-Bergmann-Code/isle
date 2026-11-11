import AppKit
import AVFoundation
import Observation
import SwiftUI

/// A camera mirror for a quick look before a call. It temporarily takes the Now Playing pane
/// on Home. The camera runs only while the mirror is on screen: it stops the moment the
/// island closes, the tab changes, the feature is switched off or the mirror is dismissed.
/// Sendable by convention: its state is only touched on main, the session only on `queue`.
@Observable
final class MirrorService: @unchecked Sendable {
    enum Access { case unknown, authorized, denied, unavailable }

    /// The mirror replaces the player on the Home tab.
    private(set) var isShown = false
    private(set) var access: Access = .unknown

    @ObservationIgnored private let vm: IslandViewModel
    @ObservationIgnored private let settings: AppSettings
    /// AVCaptureSession calls block, so they never run on main.
    @ObservationIgnored private let queue = DispatchQueue(label: "io.github.felix-bergmann-code.isle.mirror")
    /// Created on first use, so the capture stack isn't loaded for people who never open the mirror.
    @ObservationIgnored private var session: AVCaptureSession?
    @ObservationIgnored private var layer: AVCaptureVideoPreviewLayer?

    init(vm: IslandViewModel, settings: AppSettings) {
        self.vm = vm
        self.settings = settings
    }

    /// The live preview, horizontally mirrored and aspect-filled. Main thread only.
    var previewLayer: AVCaptureVideoPreviewLayer {
        if let layer { return layer }
        let session = AVCaptureSession()
        session.sessionPreset = .medium
        let l = AVCaptureVideoPreviewLayer(session: session)
        l.videoGravity = .resizeAspectFill
        self.session = session
        self.layer = l
        return l
    }

    func show() {
        guard settings.cameraMirror, vm.isOpen, vm.tab == .home else { return }
        if !isShown {
            withAnimation(Anim.island) { isShown = true }
            watch()
        }
        refreshAccess()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshAccess()
                    if self.isShown, self.access == .authorized { self.startSession() }
                }
            }
        default:
            break
        }
    }

    func hide() {
        guard isShown else { return }
        stopSession()
        withAnimation(Anim.island) { isShown = false }
    }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    private func refreshAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: access = .authorized
        case .notDetermined: access = .unknown
        default: access = .denied
        }
    }

    /// Hides the mirror as soon as it can't be seen. Re-arms itself only while shown, so
    /// nothing is observed when the mirror is off.
    private func watch() {
        withObservationTracking {
            _ = vm.isOpen
            _ = vm.tab
            _ = settings.cameraMirror
        } onChange: { [weak self] in
            // onChange fires before the new value is stored; read it on the next turn.
            DispatchQueue.main.async {
                guard let self, self.isShown else { return }
                if self.vm.isOpen, self.vm.tab == .home, self.settings.cameraMirror { self.watch() } else { self.hide() }
            }
        }
    }

    private func startSession() {
        _ = previewLayer
        guard let session, let layer else { return }
        queue.async { [weak self] in
            if session.inputs.isEmpty {
                guard let device = Self.camera(),
                      let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else {
                    DispatchQueue.main.async { self?.access = .unavailable }
                    return
                }
                session.beginConfiguration()
                session.addInput(input)
                session.commitConfiguration()
                // People expect a mirror, not what the other side sees.
                if let c = layer.connection, c.isVideoMirroringSupported {
                    c.automaticallyAdjustsVideoMirroring = false
                    c.isVideoMirrored = true
                }
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    private func stopSession() {
        guard let session else { return }
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    /// The built-in front camera if there is one, else whatever the system offers.
    private static func camera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            ?? AVCaptureDevice.default(for: .video)
    }
}
