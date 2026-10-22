import AppKit

final class SidebarStatusAnimationView: NSView {
    enum Kind { case working, question, background }
    private(set) var kind: Kind = .working
    private let shape = CAShapeLayer()
    private let glyph = CALayer()
    private let innerGlow = CALayer()
    private let outerGlow = CALayer()
    static let animationKey = "status-decoration"
    private static let blue = NSColor(srgbRed: 0.45, green: 0.75, blue: 1, alpha: 1)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for child in [shape, outerGlow, innerGlow, glyph] { layer?.addSublayer(child) }
        setAccessibilityElement(false)
        refresh()
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ kind: Kind) {
        guard kind != self.kind else { return }
        self.kind = kind
        for child in [shape, innerGlow, outerGlow] { child.removeAnimation(forKey: Self.animationKey) }
        refresh()
    }

    override func layout() { super.layout(); refresh() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAnimation() }
    override func viewDidHide() { super.viewDidHide(); updateAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateAnimation() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.isHidden = kind == .question
        for child in [glyph, innerGlow, outerGlow] { child.isHidden = kind != .question }
        shape.frame = bounds
        switch kind {
        case .working:
            shape.path = CGPath(ellipseIn: bounds, transform: nil)
            shape.fillColor = nil
            effectiveAppearance.performAsCurrentDrawingAppearance { shape.strokeColor = NSColor.systemGreen.cgColor }
            shape.lineWidth = 1.3
            shape.lineCap = .round
            shape.strokeStart = 0.15
            shape.strokeEnd = 1
            shape.opacity = 1
        case .background:
            shape.path = CGPath(roundedRect: bounds, cornerWidth: 4, cornerHeight: 4, transform: nil)
            shape.fillColor = Self.blue.cgColor
            shape.strokeColor = nil
            shape.opacity = 0.13
        case .question:
            let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .heavy)
                .applying(.init(paletteColors: [Self.blue]))
            let image = NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            let size = image?.size ?? .zero
            let rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height)
            for child in [glyph, innerGlow, outerGlow] {
                child.frame = rect
                child.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                child.contentsScale = window?.backingScaleFactor ?? 2
                child.shadowColor = Self.blue.cgColor
                child.shadowOffset = .zero
            }
            innerGlow.shadowRadius = 2
            innerGlow.shadowOpacity = 0.55
            outerGlow.shadowRadius = 2.5
            outerGlow.shadowOpacity = 0.55 * 0.7
        }
        CATransaction.commit()
        updateAnimation()
    }

    private func updateAnimation() {
        guard window != nil, !isHiddenOrHasHiddenAncestor else {
            for child in [shape, innerGlow, outerGlow] { child.removeAnimation(forKey: Self.animationKey) }
            return
        }
        switch kind {
        case .working:
            guard shape.animation(forKey: Self.animationKey) == nil else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 1
            spin.repeatCount = .infinity
            shape.add(spin, forKey: Self.animationKey)
        case .background:
            pulse(shape, keyPath: "opacity", midpoint: 0.13, amplitude: 0.07)
        case .question:
            pulse(innerGlow, keyPath: "shadowOpacity", midpoint: 0.55, amplitude: 0.45)
            pulse(outerGlow, keyPath: "shadowOpacity", midpoint: 0.55 * 0.7, amplitude: 0.45 * 0.7)
        }
    }

    private func pulse(_ layer: CALayer, keyPath: String, midpoint: Double, amplitude: Double) {
        guard layer.animation(forKey: Self.animationKey) == nil else { return }
        let pulse = CAKeyframeAnimation(keyPath: keyPath)
        pulse.values = (0...60).map { midpoint + amplitude * sin(Double($0) / 60 * 2 * .pi) }
        pulse.duration = 2 * .pi / 1.5
        pulse.repeatCount = .infinity
        layer.add(pulse, forKey: Self.animationKey)
    }
}
