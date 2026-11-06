import Foundation
import CryptoKit
import Darwin

private struct ImageDragCacheTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func cacheRequire(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw ImageDragCacheTestFailure(description: message) }
}

private func awaitCache(_ done: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(10)
    while !done(), Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    try cacheRequire(done(), "Image cache completion timed out")
}

private func prepareCache(_ cache: ImageDragFileCache, _ bytes: Data, ext: String = "png") throws -> Result<URL, Error> {
    var result: Result<URL, Error>?
    var main = false
    cache.prepare(bytes: bytes, fileExtension: ext) { main = Thread.isMainThread; result = $0 }
    try cacheRequire(result == nil, "Cache completion must be asynchronous")
    try awaitCache { result != nil }
    try cacheRequire(main, "Cache completion must be on main")
    return result!
}

private func cacheFailed(_ result: Result<URL, Error>) -> Bool {
    if case .failure = result { return true }; return false
}

/// Uses only disposable caller-owned fixtures and no general pasteboard or UI.
func testImageDragFileCache(directory: URL) throws {
    precondition(Thread.isMainThread)
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let bytes = Data([0, 1, 2, 3, 255, 137, 80, 78, 71])
    let cacheDirectory = directory.appendingPathComponent("files", isDirectory: true)
    let cache = ImageDragFileCache(directory: cacheDirectory, byteLimit: 32)
    let first = try prepareCache(cache, bytes, ext: "PNG").get()
    try cacheRequire(try Data(contentsOf: first) == bytes, "Cache changed original bytes")
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    try cacheRequire(first.lastPathComponent == digest + ".png", "Cache name is not deterministic and safe")
    let fileAttrs = try fm.attributesOfItem(atPath: first.path)
    let dirAttrs = try fm.attributesOfItem(atPath: cacheDirectory.path)
    try cacheRequire((fileAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Image file is not private")
    try cacheRequire((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Cache directory is not private")
    let second = try prepareCache(cache, bytes).get()
    try cacheRequire(second == first, "Cache did not reuse identical data")
    try cacheRequire((try fm.contentsOfDirectory(atPath: cacheDirectory.path)).count == 1, "Reuse left extra files")
    // Releasing an exporter and reading later must preserve receiver access.
    do {
        let transient = ImageDragFileCache(directory: cacheDirectory, byteLimit: 32)
        _ = try prepareCache(transient, bytes).get()
    }
    try cacheRequire(try Data(contentsOf: first) == bytes, "Releasing the exporter deleted the drag file")
    let recent = try prepareCache(cache, Data(repeating: 22, count: 20)).get()
    try cacheRequire(cacheFailed(try prepareCache(cache, Data(repeating: 23, count: 20))), "Cache exceeded its byte budget")
    try cacheRequire(fm.fileExists(atPath: first.path) && fm.fileExists(atPath: recent.path), "Capacity evicted recent receiver files")
    // Only an expired owned cache file may be reclaimed.
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-25 * 3600)], ofItemAtPath: first.path)
    let replacement = try prepareCache(cache, Data(repeating: 24, count: 10)).get()
    try cacheRequire(!fm.fileExists(atPath: first.path), "Expired cache entry was not reclaimed")
    try cacheRequire(try Data(contentsOf: recent) == Data(repeating: 22, count: 20), "Expiry deleted a recent entry")
    try cacheRequire(try Data(contentsOf: replacement) == Data(repeating: 24, count: 10), "Replacement bytes changed")
    try cacheRequire(cacheFailed(try prepareCache(cache, bytes, ext: "../../png")), "Unsafe extension was accepted")
    try cacheRequire(cacheFailed(try prepareCache(cache, Data())), "Empty export was accepted")

    let original = directory.appendingPathComponent("original.bin")
    try bytes.write(to: original)
    let unsafeDirectory = directory.appendingPathComponent("symlink", isDirectory: true)
    try fm.createDirectory(at: unsafeDirectory, withIntermediateDirectories: false)
    try fm.createSymbolicLink(at: unsafeDirectory.appendingPathComponent(digest + ".png"), withDestinationURL: original)
    try cacheRequire(cacheFailed(try prepareCache(ImageDragFileCache(directory: unsafeDirectory), bytes)), "Cache followed a symlink collision")
    try cacheRequire(try Data(contentsOf: original) == bytes, "Cache touched an original outside its directory")
    let linkedDirectory = directory.appendingPathComponent("linked-directory")
    try fm.createSymbolicLink(at: linkedDirectory, withDestinationURL: cacheDirectory)
    try cacheRequire(cacheFailed(try prepareCache(ImageDragFileCache(directory: linkedDirectory), bytes)), "Cache followed a directory symlink")
    try cacheRequire(cacheFailed(try prepareCache(ImageDragFileCache(directory: original), bytes)), "Cache accepted a regular file as directory")

    let queued = ImageDragFileCache(directory: directory.appendingPathComponent("queued"))
    var completions = 0
    var successes: [URL] = []
    var failures = 0
    var allMain = true
    // Hold main delivery until all 65 requests are submitted. Reservations must
    // also bound completed-but-undelivered requests, even when data is reused.
    for _ in 0..<65 {
        queued.prepare(bytes: bytes, fileExtension: "png") { result in
            allMain = allMain && Thread.isMainThread
            if case .success(let url) = result { successes.append(url) } else { failures += 1 }
            completions += 1
        }
    }
    try awaitCache { completions == 65 }
    try cacheRequire(allMain && failures == 1 && successes.count == 64, "Cache pending request bound or main callbacks failed")
    try cacheRequire(Set(successes).count == 1, "Concurrent cache requests did not reuse the file")
    _ = try prepareCache(queued, bytes).get()
}
