import SwiftUI

/// An original little creature per agent. Body language shows the phase:
/// working → bouncy + looking around, waiting → wiggle + "!", done → happy
/// eyes + check, idle → sleepy breathing + "z".
struct AgentAvatar: View {
    let kind: AgentKind
    let phase: AgentPhase
    let size: CGFloat
    var seed: Double = 0
    /// false = a still pose (pair with LayerMotionView for free motion).
    var animated = true

    var body: some View {
        let detailed = size >= 22
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 1 / (phase == .idle ? 10 : 30))) { ctx in
                    creature(t: ctx.date.timeIntervalSinceReferenceDate + seed * 0.37, detailed: detailed)
                }
            } else {
                creature(t: 0.5, detailed: detailed)
            }
        }
        .frame(width: size, height: size)
    }

    private func creature(t: Double, detailed: Bool) -> some View {
        let m = motion(t)
        return ZStack {
            // body
            RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                .fill(LinearGradient(colors: [kind.color.mix(with: .white, by: 0.28), kind.color],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: max(0.5, size * 0.02))
                )
                .frame(width: size * 0.82, height: size * 0.74)
                .overlay(face(t: t), alignment: .center)
                .overlay(alignment: .top) {
                    if detailed {
                        Image(systemName: kind.accessory)
                            .font(.system(size: size * 0.2, weight: .black))
                            .foregroundStyle(kind.color.mix(with: .white, by: 0.5))
                            .offset(y: -size * 0.15)
                            .rotationEffect(.degrees(sin(t * 3) * (phase == .working ? 12 : 4)))
                    }
                }
                .scaleEffect(x: m.sx, y: m.sy, anchor: .bottom)
                .rotationEffect(.degrees(m.rot), anchor: .bottom)
                .offset(y: m.dy + size * 0.06)

            if detailed { badge(t: t) }
        }
    }

    private struct Motion { var dy: CGFloat = 0; var sx: CGFloat = 1; var sy: CGFloat = 1; var rot: Double = 0 }

    private func motion(_ t: Double) -> Motion {
        var m = Motion()
        switch phase {
        case .working:
            let b = abs(sin(t * 6.5))
            m.dy = -CGFloat(b) * size * 0.08
            let squash = CGFloat(max(0, 0.25 - b)) * 0.3
            m.sx = 1 + squash
            m.sy = 1 - squash
        case .waiting:
            let cycle = t.truncatingRemainder(dividingBy: 1.6)
            m.rot = cycle < 0.45 ? sin(cycle * 42) * 9 : 0
            m.dy = cycle < 0.45 ? -size * 0.03 : 0
        case .done:
            let cycle = t.truncatingRemainder(dividingBy: 2.4)
            m.dy = cycle < 0.3 ? -CGFloat(sin(cycle / 0.3 * .pi)) * size * 0.1 : 0
        case .idle:
            let br = sin(t * 1.7) * 0.025
            m.sy = 1 + CGFloat(br)
            m.sx = 1 - CGFloat(br) * 0.5
        }
        return m
    }

    @ViewBuilder private func face(t: Double) -> some View {
        let eyeW = size * 0.15
        let gap = size * 0.14
        HStack(spacing: gap) {
            eye(t: t, w: eyeW, mirrored: false)
            eye(t: t, w: eyeW, mirrored: true)
        }
        .offset(y: -size * 0.02)
    }

    @ViewBuilder private func eye(t: Double, w: CGFloat, mirrored: Bool) -> some View {
        switch phase {
        case .idle:
            Capsule().fill(Color.black.opacity(0.75)).frame(width: w * 1.1, height: max(1, size * 0.035))
        case .done:
            HappyEye().stroke(Color.black.opacity(0.78), style: StrokeStyle(lineWidth: max(1, size * 0.045), lineCap: .round))
                .frame(width: w * 1.1, height: w * 0.6)
        case .working, .waiting:
            let blink = t.truncatingRemainder(dividingBy: 3.3) < 0.11
            let look = phase == .working ? CGFloat(sin(t * 1.9)) * w * 0.28 : 0
            ZStack {
                Capsule().fill(Color.white).frame(width: w, height: blink ? w * 0.15 : w * 1.3)
                if !blink {
                    Circle().fill(Color.black).frame(width: w * 0.62, height: w * 0.62)
                        .offset(x: look, y: phase == .waiting ? -w * 0.2 : w * 0.1)
                }
            }
        }
    }

    @ViewBuilder private func badge(t: Double) -> some View {
        switch phase {
        case .waiting:
            Text("!")
                .font(.system(size: size * 0.26, weight: .black, design: .rounded))
                .foregroundStyle(.black)
                .frame(width: size * 0.34, height: size * 0.34)
                .background(Circle().fill(AgentPhase.waiting.color))
                .scaleEffect(1 + CGFloat(sin(t * 6)) * 0.08)
                .offset(x: size * 0.36, y: -size * 0.32)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.17, weight: .black))
                .foregroundStyle(.black)
                .frame(width: size * 0.32, height: size * 0.32)
                .background(Circle().fill(AgentPhase.done.color))
                .offset(x: size * 0.36, y: -size * 0.32)
        case .idle:
            let p = t.truncatingRemainder(dividingBy: 2.6) / 2.6
            Text("z")
                .font(.system(size: size * 0.2, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.7 * (1 - p)))
                .offset(x: size * 0.32 + CGFloat(p) * size * 0.08, y: -size * 0.22 - CGFloat(p) * size * 0.2)
        case .working:
            HStack(spacing: size * 0.04) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color.white)
                        .frame(width: size * 0.07, height: size * 0.07)
                        .opacity(0.35 + 0.65 * (sin(t * 7 - Double(i) * 0.9) * 0.5 + 0.5))
                }
            }
            .padding(.horizontal, size * 0.05).padding(.vertical, size * 0.04)
            .background(Capsule().fill(Color.white.opacity(0.18)))
            .offset(x: size * 0.36, y: -size * 0.34)
        }
    }
}

private struct HappyEye: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6))
        return p
    }
}
