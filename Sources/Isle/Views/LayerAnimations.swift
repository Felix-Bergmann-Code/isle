import AppKit
import SwiftUI

// Looping animations that stay visible while the island is closed are driven
// by Core Animation, not SwiftUI timelines. CA animations run in the render
// server, so a playing visualizer or a spinning agent ring costs ~0% CPU in
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

// MARK: - Spinner ring

struct LayerSpinner: NSViewRepresentable {
    let color: Color
    var lineWidth: CGFloat = 2

    func makeNSView(context: Context) -> SpinnerView { SpinnerView(lineWidth: lineWidth) }
    func updateNSView(_ v: SpinnerView, context: Context) { v.setColor(NSColor(color)) }
}

final class SpinnerView: NSView {
    private let arc = CAShapeLayer()
    private let lineWidth: CGFloat

    init(lineWidth: CGFloat) {
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineCap = .round
        arc.lineWidth = lineWidth
        arc.strokeStart = 0
        arc.strokeEnd = 0.3
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = bounds
        let inset = lineWidth / 2
        arc.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, arc.animation(forKey: "spin") == nil else { return }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = -Double.pi * 2
        a.duration = 0.9
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        arc.add(a, forKey: "spin")
    }

    func setColor(_ c: NSColor) { arc.strokeColor = c.cgColor }
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
