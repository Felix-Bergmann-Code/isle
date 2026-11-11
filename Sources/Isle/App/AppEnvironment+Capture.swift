import SwiftUI

/// Microphone & camera in use: an iOS-style dot beside the notch while closed and a small
/// glyph in the open header. No banners; macOS already announces capture, this stays ambient.
extension AppEnvironment {
    func startCaptureIndicator() {
        capture.onChange = { [weak self] in self?.updateCaptureLive() }
        settings.onCaptureChange = { [weak self] in self?.applyCaptureSetting() }
        applyCaptureSetting()
    }

    private func applyCaptureSetting() {
        // Off means no listeners at all, not just a hidden dot.
        if settings.showCaptureIndicator { capture.start() } else { capture.stop() }
        updateCaptureLive()
    }

    private func updateCaptureLive() {
        guard settings.showCaptureIndicator, capture.micInUse || capture.cameraInUse else {
            vm.clearLive("capture")
            return
        }
        // Camera wins when both are on, as on iOS.
        let camera = capture.cameraInUse
        vm.setLive(LiveItem(id: "capture", priority: 10, icon: camera ? "video.fill" : "mic.fill",
                            tint: camera ? .cameraInUse : .micInUse, style: .dot))
    }
}
