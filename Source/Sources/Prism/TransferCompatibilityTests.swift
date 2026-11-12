import AppKit
import ImageIO
import UniformTypeIdentifiers

private func prepareTransfer(_ clip: Clip, dragging: Bool, directory: URL) throws -> [NSPasteboardWriting] {
    try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
    var result: Result<[NSPasteboardWriting], Error>?
    FileTransferPreparation.prepare(clips: [clip], forDragging: dragging,
                                    cache: TransferFileCache(directory: directory)) {
        precondition(Thread.isMainThread)
        result = $0
    }
    try waitFor("Transfer preparation did not finish", timeout: 20) { result != nil }
    return try result!.get()
}

private func transferBoard<T>(_ body: (NSPasteboard) throws -> T) rethrows -> T {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    return try body(board)
}

func testWeChatImageRecovery(directory: URL) throws {
    let tiff = try dragImageData(width: 2173, height: 49, format: .tiff)
    let missing = directory.appendingPathComponent("deleted-WeChat-image.png")
    let payload = Payload(types: ["public.file-url": Data(missing.absoluteString.utf8), "public.tiff": tiff,
                                  Payload.qtImageType: Data(), "com.trolltech.anymime.text--uri-list": Data()])
    let clip = Clip(source: "微信", bundle: "com.tencent.xinWeChat", payloads: [payload])
    try require(clip.kind == "图片", "WeChat inline image is classified only as a temporary file")
    let store = ClipStore(directory: directory.appendingPathComponent("history"))
    store.add(clip); try require(store.flush(), "Cannot persist WeChat fixture")
    let loaded = ClipStore(directory: store.directory).clips[0]
    let copy = try prepareTransfer(loaded, dragging: false, directory: directory.appendingPathComponent("copy"))
    try transferBoard { board in
        try require(board.writeObjects(copy), "Recovered image cannot be copied")
        let item = board.pasteboardItems![0]
        try require(item.data(forType: .tiff) == tiff && item.data(forType: .png) != nil, "Lossless PNG alternative or original TIFF is missing")
        try require(item.data(forType: .fileURL) == nil, "Stale WeChat file URL is still advertised")
        let source = CGImageSourceCreateWithData(item.data(forType: .png)! as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        try require(properties[kCGImagePropertyPixelWidth] as? Int == 2173 && properties[kCGImagePropertyPixelHeight] as? Int == 49,
                    "Recovery exported a downsampled preview")
    }
    let drag = try prepareTransfer(loaded, dragging: true, directory: directory.appendingPathComponent("drag"))
    try require(drag.count == 1 && (drag[0] as? ClipFileWriter)?.fileURL.pathExtension == "png", "Recovered drag did not prepare one compatible PNG file")
    try require(try loaded.loadPayloads() == [payload], "Recovery modified original history representations")
    let icon = Clip(source: "Finder", bundle: "", payloads: [Payload(types: ["public.file-url": Data(missing.deletingPathExtension().appendingPathExtension("pdf").absoluteString.utf8), "public.tiff": tiff])])
    var rejected = false
    do { _ = try icon.pasteboardWriters() } catch { rejected = true }
    try require(rejected, "A missing PDF was replaced with its accompanying icon image")
}

func testImageFormatAliases(directory: URL) throws {
    let tiny = try tinyImageData()
    let bitmap = NSBitmapImageRep(data: tiny.png)!
    let formats: [(String, Data)] = [
        ("image/png", tiny.png), ("com.trolltech.anymime.image--tiff", tiny.tiff), ("public.png", tiny.tiff),
        ("image/jpeg", bitmap.representation(using: .jpeg, properties: [:])!),
        ("image/gif", bitmap.representation(using: .gif, properties: [:])!),
        ("image/bmp", bitmap.representation(using: .bmp, properties: [:])!)
    ]
    var variants = formats
    let heic = NSMutableData()
    let source = CGImageSourceCreateWithData(tiny.png as CFData, nil)!
    guard let destination = CGImageDestinationCreateWithData(heic, UTType.heic.identifier as CFString, 1, nil) else {
        throw SelfTestFailure(description: "System HEIC encoder is unavailable")
    }
    CGImageDestinationAddImageFromSource(destination, source, 0, nil)
    try require(CGImageDestinationFinalize(destination), "HEIC fixture encoding failed")
    variants.append(("image/heic", heic as Data))
    for (index, variant) in variants.enumerated() {
        let clip = Clip(source: "Alias Fixture", bundle: "", payloads: [Payload(types: [variant.0: variant.1])])
        let actual = CGImageSourceGetType(CGImageSourceCreateWithData(variant.1 as CFData, nil)!)! as String
        let copy = try prepareTransfer(clip, dragging: false, directory: directory.appendingPathComponent("copy-\(index)"))
        try transferBoard { board in
            try require(board.writeObjects(copy), "Cannot copy image alias \(variant.0)")
            try require(board.data(forType: .init(actual)) == variant.1, "Canonical image type is absent or changed for \(variant.0)")
            try require(board.data(forType: .png) != nil, "PNG fallback is missing for \(variant.0)")
        }
        let drag = try prepareTransfer(clip, dragging: true, directory: directory.appendingPathComponent("drag-\(index)"))
        guard let writer = drag.first as? ClipFileWriter else { throw SelfTestFailure(description: "Alias cannot be dragged as a file") }
        try require(try Data(contentsOf: writer.fileURL) == variant.1, "Alias drag changed original encoded bytes")
    }
}

func testFileURLCompatibility(directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let files = ["中文 文件 #1.epro", "other % file.asc"].map { directory.appendingPathComponent($0) }
    for file in files { try Data([0, 255, 7]).write(to: file) }
    let list = "# URI list fixture\r\n" + files.map(\.absoluteString).joined(separator: "\r\n") + "\r\n"
    for name in ["text/uri-list", "com.trolltech.anymime.text--uri-list"] {
        let clip = Clip(source: "Qt", bundle: "", payloads: [Payload(types: [name: Data(list.utf8)])])
        try require(clip.fileCount == 2, "URI list files are missing from metadata")
        let writers = try clip.pasteboardWriters()
        try require(writers.count == 2 && writers.allSatisfy { $0 is NSURL }, "URI list did not produce native file URLs")
        try require(writers.compactMap { ($0 as? NSURL).map { $0 as URL } } == files, "URI list changed percent-encoded paths or ordering")
    }
    let variants = [files[0].absoluteString.data(using: .utf16)!, Data((files[0].path + "\r\n").utf8),
                    try PropertyListSerialization.data(fromPropertyList: files[0].absoluteString, format: .binary, options: 0)]
    for bytes in variants {
        let clip = Clip(source: "Legacy", bundle: "", payloads: [Payload(types: ["public.file-url": bytes])])
        try require((try clip.pasteboardWriters()[0] as? NSURL).map { $0 as URL } == files[0], "Legacy file URL normalization changed its path")
    }
}

func testTemporaryAttachmentSnapshots(directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let names = ["文档.docx", "slides.pptx", "table.xlsx", "paper.pdf", "archive.rar", "archive.zip", "project.epro", "measure.asc", "file.custom-extension", "empty"] + (1...70).map { "batch-\($0).bin" }
    let contents = names.enumerated().map { $0.offset == names.count - 1 ? Data() : Data([0x50, 0x4b, UInt8($0.offset), 0, 255]) }
    let files = names.map { directory.appendingPathComponent($0) }
    for (file, bytes) in zip(files, contents) { try bytes.write(to: file) }
    let original = Clip(source: "Temporary Files", bundle: "", payloads: files.map { Payload(types: ["public.file-url": Data($0.absoluteString.utf8)]) })
    let captured = original.preservingTemporaryFiles()
    try require(captured.byteCount > original.byteCount, "Temporary attachments were not captured")
    let archive = try JSONDecoder().decode(Archive.self, from: JSONEncoder().encode(Archive(clips: [captured], boards: [])))
    let store = ClipStore(directory: directory.appendingPathComponent("history"))
    store.add(archive.clips[0]); try require(store.flush(), "Temporary snapshots could not be persisted")
    let loaded = ClipStore(directory: store.directory).clips[0]
    for file in files { try FileManager.default.removeItem(at: file) }
    for dragging in [false, true] {
        let writers = try prepareTransfer(loaded, dragging: dragging, directory: directory.appendingPathComponent(dragging ? "drag" : "copy"))
        try transferBoard { board in
            try require(board.writeObjects(writers), "Cannot publish saved temporary attachments")
            let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            try require(urls.map(\.lastPathComponent) == names, "Attachment filenames or mixed-file ordering changed")
            for (url, bytes) in zip(urls, contents) { try require(try Data(contentsOf: url) == bytes, "Saved attachment bytes changed after source deletion") }
        }
    }
    try require(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "Snapshot replay recreated source-owned files")
    let large = directory.appendingPathComponent("large.bin")
    _ = FileManager.default.createFile(atPath: large.path, contents: nil)
    let handle = try FileHandle(forWritingTo: large); try handle.truncate(atOffset: UInt64(ClipStore.maxBytes + 1)); try handle.close()
    let reference = Clip(source: "Large", bundle: "", payloads: [Payload(types: ["public.file-url": Data(large.absoluteString.utf8)])])
    try require(reference.preservingTemporaryFiles().byteCount == reference.byteCount, "Oversized file reference was embedded into history")
}

func testEncodedFileExports(directory: URL) throws {
    let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2\" height=\"2\"><rect width=\"2\" height=\"2\"/></svg>".utf8)
    let variants = [("com.adobe.pdf", Data("%PDF-1.4\nfixture\n%%EOF".utf8)), (UTType.svg.identifier, svg),
                    (UTType.wav.identifier, Data("RIFF0000WAVE".utf8)), (UTType.mpeg4Movie.identifier, Data([0, 0, 0, 16]) + Data("ftypmp42".utf8)),
                    (UTType.zip.identifier, Data([0x50, 0x4b, 5, 6]) + Data(repeating: 0, count: 18))]
    for (index, variant) in variants.enumerated() {
        let clip = Clip(source: "Encoded", bundle: "", payloads: [Payload(types: [variant.0: variant.1])])
        let writers = try prepareTransfer(clip, dragging: true, directory: directory.appendingPathComponent(String(index)))
        guard let writer = writers.first as? ClipFileWriter else { throw SelfTestFailure(description: "Encoded content did not become a native file") }
        try require(try Data(contentsOf: writer.fileURL) == variant.1, "Encoded file export changed its bytes")
        try require(UTType(filenameExtension: writer.fileURL.pathExtension) == UTType(variant.0), "Encoded file extension does not match its content type")
    }
}

private final class TestPromiseReceiver: NSFilePromiseReceiver {
    private let files: [(name: String, bytes: Data)]
    private let shouldFail: Bool
    private var names: [String] = []
    override var fileNames: [String] { names }
    override var fileTypes: [String] { [UTType.data.identifier] }

    init(files: [(name: String, bytes: Data)], shouldFail: Bool = false) {
        self.files = files
        self.shouldFail = shouldFail
        super.init()
    }

    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        return nil
    }

    override func receivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any],
                                       operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        names = shouldFail ? ["failed-file"] : files.map(\.name)
        if shouldFail {
            operationQueue.addOperation {
                reader(destinationDir, StorageError.message("Test promise failed"))
            }
            return
        }
        // Deliberately finish legacy multi-file promises in reverse order.
        for file in files.reversed() {
            operationQueue.addOperation {
                let url = destinationDir.appendingPathComponent(file.name)
                do { try file.bytes.write(to: url); reader(url, nil) }
                catch { reader(url, error) }
            }
        }
    }
}

func testFilePromiseImport(directory: URL) throws {
    let image = try tinyImageData().png
    let bytes = Data([0x50, 0x4b, 0, 255])
    let first = TestPromiseReceiver(files: [("promised-image.png", image), ("second-image.png", image)])
    let last = TestPromiseReceiver(files: [("promised-archive.zip", bytes)])
    let text = Payload(types: ["public.utf8-plain-text": Data("between promises".utf8)])
    let placeholder = Payload(types: [:])
    var result: Result<Clip, Error>?
    let session = PromisedFileImport(objects: [first, text.pasteboardItem(), last], payloads: [placeholder, text, placeholder]) { result = $0 }
    session.start()
    try waitFor("Promised files were not imported", timeout: 20) { result != nil }
    let clip = try result!.get()
    try require(clip.itemCount == 4 && clip.payloads[2].string(.string) == "between promises", "Mixed promised-file ordering changed")
    let names = try clip.payloads.filter { $0.string(.string) == nil }.map { try $0.storedTransferFiles()[0].name }
    try require(names == ["promised-image.png", "second-image.png", "promised-archive.zip"], "Legacy multi-file promise completion order leaked into item order")
    let writers = try prepareTransfer(clip, dragging: true, directory: directory.appendingPathComponent("replay"))
    try require(writers.count == 4, "Promised-file replay added duplicate items")
    try require(try Data(contentsOf: (writers[0] as! ClipFileWriter).fileURL) == image, "Promised image did not survive import cleanup")
    try require(try Data(contentsOf: (writers[3] as! ClipFileWriter).fileURL) == bytes, "Promised archive did not survive import cleanup")

    var failed: Result<Clip, Error>?
    let failure = PromisedFileImport(objects: [TestPromiseReceiver(files: [], shouldFail: true)], payloads: [placeholder]) { failed = $0 }
    failure.start()
    try waitFor("Failed file promise did not complete") { failed != nil }
    if case .success = failed! { throw SelfTestFailure(description: "Failed file promise published a partial clip") }
    try transferBoard { board in
        let secret = Payload(types: [ClipStore.sensitiveTypes[0]: Data()]).pasteboardItem()
        try require(board.writeObjects([text.pasteboardItem(), secret]), "Cannot write sensitive import fixture")
        try require(!FileTransferImport.receive(board) { _ in preconditionFailure("Sensitive import callback ran") }, "Sensitive drag import was accepted")
    }
}

func testNamedTransferCache(directory: URL) throws {
    let cache = TransferFileCache(directory: directory)
    for (index, name) in ["中文 名称 #1.docx", "extensionless", "empty", "../safe.txt", String(repeating: "长", count: 100) + ".pdf"].enumerated() {
        let bytes = index == 2 ? Data() : Data([0, 1, 255])
        var result: Result<URL, Error>?
        cache.prepare(bytes: bytes, fileExtension: (name as NSString).pathExtension, filename: name) { result = $0 }
        try waitFor("Named transfer cache did not finish") { result != nil }
        let url = try result!.get()
        try require(url.lastPathComponent == TransferFileCache.safeFilename(name), "Preferred filename was not preserved safely")
        try require(url.path.hasPrefix(directory.path + "/") && url.lastPathComponent.utf8.count <= 180, "Unsafe named export path")
        try require(try Data(contentsOf: url) == bytes, "Named export changed file contents")
        var reused: Result<URL, Error>?
        cache.prepare(bytes: bytes, fileExtension: (name as NSString).pathExtension, filename: name) { reused = $0 }
        try waitFor("Named cache reuse did not finish") { reused != nil }
        try require(try reused!.get() == url, "Named export was not reused")
    }
}
