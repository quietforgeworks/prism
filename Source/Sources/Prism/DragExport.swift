import AppKit
import ImageIO
import UniformTypeIdentifiers

// A drag can expose the original image representations to image/chat editors
// and promise a real file to Finder. No file is created until a destination asks
// for it; the destination owns that file, so there is no temporary export cache.
final class ImageDragPromiseProvider: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    static let clipIDType = NSPasteboard.PasteboardType("local.prism.clip-id")
    var clipIDs: String?
    let suggestedFilename: String
    private let payload: Payload
    private let originalBytes: Data
    var exportByteCount: Int { originalBytes.count }
    private var promiseTypes: Set<NSPasteboard.PasteboardType> = []
    private static let exportQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "local.prism.image-drag-export"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    init?(payload: Payload) {
        // Inspect only encoded headers, never Clip.image (the 1600px preview).
        // If a payload includes multiple image sizes, export the largest original
        // representation. For equal sizes, prefer PNG, then TIFF, then JPEG.
        let preferred = ["public.png", "public.tiff", "public.jpeg"]
        let types = payload.types.keys.filter {
            UTType($0)?.conforms(to: .image) == true && $0 != "com.apple.icns"
        }.sorted {
            let lhs = preferred.firstIndex(of: $0) ?? preferred.count
            let rhs = preferred.firstIndex(of: $1) ?? preferred.count
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        var best: (bytes: Data, type: UTType, area: Double)?
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
            if best == nil || area > best!.area { best = (bytes, actualType, area) }
        }
        guard let best, let fileExtension = best.type.preferredFilenameExtension else { return nil }
        self.payload = payload
        originalBytes = best.bytes
        suggestedFilename = "Prism-\(UUID().uuidString.prefix(8)).\(fileExtension)"
        super.init()
        fileType = best.type.identifier
        // NSFilePromiseProvider.delegate is weak. The provider is its own
        // delegate, keeping the bytes alive for AppKit's pending write request
        // even after the source card has finished its drag and been recycled.
        delegate = self
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        let native = super.writableTypes(for: pasteboard)
        promiseTypes = Set(native)
        let original = payload.types.keys.sorted().map { NSPasteboard.PasteboardType($0) }
            .filter { !promiseTypes.contains($0) && $0 != Self.clipIDType }
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
    func prepareFileWriter(cache: ImageDragFileCache = .shared,
                           completion: @escaping (Result<NSPasteboardWriting, Error>) -> Void) {
        cache.prepare(bytes: originalBytes, fileExtension: (suggestedFilename as NSString).pathExtension) { [payload] result in
            completion(result.map { ImageFileDragWriter(url: $0, payload: payload) })
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
final class ImageFileDragWriter: NSObject, NSPasteboardWriting {
    let fileURL: URL
    private let nativeURL: NSURL
    private let imageTypes: [NSPasteboard.PasteboardType]
    private let payload: Payload

    init(url: URL, payload: Payload) {
        fileURL = url; nativeURL = url as NSURL; self.payload = payload
        imageTypes = payload.types.keys.filter { UTType($0)?.conforms(to: .image) == true }
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

enum ImageDragPreparation {
    /// Keep order and item count for mixed/multi-selection drags. A failed image
    /// must fail the preparation as a whole rather than silently disappear.
    static func prepare(_ writers: [NSPasteboardWriting], cache: ImageDragFileCache = .shared,
                        completion: @escaping (Result<[NSPasteboardWriting], Error>) -> Void) {
        precondition(Thread.isMainThread)
        let promises = writers.enumerated().compactMap { index, writer in
            (writer as? ImageDragPromiseProvider).map { (index, $0) }
        }
        guard !promises.isEmpty else { completion(.success(writers)); return }
        let total = promises.reduce(Int64(0)) { $0 + Int64($1.1.exportByteCount) }
        guard total <= 256 * 1024 * 1024, promises.count <= 64 else {
            completion(.failure(NSError(domain: "local.prism.image-drag", code: 1, userInfo: [NSLocalizedDescriptionKey: "一次拖出的图片较多，请分批拖动（每批最多256 MiB、64张）。"])))
            return
        }
        var prepared = writers
        var remaining = promises.count
        var failure: Error?
        for (index, promise) in promises {
            promise.prepareFileWriter(cache: cache) { result in
                switch result {
                case .success(let writer): prepared[index] = writer
                case .failure(let error): if failure == nil { failure = error }
                }
                remaining -= 1
                guard remaining == 0 else { return }
                if let failure { completion(.failure(failure)) }
                else { completion(.success(prepared)) }
            }
        }
    }
}
