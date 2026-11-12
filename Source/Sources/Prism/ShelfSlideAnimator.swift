import AppKit
import QuartzCore

/// Shelf motion runs on the compositor, with no application-side frame loop.
final class ShelfSlideAnimator {
    static let layerAnimationKey = "Prism.ShelfSlideAnimator.translationY"

    enum Curve {
        case easeIn, easeOut
        var timingFunction: CAMediaTimingFunction {
            switch self {
            case .easeIn: return CAMediaTimingFunction(controlPoints: 1.0 / 3, 0, 2.0 / 3, 1.0 / 3)
            case .easeOut: return CAMediaTimingFunction(controlPoints: 1.0 / 3, 1, 2.0 / 3, 1)
            }
        }
    }
    private final class Delegate: NSObject, CAAnimationDelegate {
        weak var animator: ShelfSlideAnimator?
        let generation: UInt64
        init(animator: ShelfSlideAnimator, generation: UInt64) {
            self.animator = animator
            self.generation = generation
        }
        func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
            animator?.finish(generation: generation, finished: flag)
        }
    }
    private struct Animation {
        weak var layer: CALayer?
        var delegate: Delegate
        var startTransform: CATransform3D
        var completion: () -> Void
    }
    private var animation: Animation?
    private var generation: UInt64 = 0
    var isAnimating: Bool { animation != nil }
    deinit { cancel() }

    func cancel() {
        generation &+= 1
        guard let previous = animation else { return }
        animation = nil
        guard let layer = previous.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Preserve a reversal even before the first render-server commit.
        layer.sublayerTransform = layer.presentation()?.sublayerTransform ?? previous.startTransform
        CATransaction.commit()
        layer.removeAnimation(forKey: Self.layerAnimationKey)
    }

    func animate(layer: CALayer, from start: CGFloat, to end: CGFloat,
                 duration: TimeInterval, curve: Curve, window: NSWindow? = nil,
                 completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        cancel()
        let token = generation
        var startTransform = layer.sublayerTransform
        startTransform.m42 = start
        var endTransform = startTransform
        endTransform.m42 = end
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = endTransform
        CATransaction.commit()
        guard duration > 0, start != end else { completion(); return }

        let delegate = Delegate(animator: self, generation: token)
        let slide = CABasicAnimation(keyPath: "sublayerTransform.translation.y")
        slide.fromValue = start
        slide.toValue = end
        slide.duration = duration
        slide.timingFunction = curve.timingFunction
        slide.delegate = delegate
        if let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first {
            let maximum = Float(max(1, screen.maximumFramesPerSecond))
            slide.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        }
        animation = Animation(layer: layer, delegate: delegate, startTransform: startTransform, completion: completion)
        layer.add(slide, forKey: Self.layerAnimationKey)
    }

    private func finish(generation token: UInt64, finished: Bool) {
        guard token == generation, let previous = animation else { return }
        animation = nil
        if finished { previous.completion() }
    }
}
