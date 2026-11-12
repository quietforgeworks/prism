import AppKit
import CoreFoundation
import Foundation
import ImageIO
import QuartzCore

// Run explicitly with --self-test. These tests use only private pasteboards and
// disposable storage; they never show the shelf or touch the general board.
struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw SelfTestFailure(description: message) }
}

private func withTestPasteboard<T>(_ body: (NSPasteboard) throws -> T) rethrows -> T {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    return try body(board)
}

func waitFor(_ message: String, timeout: TimeInterval = 5, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    try require(condition(), message)
}

private func textClip(_ text: String, source: String = "Self Test") -> Clip {
    Clip(source: source, bundle: "local.prism.selftest", payloads: [
        Payload(types: [NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)])
    ])
}

func tinyImageData() throws -> (png: Data, tiff: Data) {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        throw SelfTestFailure(description: "Cannot create image fixture")
    }
    guard let pixels = bitmap.bitmapData else { throw SelfTestFailure(description: "Image fixture has no pixel buffer") }
    for y in 0..<2 { for x in 0..<3 {
        let offset = y * bitmap.bytesPerRow + x * 4
        pixels[offset] = UInt8(x * 100); pixels[offset + 1] = UInt8(y * 150)
        pixels[offset + 2] = 32; pixels[offset + 3] = 255
    } }
    guard let png = bitmap.representation(using: .png, properties: [:]),
          let tiff = bitmap.representation(using: .tiff, properties: [:]) else {
        throw SelfTestFailure(description: "Cannot encode image fixture")
    }
    return (png, tiff)
}

func dragImageData(width: Int, height: Int, format: NSBitmapImageRep.FileType) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let pixels = bitmap.bitmapData else {
        throw SelfTestFailure(description: "Cannot allocate drag image fixture")
    }
    pixels.initialize(repeating: 0x87, count: bitmap.bytesPerRow * height)
    for y in 0..<height { for x in 0..<width {
        let offset = y * bitmap.bytesPerRow + x * 4
        pixels[offset] = UInt8(x % 251); pixels[offset + 1] = UInt8(y % 251)
        pixels[offset + 3] = 255
    } }
    guard let bytes = bitmap.representation(using: format, properties: [:]) else {
        throw SelfTestFailure(description: "Cannot encode drag image fixture")
    }
    return bytes
}

// Simulate a receiver requesting its final destination on the provider's actual
// export queue. No drag session, visible window or general pasteboard is used.
private final class PromiseWriteObservation {
    private let lock = NSLock()
    private var error: Error?
    private var count = 0
    private var wasMainThread = false
    func record(_ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        self.error = error; count += 1; wasMainThread = Thread.isMainThread
    }
    var result: (error: Error?, count: Int, wasMainThread: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (error, count, wasMainThread)
    }
}

private func deliverImagePromise(_ provider: ClipFilePromiseProvider, to destination: URL) throws -> Error? {
    let queue = provider.operationQueue(for: provider)
    try require(queue !== OperationQueue.main, "Image file delivery uses the main operation queue")
    let observation = PromiseWriteObservation()
    queue.addOperation {
        provider.filePromiseProvider(provider, writePromiseTo: destination) { observation.record($0) }
    }
    try waitFor("Image file promise never called its completion handler") { observation.result.count > 0 }
    queue.waitUntilAllOperationsAreFinished()
    let result = observation.result
    try require(result.count == 1, "Image file promise completed more than once")
    try require(!result.wasMainThread, "Image file delivery ran on the main thread")
    return result.error
}

private func imagePromise(_ clip: Clip) throws -> ClipFilePromiseProvider {
    let writers = try clip.pasteboardWriters(forDragging: true)
    guard writers.count == 1, let provider = writers[0] as? ClipFilePromiseProvider else {
        throw SelfTestFailure(description: "Image drag did not preserve a native file promise provider")
    }
    return provider
}

private func fixturePayloads(root: URL) throws -> [Payload] {
    let image = try tinyImageData()
    let firstFile = root.appendingPathComponent("文件 one.txt")
    let secondFile = root.appendingPathComponent("second.dat")
    try Data("file one".utf8).write(to: firstFile)
    try Data([0, 1, 255, 7]).write(to: secondFile)
    let pdf = NSMutableData()
    guard let consumer = CGDataConsumer(data: pdf as CFMutableData) else {
        throw SelfTestFailure(description: "Cannot create PDF fixture")
    }
    var page = CGRect(x: 0, y: 0, width: 60, height: 40)
    guard let context = CGContext(consumer: consumer, mediaBox: &page, nil) else {
        throw SelfTestFailure(description: "Cannot create PDF context")
    }
    context.beginPDFPage(nil); context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 5, y: 5, width: 40, height: 20)); context.endPDFPage(); context.closePDF()
    return [
        Payload(types: ["public.utf8-plain-text": Data("Prism rich text\n第二行".utf8),
                        "public.rtf": Data(#"{\rtf1\ansi Rich \b text\b0 .}"#.utf8),
                        "public.html": Data("<html><meta charset=\"utf-8\"><body><b>Rich text</b> 中文</body></html>".utf8),
                        "local.prism.selftest.custom": Data([0, 255, 0, 3, 128]),
                        "local.prism.selftest.empty": Data()]),
        Payload(types: ["public.png": image.png, "public.tiff": image.tiff]),
        Payload(types: ["com.adobe.pdf": pdf as Data]),
        Payload(types: ["public.file-url": Data(firstFile.absoluteString.utf8)]),
        Payload(types: ["public.file-url": Data(secondFile.absoluteString.utf8)]),
        Payload(types: ["public.url": Data("https://example.com/path?q=%E4%B8%AD".utf8)]),
        Payload(types: ["local.prism.selftest.binary": Data([255, 254, 0, 1, 127])])
    ]
}

private func verifyPayloads(_ actual: [Payload], _ expected: [Payload], _ context: String) throws {
    try require(actual.count == expected.count, "\(context): item count \(actual.count), expected \(expected.count)")
    for (i, pair) in zip(actual, expected).enumerated() {
        for (type, bytes) in pair.1.types {
            try require(pair.0.types[type] == bytes, "\(context): item \(i) changed or lost \(type)")
        }
    }
}

private struct DiskSnapshot: Equatable {
    let bytes: Data
    let modified: Date
}

private func payloadSnapshots(_ root: URL, id: UUID? = nil) throws -> [String: DiskSnapshot] {
    var result: [String: DiskSnapshot] = [:]
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
    while let file = files?.nextObject() as? URL {
        guard file.pathExtension == "payload", id == nil || file.lastPathComponent.lowercased().hasPrefix(id!.uuidString.lowercased()) else { continue }
        let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
        result[file.path] = DiskSnapshot(bytes: try Data(contentsOf: file), modified: values.contentModificationDate ?? .distantPast)
    }
    return result
}

func runSelfTests() -> Int32 {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Prism-SelfTest-\(UUID().uuidString)", isDirectory: true)
    do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    catch { print("FAIL: temporary directory: \(error)"); return 1 }
    defer { try? FileManager.default.removeItem(at: root) }
    var passed = 0, failed = 0
    func run(_ name: String, _ body: () throws -> Void) {
        do { try autoreleasepool(invoking: body); passed += 1; print("PASS: \(name)") }
        catch { failed += 1; print("FAIL: \(name): \(error)") }
        fflush(stdout)
    }
    func directory(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    run("multi-item / multi-UTI pasteboard round trip") {
        let expected = try fixturePayloads(root: root)
        try withTestPasteboard { board in
            try require(board.writeObjects(expected.map { $0.pasteboardItem() }), "Could not write private pasteboard")
            guard let captured = ClipStore.read(board, source: "Fixture App", bundle: "local.fixture") else {
                throw SelfTestFailure(description: "Capture rejected valid mixed content")
            }
            try verifyPayloads(captured.payloads, expected, "capture")
            try require(captured.files.count == 2, "Lost one of two file URLs")
            try require(captured.image != nil, "Image cannot be decoded")
            try require(captured.pdf == expected[2].data(.pdf), "PDF in later item is inaccessible")
            board.clearContents()
            try require(board.writeObjects(captured.payloads.map { $0.pasteboardItem() }), "Could not restore private pasteboard")
            guard let restored = ClipStore.read(board, source: "Other App", bundle: "other") else {
                throw SelfTestFailure(description: "Restored pasteboard could not be read")
            }
            try verifyPayloads(restored.payloads, expected, "restore")
        }
    }

    run("file URL above 1 GiB / small persisted payload / native URL round trip") {
        let gibibyte: UInt64 = 1024 * 1024 * 1024
        let logicalSize = gibibyte + 1
        let file = root.appendingPathComponent("large sparse 文件.bin")
        try require(FileManager.default.createFile(atPath: file.path, contents: nil), "Could not create sparse file fixture")
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: logicalSize)
        let initialAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try require((initialAttributes[.size] as? NSNumber)?.uint64Value == logicalSize && logicalSize > gibibyte, "Sparse file is not larger than 1 GiB")
        let expectedURL = file.resolvingSymlinksInPath().standardizedFileURL

        try withTestPasteboard { sourceBoard in
            try require(sourceBoard.writeObjects([file as NSURL]), "Could not write native file URL to private pasteboard")
            guard let captured = ClipStore.read(sourceBoard, source: "File Fixture", bundle: "local.prism.selftest.files") else {
                throw SelfTestFailure(description: "Capture rejected a file URL for a file larger than 1 GiB")
            }
            try require(captured.files.map { $0.resolvingSymlinksInPath().standardizedFileURL } == [expectedURL], "Captured file URL changed")
            try require(captured.byteCount < 64 * 1024, "File URL capture embedded a large payload")
            let store = ClipStore(directory: directory("large-file-url"))
            let id = store.add(captured)
            try require(store.flush(), "File URL could not be saved")
            try require(store.diskUsage() < 2 * 1024 * 1024, "File URL history copied a large amount of file data")
            let restarted = ClipStore(directory: store.directory)
            guard let loaded = restarted.clips.first(where: { $0.id == id }) else {
                throw SelfTestFailure(description: "File URL record missing after restart")
            }
            try require(loaded.files.map { $0.resolvingSymlinksInPath().standardizedFileURL } == [expectedURL], "Persisted file URL changed")
            try require(loaded.byteCount < 64 * 1024, "Persisted file URL payload became large")
            let payloads = try loaded.loadPayloads()
            try verifyPayloads(payloads, captured.payloads, "large file URL disk restart")
            let archive = try JSONEncoder().encode(Archive(clips: [loaded], boards: []))
            try require(archive.count < 64 * 1024, "Archive embedded the large file contents")

            try withTestPasteboard { restoredBoard in
                let writers = try loaded.pasteboardWriters()
                try require(restoredBoard.writeObjects(writers), "Could not restore file URL payload to private pasteboard")
                let nativeURLs = (restoredBoard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? [])
                    .map { ($0 as URL).resolvingSymlinksInPath().standardizedFileURL }
                try require(nativeURLs == [expectedURL], "Restored payload cannot be read as the original native file URL")
            }
        }
        try require(FileManager.default.fileExists(atPath: file.path), "Original file disappeared during file URL round trip")
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try require((finalAttributes[.size] as? NSNumber)?.uint64Value == logicalSize, "File URL round trip changed the original file size")
    }

    run("file-reference drag writer / filename suppression / internal marker") {
        let file = root.appendingPathComponent("幻灯片 drag fixture.pptx")
        let contents = Data([0x50, 0x4b, 0x03, 0x04, 0x01, 0x02])
        try contents.write(to: file)
        guard let reference = CFURLCreateFileReferenceURL(kCFAllocatorDefault, file as CFURL, nil) else {
            throw SelfTestFailure(description: "Could not create native file-reference URL fixture")
        }
        // Bridging a file-reference NSURL to Swift URL normalizes it to a path.
        // Read the CFURL's original string so this reproduces Finder's payload.
        let referenceString = CFURLGetString(reference.takeRetainedValue()) as String
        try require(referenceString.contains("/.file/id="), "Fixture does not exercise the Finder file-reference URL form")
        let clip = Clip(source: "Finder Fixture", bundle: "local.prism.selftest.files", payloads: [Payload(types: [
            NSPasteboard.PasteboardType.fileURL.rawValue: Data(referenceString.utf8),
            NSPasteboard.PasteboardType.string.rawValue: Data(file.lastPathComponent.utf8),
            "public.utf16-external-plain-text": file.lastPathComponent.data(using: .utf16)!,
            NSPasteboard.PasteboardType.URL.rawValue: Data("https://example.com/unrelated-representation".utf8),
            "com.apple.icns": try tinyImageData().png
        ])])
        let writers = try clip.pasteboardWriters()
        try require(writers.count == 1 && writers[0] is NSURL, "File item was not promoted to one native NSURL writer")
        let expectedURL = file.resolvingSymlinksInPath().standardizedFileURL
        let marker = NSPasteboard.PasteboardType("local.prism.clip-id")
        try withTestPasteboard { board in
            let nativeTypes = writers[0].writableTypes(for: board)
            try require(nativeTypes.contains(.fileURL) && nativeTypes == (file as NSURL).writableTypes(for: board), "File writer does not advertise the native file representations")
            try require(board.writeObjects(writers), "Could not write native file-reference writers")
            var urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? [])
                .map { ($0 as URL).resolvingSymlinksInPath().standardizedFileURL }
            try require(urls == [expectedURL], "Native writer did not resolve the original file-reference URL")
            try require(board.pasteboardItems?.first?.string(forType: .string) != file.lastPathComponent, "File can still be exported as a filename text clipping")

            board.clearContents()
            let wrapped = ClipDragWriter(writer: writers[0], clipIDs: clip.id.uuidString)
            try require(Set(wrapped.writableTypes(for: board)) == Set(nativeTypes + [marker]), "Internal drag wrapper changed native writer types")
            try require(board.writeObjects([wrapped]), "Could not write marked native drag writer")
            urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? [])
                .map { ($0 as URL).resolvingSymlinksInPath().standardizedFileURL }
            try require(urls == [expectedURL], "Internal drag metadata broke native file decoding")
            try require(board.pasteboardItems?.first?.string(forType: marker) == clip.id.uuidString, "Internal clip identity was lost")
            try require(board.pasteboardItems?.first?.string(forType: .string) != file.lastPathComponent, "Internal drag wrapper reintroduced filename text")
            let destinationFolder = directory("file-drag-delivery")
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            let destination = destinationFolder.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: urls[0], to: destination)
            let deliveredContents = try Data(contentsOf: destination)
            try require(deliveredContents == contents && destination.pathExtension == "pptx", "File writer did not deliver the original fixture bytes and extension")
        }
        let remainingContents = try Data(contentsOf: file)
        try require(remainingContents == contents, "Preparing file drag modified the original file")
    }

    run("mixed native and legacy file writers preserve order and non-file formats") {
        let files = (1...3).map { root.appendingPathComponent("mixed drag file \($0).bin") }
        for (index, file) in files.enumerated() { try Data([UInt8(index), 0xff]).write(to: file) }
        let literal = "file:///this/is/ordinary/copied/text.bin"
        let firstText = Payload(types: [NSPasteboard.PasteboardType.string.rawValue: Data(literal.utf8),
                                      "local.prism.selftest.exact": Data([0, 0xff, 7])])
        let betweenText = Payload(types: [NSPasteboard.PasteboardType.string.rawValue: Data("between files".utf8),
                                        NSPasteboard.PasteboardType.html.rawValue: Data("<b>between files</b>".utf8)])
        let legacy = try PropertyListSerialization.data(fromPropertyList: files.dropFirst().map(\.path), format: .binary, options: 0)
        let clip = Clip(source: "Mixed Fixture", bundle: "local.prism.selftest.files", payloads: [
            firstText,
            Payload(types: [NSPasteboard.PasteboardType.fileURL.rawValue: Data(files[0].absoluteString.utf8),
                            NSPasteboard.PasteboardType.string.rawValue: Data(files[0].lastPathComponent.utf8)]),
            betweenText,
            Payload(types: ["NSFilenamesPboardType": legacy,
                            NSPasteboard.PasteboardType.string.rawValue: Data("two filenames".utf8)])
        ])
        let writers = try clip.pasteboardWriters()
        try require(writers.count == 5, "Mixed/legacy file payloads lost or added items")
        try require(writers[0] is NSPasteboardItem && writers[1] is NSURL && writers[2] is NSPasteboardItem && writers[3] is NSURL && writers[4] is NSURL,
                    "Mixed items changed order or plain file:// text became a file")
        try withTestPasteboard { board in
            try require(board.writeObjects(writers), "Could not write mixed file writers")
            guard let items = board.pasteboardItems, items.count == 5 else { throw SelfTestFailure(description: "Mixed private pasteboard item count changed") }
            for (index, expected) in [(0, firstText), (2, betweenText)] {
                for (type, bytes) in expected.types {
                    try require(items[index].data(forType: .init(type)) == bytes, "Non-file item \(index) lost or changed \(type)")
                }
            }
            for (fileIndex, itemIndex) in [1, 3, 4].enumerated() {
                try require(items[itemIndex].availableType(from: [.fileURL]) == .fileURL
                            && writers[itemIndex].writableTypes(for: board) == (files[fileIndex] as NSURL).writableTypes(for: board),
                            "Mixed file item \(itemIndex) does not preserve the native file representations")
                try require(items[itemIndex].string(forType: .string) != files[fileIndex].lastPathComponent
                            && items[itemIndex].string(forType: .string) != "two filenames",
                            "Mixed file item \(itemIndex) exposes a competing filename string")
            }
            let urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? [])
                .map { ($0 as URL).resolvingSymlinksInPath().standardizedFileURL }
            try require(urls == files.map { $0.resolvingSymlinksInPath().standardizedFileURL }, "Native and legacy file URL order changed")
        }
    }

    run("missing real file writer fails instead of falling back to filename text") {
        let file = root.appendingPathComponent("removed drag fixture.bin")
        try Data([1, 2, 3]).write(to: file)
        guard let reference = CFURLCreateFileReferenceURL(kCFAllocatorDefault, file as CFURL, nil) else { throw SelfTestFailure(description: "Could not create missing-file reference fixture") }
        let referenceString = CFURLGetString(reference.takeRetainedValue()) as String
        try require(referenceString.contains("/.file/id="), "Missing-file fixture does not exercise the Finder file-reference URL form")
        try FileManager.default.removeItem(at: file)
        let legacy = try PropertyListSerialization.data(fromPropertyList: [file.path], format: .binary, options: 0)
        let fixtures: [[String: Data]] = [
            [NSPasteboard.PasteboardType.fileURL.rawValue: Data(file.absoluteString.utf8)],
            [NSPasteboard.PasteboardType.fileURL.rawValue: Data(referenceString.utf8)],
            ["NSFilenamesPboardType": legacy]
        ]
        for (index, representation) in fixtures.enumerated() {
            var types = representation
            types[NSPasteboard.PasteboardType.string.rawValue] = Data(file.lastPathComponent.utf8)
            let clip = Clip(source: "Removed File Fixture", bundle: "local.prism.selftest.files", payloads: [Payload(types: types)])
            var rejected = false
            do { _ = try clip.pasteboardWriters() } catch { rejected = true }
            try require(rejected, "Missing-file representation \(index) silently fell back to filename text")
        }
    }

    run("image copy keeps raw formats without drag promise representations") {
        let image = try tinyImageData()
        let payload = Payload(types: ["public.png": image.png, "public.tiff": image.tiff,
                                      "local.prism.selftest.image-extra": Data([0, 255, 7])])
        let clip = Clip(source: "Image Copy Fixture", bundle: "", payloads: [payload])
        let writers = try clip.pasteboardWriters()
        try require(writers.count == 1 && writers[0] is NSPasteboardItem,
                    "Ordinary image copy was changed into a file promise")
        try withTestPasteboard { board in
            try require(board.writeObjects(writers), "Could not copy raw image to private pasteboard")
            guard let item = board.pasteboardItems?.first else { throw SelfTestFailure(description: "Raw image copy is missing") }
            try require(Set(item.types.map(\.rawValue)) == Set(payload.types.keys), "Ordinary image copy added or lost format types")
            for (type, bytes) in payload.types {
                try require(item.data(forType: .init(type)) == bytes, "Ordinary image copy changed \(type)")
            }
        }
        _ = try imagePromise(clip)
        let after = try clip.loadPayloads()
        try require(after == [payload], "Preparing an image drag modified the original copy payload")
    }

    run("image drag retains native promise identity / private marker / raw image formats") {
        let image = try tinyImageData()
        let payload = Payload(types: ["public.png": image.png, "public.tiff": image.tiff,
                                      "local.prism.selftest.image-extra": Data([1, 0, 255])])
        let clip = Clip(source: "Image Drag Fixture", bundle: "", payloads: [payload])
        let provider = try imagePromise(clip)
        // The UI sets metadata on this object directly. A generic writer wrapper
        // would conceal its NSFilePromiseProvider dynamic type from AppKit.
        let ids = [clip.id.uuidString, UUID().uuidString].joined(separator: ",")
        provider.clipIDs = ids
        try require(provider.delegate === provider, "Image promise lost its delegate before receiver delivery")
        try withTestPasteboard { board in
            let native = NSFilePromiseProvider(fileType: provider.fileType, delegate: provider)
            let nativeTypes = Set(native.writableTypes(for: board))
            let advertised = provider.writableTypes(for: board)
            try require(!nativeTypes.isEmpty && nativeTypes.isSubset(of: Set(advertised)), "Image drag lost native promise representations")
            try require(Set(advertised).count == advertised.count, "Image drag advertises a format more than once")
            try require(board.writeObjects([provider]), "Could not write marked image promise to private pasteboard")
            guard let item = board.pasteboardItems?.first else { throw SelfTestFailure(description: "Image promise pasteboard item is missing") }
            try require(item.string(forType: ClipFilePromiseProvider.clipIDType) == ids, "Image promise lost multi-selection identity")
            try require(nativeTypes.isSubset(of: Set(item.types)), "Writing internal metadata removed native promise types")
            for (type, bytes) in payload.types {
                try require(item.data(forType: .init(type)) == bytes, "Image destination cannot read original \(type)")
            }
        }
        try require(try clip.loadPayloads() == [payload], "Image promise pasteboard access mutated the stored image")
    }

    run("PNG / TIFF / JPEG image promises deliver original encodings and matching filenames") {
        let image = try tinyImageData()
        let jpeg = try dragImageData(width: 3, height: 2, format: .jpeg)
        let variants: [(type: String, bytes: Data, extensions: Set<String>)] = [
            ("public.png", image.png, ["png"]),
            ("public.tiff", image.tiff, ["tiff", "tif"]),
            ("public.jpeg", jpeg, ["jpeg", "jpg"])
        ]
        for variant in variants {
            let payload = Payload(types: [variant.type: variant.bytes])
            let clip = Clip(source: "Encoded Image Fixture", bundle: "", payloads: [payload])
            let provider = try imagePromise(clip)
            try require(provider.fileType == variant.type, "Promise file type does not describe the original encoding")
            let filename = provider.filePromiseProvider(provider, fileNameForType: provider.fileType)
            try require(filename == URL(fileURLWithPath: filename).lastPathComponent,
                        "Image promise supplied a path instead of a filename")
            try require(variant.extensions.contains((filename as NSString).pathExtension.lowercased()), "Image promise filename has the wrong extension")
            let destination = root.appendingPathComponent(filename)
            try require(!FileManager.default.fileExists(atPath: destination.path), "Image promise wrote a file before receiver request")
            let error = try deliverImagePromise(provider, to: destination)
            try require(error == nil, "Image promise failed to write \(variant.type): \(String(describing: error))")
            let delivered = try Data(contentsOf: destination)
            try require(delivered == variant.bytes, "Image promise recompressed or changed original \(variant.type) bytes")
            try require(try clip.loadPayloads() == [payload], "Image file delivery changed the history payload")
        }
        let allFormats = Payload(types: ["public.png": image.png, "public.tiff": image.tiff, "public.jpeg": jpeg])
        let preferred = try imagePromise(Clip(source: "Multi-format Fixture", bundle: "", payloads: [allFormats]))
        try require(preferred.fileType == "public.png", "Equal-size image representations do not prefer PNG")
        let destination = root.appendingPathComponent(preferred.suggestedFilename)
        let error = try deliverImagePromise(preferred, to: destination)
        try require(error == nil, "Multi-format image promise failed")
        try require(try Data(contentsOf: destination) == image.png, "Multi-format image promise did not preserve the selected PNG bytes")
    }

    run("persisted image promise exports full resolution instead of preview or smaller representation") {
        let original = try dragImageData(width: 2048, height: 61, format: .tiff)
        let smallerPNG = try tinyImageData().png
        let payload = Payload(types: ["public.png": smallerPNG, "public.tiff": original])
        let store = ClipStore(directory: directory("image-promise"))
        let id = store.add(Clip(source: "Full-resolution Fixture", bundle: "", payloads: [payload]))
        try require(store.flush(), "Could not persist image promise fixture")
        let before = try payloadSnapshots(store.directory, id: id)
        let restarted = ClipStore(directory: store.directory)
        guard let loaded = restarted.clips.first(where: { $0.id == id }) else { throw SelfTestFailure(description: "Persisted image fixture missing") }
        let provider = try imagePromise(loaded)
        try require(provider.fileType == "public.tiff", "Image promise selected a smaller representation over the full-resolution original")
        let destination = root.appendingPathComponent(provider.suggestedFilename)
        let error = try deliverImagePromise(provider, to: destination)
        try require(error == nil, "Full-resolution image promise failed")
        let delivered = try Data(contentsOf: destination)
        try require(delivered == original, "Full-resolution image was replaced with a preview or re-encoded")
        guard let source = CGImageSourceCreateWithData(delivered as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SelfTestFailure(description: "Promised image file does not decode") }
        try require(image.width == 2048 && image.height == 61, "Image promise changed original pixel dimensions")
        try require(try payloadSnapshots(store.directory, id: id) == before, "Image drag rewrote the persisted source bytes or modification date")
        try require(restarted.clips.contains(where: { $0.id == id }), "Image drag removed the source history card")
    }

    run("image promise reports invalid destination and remains usable for retry") {
        let image = try tinyImageData()
        let payload = Payload(types: ["public.png": image.png])
        let clip = Clip(source: "Image Promise Failure Fixture", bundle: "", payloads: [payload])
        let provider = try imagePromise(clip)
        // A file used as a parent fails on every account without changing
        // permissions or relying on privileged/unprivileged test execution.
        let blocker = root.appendingPathComponent("not-an-image-directory")
        let sentinel = Data("keep this unrelated file".utf8)
        try sentinel.write(to: blocker)
        let badDestination = blocker.appendingPathComponent(provider.suggestedFilename)
        let failure = try deliverImagePromise(provider, to: badDestination)
        try require(failure != nil, "Unwritable image destination reported success")
        try require(!(failure?.localizedDescription.isEmpty ?? true), "Image promise failure has no error description")
        try require(!FileManager.default.fileExists(atPath: badDestination.path), "Failed image promise left a destination file")
        try require(try Data(contentsOf: blocker) == sentinel, "Failed image promise changed an unrelated existing file")
        let goodDestination = root.appendingPathComponent(provider.suggestedFilename)
        let retryError = try deliverImagePromise(provider, to: goodDestination)
        try require(retryError == nil, "Image promise could not retry after a failed destination")
        try require(try Data(contentsOf: goodDestination) == image.png, "Retry did not write the original image bytes")
        try require(try clip.loadPayloads() == [payload], "Failed or retried image export changed the original payload")
    }

    run("image file drag cache is bounded and preserves delayed receiver access") {
        try testTransferFileCache(directory: directory("image-drag-file-cache"))
    }

    run("image drag supplies one native existing file URL with exact original image formats") {
        let png = try dragImageData(width: 2048, height: 61, format: .png)
        let tiff = try tinyImageData().tiff
        let payload = Payload(types: ["public.png": png, "public.tiff": tiff])
        let clip = Clip(source: "Chat File Drop Fixture", bundle: "", payloads: [payload])
        let original = try clip.pasteboardWriters(forDragging: true)
        let cache = TransferFileCache(directory: directory("chat-drop-export"))
        var prepared: Result<[NSPasteboardWriting], Error>?
        FileTransferPreparation.prepare(original, cache: cache) { prepared = $0 }
        try waitFor("Image file preparation did not complete") { prepared != nil }
        let writers = try prepared!.get()
        try require(writers.count == 1 && writers[0] is ClipFileWriter,
                    "One image did not become exactly one native file writer")
        let writer = writers[0] as! ClipFileWriter
        try require(writer.fileURL.pathExtension == "png", "Image file has wrong original encoding extension")
        try require(try Data(contentsOf: writer.fileURL) == png, "Prepared PNG differs from original encoded bytes")
        let ids = clip.id.uuidString
        try withTestPasteboard { board in
            try require(board.writeObjects([ClipDragWriter(writer: writer, clipIDs: ids)]), "Could not publish native image file")
            try require(board.pasteboardItems?.count == 1, "Image drag created duplicate pasteboard items")
            let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            try require(urls == [writer.fileURL], "File-only receiver cannot read the native image URL")
            let item = board.pasteboardItems![0]
            try require(item.data(forType: .png) == png && item.data(forType: .tiff) == tiff,
                        "Native image consumers lost their original raw formats")
            try require(item.string(forType: ClipFilePromiseProvider.clipIDType) == ids,
                        "Image file drag lost collection identity")
            let promise = try imagePromise(clip)
            let promiseTypes = NSFilePromiseProvider(fileType: promise.fileType, delegate: promise).writableTypes(for: board)
            try require(Set(item.types).isDisjoint(with: Set(promiseTypes)),
                        "Existing file is also exposed as a competing file promise")
        }
        try require(FileManager.default.fileExists(atPath: writer.fileURL.path), "Export disappeared when receiver read the pasteboard")
        try require(try clip.loadPayloads() == [payload], "Image file preparation changed history")
    }

    run("mixed image and native-file drag keeps item order and fails atomically on export error") {
        let png = try tinyImageData().png
        let image = Clip(source: "Mixed Fixture", bundle: "", payloads: [Payload(types: ["public.png": png])])
        let file = root.appendingPathComponent("retained-file.txt")
        let sentinel = Data("retained source".utf8); try sentinel.write(to: file)
        let inputs: [NSPasteboardWriting] = [file as NSURL] + (try image.pasteboardWriters(forDragging: true))
        var prepared: Result<[NSPasteboardWriting], Error>?
        FileTransferPreparation.prepare(inputs, cache: TransferFileCache(directory: directory("mixed-image-export"))) { prepared = $0 }
        try waitFor("Mixed drag preparation did not complete") { prepared != nil }
        let writers = try prepared!.get()
        try require(writers.count == 2 && (writers[0] as? NSURL) == (file as NSURL) && writers[1] is ClipFileWriter,
                    "Mixed drag changed file order or item count")
        try require(try Data(contentsOf: file) == sentinel, "Mixed drag modified original native file")
        var failed: Result<[NSPasteboardWriting], Error>?
        FileTransferPreparation.prepare(inputs, cache: TransferFileCache(directory: directory("export-capacity"), byteLimit: 1)) { failed = $0 }
        try waitFor("Failed image export never completed") { failed != nil }
        if case .success = failed! { throw SelfTestFailure(description: "Partial image preparation was published as success") }
        try require(try Data(contentsOf: file) == sentinel, "Failed preparation changed native source")
    }

    run("appearance defaults, persistence and scoped reset preserve existing preferences") {
        try testAppearancePreferences()
    }

    run("compositor slide requests the current screen refresh rate") {
        let animator = ShelfSlideAnimator(), layer = CALayer()
        animator.animate(layer: layer, from: -374, to: 0, duration: 0.2, curve: .easeOut) {}
        let slide = layer.animation(forKey: ShelfSlideAnimator.layerAnimationKey)!
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let maximum = Float(max(1, screen.maximumFramesPerSecond))
            try require(slide.preferredFrameRateRange.maximum == maximum && slide.preferredFrameRateRange.preferred == maximum,
                        "Compositor animation does not request the display maximum")
        }
        animator.cancel()
    }
    run("compositor reversal preserves its supplied position and ignores old completions") {
        let animator = ShelfSlideAnimator(), layer = CALayer()
        var closed = 0, reopened = 0
        animator.animate(layer: layer, from: 0, to: -374, duration: 0.2, curve: .easeIn) { closed += 1 }
        let closing = layer.animation(forKey: ShelfSlideAnimator.layerAnimationKey)!
        animator.animate(layer: layer, from: -125, to: 0, duration: 0.1, curve: .easeOut) { reopened += 1 }
        let opening = layer.animation(forKey: ShelfSlideAnimator.layerAnimationKey) as! CABasicAnimation
        try require((opening.fromValue as? NSNumber)?.doubleValue == -125, "Reversal jumped to an endpoint")
        closing.delegate?.animationDidStop?(closing, finished: true)
        try require(closed == 0 && reopened == 0 && animator.isAnimating, "Old completion ended the replacement slide")
        opening.delegate?.animationDidStop?(opening, finished: true)
        opening.delegate?.animationDidStop?(opening, finished: true)
        try require(closed == 0 && reopened == 1 && !animator.isAnimating, "Reopening did not complete exactly once")
    }

    run("compositor slide commits endpoints and isolates cancelled completions") {
        let animator = ShelfSlideAnimator(), layer = CALayer()
        var completions = 0
        animator.animate(layer: layer, from: -374, to: 0, duration: 0.2, curve: .easeOut) { completions += 1 }
        guard let original = layer.animation(forKey: ShelfSlideAnimator.layerAnimationKey) as? CABasicAnimation else {
            throw SelfTestFailure(description: "Compositor animation was not installed")
        }
        try require(animator.isAnimating && layer.sublayerTransform.m42 == 0,
                    "Compositor destination or active state is incorrect")
        try require(original.keyPath == "sublayerTransform.translation.y" && original.duration == 0.2,
                    "Shelf does not animate only the clipped child-layer translation")
        let unrelated = CABasicAnimation(keyPath: "opacity"); unrelated.duration = 1
        layer.add(unrelated, forKey: "unrelated")
        animator.cancel()
        try require(layer.sublayerTransform.m42 == -374, "Pre-commit cancellation jumped to the unrendered destination")
        original.delegate?.animationDidStop?(original, finished: true)
        try require(completions == 0 && !animator.isAnimating && layer.animation(forKey: "unrelated") != nil,
                    "Cancellation invoked stale completion or removed another animation")
        animator.animate(layer: layer, from: -150, to: 0, duration: 0.1, curve: .easeOut) { completions += 1 }
        let current = layer.animation(forKey: ShelfSlideAnimator.layerAnimationKey)!
        current.delegate?.animationDidStop?(current, finished: true)
        current.delegate?.animationDidStop?(current, finished: true)
        try require(completions == 1 && !animator.isAnimating, "Compositor completion was not exactly once")
        animator.animate(layer: layer, from: 0, to: -374, duration: 0, curve: .easeIn) { completions += 1 }
        try require(completions == 2 && layer.sublayerTransform.m42 == -374 && !animator.isAnimating,
                    "Immediate compositor transition failed")
    }

    run("asynchronous search captures immutable directory and preserves full-text filters") {
        try testAsyncSearchSnapshot(directory: directory("async-search-snapshot"))
    }
    run("asynchronous search publishes only the newest uncancelled query") {
        try testAsyncSearchCancellation(directory: directory("async-search-cancellation"))
    }
    run("card selection preserves body rendering and metadata updates change cached text") {
        let store = ClipStore(directory: directory("card-display"))
        let clip = textClip("Rendering fixture")
        store.add(clip); try require(store.flush(), "Could not save display fixture")
        let actions = ShelfActions(paste: { _, _ in }, copy: { _, _ in }, enqueue: { _ in }, settings: {}, pauseToggle: {}, stackToggle: {}, clear: {}, export: {}, import: {}, quit: {}, isPaused: { false }, isStack: { false }, targetName: { "Test" }, invalidatePendingPaste: {})
        let shelf = ShelfController(store: store, actions: actions)
        let card = ClipCard(frame: NSRect(x: 0, y: 0, width: 270, height: 280))
        let host = NSWindow(contentRect: card.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        host.contentView = card
        card.configure(clip, selected: false, number: 1, shelf: shelf)
        card.layoutSubtreeIfNeeded()
        func pixels() -> Data {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 270, pixelsHigh: 280, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.current = context
            context.cgContext.clear(card.bounds)
            card.draw(card.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let original = pixels()
        card.selected = true
        card.configure(clip, selected: true, number: 1, shelf: shelf)
        try require(pixels() == original, "Selection changed the cached card body")
        var renamed = clip; renamed.title = "Updated title"
        card.configure(renamed, selected: true, number: 1, shelf: shelf)
        try require(pixels() != original && card.clip?.title == "Updated title", "Changed metadata was not rendered")
        card.reset()
        try require(!card.selected && card.clip == nil, "Reuse leaked previous selection")
    }

    run("card double-click waits for mouse-up and clears pending paste on reuse") {
        // Call the real handlers on an unshown panel. Never post an event or
        // start a dragging session; the paste action records arguments only.
        NSApplication.shared.setActivationPolicy(.accessory)
        let store = ClipStore(directory: directory("card-gesture"))
        let first = Clip(source: "Gesture Fixture", bundle: "", payloads: [
            Payload(types: [NSPasteboard.PasteboardType.string.rawValue: Data("first card".utf8)])
        ])
        store.add(first)
        try require(store.flush(), "Could not save gesture fixture")
        var pastes: [(ids: [UUID], plain: Bool)] = []
        let actions = ShelfActions(
            paste: { pastes.append((ids: $0.map(\.id), plain: $1)) },
            copy: { _, _ in }, enqueue: { _ in }, settings: {}, pauseToggle: {}, stackToggle: {},
            clear: {}, export: {}, import: {}, quit: {}, isPaused: { false }, isStack: { false },
            targetName: { "Self Test" }, invalidatePendingPaste: {}, reportError: { _ in }
        )
        let shelf = ShelfController(store: store, actions: actions)
        guard let window = shelf.window, let content = window.contentView else {
            throw SelfTestFailure(description: "Could not create hidden gesture fixture")
        }
        try require(!window.isVisible, "Gesture fixture unexpectedly showed a window")
        let card = ClipCard(frame: NSRect(x: 20, y: 20, width: 200, height: 180))
        content.addSubview(card)
        defer { card.removeFromSuperview(); window.close() }
        card.configure(first, selected: true, number: nil, shelf: shelf)
        func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            guard let value = NSEvent.mouseEvent(with: type, location: NSPoint(x: 40, y: 40),
                modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 2, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw SelfTestFailure(description: "Could not construct gesture event")
            }
            return value
        }
        let shiftDown = try event(.leftMouseDown, flags: .shift)
        let up = try event(.leftMouseUp)
        card.mouseDown(with: shiftDown)
        try require(pastes.isEmpty, "Second mouse-down pasted before the user could drag")
        card.mouseUp(with: up)
        try require(pastes.count == 1 && pastes[0].ids == [first.id] && pastes[0].plain,
                    "Completed Shift-double-click did not paste once with the captured modifier")
        card.mouseUp(with: up)
        try require(pastes.count == 1, "Completed double-click left a pending paste")

        card.mouseDown(with: shiftDown)
        try require(pastes.count == 1, "Second mouse-down pasted before reuse")
        card.reset()
        let replacement = Clip(source: "Gesture Fixture", bundle: "", payloads: [
            Payload(types: [NSPasteboard.PasteboardType.string.rawValue: Data("replacement card".utf8)])
        ])
        store.add(replacement)
        try require(store.flush(), "Could not save replacement gesture fixture")
        shelf.refresh()
        card.configure(replacement, selected: true, number: nil, shelf: shelf)
        shelf.select(replacement, event: up)
        card.mouseUp(with: up)
        try require(pastes.count == 1, "Reused card pasted a new item from an old pending double-click")

        card.mouseDown(with: try event(.leftMouseDown))
        try require(pastes.count == 1, "Unmodified second mouse-down pasted early")
        card.mouseUp(with: up)
        try require(pastes.count == 2 && pastes[1].ids == [replacement.id] && !pastes[1].plain,
                    "Reused card no longer completes an ordinary double-click")
        try require(!window.isVisible && !shelf.isDragging, "Gesture handlers showed the shelf or started a drag")
    }

    run("format extraction and internal marker exclusion") {
        let rtf = Payload(types: ["public.rtf": Data(#"{\rtf1\ansi Rich \b text\b0 .}"#.utf8)])
        let html = Payload(types: ["public.html": Data("<html><body><b>HTML fixture</b></body></html>".utf8)])
        try require(Clip(source: "T", bundle: "", payloads: [rtf]).text.contains("Rich text"), "RTF text extraction failed")
        try require(Clip(source: "T", bundle: "", payloads: [html]).text.contains("HTML fixture"), "HTML text extraction failed")
        try withTestPasteboard { board in
            let item = textClip("Only visible text").payloads[0].pasteboardItem()
            item.setString(UUID().uuidString, forType: .init("local.prism.clip-id"))
            try require(board.writeObjects([item]), "Private board write failed")
            guard let clip = ClipStore.read(board, source: "T", bundle: "") else { throw SelfTestFailure(description: "Marker-bearing item rejected") }
            try require(clip.payloads[0].types["local.prism.clip-id"] == nil, "Internal drag marker leaked into history")
            try require(clip.text == "Only visible text", "Internal marker affected text")
        }
    }

    run("WeChat temporary image recovery / full-size PNG copy and file drag") {
        try testWeChatImageRecovery(directory: directory("wechat-recovery"))
    }
    run("MIME and Qt image aliases / PNG TIFF JPEG GIF BMP HEIC SVG preservation") {
        try testImageFormatAliases(directory: directory("image-aliases"))
    }
    run("legacy / Qt URI lists / percent-encoded and UTF16 file URLs") {
        try testFileURLCompatibility(directory: directory("uri-lists"))
    }
    run("temporary attachment snapshots survive source deletion / restart / archive") {
        try testTemporaryAttachmentSnapshots(directory: directory("attachment-snapshots"))
    }
    run("PDF / SVG / audio / movie / archive raw data drag exports") {
        try testEncodedFileExports(directory: directory("encoded-files"))
    }
    run("native promised-file import / mixed ordering / sensitive input rejection") {
        try testFilePromiseImport(directory: directory("promised-import"))
    }
    run("named transfer cache / empty and extensionless files / safe filenames") {
        try testNamedTransferCache(directory: directory("named-cache"))
    }
    run("file expiration / large reference / restored path / recoverable attachment") {
        try testFileReferenceAvailability(directory: directory("file-availability"))
    }
    run("asynchronous file status / deletion refresh / cancellation") {
        try testFileAvailabilityMonitor(directory: directory("file-monitor"))
    }
    run("expired card gray overlay / status label / selection / reuse") {
        try testExpiredCardOverlay(directory: directory("expired-card"))
    }
    run("multi-selection double-click / Command and Shift selection / activation") {
        try testMultiSelectionGestures(directory: directory("multi-gestures"))
    }
    run("multi-text paste into native text editor / RTF formatting / HTML") {
        try testCombinedTextPaste(directory: directory("combined-text"))
    }
    run("combined RTFD paste keeps inline attachment and surrounding texts") {
        try testCombinedAttachmentPaste(directory: directory("combined-attachment"))
    }
    run("mixed multi-selection copy and drag / invalid-card skip / ordering") {
        try testMixedSelectionTransfer(directory: directory("mixed-selection"))
    }
    run("raw PDF SVG Office audio archive copy and drag as native files") {
        try testEncodedFileCopy(directory: directory("encoded-copy"))
    }
    run("animated GIF copy and drag retain all frames and original encoding") {
        try testAnimatedImageTransfer(directory: directory("animated-gif"))
    }
    run("bounded inline multi-selection / large file references stay transferable") {
        try testSelectionMemoryBound(directory: directory("selection-memory"))
    }
    if let path = ProcessInfo.processInfo.environment["PRISM_FORMAT_FIXTURE_DIRECTORY"] {
        run("real codec fixtures / image paste / byte-exact file drag / multi-file clipboard") {
            try testExternalFormatFixtures(directory: directory("external-formats"), fixtures: URL(fileURLWithPath: path))
        }
    }

    run("custom scroll view opts into native responsive scrolling") {
        try require(ShelfScrollView.isCompatibleWithResponsiveScrolling, "Custom wheel handling disabled responsive scrolling")
    }
    run("hidden cards do not preload thumbnails or application icons") {
        try testHiddenCardDoesNotLoadAssets(directory: directory("asset-demand"))
    }
    run("live scrolling defers card repaints until the interaction ends") {
        try testScrollDefersCardUpdates(directory: directory("scroll-repaints"))
    }

    run("thumbnail lookahead stays within four neighbors and its payload budget") {
        try testThumbnailPrefetchBounds()
    }
    run("visible thumbnails have priority and retain a decoding slot") {
        try testVisibleThumbnailPriority()
    }

    run("sensitive marker rejection across items") {
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword", "com.1password.1password", "de.petermaurer.TransientPasteboardType"] {
            try withTestPasteboard { board in
                let safe = textClip("ordinary first item").payloads[0].pasteboardItem()
                let secret = textClip("must never be retained").payloads[0].pasteboardItem()
                secret.setData(Data(), forType: .init(marker))
                try require(board.writeObjects([safe, secret]), "Private board write failed")
                try require(ClipStore.read(board, source: "T", bundle: "") == nil, "Accepted empty sensitive marker \(marker) on second item")
            }
        }
        try withTestPasteboard { board in
            try require(ClipStore.read(board, source: "T", bundle: "") == nil, "Accepted empty pasteboard")
        }
    }

    run("oversized payload rejection") {
        try withTestPasteboard { board in
            let item = NSPasteboardItem()
            item.setData(Data(repeating: 0xa7, count: ClipStore.maxBytes + 1), forType: .init("local.prism.selftest.large"))
            try require(board.writeObjects([item]), "Private board write failed")
            try require(ClipStore.read(board, source: "T", bundle: "") == nil, "Accepted content above capture size limit")
        }
    }

    run("fingerprint boundaries / order / deduplication") {
        let one = Payload(types: ["a": Data("bc".utf8)])
        let other = Payload(types: ["ab": Data("c".utf8)])
        try require(Clip(source: "A", bundle: "", payloads: [one]).fingerprint != Clip(source: "A", bundle: "", payloads: [other]).fingerprint, "UTI/data boundary collision")
        let first = Payload(types: ["x": Data([1]), "y": Data([2])])
        let reordered = Payload(types: ["y": Data([2]), "x": Data([1])])
        let c = Clip(source: "First App", bundle: "first", payloads: [first, other])
        try require(c.fingerprint == Clip(source: "Other App", bundle: "other", payloads: [reordered, other]).fingerprint, "Dictionary order/source affected content identity")
        try require(c.fingerprint != Clip(source: "A", bundle: "", payloads: [other, first]).fingerprint, "Item order was discarded")
        let store = ClipStore(directory: directory("dedupe"))
        let board = Board(name: "Pinned"); store.boards = [board]
        let id = store.add(c)
        var duplicate = c; duplicate.id = UUID(); duplicate.date = Date().addingTimeInterval(10)
        let duplicateID = store.add(duplicate, board: board.id)
        try require(id == duplicateID && store.clips.count == 1, "Duplicate created another history entry")
        try require(store.clips[0].boardIDs.contains(board.id), "Dedupe lost board assignment")
        store.flush()
        let restarted = ClipStore(directory: store.directory)
        try require(restarted.clips.count == 1 && restarted.add(duplicate) == id, "Dedupe failed after restart")
        restarted.flush()
    }

    run("persistence / archive / exact binary payloads") {
        let payloads = try fixturePayloads(root: root)
        let store = ClipStore(directory: directory("restart"))
        let board = Board(name: "收藏 🧪", color: 3); store.boards = [board]
        var clip = Clip(source: "Fixture App", bundle: "local.fixture", payloads: payloads)
        clip.title = "Preserved title"; clip.recognizedText = "OCR fixture 识别文字"
        let id = store.add(clip, board: board.id); store.flush()
        let restarted = ClipStore(directory: store.directory)
        try require(restarted.boards == [board], "Board metadata changed")
        guard let loaded = restarted.clips.first(where: { $0.id == id }) else { throw SelfTestFailure(description: "History missing after restart") }
        try require(loaded.title == clip.title && loaded.recognizedText == clip.recognizedText && loaded.boardIDs == [board.id], "Clip metadata changed")
        try verifyPayloads(loaded.payloads, payloads, "disk restart")
        let archive = Archive(clips: restarted.clips, boards: restarted.boards)
        let decoded = try JSONDecoder().decode(Archive.self, from: JSONEncoder().encode(archive))
        try verifyPayloads(decoded.clips[0].payloads, payloads, "portable archive")
    }

    run("streamed backup round trip / valid-payload corruption rejection / replacement") {
        let marker = Data([0x52, 0x4f, 0x55, 0x4e, 0x44, 0, 0xff, 0x54, 0x52, 0x49, 0x50])
        let payloads = [
            Payload(types: ["public.utf8-plain-text": Data("Backup 中文 🧪".utf8),
                            "public.html": Data("<p>Backup <b>rich text</b></p>".utf8),
                            "local.prism.selftest.empty": Data()]),
            Payload(types: ["local.prism.selftest.backup-binary": marker,
                            "public.utf8-plain-text": Data("second item".utf8)])
        ]
        let board = Board(name: "Backup board", color: 4)
        var clip = Clip(source: "Backup Fixture", bundle: "local.prism.selftest.backup", payloads: payloads)
        clip.title = "Backup title"; clip.boardIDs = [board.id]; clip.recognizedText = "Preserved recognition"
        let companion = textClip("companion")
        let destination = root.appendingPathComponent("roundtrip.prismbackup", isDirectory: true)
        let archive = Archive(clips: [companion, clip], boards: [board])
        try ClipStore.exportBackup(archive, to: destination)
        let manifest = try ClipStore.readBackupManifest(at: destination)
        try require(manifest.ids == [companion.id, clip.id] && manifest.boards == [board], "Backup order or boards changed")
        let loaded = try manifest.clips.map { try ClipStore.readBackupClip(entry: $0, at: destination) }
        guard let restored = loaded.first(where: { $0.id == clip.id }) else { throw SelfTestFailure(description: "Backup omitted multi-item record") }
        try verifyPayloads(restored.payloads, payloads, "streamed backup")
        try require(restored.title == clip.title && restored.source == clip.source && restored.bundle == clip.bundle && restored.boardIDs == clip.boardIDs && restored.recognizedText == clip.recognizedText, "Backup clip metadata changed")
        let target = ClipStore(directory: directory("backup-import"))
        target.importArchive(Archive(clips: loaded, boards: manifest.boards))
        try require(target.flush(), "Imported backup could not be saved")
        let restarted = ClipStore(directory: target.directory)
        guard let imported = restarted.clips.first(where: { $0.id == clip.id }) else { throw SelfTestFailure(description: "Imported backup missing after restart") }
        try verifyPayloads(imported.payloads, payloads, "imported streamed backup")

        // Alter a raw data byte without changing the file length or breaking the
        // property list. Rejection must therefore detect changed content, rather
        // than merely failing to parse a malformed fixture.
        let recordFile = destination.appendingPathComponent("Records").appendingPathComponent(clip.id.uuidString + ".plist")
        let original = try Data(contentsOf: recordFile)
        guard let range = original.range(of: marker) else { throw SelfTestFailure(description: "Could not find binary fixture in exported record") }
        var corrupted = original; corrupted[range.lowerBound + 1] ^= 1
        let stillDecodes = try PropertyListDecoder().decode(Clip.self, from: corrupted)
        try require(stillDecodes.payloads[1].types["local.prism.selftest.backup-binary"] != marker, "Corruption fixture did not modify payload")
        try corrupted.write(to: recordFile)
        var rejected = false
        do { _ = try ClipStore.readBackupClip(id: clip.id, at: destination, manifest: manifest) }
        catch { rejected = true }
        try require(rejected, "Backup accepted a changed but decodable payload")
        try original.write(to: recordFile)

        let replacement = textClip("replacement backup")
        try ClipStore.exportBackup(Archive(clips: [replacement], boards: []), to: destination)
        let replaced = try ClipStore.readBackupManifest(at: destination)
        try require(replaced.ids == [replacement.id] && replaced.boards.isEmpty, "Replacing an existing backup retained stale records")
        let replacedClip = try ClipStore.readBackupClip(id: replacement.id, at: destination, manifest: replaced)
        try require(replacedClip.text == "replacement backup", "Replacement backup cannot be read")
    }

    run("pin protection / retention / explicit removal") {
        let store = ClipStore(directory: directory("retention"))
        let board = Board(name: "Protected"); store.boards = [board]
        var pinned = textClip("pinned old"); pinned.date = .distantPast
        let pinID = store.add(pinned, board: board.id)
        var expired = textClip("expired"); expired.date = Date().addingTimeInterval(-10 * 86400)
        let expiredID = store.add(expired)
        let olderID = store.add(textClip("ordinary older"))
        let newestID = store.add(textClip("ordinary newest"))
        store.prune(days: 1, limit: 1); store.flush()
        try require(Set(store.clips.map(\.id)) == [pinID, newestID], "Retention kept expired/excess entries or removed pinned entry (expired \(expiredID), older \(olderID))")
        store.pin([pinID], board: board.id, remove: true)
        store.prune(days: 1, limit: 1); store.flush()
        try require(store.clips.map(\.id) == [newestID], "Unpinned expired entry did not become eligible")
        store.remove([newestID]); store.flush()
        try require(ClipStore(directory: store.directory).clips.isEmpty, "Explicit deletion did not persist")
    }

    run("incremental payload writes / updated search") {
        let store = ClipStore(directory: directory("incremental"))
        let stableID = store.add(textClip("stable payload untouched"))
        let editID = store.add(textClip("oldneedle")); store.flush()
        let stableBefore = try payloadSnapshots(store.directory, id: stableID)
        let editedBefore = try payloadSnapshots(store.directory, id: editID)
        try require(!stableBefore.isEmpty && !editedBefore.isEmpty, "Payloads were not placed in independent disk objects")
        guard var edited = store.clips.first(where: { $0.id == editID }) else { throw SelfTestFailure(description: "Edit target missing") }
        edited.title = "Renamed title"; store.update(edited); store.flush()
        let editedAfterRename = try payloadSnapshots(store.directory, id: editID)
        try require(editedAfterRename == editedBefore, "Title-only edit rewrote original payload")
        edited.payloads = textClip("newneedle 修改后").payloads
        store.update(edited); store.flush()
        let stableAfterEdit = try payloadSnapshots(store.directory, id: stableID)
        try require(stableAfterEdit == stableBefore, "Editing one entry rewrote another payload")
        let restarted = ClipStore(directory: store.directory)
        try require(restarted.search(query: "newneedle").map(\.id) == [editID], "Updated text not searchable after restart")
        try require(restarted.search(query: "oldneedle").isEmpty, "Stale full text remained searchable")
        try require(restarted.clips.first(where: { $0.id == editID })?.text == "newneedle 修改后", "Updated payload not persisted")
    }

    run("full-text search / filters / no payload hydration") {
        let store = ClipStore(directory: directory("fulltext"))
        var clip = textClip(String(repeating: "prefix body ", count: 24000) + "distantNeedle 独特检索尾部", source: "Research App")
        clip.title = "Named title"; clip.recognizedText = "recognizedNeedle"
        let id = store.add(clip)
        var old = textClip("oldfilter", source: "Archive App"); old.date = Date().addingTimeInterval(-40 * 86400); store.add(old)
        store.flush()
        let before = Clip.payloadCacheByteCount
        let restarted = ClipStore(directory: store.directory)
        for query in ["distantNeedle", "stantNeed", "独特检索尾部", "检索", "尾", "named Research", "recognizedNeedle", "local.prism.selftest"] {
            try require(restarted.search(query: query).contains(where: { $0.id == id }), "Full text or metadata query missed '\(query)'")
        }
        try require(restarted.search(query: "distantNeedle", kind: "图片").isEmpty, "Kind filter ignored")
        try require(restarted.search(query: "distantNeedle", app: "Wrong App").isEmpty, "App filter ignored")
        try require(restarted.search(query: "oldfilter", days: 7).isEmpty, "Age filter ignored")
        try require(Clip.payloadCacheByteCount <= before, "Opening/searching history hydrated original payloads")
    }

    run("failed write reports error / retry preserves committed history") {
        let store = ClipStore(directory: directory("write-retry"))
        let firstID = store.add(textClip("committed before failure"))
        try require(store.flush(), "Initial save failed")
        let objects = store.directory.appendingPathComponent("Objects")
        let hold = store.directory.appendingPathComponent("Objects.hold")
        try FileManager.default.moveItem(at: objects, to: hold)
        var restored = false
        defer {
            if !restored {
                try? FileManager.default.removeItem(at: objects)
                try? FileManager.default.moveItem(at: hold, to: objects)
            }
        }
        try Data("intentionally block the object directory".utf8).write(to: objects)
        let secondID = store.add(textClip("pending retry"))
        try require(!store.flush() && store.lastError != nil, "Write failure was reported as success")
        try require(store.search(query: "committed").contains(where: { $0.id == firstID }), "Failed transaction lost committed search index")
        try FileManager.default.removeItem(at: objects)
        try FileManager.default.moveItem(at: hold, to: objects); restored = true
        try require(store.flush() && store.lastError == nil, "Save could not retry after disk became writable")
        let restarted = ClipStore(directory: store.directory)
        try require(Set(restarted.clips.map(\.id)) == [firstID, secondID], "Retry lost existing or pending record")
        try require(restarted.clips.first(where: { $0.id == secondID })?.text == "pending retry", "Retry published incomplete payload")
    }

    run("large image downsampling / original preservation / disk thumbnail") {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4096, pixelsHigh: 2048,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let pixels = bitmap.bitmapData else {
            throw SelfTestFailure(description: "Cannot allocate large image fixture")
        }
        pixels.initialize(repeating: 0xc4, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        guard let original = bitmap.representation(using: .png, properties: [:]) else {
            throw SelfTestFailure(description: "Cannot encode large image")
        }
        let clip = Clip(source: "Image Fixture", bundle: "", payloads: [Payload(types: ["public.png": original])])
        guard let thumbnail = clip.thumbnail(maxPixelSize: 320), let cg = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw SelfTestFailure(description: "Large image thumbnail failed")
        }
        try require(max(cg.width, cg.height) <= 320 && cg.width > 100, "Thumbnail did not respect pixel bound")
        try require(clip.payloads[0].data(.png) == original, "Thumbnail operation modified original bytes")
        let store = ClipStore(directory: directory("thumbnails"))
        let id = store.add(clip); store.flush()
        let before = Clip.payloadCacheByteCount
        let restarted = ClipStore(directory: store.directory)
        guard let loaded = restarted.clips.first(where: { $0.id == id }),
              let diskThumbnail = loaded.thumbnail(maxPixelSize: 200),
              let diskCG = diskThumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw SelfTestFailure(description: "Persisted image thumbnail failed")
        }
        try require(max(diskCG.width, diskCG.height) <= 200, "Disk thumbnail ignored requested bound")
        try require(Clip.payloadCacheByteCount <= before, "Disk thumbnail decoded original payload")
        try require(loaded.payloads[0].data(.png) == original, "Image payload changed on disk")
    }

    run("bounded payload cache / disk budget pin protection") {
        let store = ClipStore(directory: directory("cache"))
        let board = Board(name: "Keep"); store.boards = [board]
        var ids: [UUID] = []
        for index in 0..<36 {
            var data = Data(repeating: UInt8(index), count: 1024 * 1024)
            data.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(index).bigEndian) { Data($0) })
            let clip = Clip(source: "Binary", bundle: "selftest.binary", payloads: [Payload(types: ["local.prism.selftest.blob": data])])
            ids.append(store.add(clip, board: index == 0 ? board.id : nil))
        }
        store.flush()
        try require(store.diskUsage() >= 36 * 1024 * 1024, "Large payloads were not saved on disk")
        let restarted = ClipStore(directory: store.directory)
        for id in ids {
            guard let clip = restarted.clips.first(where: { $0.id == id }) else { throw SelfTestFailure(description: "Cached clip lost") }
            try require(clip.payloads.first?.types["local.prism.selftest.blob"]?.count == 1024 * 1024, "Evicted payload could not be read back")
            try require(Clip.payloadCacheByteCount <= Clip.payloadCacheLimit, "Payload cache exceeded configured limit")
        }
        // Verify recency through observable reads: temporarily make two disk
        // objects unavailable. A hot object must still work; an evicted one must
        // report the missing source, rather than silently returning empty data.
        let recent = restarted.clips.first(where: { $0.id == ids[20] })!
        let old = restarted.clips.first(where: { $0.id == ids[9] })!
        _ = try recent.loadPayloads()
        for id in ids.prefix(8) { _ = try restarted.clips.first(where: { $0.id == id })!.loadPayloads() }
        var moved: [(URL, URL)] = []
        defer { for pair in moved { try? FileManager.default.moveItem(at: pair.1, to: pair.0) } }
        for id in [recent.id, old.id] {
            guard let path = try payloadSnapshots(store.directory, id: id).keys.first else { throw SelfTestFailure(description: "Cache test payload file missing") }
            let source = URL(fileURLWithPath: path), hold = URL(fileURLWithPath: path + ".hold")
            try FileManager.default.moveItem(at: source, to: hold); moved.append((source, hold))
        }
        let recentPayloads = try recent.loadPayloads()
        try require(recentPayloads.first?.types["local.prism.selftest.blob"]?.count == 1024 * 1024, "Recently accessed object was evicted")
        var missingReported = false
        do { _ = try old.loadPayloads() } catch { missingReported = true }
        try require(missingReported, "Least recently used object remained cached after capacity pressure")
        for pair in moved { try FileManager.default.moveItem(at: pair.1, to: pair.0) }; moved = []
        restarted.pruneStorage(maxBytes: 1)
        try waitFor("Asynchronous disk pruning did not complete") { restarted.clips.map(\.id) == [ids[0]] }
        restarted.flush()
        try require(restarted.clips.map(\.id) == [ids[0]], "Disk budget failed to remove unpinned entries or removed pinned entry")
        let final = ClipStore(directory: store.directory)
        try require(final.clips.map(\.id) == [ids[0]], "Disk pruning did not persist")
        try require(final.clips[0].payloads[0].types["local.prism.selftest.blob"]?.count == 1024 * 1024, "Protected object deleted from disk")
    }

    print("Prism self-test: \(passed) passed, \(failed) failed. General clipboard unchanged; disposable data removed.")
    return failed == 0 ? 0 : 1
}
