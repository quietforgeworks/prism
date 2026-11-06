import AppKit
import QuickLookThumbnailing

/// A subscription, rather than the shared worker. Cancelling one reused card
/// must not cancel another card's request for the same thumbnail or app icon.
private final class ImageSubscription: Operation, @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (() -> Void)?
    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init()
    }
    override func cancel() {
        super.cancel()
        lock.lock()
        let action = onCancel
        onCancel = nil
        lock.unlock()
        action?()
    }
}

/// All scheduling and subscription state belongs to the main thread. Only
/// bounded image decoding / workspace lookup runs on workers. Quick Look is
/// already asynchronous; it never occupies a worker waiting on a semaphore.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    let images = NSCache<NSString, NSImage>()
    let icons = NSCache<NSString, NSImage>()
    // Full-size preview work must not delay the small shelf thumbnails.
    let queue = ThumbnailCache.makeQueue("Prism.Previews", concurrent: 1)
    private let thumbnailQueue = ThumbnailCache.makeQueue("Prism.Thumbnails", concurrent: 2)
    private let iconQueue = ThumbnailCache.makeQueue("Prism.AppIcons", concurrent: 1)
    private let maximumPending = 64
    private let maximumSubscribers = 32

    private enum Input {
        case thumbnail(Clip), icon(String)
        var lane: Int { if case .icon = self { return 1 }; return 0 }
    }
    private struct Subscriber {
        let token: ImageSubscription
        let completion: (NSImage?) -> Void
    }
    private final class Job {
        enum Phase { case queued, decoding, quickLook, finished }
        let id = UUID()
        let key: String
        let input: Input
        var subscribers: [UUID: Subscriber] = [:]
        var phase = Phase.queued
        var request: QLThumbnailGenerator.Request?
        var timeout: DispatchWorkItem?
        init(key: String, input: Input) { self.key = key; self.input = input }
    }
    private var jobs: [String: Job] = [:]
    private var pending: [[Job]] = [[], []]
    private var active: [[UUID: Job]] = [[:], [:]]

    init() {
        images.totalCostLimit = 20 * 1024 * 1024
        images.countLimit = 100
        icons.totalCostLimit = 4 * 1024 * 1024
        icons.countLimit = 48
    }
    private static func makeQueue(_ name: String, concurrent: Int) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = name
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = concurrent
        return queue
    }
    func key(_ clip: Clip) -> NSString { "\(clip.id)-\(clip.fingerprint)" as NSString }

    @discardableResult
    func load(_ clip: Clip, completion: @escaping (NSImage?) -> Void) -> Operation? {
        precondition(Thread.isMainThread)
        let cacheKey = key(clip)
        if let image = images.object(forKey: cacheKey) { completion(image); return nil }
        return subscribe(key: "thumbnail:\(cacheKey)", input: .thumbnail(clip), completion: completion)
    }

    @discardableResult
    func icon(_ bundle: String, completion: @escaping (NSImage?) -> Void) -> Operation? {
        precondition(Thread.isMainThread)
        if let image = icons.object(forKey: bundle as NSString) { completion(image); return nil }
        guard !bundle.isEmpty else { completion(nil); return nil }
        return subscribe(key: "icon:\(bundle)", input: .icon(bundle), completion: completion)
    }

    private func subscribe(key: String, input: Input, completion: @escaping (NSImage?) -> Void) -> Operation? {
        let job: Job
        if let existing = jobs[key] {
            // Even callers that forget to cancel cannot grow a single-flight
            // request's callback list without a bound.
            guard existing.subscribers.count < maximumSubscribers else { completion(nil); return nil }
            job = existing
        } else {
            let lane = input.lane
            // Prefer recently visible cards if requests arrive faster than
            // providers can complete them. Dropped previews keep their icon.
            if pending[lane].count >= maximumPending, let oldest = pending[lane].first {
                finish(oldest, image: nil)
            }
            job = Job(key: key, input: input)
            jobs[key] = job
            pending[lane].append(job)
        }
        let subscriberID = UUID()
        let jobID = job.id
        let token = ImageSubscription { [weak self] in
            let cancel = { [weak self] in self?.cancel(key: key, jobID: jobID, subscriberID: subscriberID) }
            if Thread.isMainThread { cancel() }
            else { DispatchQueue.main.async { cancel() } }
        }
        job.subscribers[subscriberID] = Subscriber(token: token, completion: completion)
        startAvailableJobs(in: input.lane)
        return token
    }

    private func startAvailableJobs(in lane: Int) {
        let concurrency = lane == 0 ? 2 : 1
        while active[lane].count < concurrency, !pending[lane].isEmpty {
            let job = pending[lane].removeFirst()
            guard job.phase == .queued, !job.subscribers.isEmpty else { continue }
            job.phase = .decoding
            active[lane][job.id] = job
            switch job.input {
            case .thumbnail(let clip):
                thumbnailQueue.addOperation { [weak self, job] in
                    let result: (NSImage?, URL?) = autoreleasepool {
                        if let image = clip.thumbnail(maxPixelSize: 640) { return (image, nil) }
                        if let url = clip.files.first, FileManager.default.fileExists(atPath: url.path) { return (nil, url) }
                        return (nil, nil)
                    }
                    DispatchQueue.main.async { self?.decoded(job, image: result.0, file: result.1) }
                }
            case .icon(let bundle):
                iconQueue.addOperation { [weak self, job] in
                    let image: NSImage? = autoreleasepool {
                        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
                        // Rasterize only the representation needed by the card,
                        // rather than retaining an entire multi-size icon family.
                        let source = NSWorkspace.shared.icon(forFile: url.path)
                        var rect = NSRect(x: 0, y: 0, width: 96, height: 96)
                        guard let cg = source.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                              let context = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8,
                                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                        context.interpolationQuality = .high
                        context.draw(cg, in: CGRect(x: 0, y: 0, width: 96, height: 96))
                        guard let rendered = context.makeImage() else { return nil }
                        return NSImage(cgImage: rendered, size: NSSize(width: 48, height: 48))
                    }
                    DispatchQueue.main.async { self?.finish(job, image: image) }
                }
            }
        }
    }

    private func decoded(_ job: Job, image: NSImage?, file: URL?) {
        guard job.phase == .decoding else { return }
        guard !job.subscribers.isEmpty else { finish(job, image: nil); return }
        if let image { finish(job, image: image); return }
        guard let file else { finish(job, image: nil); return }
        let request = QLThumbnailGenerator.Request(fileAt: file, size: NSSize(width: 280, height: 230), scale: 2, representationTypes: .thumbnail)
        job.phase = .quickLook
        job.request = request
        let timeout = DispatchWorkItem { [weak self, weak job] in
            guard let self, let job, job.phase == .quickLook else { return }
            QLThumbnailGenerator.shared.cancel(request)
            self.finish(job, image: nil)
        }
        job.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self, weak job] representation, _ in
            let image = representation?.nsImage
            DispatchQueue.main.async {
                guard let self, let job, job.phase == .quickLook else { return }
                self.finish(job, image: image)
            }
        }
    }

    private func cancel(key: String, jobID: UUID, subscriberID: UUID) {
        guard let job = jobs[key], job.id == jobID else { return }
        job.subscribers.removeValue(forKey: subscriberID)
        guard job.subscribers.isEmpty else { return }
        jobs.removeValue(forKey: key)
        if job.phase == .decoding {
            // A synchronous ImageIO/Workspace call cannot be interrupted. Keep
            // its slot until it returns, so cancellation cannot exceed the
            // decoder concurrency or allow stale work to accumulate.
            return
        }
        if let request = job.request { QLThumbnailGenerator.shared.cancel(request) }
        finish(job, image: nil)
    }

    private func finish(_ job: Job, image: NSImage?) {
        guard job.phase != .finished else { return }
        job.phase = .finished
        job.timeout?.cancel(); job.timeout = nil; job.request = nil
        let lane = job.input.lane
        pending[lane].removeAll { $0 === job }
        active[lane].removeValue(forKey: job.id)
        if jobs[job.key] === job { jobs.removeValue(forKey: job.key) }
        let subscribers = job.subscribers.values
        job.subscribers = [:]
        if let image, !subscribers.isEmpty {
            switch job.input {
            case .thumbnail(let clip): images.setObject(image, forKey: key(clip), cost: cost(image))
            case .icon(let bundle): icons.setObject(image, forKey: bundle as NSString, cost: cost(image))
            }
        }
        // Release the job before delivering callbacks: a callback may request
        // or cancel more cards, including this same key.
        startAvailableJobs(in: lane)
        for subscriber in subscribers where !subscriber.token.isCancelled { subscriber.completion(image) }
    }

    private func cost(_ image: NSImage) -> Int {
        image.representations.map { max(1, $0.pixelsWide) * max(1, $0.pixelsHigh) * 4 }.max()
            ?? Int(image.size.width * image.size.height * 4)
    }
}
