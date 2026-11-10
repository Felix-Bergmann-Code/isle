import AppKit
import SwiftUI

// Looping animations that stay visible while the island is closed are driven
// by Core Animation, not SwiftUI timelines. CA animations run in the render
// server, so a playing visualizer or the agent thinking dots cost ~0% CPU in
// Isle instead of re-rendering the SwiftUI display list 20–120× a second.

// MARK: - Audio bars

struct LayerAudioBars: NSViewRepresentable {
    let playing: Bool
    let color: Color
    var count = 4
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2.5

    func makeNSView(context: Context) -> BarsView { BarsView(count: count, barWidth: barWidth, spacing: spacing) }

    func updateNSView(_ v: BarsView, context: Context) {
        v.setColor(NSColor(color))
        v.setPlaying(playing)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BarsView, context: Context) -> CGSize? {
        CGSize(width: CGFloat(count) * barWidth + CGFloat(count - 1) * spacing, height: proposal.height ?? 14)
    }
}

final class BarsView: NSView {
    private var bars: [CALayer] = []
    private let barWidth: CGFloat
    private let spacing: CGFloat
    private var playing = false

    init(count: Int, barWidth: CGFloat, spacing: CGFloat) {
        self.barWidth = barWidth
        self.spacing = spacing
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<count {
            let l = CALayer()
            l.backgroundColor = NSColor.white.cgColor
            l.cornerRadius = barWidth / 2
            l.transform = CATransform3DMakeScale(1, 0.22, 1)
            layer?.addSublayer(l)
            bars.append(l)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let total = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * spacing
        var x = (bounds.width - total) / 2
        for l in bars {
            l.bounds = CGRect(x: 0, y: 0, width: barWidth, height: bounds.height)
            l.position = CGPoint(x: x + barWidth / 2, y: bounds.midY)
            x += barWidth + spacing
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, playing { start() }
    }

    func setColor(_ c: NSColor) {
        for l in bars where l.backgroundColor != c.cgColor { l.backgroundColor = c.cgColor }
    }

    func setPlaying(_ p: Bool) {
        guard p != playing else { return }
        playing = p
        p ? start() : stop()
    }

    private func start() {
        for (i, l) in bars.enumerated() where l.animation(forKey: "eq") == nil {
            let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
            var rng = SystemRandomNumberGenerator()
            a.values = (0..<7).map { _ in Double.random(in: 0.25...1, using: &rng) } + [0.4]
            a.values?.insert(0.4, at: 0)
            a.duration = 1.1 + Double(i) * 0.17
            a.calculationMode = .cubic
            a.repeatCount = .infinity
            a.beginTime = CACurrentMediaTime() - Double(i) * 0.23
            a.isRemovedOnCompletion = false
            l.add(a, forKey: "eq")
        }
    }

    private func stop() {
        for l in bars {
            let current = l.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat ?? 0.22
            l.removeAnimation(forKey: "eq")
            let settle = CABasicAnimation(keyPath: "transform.scale.y")
            settle.fromValue = current
            settle.toValue = 0.22
            settle.duration = 0.25
            l.transform = CATransform3DMakeScale(1, 0.22, 1)
            l.add(settle, forKey: "settle")
        }
    }
}

// MARK: - Thinking dots

/// Four dots on a 2×2 grid that keep trading places: two opposite dots swing
/// past their neighbours and swap corners, then the other diagonal pair swaps
/// the mirrored way. Path and timing are traced from the Claude Code "thinking"
/// indicator (recorded at 120 fps), so the motion is one continuous glide.
struct LayerThinkingDots: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> ThinkingDotsView { ThinkingDotsView() }
    func updateNSView(_ v: ThinkingDotsView, context: Context) { v.setColor(NSColor(color)) }
}

final class ThinkingDotsView: NSView {
    /// One swap, top-left → bottom-right, in units of half the grid spacing
    /// (x right, y down). Times are fractions of a swap.
    private static let swapPath: [(t: Double, x: Double, y: Double)] = [
        (0.00, -1.00, -1.00), (0.10, -0.93, -0.80), (0.20, -0.80, -0.47),
        (0.31, -0.58, 0.00), (0.37, -0.47, 0.40), (0.43, -0.27, 0.70),
        (0.48, -0.03, 0.93), (0.54, 0.20, 1.10), (0.59, 0.40, 1.19),
        (0.65, 0.60, 1.20), (0.74, 0.77, 1.15), (0.85, 0.90, 1.09),
        (0.94, 0.97, 1.03), (1.00, 1.00, 1.00),
    ]

    /// Corners as (x, y) signs, y down: TL, TR, BL, BR.
    private static let corners: [(Double, Double)] = [(-1, -1), (1, -1), (-1, 1), (1, 1)]

    private var dots: [CALayer] = []
    private var laidOutSize: CGSize = .zero
    private let swap: CFTimeInterval = 0.62
    private let samples = 60

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        for _ in 0..<4 {
            let l = CALayer()
            l.backgroundColor = NSColor.white.cgColor
            dots.append(l)
            layer?.addSublayer(l)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize, bounds.width > 0 else { return }
        laidOutSize = bounds.size
        install()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { install() }
    }

    func setColor(_ c: NSColor) {
        for l in dots where l.backgroundColor != c.cgColor { l.backgroundColor = c.cgColor }
    }

    /// Smooth (C1) interpolation through `swapPath`, starting and ending at rest.
    private static func swapPoint(_ u: Double) -> (Double, Double) {
        let k = swapPath
        guard u > 0 else { return (k[0].x, k[0].y) }
        guard u < 1 else { return (k[k.count - 1].x, k[k.count - 1].y) }
        var i = 0
        while k[i + 1].t < u { i += 1 }
        func tangent(_ j: Int) -> (Double, Double) {
            if j == 0 || j == k.count - 1 { return (0, 0) }
            let dt = k[j + 1].t - k[j - 1].t
            return ((k[j + 1].x - k[j - 1].x) / dt, (k[j + 1].y - k[j - 1].y) / dt)
        }
        let a = k[i], b = k[i + 1], dt = b.t - a.t
        let s = (u - a.t) / dt, s2 = s * s, s3 = s2 * s
        let h00 = 2 * s3 - 3 * s2 + 1, h10 = s3 - 2 * s2 + s
        let h01 = -2 * s3 + 3 * s2, h11 = s3 - s2
        let ma = tangent(i), mb = tangent(i + 1)
        return (h00 * a.x + h10 * dt * ma.0 + h01 * b.x + h11 * dt * mb.0,
                h00 * a.y + h10 * dt * ma.1 + h01 * b.y + h11 * dt * mb.1)
    }

    private func install() {
        guard window != nil, bounds.width > 0 else { return }
        let side = min(bounds.width, bounds.height)
        let half = side * 0.2                 // half the distance between dot centres
        let d = max(2, half * 0.72)           // dot diameter ≈ ⅓ of the spacing
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        func pt(_ x: Double, _ y: Double) -> NSValue {
            NSValue(point: CGPoint(x: c.x + CGFloat(x) * half, y: c.y - CGFloat(y) * half))
        }

        // Four swaps bring every dot back to where it started: TL↔BR, TR↔BL, TL↔BR, TR↔BL.
        let swaps = 4
        var at = [0, 1, 2, 3]                 // corner index each dot currently sits on
        var values = [[NSValue]](repeating: [], count: 4)
        var times = [[NSNumber]](repeating: [], count: 4)
        for h in 0..<swaps {
            let active: Set<Int> = h % 2 == 0 ? [0, 3] : [1, 2]
            let t0 = Double(h) / Double(swaps), t1 = Double(h + 1) / Double(swaps)
            for dot in 0..<4 {
                let corner = at[dot]
                let (sx, sy) = Self.corners[corner]
                if active.contains(corner) {
                    // Mirror the traced TL→BR swap so it starts from this corner.
                    for n in 0...samples {
                        let u = Double(n) / Double(samples)
                        let (x, y) = Self.swapPoint(u)
                        values[dot].append(pt(-sx * x, -sy * y))
                        times[dot].append(NSNumber(value: t0 + (t1 - t0) * u))
                    }
                    at[dot] = 3 - corner      // opposite corner
                } else {
                    values[dot] += [pt(sx, sy), pt(sx, sy)]
                    times[dot] += [NSNumber(value: t0), NSNumber(value: t1)]
                }
            }
        }

        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, l) in dots.enumerated() {
            l.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            l.cornerRadius = d / 2
            l.position = values[i][0].pointValue
            l.removeAnimation(forKey: "shuffle")
            let a = CAKeyframeAnimation(keyPath: "position")
            a.values = values[i]
            a.keyTimes = times[i]
            a.calculationMode = .linear
            a.duration = swap * Double(swaps)
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            a.beginTime = now
            l.add(a, forKey: "shuffle")
        }
        CATransaction.commit()
    }
}

// MARK: - Bob / wiggle any SwiftUI view on the render server

enum LayerMotion: Equatable {
    case none, bob, wiggle, breathe
}

struct LayerMotionView<Content: View>: NSViewRepresentable {
    let motion: LayerMotion
    var amplitude: CGFloat = 2
    var phase: Double = 0
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> MotionHost<Content> {
        MotionHost(root: content())
    }

    func updateNSView(_ v: MotionHost<Content>, context: Context) {
        v.host.rootView = content()
        v.apply(motion, amplitude: amplitude, phase: phase)
    }
}

final class MotionHost<Content: View>: NSView {
    let host: NSHostingView<Content>
    private var motion: LayerMotion = .none
    private var amplitude: CGFloat = 2
    private var phase: Double = 0

    init(root: Content) {
        host = NSHostingView(rootView: root)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        host.wantsLayer = true
        host.sizingOptions = []
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { install() }
    }

    func apply(_ m: LayerMotion, amplitude: CGFloat, phase: Double) {
        guard m != motion || amplitude != self.amplitude else { return }
        motion = m
        self.amplitude = amplitude
        self.phase = phase
        install()
    }

    private func install() {
        guard let l = host.layer else { return }
        l.removeAnimation(forKey: "motion")
        let a: CAAnimation
        switch motion {
        case .none:
            return
        case .bob:
            let k = CAKeyframeAnimation(keyPath: "transform.translation.y")
            k.values = [0, amplitude, 0, amplitude * 0.35, 0]
            k.keyTimes = [0, 0.22, 0.45, 0.6, 0.75]
            k.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
            k.duration = 0.62
            a = k
        case .wiggle:
            let k = CAKeyframeAnimation(keyPath: "transform.translation.x")
            k.values = [0, -amplitude, amplitude, -amplitude, amplitude * 0.6, 0, 0]
            k.keyTimes = [0, 0.06, 0.12, 0.18, 0.24, 0.3, 1]
            k.duration = 1.6
            a = k
        case .breathe:
            let k = CAKeyframeAnimation(keyPath: "transform.translation.y")
            k.values = [0, amplitude * 0.5, 0]
            k.duration = 2.8
            k.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            a = k
        }
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        a.beginTime = CACurrentMediaTime() + phase
        l.add(a, forKey: "motion")
    }
}
