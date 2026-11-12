import AppKit
import ImageIO
import UniformTypeIdentifiers

// Encoded clipboard content and captured temporary files share the same native
// file handoff. Editors can also read their original data representations.
final class ClipFilePromiseProvider: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    static let clipIDType = NSPasteboard.PasteboardType("local.prism.clip-id")
    var clipIDs: String?
    let suggestedFilename: String
    private let payload: Payload
    private let originalBytes: Data
    private let originalFilename: String?
    var exportByteCount: Int { originalBytes.count }
    private var promiseTypes: Set<NSPasteboard.PasteboardType> = []
    private static let exportQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "local.prism.image-drag-export"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    convenience init?(payload: Payload) {
        // Inspect only encoded headers, never Clip.image (the 1600px preview).
        // If a payload includes multiple image sizes, export the largest original
        // representation. For equal sizes, prefer PNG, then TIFF, then JPEG.
        let preferred = ["public.png", "public.tiff", "public.jpeg"]
        let types = payload.types.keys.filter {
            Payload.imageType($0) != nil
        }.sorted {
            let lhs = preferred.firstIndex(of: $0) ?? preferred.count
            let rhs = preferred.firstIndex(of: $1) ?? preferred.count
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        var best: (bytes: Data, type: UTType, area: Double, frames: Int)?
        for type in types {
            guard let bytes = payload.types[type], !bytes.isEmpty,
                  let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let identifier = CGImageSourceGetType(source),
                  let actualType = UTType(identifier as String), actualType.conforms(to: .image),
                  actualType.identifier != "com.apple.icns", actualType.preferredFilenameExtension != nil,
                  CGImageSourceGetCount(source) > 0 else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any]
            let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
            let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
            let area = width * height
            let frames = CGImageSourceGetCount(source)
            let preservesMoreFrames = frames > 1 && best?.frames == 1
            let sameFrameCategory = (frames > 1) == ((best?.frames ?? 1) > 1)
            if best == nil || preservesMoreFrames || (sameFrameCategory && area > best!.area) {
                best = (bytes, actualType, area, frames)
            }
        }
        if let best {
            self.init(payload: payload, bytes: best.bytes, type: best.type)
            return
        }
        // Vector images, PDF, audio, video and archives may be supplied as
        // encoded content without any file URL or ImageIO raster decoder.
        for name in payload.types.keys.sorted() {
            guard let bytes = payload.types[name], !bytes.isEmpty,
                  let type = Payload.fileExportType(name) else { continue }
            self.init(payload: payload, bytes: bytes, type: type)
            return
        }
        return nil
    }

    init(payload: Payload, bytes: Data, type: UTType, filename: String? = nil) {
        self.payload = payload
        originalBytes = bytes
        originalFilename = filename.map(TransferFileCache.safeFilename)
        suggestedFilename = originalFilename ?? "Prism-\(UUID().uuidString.prefix(8)).\(type.preferredFilenameExtension ?? "bin")"
        super.init()
        fileType = type.identifier
        // NSFilePromiseProvider.delegate is weak. The provider is its own
        // delegate, keeping the bytes alive for AppKit's pending write request
        // even after the source card has finished its drag and been recycled.
        delegate = self
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let native = super.writableTypes(for: pasteboard)
        promiseTypes = Set(native)
        let original = payload.types.keys.sorted().map { NSPasteboard.PasteboardType($0) }
            .filter { !promiseTypes.contains($0) && $0 != Self.clipIDType && !$0.rawValue.contains("/") }
        return native + original + (clipIDs == nil ? [] : [Self.clipIDType])
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == Self.clipIDType { return clipIDs }
        if promiseTypes.contains(type) { return super.pasteboardPropertyList(forType: type) }
        if let bytes = payload.data(type) { return bytes }
        return super.pasteboardPropertyList(forType: type)
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == Self.clipIDType { return [] }
        if promiseTypes.contains(type) { return super.writingOptions(forType: type, pasteboard: pasteboard) }
        // The superclass owns lazy fulfillment for its native promise types.
        // Extra representations must be supplied immediately through our
        // pasteboardPropertyList override so image/chat apps can read every UTI.
        if payload.data(type) != nil { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        suggestedFilename
    }

    /// Web-based attachment fields need an existing file at drag entry. Prepare
    /// it off main, then advertise native NSURL representations on a single item.
    /// Do not mix file promises with that URL: some receivers create both a file
    /// attachment and an image attachment from the same promised item.
    func prepareFileWriter(cache: TransferFileCache = .shared,
                           completion: @escaping (Result<NSPasteboardWriting, Error>) -> Void) {
        cache.prepare(bytes: originalBytes, fileExtension: (suggestedFilename as NSString).pathExtension,
                      filename: originalFilename) { [payload] result in
            completion(result.map { ClipFileWriter(url: $0, payload: payload) })
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { Self.exportQueue }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do {
            // AppKit supplies the final URL. Keep every encoded byte, pixel,
            // metadata field and animation frame; do not render or recompress.
            try originalBytes.write(to: url, options: .atomic)
            completionHandler(nil)
        } catch { completionHandler(error) }
    }
}

/// The real file and the original image UTIs are alternatives on ONE item.
/// NSURL owns URL serialization and writing options (including AppKit's native
/// file handoff); image editors can still ask for their preferred raw encoding.
final class ClipFileWriter: NSObject, NSPasteboardWriting {
    let fileURL: URL
    private let nativeURL: NSURL
    private let imageTypes: [NSPasteboard.PasteboardType]
    private let payload: Payload

    init(url: URL, payload: Payload) {
        fileURL = url; nativeURL = url as NSURL; self.payload = payload
        let fileType = UTType(filenameExtension: url.pathExtension)
        imageTypes = payload.types.keys.filter {
            !$0.contains("/") && (Payload.imageType($0) != nil || $0 == UTType.pdf.identifier || $0 == fileType?.identifier)
        }
            .sorted().map { NSPasteboard.PasteboardType($0) }
        super.init()
    }
    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let native = nativeURL.writableTypes(for: pasteboard)
        return native + imageTypes.filter { !native.contains($0) }
    }
    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if imageTypes.contains(type) { return payload.data(type) }
        return nativeURL.pasteboardPropertyList(forType: type)
    }
    func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if imageTypes.contains(type) { return [] }
        return nativeURL.writingOptions(forType: type, pasteboard: pasteboard)
    }
}

struct PreparedTransfer {
    var writers: [NSPasteboardWriting]
    var clipIDs: [UUID]
    var unavailableClipIDs: [UUID]
}

enum FileTransferPreparation {
    private static let worker = DispatchQueue(label: "local.prism.transfer-preparation", qos: .userInitiated)

    static func prepareSelection(clips: [Clip], forDragging: Bool, cache: TransferFileCache = .shared,
                                 completion: @escaping (Result<PreparedTransfer, Error>) -> Void) {
        worker.async {
            let planned = Result { () throws -> PreparedTransfer in
                let payloadBytes = clips.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
                guard payloadBytes <= TransferFileCache.maximumPendingBytes else {
                    throw StorageError.message("选中的历史内容超过 256 MiB，请分批复制或拖动。")
                }
                var available: [Clip] = []
                var unavailable: [UUID] = []
                for clip in clips {
                    if clip.hasFileReferences, (try? FileReferenceRequirements(clip: clip).isUnavailable) != false {
                        unavailable.append(clip.id)
                    } else { available.append(clip) }
                }
                let writers: [NSPasteboardWriting]
                if let combined = try CombinedTextTransfer.payload(from: available) {
                    writers = [combined.pasteboardItem()]
                } else {
                    // Native file representations let file-only receivers see
                    // every image in multi-selection clipboard pastes as well.
                    let multipleItems = available.reduce(0) { $0 + $1.itemCount } > 1
                    writers = try available.flatMap { try $0.pasteboardWriters(forDragging: forDragging || multipleItems) }
                }
                return PreparedTransfer(writers: writers, clipIDs: available.map(\.id), unavailableClipIDs: unavailable)
            }
            DispatchQueue.main.async {
                switch planned {
                case .failure(let error): completion(.failure(error))
                case .success(let plan):
                    prepare(plan.writers, cache: cache) { result in
                        completion(result.map { PreparedTransfer(writers: $0, clipIDs: plan.clipIDs, unavailableClipIDs: plan.unavailableClipIDs) })
                    }
                }
            }
        }
    }

    static func prepare(clips: [Clip], forDragging: Bool, cache: TransferFileCache = .shared,
                        completion: @escaping (Result<[NSPasteboardWriting], Error>) -> Void) {
        // Payload hydration and full-size lossless image conversion stay off
        // the UI thread. Pasteboard publication happens on the main thread.
        worker.async {
            let result = Result { try clips.flatMap { try $0.pasteboardWriters(forDragging: forDragging) } }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error): completion(.failure(error))
                case .success(let writers): prepare(writers, cache: cache, completion: completion)
                }
            }
        }
    }
    /// Keep order and item count for mixed/multi-selection drags. A failed image
    /// must fail the preparation as a whole rather than silently disappear.
    static func prepare(_ writers: [NSPasteboardWriting], cache: TransferFileCache = .shared,
                        completion: @escaping (Result<[NSPasteboardWriting], Error>) -> Void) {
        precondition(Thread.isMainThread)
        let promises = writers.enumerated().compactMap { index, writer in
            (writer as? ClipFilePromiseProvider).map { (index, $0) }
        }
        guard !promises.isEmpty else { completion(.success(writers)); return }
        let total = promises.reduce(Int64(0)) { $0 + Int64($1.1.exportByteCount) }
        guard total <= 256 * 1024 * 1024 else {
            completion(.failure(NSError(domain: "local.prism.file-transfer", code: 1, userInfo: [NSLocalizedDescriptionKey: "一次传输的数据较多，请分批操作（每批最多256 MiB）。"])))
            return
        }
        var prepared = writers
        // Prepare sequentially so large batches do not exhaust the cache's
        // bounded pending-request queue. Publish only the complete selection.
        func prepareNext(_ offset: Int) {
            guard offset < promises.count else { completion(.success(prepared)); return }
            let (index, promise) = promises[offset]
            promise.prepareFileWriter(cache: cache) { result in
                switch result {
                case .success(let writer):
                    prepared[index] = writer
                    prepareNext(offset + 1)
                case .failure(let error): completion(.failure(error))
                }
            }
        }
        prepareNext(0)
    }
}
