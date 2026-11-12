import AppKit

/// Immutable recovery information is cached independently of the source paths.
/// Only the existence checks run again while the shelf is visible.
struct FileReferenceRequirements {
    var originalFiles: [NSURL] = []
    var invalidAddresses = false

    init(clip: Clip) throws {
        for payload in try clip.loadPayloads() {
            let stored = try payload.storedTransferFiles()
            if stored.isEmpty, payload.replayImage(addPNG: false) != nil { continue }
            do {
                let files = try payload.transferFileURLs()
                originalFiles += files.filter { file in
                    !stored.contains { $0.originalURL == file.absoluteString }
                }
            } catch {
                invalidAddresses = true
            }
        }
    }

    var isUnavailable: Bool {
        invalidAddresses || originalFiles.contains { file in
            guard let url = file.filePathURL?.standardizedFileURL else { return true }
            return !FileManager.default.fileExists(atPath: url.path)
        }
    }
}

extension Clip {
    var hasFileReferences: Bool {
        !files.isEmpty || typeNames.contains(NSPasteboard.PasteboardType.fileURL.rawValue) ||
            typeNames.contains(Payload.legacyFilesType) || typeNames.contains(where: Payload.uriListTypes.contains)
    }
}

/// At most one check and one latest pending request are retained. Filesystem
/// lookups and payload hydration never run in card drawing or on the UI thread.
final class FileAvailabilityMonitor {
    private struct Request {
        var clips: [Clip]
        var generation: UInt64
        var completion: ([UUID: Bool]) -> Void
    }
    private let worker = DispatchQueue(label: "local.prism.file-availability", qos: .utility)
    private var generation: UInt64 = 0
    private var running = false
    private var pending: Request?
    private(set) var needsPolling = false
    // Owned by worker. Keep plans only for the latest on-screen clips.
    private var requirements: [String: FileReferenceRequirements] = [:]

    func check(_ clips: [Clip], completion: @escaping ([UUID: Bool]) -> Void) {
        precondition(Thread.isMainThread)
        generation &+= 1
        let request = Request(clips: clips, generation: generation, completion: completion)
        if running { pending = request }
        else { start(request) }
    }

    func cancel() {
        precondition(Thread.isMainThread)
        generation &+= 1
        pending = nil
        needsPolling = false
    }

    private func start(_ request: Request) {
        running = true
        worker.async { [self] in
            var result: [UUID: Bool] = [:]
            var activeKeys = Set<String>()
            var requiresPolling = false
            for clip in request.clips {
                guard clip.hasFileReferences else { result[clip.id] = false; continue }
                let key = "\(clip.id)-\(clip.fingerprint)"
                activeKeys.insert(key)
                do {
                    // Complete file metadata can establish a live path without
                    // loading an immutable image or attachment payload.
                    if requirements[key] == nil, !clip.files.isEmpty, clip.files.count >= clip.itemCount,
                       clip.files.allSatisfy({ file in
                           guard file.isFileURL, let path = (file as NSURL).filePathURL else { return false }
                           return FileManager.default.fileExists(atPath: path.path)
                       }) {
                        result[clip.id] = false
                        requiresPolling = true
                        continue
                    }
                    let plan = try autoreleasepool { try requirements[key] ?? FileReferenceRequirements(clip: clip) }
                    requirements[key] = plan
                    result[clip.id] = plan.isUnavailable
                    requiresPolling = requiresPolling || !plan.originalFiles.isEmpty
                } catch {
                    result[clip.id] = true
                }
            }
            requirements = requirements.filter { activeKeys.contains($0.key) }
            DispatchQueue.main.async { [self] in
                running = false
                if request.generation == generation {
                    needsPolling = requiresPolling
                    request.completion(result)
                }
                if let next = pending {
                    pending = nil
                    start(next)
                }
            }
        }
    }
}
