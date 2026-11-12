import AppKit
import UniformTypeIdentifiers

/// Keep a small image-only lookahead around the visible cards. The shared
/// thumbnail cache gives visible work priority and runs at most one prefetch.
final class ThumbnailPrefetcher {
    private let cache: ThumbnailCache
    private var requested = Set<String>()
    private var requests: [String: Operation] = [:]

    init(cache: ThumbnailCache = .shared) { self.cache = cache }
    deinit { for operation in requests.values { operation.cancel() } }

    static func neighborIndices(visible: ClosedRange<Int>, itemCount: Int) -> [Int] {
        guard itemCount > 0, visible.lowerBound < itemCount, visible.upperBound >= 0 else { return [] }
        let first = max(0, visible.lowerBound)
        let last = min(itemCount - 1, visible.upperBound)
        return Array(max(0, first - 2)..<first) + Array((last + 1)..<min(itemCount, last + 3))
    }

    func update(items: [Clip], visible: ClosedRange<Int>) {
        precondition(Thread.isMainThread)
        let clips = Self.neighborIndices(visible: visible, itemCount: items.count).map { items[$0] }.filter { clip in
            clip.byteCount <= 16 * 1024 * 1024 && (clip.kind == "图片" ||
                clip.files.contains { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true })
        }
        let keys = Set(clips.map { cache.key($0) as String })
        for key in Array(requests.keys) where !keys.contains(key) { requests.removeValue(forKey: key)?.cancel() }
        requested.formIntersection(keys)
        for clip in clips {
            let key = cache.key(clip) as String
            guard requested.insert(key).inserted else { continue }
            if let operation = cache.load(clip, prefetch: true, completion: { [weak self] _ in
                self?.requests.removeValue(forKey: key)
            }) {
                requests[key] = operation
            }
        }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        for operation in requests.values { operation.cancel() }
        requests.removeAll()
        requested.removeAll()
    }
}
