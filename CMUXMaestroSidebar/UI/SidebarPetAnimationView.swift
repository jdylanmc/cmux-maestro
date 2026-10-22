import AppKit

final class SidebarPetAnimationView: NSView {
    private var frames: [CGImage] = []
    private let imageLayer = CALayer()
    static let animationKey = "pet-frames"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .linear
        layer?.addSublayer(imageLayer)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setFrames(_ frames: [CGImage]) {
        guard self.frames.count != frames.count || !zip(self.frames, frames).allSatisfy({ $0 === $1 }) else { return }
        self.frames = frames
        imageLayer.removeAnimation(forKey: Self.animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = frames.first
        CATransaction.commit()
        updateAnimation()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAnimation() }
    override func viewDidHide() { super.viewDidHide(); updateAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateAnimation() }

    private func updateAnimation() {
        guard window != nil, !isHiddenOrHasHiddenAncestor, frames.count > 1 else {
            imageLayer.removeAnimation(forKey: Self.animationKey)
            return
        }
        guard imageLayer.animation(forKey: Self.animationKey) == nil else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.keyTimes = frames.indices.map { NSNumber(value: Double($0) / Double(frames.count)) }
        animation.calculationMode = .discrete
        animation.duration = Double(frames.count) / 7
        animation.repeatCount = .infinity
        imageLayer.add(animation, forKey: Self.animationKey)
    }
}
