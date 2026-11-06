import AppKit

private struct SearchTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func searchRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SearchTestFailure(description: message) }
}

private func awaitSearch(_ message: String, _ done: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(5)
    while !done(), Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    try searchRequire(done(), message)
}

/// Private storage only. Covers main-thread delivery, full-text matching and an
/// immutable search snapshot while the main-owned directory changes.
func testAsyncSearchSnapshot(directory: URL) throws {
    let store = ClipStore(directory: directory)
    let text = String(repeating: "snapshot fixture content ", count: 300) + " beyondpreviewneedle"
    let clip = Clip(source: "Snapshot Source", bundle: "local.prism.search-test", payloads: [
        Payload(types: [NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)])
    ])
    store.add(clip)
    try searchRequire(store.flush(), "Search fixture did not persist")
    let expected = store.search(query: "beyondpreviewneedle", kind: "文本", app: "Snapshot Source", days: 7).map(\.id)
    try searchRequire(expected == [clip.id], "Fixture full text is not indexed")
    var received: [UUID]?
    var deliveredOnMain = false
    store.searchAsync(query: "beyondpreviewneedle", kind: "文本", app: "Snapshot Source", days: 7) {
        received = $0.map(\.id); deliveredOnMain = Thread.isMainThread
    }
    // This mutation intentionally has no save: it tests ownership, not deletion.
    store.clips = []
    try awaitSearch("Snapshot search did not complete") { received != nil }
    try searchRequire(deliveredOnMain, "Search completion did not run on main")
    try searchRequire(received == expected, "Worker read the changing public directory")
    var filtered: [UUID]?
    store.clips = [clip]
    store.searchAsync(query: "beyondpreviewneedle", kind: "图片") { filtered = $0.map(\.id) }
    try awaitSearch("Filtered search did not complete") { filtered != nil }
    try searchRequire(filtered?.isEmpty == true, "Asynchronous search ignored kind filter")
    try searchRequire(store.flush(), "Search fixture final flush failed")
}

/// Submit without pumping main so completed-but-undelivered searches are also
/// superseded. Only the newest query may publish a result.
func testAsyncSearchCancellation(directory: URL) throws {
    let store = ClipStore(directory: directory)
    for i in 0..<16 {
        let clip = Clip(source: "Search Test", bundle: "local.prism.search-test", payloads: [
            Payload(types: [NSPasteboard.PasteboardType.string.rawValue: Data("query-\(i) 检索内容".utf8)])
        ])
        store.add(clip)
    }
    try searchRequire(store.flush(), "Cancellation fixture did not persist")
    var staleCallbacks = 0
    var oldTokens: [ClipSearchToken] = []
    for _ in 0..<80 {
        oldTokens.append(store.searchAsync(query: "检索") { _ in staleCallbacks += 1 })
    }
    let expected = store.search(query: "query-15").map(\.id)
    var newest: [UUID]?
    store.searchAsync(query: "query-15") { newest = $0.map(\.id) }
    try searchRequire(oldTokens.allSatisfy(\.isCancelled), "Superseded search token stayed active")
    try awaitSearch("Newest search did not complete") { newest != nil }
    try searchRequire(newest == expected && expected.count == 1, "Newest query result changed")
    try searchRequire(staleCallbacks == 0, "Superseded query published a stale result")
    let cancelled = store.searchAsync(query: "检索") { _ in staleCallbacks += 1 }
    cancelled.cancel()
    var barrier = false
    store.searchAsync(query: "query-0") { _ in barrier = true }
    try awaitSearch("Search after explicit cancellation did not complete") { barrier }
    try searchRequire(staleCallbacks == 0, "Explicitly cancelled query published a result")
    try searchRequire(store.flush(), "Cancellation fixture final flush failed")
}
