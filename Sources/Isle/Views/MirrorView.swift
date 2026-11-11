import AppKit
import AVFoundation
import SwiftUI

/// The camera mirror that stands in for Now Playing on Home. Same footprint and corners as
/// the album art, so swapping the two feels like one pane changing its content.
struct MirrorView: View {
    let env: AppEnvironment

    var body: some View {
        let mirror = env.mirror
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.islandFill)
            switch mirror.access {
            case .authorized:
                CameraPreview(layer: mirror.previewLayer)
                    .overlay(alignment: .bottomLeading) {
                        Text("Mirror")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.7))
                            .padding(.horizontal, 10).padding(.bottom, 8).padding(.top, 18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                    }
            case .unknown:
                Image(systemName: "camera.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.islandTertiary)
            case .denied:
                placeholder(icon: "video.slash.fill", text: "Isle can't use the camera.") {
                    PillButton(title: "Allow camera", icon: "camera.fill") { mirror.openPrivacySettings() }
                }
            case .unavailable:
                placeholder(icon: "video.slash.fill", text: "No camera found.") { EmptyView() }
            }
        }
        .frame(width: 192, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topTrailing) {
            IslandIconButton(systemName: "xmark", size: 9, weight: .bold, padding: 5) { mirror.hide() }
                .background(Circle().fill(Color.black.opacity(0.45)))
                .padding(6)
                .help("Close mirror")
        }
    }

    private func placeholder<Action: View>(icon: String, text: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.islandTertiary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Color.islandSecondary)
            action()
        }
        .padding(.horizontal, 12)
    }
}

/// The mirror's only way in from Home: sits left of an imminent meeting's join button, in the
/// same capsule but neutral, so joining stays the obvious action.
struct MirrorButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "camera.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 20)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.22 : 0.14)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Check your camera")
    }
}

/// Hosts the session's preview layer. The layer belongs to `MirrorService`, so the view only
/// lends it a place on screen.
private struct CameraPreview: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> PreviewHost {
        let v = PreviewHost()
        v.preview = layer
        return v
    }

    func updateNSView(_ v: PreviewHost, context: Context) {
        if v.preview !== layer { v.preview = layer }
    }

    final class PreviewHost: NSView {
        var preview: AVCaptureVideoPreviewLayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let preview { layer?.addSublayer(preview) }
                needsLayout = true
            }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            // SwiftUI's clipShape doesn't reach into AppKit-hosted layers, so round them here.
            layer?.cornerRadius = 16
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview?.frame = bounds
            CATransaction.commit()
        }
    }
}
