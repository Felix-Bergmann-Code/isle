import SwiftUI

extension Color {
    /// The tints of macOS's own privacy indicators.
    static let micInUse = Color(red: 1.0, green: 0.58, blue: 0.0)
    static let cameraInUse = Color(red: 0.2, green: 0.84, blue: 0.29)
}

/// Header accessory while the mic or a camera is in use: the dot from the closed island plus
/// the glyph saying which. Nothing at all when idle.
struct CaptureHeaderIndicator: View {
    let env: AppEnvironment

    var body: some View {
        let mic = env.capture.micInUse
        let camera = env.capture.cameraInUse
        if env.settings.showCaptureIndicator, mic || camera {
            let tint: Color = camera ? .cameraInUse : .micInUse
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Image(systemName: camera ? "video.fill" : "mic.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(camera && mic ? "Camera and microphone in use" : camera ? "Camera in use" : "Microphone in use")
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }
}
