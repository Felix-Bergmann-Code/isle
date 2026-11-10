import SwiftUI

enum Anim {
    /// Springy open, like the iPhone island.
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.74, blendDuration: 0)
    /// Crisp, no-overshoot close.
    static let close = Animation.spring(response: 0.36, dampingFraction: 0.92, blendDuration: 0)
    static let island = Animation.spring(response: 0.4, dampingFraction: 0.8, blendDuration: 0)
    static let tab = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let micro = Animation.spring(response: 0.25, dampingFraction: 0.8)
}

/// The notch silhouette: concave "ears" at the top corners that melt into the
/// menu bar, rounded corners at the bottom. Both radii animate.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = max(0, min(topRadius, rect.width / 4))
        let b = max(0, min(bottomRadius, rect.height / 2, (rect.width - 2 * t) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // top-left ear (concave)
        p.addCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                   control1: CGPoint(x: rect.minX + t * 0.62, y: rect.minY),
                   control2: CGPoint(x: rect.minX + t, y: rect.minY + t * 0.38))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        // bottom-left (continuous-ish)
        p.addCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                   control1: CGPoint(x: rect.minX + t, y: rect.maxY - b * 0.42),
                   control2: CGPoint(x: rect.minX + t + b * 0.42, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        // bottom-right
        p.addCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                   control1: CGPoint(x: rect.maxX - t - b * 0.42, y: rect.maxY),
                   control2: CGPoint(x: rect.maxX - t, y: rect.maxY - b * 0.42))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        // top-right ear
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                   control1: CGPoint(x: rect.maxX - t, y: rect.minY + t * 0.38),
                   control2: CGPoint(x: rect.maxX - t * 0.62, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

private struct BlurFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 10 : 0)
            .opacity(active ? 0 : 1)
            .scaleEffect(active ? 0.9 : 1, anchor: .top)
    }
}

private struct SlideBlur: ViewModifier {
    let offset: CGFloat
    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .blur(radius: offset == 0 ? 0 : 6)
            .opacity(offset == 0 ? 1 : 0)
    }
}

extension AnyTransition {
    /// Content blooms in after the shape starts growing; disappears fast.
    static var blurFade: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
                .animation(.spring(response: 0.38, dampingFraction: 0.9).delay(0.07)),
            removal: .modifier(active: BlurFade(active: true), identity: BlurFade(active: false))
                .animation(.easeOut(duration: 0.12))
        )
    }

    static func tabSlide(_ direction: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: SlideBlur(offset: 36 * direction), identity: SlideBlur(offset: 0)),
            removal: .modifier(active: SlideBlur(offset: -36 * direction), identity: SlideBlur(offset: 0))
        )
    }
}

/// A hover-highlighting icon button used throughout the island.
struct IslandIconButton: View {
    let systemName: String
    var size: CGFloat = 14
    var weight: Font.Weight = .semibold
    var padding: CGFloat = 7
    var tint: Color = .white
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint.opacity(hovering ? 1 : 0.85))
                .frame(width: size + padding * 2, height: size + padding * 2)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
                .scaleEffect(pressed ? 0.86 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Anim.micro) { hovering = h } }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !pressed { withAnimation(Anim.micro) { pressed = true } } }
            .onEnded { _ in withAnimation(Anim.micro) { pressed = false } })
    }
}

extension Color {
    static let islandSecondary = Color.white.opacity(0.55)
    static let islandTertiary = Color.white.opacity(0.32)
    static let islandFill = Color.white.opacity(0.07)
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

func formatClock(_ seconds: Double) -> String {
    let s = Int(max(0, seconds.rounded(.down)))
    return String(format: "%d:%02d", s / 60, s % 60)
}
