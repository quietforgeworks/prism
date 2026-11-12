import AppKit

private func performanceShelf(directory: URL) -> ShelfController {
    let actions = ShelfActions(paste: { _, _ in }, copy: { _, _ in }, enqueue: { _ in }, settings: {}, pauseToggle: {}, stackToggle: {},
                               clear: {}, export: {}, import: {}, quit: {}, isPaused: { false }, isStack: { false },
                               targetName: { "Fixture" }, invalidatePendingPaste: {})
    return ShelfController(store: ClipStore(directory: directory), actions: actions)
}

func testHiddenCardDoesNotLoadAssets(directory: URL) throws {
    let shelf = performanceShelf(directory: directory)
    let card = ClipCard(frame: NSRect(x: 0, y: 0, width: 270, height: 280))
    let host = NSWindow(contentRect: card.bounds, styleMask: .borderless, backing: .buffered, defer: false)
    host.isReleasedWhenClosed = false
    host.contentView = card
    let clip = Clip(source: "Image Fixture", bundle: "local.prism.fixture.missing-app", payloads: [Payload(types: ["public.png": try tinyImageData().png])])
    let initial = ThumbnailCache.shared.outstandingRequestCount
    card.configure(clip, selected: false, number: nil, shelf: shelf)
    card.resumeVisibleContent()
    try require(ThumbnailCache.shared.outstandingRequestCount == initial,
                "Hidden card started thumbnail or app-icon loading")
    try require(!host.isVisible, "Asset-demand test showed a window")
    card.reset()
    host.close()
}

func testScrollDefersCardUpdates(directory: URL) throws {
    let shelf = performanceShelf(directory: directory)
    let card = ClipCard(frame: NSRect(x: 0, y: 0, width: 270, height: 280))
    let host = NSWindow(contentRect: card.bounds, styleMask: .borderless, backing: .buffered, defer: false)
    host.isReleasedWhenClosed = false
    host.contentView = card
    let clip = Clip(source: "Fixture", bundle: "", payloads: [Payload(types: ["public.utf8-plain-text": Data("scroll fixture".utf8)])])
    card.configure(clip, selected: false, number: nil, shelf: shelf)
    card.needsDisplay = false
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: shelf.scroll)
    try require(!shelf.deferCardRefresh(allowDuringMotion: true), "Loaded image remains blocked until scrolling stops")
    card.setFileUnavailable(true)
    try require(shelf.isInteracting && card.deferredContentUpdate, "Status update bypassed deferral during live scrolling")
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: shelf.scroll)
    card.resumeVisibleContent()
    try require(!shelf.isInteracting && !card.deferredContentUpdate, "Deferred card update was not resumed after scrolling")
    card.reset()
    host.close()
}

func testThumbnailPrefetchBounds() throws {
    try require(ThumbnailPrefetcher.neighborIndices(visible: 4...7, itemCount: 20) == [2, 3, 8, 9], "Image lookahead exceeded two cards on either side")
    try require(ThumbnailPrefetcher.neighborIndices(visible: 0...2, itemCount: 3).isEmpty, "Fully visible data was prefetched again")
    try require(ThumbnailPrefetcher.neighborIndices(visible: 0...2, itemCount: 10) == [3, 4], "Leading-edge lookahead is incorrect")
    try require(ThumbnailPrefetcher.neighborIndices(visible: 7...9, itemCount: 10) == [5, 6], "Trailing-edge lookahead is incorrect")
    let cache = ThumbnailCache()
    let prefetcher = ThumbnailPrefetcher(cache: cache)
    let huge = Clip(source: "Large Fixture", bundle: "", payloads: [Payload(types: ["public.png": Data(repeating: 0, count: 17 * 1024 * 1024)])])
    let center = Clip(source: "Text", bundle: "", payloads: [Payload(types: ["public.utf8-plain-text": Data("center".utf8)])])
    prefetcher.update(items: [huge, center, huge], visible: 1...1)
    try require(cache.outstandingRequestCount == 0, "Oversized neighbor started speculative decoding")
    prefetcher.cancel()
}

func testVisibleThumbnailPriority() throws {
    let cache = ThumbnailCache()
    let png = try tinyImageData().png
    let clips = (0..<3).map { _ in Clip(source: "Image Fixture", bundle: "", payloads: [Payload(types: ["public.png": png])]) }
    let first = cache.load(clips[0], prefetch: true) { _ in }
    let second = cache.load(clips[1], prefetch: true) { _ in }
    try require(cache.activeThumbnailWork.prefetch == 1 && cache.activeThumbnailWork.visible == 0,
                "Prefetch consumed every thumbnail worker")
    let visible = cache.load(clips[2]) { _ in }
    try require(cache.activeThumbnailWork.prefetch == 1 && cache.activeThumbnailWork.visible == 1,
                "Visible image did not get a reserved decoding slot")
    let promoted = cache.load(clips[0]) { _ in }
    try require(cache.activeThumbnailWork.prefetch == 0 && cache.activeThumbnailWork.visible == 2,
                "Newly visible image retained prefetch priority")
    for token in [first, second, visible, promoted] { token?.cancel() }
}
