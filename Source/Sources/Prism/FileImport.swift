import AppKit
import UniformTypeIdentifiers

enum FileTransferImport {
    static let draggedTypes: [NSPasteboard.PasteboardType] = {
        let names = [UTType.item.identifier, UTType.data.identifier, UTType.image.identifier,
                     UTType.audio.identifier, UTType.movie.identifier, Payload.legacyFilesType] +
            Payload.uriListTypes + NSFilePromiseReceiver.readableDraggedTypes
        return [.string, .png, .tiff, .fileURL, .URL, .rtf, .rtfd, .html, .pdf] + names.map { .init($0) }
    }()
    private static let worker = DispatchQueue(label: "local.prism.file-import", qos: .userInitiated)

    @discardableResult
    static func receive(_ pasteboard: NSPasteboard,
                        completion: @escaping (Result<Clip, Error>) -> Void) -> Bool {
        precondition(Thread.isMainThread)
        // Read the whole board first so sensitive markers on any item reject
        // the complete transfer before a file-promise request is issued.
        guard let captured = ClipStore.read(pasteboard, source: "拖入的内容", bundle: "") else { return false }
        let objects = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self, NSPasteboardItem.self], options: nil) ?? []
        guard objects.contains(where: { $0 is NSFilePromiseReceiver }) else {
            worker.async {
                let clip = captured.preservingTemporaryFiles()
                DispatchQueue.main.async { completion(.success(clip)) }
            }
            return true
        }
        guard objects.count == captured.itemCount else { return false }
        let session = PromisedFileImport(objects: objects, payloads: captured.payloads, completion: completion)
        session.start()
        return true
    }
}

final class PromisedFileImport {
    private let objects: [Any]
    private var payloads: [[Payload]]
    private let completion: (Result<Clip, Error>) -> Void
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Prism-Import-" + UUID().uuidString, isDirectory: true)
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "local.prism.promised-file-import"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    // Import callbacks are serialized by queue.
    private var remaining: Int
    private var size: Int
    private var failure: Error?

    init(objects: [Any], payloads: [Payload], completion: @escaping (Result<Clip, Error>) -> Void) {
        self.objects = objects
        self.payloads = objects.enumerated().map { $0.element is NSFilePromiseReceiver ? [] : [payloads[$0.offset]] }
        self.completion = completion
        remaining = 0
        size = self.payloads.flatMap { $0 }.reduce(0) { $0 + $1.types.values.reduce(0) { $0 + $1.count } }
    }

    func start() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            failure = error
            finish()
            return
        }
        // AppKit requires every receiver in one drag to use the same destination.
        // Names become available only after the promises have been requested.
        // Suspend callbacks until all expected file counts have been collected.
        queue.isSuspended = true
        for (index, object) in objects.enumerated() {
            guard let receiver = object as? NSFilePromiseReceiver else { continue }
            let folder = directory
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { [self] url, error in
                    if let error { failure = failure ?? error }
                    else if failure == nil {
                        do {
                            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                            guard path.hasPrefix(folder.resolvingSymlinksInPath().path + "/") else {
                                throw StorageError.message("接收到的文件位置无效。")
                            }
                            let bytes = try StoredTransferFile.read(url, limit: max(0, ClipStore.maxBytes - size))
                            let stored = StoredTransferFile(originalURL: url.absoluteString, name: url.lastPathComponent, contents: bytes)
                            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                            let payload = Payload(types: [NSPasteboard.PasteboardType.fileURL.rawValue: Data(url.absoluteString.utf8),
                                                          Payload.storedFilesType: try encoder.encode([stored])])
                            let cost = payload.types.values.reduce(0) { $0 + $1.count }
                            guard cost <= ClipStore.maxBytes - size else { throw StorageError.message("拖入的内容超过单条记录的 100 MB 上限。") }
                            size += cost
                            payloads[index].append(payload)
                        } catch { failure = error }
                    }
                    remaining -= 1
                    if remaining == 0 { finish() }
            }
            remaining += max(1, receiver.fileNames.count)
        }
        queue.isSuspended = false
    }

    private func finish() {
        let result: Result<Clip, Error>
        if let failure { result = .failure(failure) }
        else {
            let ordered = objects.enumerated().flatMap { index, object -> [Payload] in
                guard let receiver = object as? NSFilePromiseReceiver else { return payloads[index] }
                return payloads[index].sorted {
                    let lhs = (try? $0.storedTransferFiles().first?.name) ?? ""
                    let rhs = (try? $1.storedTransferFiles().first?.name) ?? ""
                    return (receiver.fileNames.firstIndex(of: lhs) ?? Int.max) < (receiver.fileNames.firstIndex(of: rhs) ?? Int.max)
                }
            }
            result = .success(Clip(source: "拖入的内容", bundle: "", payloads: ordered).preservingTemporaryFiles())
        }
        try? FileManager.default.removeItem(at: directory)
        DispatchQueue.main.async { [self] in completion(result) }
    }
}
