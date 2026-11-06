import AppKit
import QuartzCore

/// Cancellable shelf movement. The layer path runs on the compositor; the
/// numeric path remains available for callers that need individual updates.
final class ShelfSlideAnimator {
    static let layerAnimationKey = "Prism.ShelfSlideAnimator.translationY"

    enum Curve {
        case easeIn, easeOut

        func value(at progress: CGFloat) -> CGFloat {
            let p = min(1, max(0, progress))
            switch self {
            case .easeIn: return p * p
            case .easeOut: return 1 - (1 - p) * (1 - p) * (1 - p)
            }
        }

        var timingFunction: CAMediaTimingFunction {
            switch self {
            case .easeIn:
                return CAMediaTimingFunction(controlPoints: 1.0 / 3, 0, 2.0 / 3, 1.0 / 3)
            case .easeOut:
                return CAMediaTimingFunction(controlPoints: 1.0 / 3, 1, 2.0 / 3, 1)
            }
        }
    }

    private final class LayerDelegate: NSObject, CAAnimationDelegate {
        weak var animator: ShelfSlideAnimator?
        let generation: UInt64

        init(animator: ShelfSlideAnimator, generation: UInt64) {
            self.animator = animator; self.generation = generation
        }

        func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
            animator?.finishLayerAnimation(generation: generation, finished: flag)
        }
    }

    private final class LayerAnimation {
        weak var layer: CALayer?
        let delegate: LayerDelegate
        let startTransform: CATransform3D
        let completion: () -> Void

        init(layer: CALayer, delegate: LayerDelegate, startTransform: CATransform3D, completion: @escaping () -> Void) {
            self.layer = layer; self.delegate = delegate; self.startTransform = startTransform; self.completion = completion
        }
    }

    // CADisplayLink retains its target. A weak relay lets cancellation and
    // deinitialization tear down the link without a retain cycle.
    private final class DisplayTarget: NSObject {
        weak var animator: ShelfSlideAnimator?
        let generation: UInt64
        init(animator: ShelfSlideAnimator, generation: UInt64) {
            self.animator = animator; self.generation = generation
        }
        @objc func tick(_ link: CADisplayLink) {
            animator?.advance(at: max(CACurrentMediaTime(), link.targetTimestamp), generation: generation)
        }
    }
    private struct Animation {
        let start: CGFloat, end: CGFloat
        let began: CFTimeInterval, duration: TimeInterval
        let curve: Curve
        let update: (CGFloat) -> Void
        let completion: () -> Void
    }
    private var displayLink: CADisplayLink?
    private var fallbackTimer: Timer?
    private var animation: Animation?
    private var layerAnimation: LayerAnimation?
    private var generation: UInt64 = 0
    var isAnimating: Bool { animation != nil || layerAnimation != nil }

    deinit { cancel() }

    func cancel() {
        // Removing an animation can invoke its delegate. Invalidate its token
        // first, so neither cancellation nor reversal can finish an old slide.
        generation &+= 1
        stopDriver()
        animation = nil
        let previous = layerAnimation
        layerAnimation = nil
        if let previous, let layer = previous.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // A reversal can arrive before the first render-server commit.
            layer.sublayerTransform = layer.presentation()?.sublayerTransform ?? previous.startTransform
            CATransaction.commit()
            layer.removeAnimation(forKey: Self.layerAnimationKey)
        }
    }

    func animate(layer: CALayer, from start: CGFloat, to end: CGFloat,
                 duration: TimeInterval, curve: Curve,
                 completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        cancel()
        let token = generation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var startTransform = layer.sublayerTransform
        startTransform.m42 = start
        var transform = startTransform
        transform.m42 = end
        layer.sublayerTransform = transform
        CATransaction.commit()
        guard duration > 0, start != end else {
            if token == generation { completion() }
            return
        }

        let delegate = LayerDelegate(animator: self, generation: token)
        let slide = CABasicAnimation(keyPath: "sublayerTransform.translation.y")
        slide.fromValue = start
        slide.toValue = end
        slide.duration = duration
        slide.timingFunction = curve.timingFunction
        slide.delegate = delegate
        layerAnimation = LayerAnimation(layer: layer, delegate: delegate, startTransform: startTransform, completion: completion)
        layer.add(slide, forKey: Self.layerAnimationKey)
    }

    private func finishLayerAnimation(generation token: UInt64, finished: Bool) {
        guard token == generation, let previous = layerAnimation else { return }
        layerAnimation = nil
        if finished { previous.completion() }
    }

    private func stopDriver() {
        displayLink?.invalidate(); displayLink = nil
        fallbackTimer?.invalidate(); fallbackTimer = nil
    }

    func animate(from start: CGFloat, to end: CGFloat, duration: TimeInterval,
                 curve: Curve, window: NSWindow? = nil,
                 update: @escaping (CGFloat) -> Void,
                 completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        cancel()
        let token = generation
        guard duration > 0, start != end else {
            update(end)
            if token == generation { completion() }
            return
        }
        animation = Animation(start: start, end: end, began: CACurrentMediaTime(),
                              duration: duration, curve: curve, update: update, completion: completion)
        let target = DisplayTarget(animator: self, generation: token)
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let link: CADisplayLink?
        if let window, window.isVisible, window.screen != nil {
            link = window.displayLink(target: target, selector: #selector(DisplayTarget.tick(_:)))
        } else {
            // Isolated driver tests need no visible window. Normal shelf
            // presentation always uses the window link above.
            link = screen?.displayLink(target: target, selector: #selector(DisplayTarget.tick(_:)))
        }
        if let link {
            if let screen {
                let maximum = Float(max(1, screen.maximumFramesPerSecond))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            }
            displayLink = link
            link.add(to: .main, forMode: .common)
        } else {
            // No display exists in a headless process. Keep completion/cancel
            // semantics usable there without a permanently running driver.
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                self?.advance(at: CACurrentMediaTime(), generation: token)
            }
            fallbackTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func advance(at timestamp: CFTimeInterval, generation token: UInt64) {
        guard token == generation, let animation else { return }
        let progress = min(1, max(0, (timestamp - animation.began) / animation.duration))
        animation.update(animation.start + (animation.end - animation.start) * animation.curve.value(at: CGFloat(progress)))
        // An update can itself reverse/cancel the animation. Never finish that
        // superseded animation or invalidate the replacement display link.
        guard token == generation else { return }
        if progress >= 1 {
            stopDriver()
            self.animation = nil
            animation.completion()
        }
    }
}
