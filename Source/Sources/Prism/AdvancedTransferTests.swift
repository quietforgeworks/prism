import AppKit
import ImageIO
import UniformTypeIdentifiers

func preparedSelection(_ clips: [Clip], dragging: Bool, directory: URL) throws -> PreparedTransfer {
    try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
    var result: Result<PreparedTransfer, Error>?
    FileTransferPreparation.prepareSelection(clips: clips, forDragging: dragging,
                                             cache: TransferFileCache(directory: directory)) { result = $0 }
    try waitFor("Selection preparation timed out", timeout: 20) { result != nil }
    return try result!.get()
}

private func advancedBoard<T>(_ body: (NSPasteboard) throws -> T) rethrows -> T {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    return try body(board)
}

private func fileClip(_ url: URL) -> Clip {
    Clip(source: "File Fixture", bundle: "", payloads: [Payload(types: ["public.file-url": Data(url.absoluteString.utf8)])])
}

private func plainClip(_ string: String) -> Clip {
    Clip(source: "Text Fixture", bundle: "", payloads: [Payload(types: ["public.utf8-plain-text": Data(string.utf8)])])
}

func testFileReferenceAvailability(directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("large-file.zip")
    _ = FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 1024 * 1024 * 1024 + 1)
    try handle.close()
    let large = fileClip(file).preservingTemporaryFiles()
    try require(large.byteCount < 4096, "Large file was copied into history")
    let requirements = try FileReferenceRequirements(clip: large)
    try require(!requirements.isUnavailable, "Existing large file is expired")
    try FileManager.default.removeItem(at: file)
    try require(requirements.isUnavailable, "Removed large file is still available")
    try Data([1, 2, 3]).write(to: file)
    try require(!requirements.isUnavailable, "Restored path did not become available again")

    let temporary = directory.appendingPathComponent("temporary.docx")
    try Data([0x50, 0x4b, 0, 255]).write(to: temporary)
    let snapshot = fileClip(temporary).preservingTemporaryFiles()
    try FileManager.default.removeItem(at: temporary)
    try require(try !FileReferenceRequirements(clip: snapshot).isUnavailable, "Stored attachment was marked expired")
    let tiff = try tinyImageData().tiff
    let recovered = Clip(source: "微信", bundle: "", payloads: [Payload(types: ["public.file-url": Data(temporary.deletingPathExtension().appendingPathExtension("png").absoluteString.utf8), "public.tiff": tiff])])
    try require(try !FileReferenceRequirements(clip: recovered).isUnavailable, "Recoverable WeChat image was marked expired")
}

func testFileAvailabilityMonitor(directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("monitor.bin")
    try Data([1]).write(to: path)
    let clip = fileClip(path)
    let monitor = FileAvailabilityMonitor()
    var staleDelivered = false
    var latest: [UUID: Bool]?
    monitor.check([clip]) { _ in staleDelivered = true }
    monitor.check([clip]) { latest = $0 }
    try require(latest == nil, "File availability checked synchronously on the UI thread")
    try waitFor("Availability monitor did not finish") { latest != nil }
    try require(!staleDelivered && latest?[clip.id] == false, "Availability monitor delivered a superseded request")
    try require(monitor.needsPolling, "Live file reference lost deletion monitoring")
    try FileManager.default.removeItem(at: path)
    latest = nil
    monitor.check([clip]) { latest = $0 }
    try waitFor("Deleted file availability did not refresh") { latest != nil }
    try require(latest?[clip.id] == true, "Cached plan hid a source-file deletion")
    var cancelledDelivered = false
    monitor.check([clip]) { _ in cancelledDelivered = true }
    monitor.cancel()
    let until = Date().addingTimeInterval(0.05)
    try waitFor("Cancellation observation timed out") { Date() >= until }
    try require(!cancelledDelivered && !monitor.needsPolling, "Cancelled availability request updated a hidden shelf")
}

private func fixtureActions(paste: @escaping ([Clip], Bool) -> Void = { _, _ in }) -> ShelfActions {
    ShelfActions(paste: paste, copy: { _, _ in }, enqueue: { _ in }, settings: {}, pauseToggle: {}, stackToggle: {},
                 clear: {}, export: {}, import: {}, quit: {}, isPaused: { false }, isStack: { false },
                 targetName: { "Fixture" }, invalidatePendingPaste: {})
}

func testExpiredCardOverlay(directory: URL) throws {
    let store = ClipStore(directory: directory.appendingPathComponent("history"))
    let clip = fileClip(directory.appendingPathComponent("已移除的大文件.zip"))
    store.add(clip)
    let shelf = ShelfController(store: store, actions: fixtureActions())
    let card = ClipCard(frame: NSRect(x: 0, y: 0, width: 270, height: 280))
    let window = NSWindow(contentRect: card.bounds, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = card
    card.configure(clip, selected: true, number: 1, shelf: shelf)
    card.layoutSubtreeIfNeeded()
    func render() -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 270, pixelsHigh: 280,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        context.cgContext.translateBy(x: 0, y: 280)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        card.draw(card.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
    let normal = render()
    card.setFileUnavailable(true)
    try require(card.isFileUnavailable && card.accessibilityLabel()?.contains("文件已失效") == true, "Expired status has no accessible label")
    try require(render() != normal && card.selected, "Expired card is not dimmed or loses selection")
    if let path = ProcessInfo.processInfo.environment["PRISM_TEST_RENDER_DIRECTORY"] {
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            card.appearance = NSAppearance(named: appearance)
            card.effectiveAppearance.performAsCurrentDrawingAppearance {
                let bytes = render()
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 270, pixelsHigh: 280,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                bytes.copyBytes(to: bitmap.bitmapData!, count: bytes.count)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("expired-card-\(name).png"))
            }
        }
        card.appearance = nil
    }
    card.setFileUnavailable(false)
    try require(render() == normal, "Recovered card did not restore its appearance")
    card.setFileUnavailable(true)
    card.reset()
    card.configure(plainClip("replacement"), selected: false, number: nil, shelf: shelf)
    try require(!card.isFileUnavailable && card.accessibilityLabel()?.contains("文件已失效") != true, "Reused card retained the expired overlay")
    window.close()
}

private func gesture(_ type: NSEvent.EventType, window: NSWindow, count: Int = 1,
                     flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: NSPoint(x: 40, y: 40), modifierFlags: flags,
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                      context: nil, eventNumber: 1, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!
}

func testMultiSelectionGestures(directory: URL) throws {
    let store = ClipStore(directory: directory)
    for name in ["first", "second", "third"] { store.add(plainClip(name)) }
    var pasted: [[UUID]] = []
    let shelf = ShelfController(store: store, actions: fixtureActions { clips, _ in pasted.append(clips.map(\.id)) })
    let window = shelf.window!
    let first = shelf.visibleItems[0]
    let second = shelf.visibleItems[1]
    let third = shelf.visibleItems[2]
    let card = ClipCard(frame: NSRect(x: 20, y: 20, width: 200, height: 180))
    window.contentView!.addSubview(card)
    card.configure(first, selected: true, number: nil, shelf: shelf)
    shelf.select(first, event: gesture(.leftMouseDown, window: window))
    shelf.select(second, event: gesture(.leftMouseDown, window: window, flags: .command))
    let selected = shelf.selectedClips.map(\.id)
    for count in [1, 2] {
        card.mouseDown(with: gesture(.leftMouseDown, window: window, count: count))
        try require(card.isMouseDown, "Card ignored its mouse-down event when global button state was unavailable")
        card.mouseUp(with: gesture(.leftMouseUp, window: window, count: count))
        try require(!card.isMouseDown, "Card retained a pressed state after mouse-up")
    }
    try require(pasted == [selected], "Double-click collapsed a multi-selection")
    let until = Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.05)
    try waitFor("Double-click observation timed out", timeout: 3) { Date() >= until }
    try require(shelf.selectedClips.map(\.id) == selected && pasted.count == 1, "Cancelled single-click changed selection after paste")
    shelf.select(first, event: gesture(.leftMouseDown, window: window))
    shelf.select(third, event: gesture(.leftMouseDown, window: window, flags: .shift))
    let range = shelf.selectedClips.map(\.id)
    try require(range.count >= 2, "Shift range selection failed")
    try require(card.accessibilityPerformPress() && pasted.last == range, "Accessible activation dropped the multi-selection")
    for count in [1, 2] {
        card.mouseDown(with: gesture(.leftMouseDown, window: window, count: count, flags: .command))
        card.mouseUp(with: gesture(.leftMouseUp, window: window, count: count, flags: .command))
    }
    try require(pasted.count == 2, "Command double-click pasted while changing selection")
    card.mouseDown(with: gesture(.leftMouseDown, window: window))
    card.mouseUp(with: gesture(.leftMouseUp, window: window))
    let group = shelf.selectedClips.map(\.id)
    shelf.pasteSelection()
    let pasteUntil = Date().addingTimeInterval(NSEvent.doubleClickInterval + 0.05)
    try waitFor("Paste selection observation timed out", timeout: 3) { Date() >= pasteUntil }
    try require(pasted.last == group && shelf.selectedClips.map(\.id) == group,
                "A deferred single click changed selection after keyboard paste")
    card.mouseDown(with: gesture(.leftMouseDown, window: window))
    card.mouseUp(with: gesture(.leftMouseUp, window: window))
    try waitFor("Single click never resolved to one card", timeout: 3) { shelf.selectedClips.count == 1 }
    card.reset()
    try require(!card.isMouseDown, "Card reuse retained mouse-button tracking")
    window.close()
}

func testCombinedTextPaste(directory: URL) throws {
    let styled = NSAttributedString(string: "alpha", attributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.red])
    let rtf = styled.rtf(from: NSRange(location: 0, length: styled.length), documentAttributes: [:])!
    let rich = Clip(source: "RTF", bundle: "", payloads: [Payload(types: ["public.rtf": rtf])])
    let plain = plainClip("beta")
    let prepared = try preparedSelection([rich, plain], dragging: false, directory: directory.appendingPathComponent("rtf"))
    try advancedBoard { board in
        try require(prepared.writers.count == 1 && board.writeObjects(prepared.writers), "Multiple texts did not become one pasteable item")
        let receiver = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        receiver.isRichText = true
        try require(receiver.readSelection(from: board), "Native text editor rejected combined selection")
        try require(receiver.string == "alpha\nbeta", "Native text paste lost a selected entry or order")
        let font = receiver.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        try require(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "Merged RTF lost bold formatting")
    }
    let dragged = try preparedSelection([rich, plain], dragging: true, directory: directory.appendingPathComponent("rtf-drag"))
    try advancedBoard { board in
        try require(dragged.writers.count == 1 && board.writeObjects(dragged.writers), "Multi-text drag did not produce one complete representation")
        let receiver = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        receiver.isRichText = true
        try require(receiver.readSelection(from: board) && receiver.string == "alpha\nbeta", "Multi-text drag lost an entry")
    }
    let html = Clip(source: "HTML", bundle: "", payloads: [Payload(types: ["public.html": Data("<html><head><style>b { color: red; }</style></head><body><b>gamma</b></body></html>".utf8)])])
    let combined = try preparedSelection([plain, html], dragging: false, directory: directory.appendingPathComponent("html"))
    try advancedBoard { board in
        try require(board.writeObjects(combined.writers), "Cannot write combined HTML")
        try require(board.string(forType: .string) == "beta\ngamma", "Combined HTML plain alternative is incomplete")
        let content = board.string(forType: .html) ?? ""
        try require(content.contains("<b>gamma</b>") && content.contains("beta") && content.contains("<style>"), "Combined HTML lost original markup or styles")
    }
}

func testCombinedAttachmentPaste(directory: URL) throws {
    let png = try tinyImageData().png
    let wrapper = FileWrapper(regularFileWithContents: png)
    wrapper.preferredFilename = "inline-image.png"
    let attributed = NSMutableAttributedString(string: "before ")
    attributed.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
    let data = attributed.rtfd(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:])!
    let clip = Clip(source: "RTFD", bundle: "", payloads: [Payload(types: [NSPasteboard.PasteboardType.rtfd.rawValue: data])])
    let prepared = try preparedSelection([clip, plainClip("after")], dragging: false, directory: directory)
    try advancedBoard { board in
        try require(board.writeObjects(prepared.writers), "Cannot write combined RTFD")
        let receiver = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        receiver.isRichText = true
        receiver.importsGraphics = true
        try require(receiver.readSelection(from: board), "Native text editor rejected combined RTFD")
        try require(receiver.string.contains("before") && receiver.string.contains("after"), "RTFD paste lost surrounding texts")
        var attachmentCount = 0
        var attachmentBytes: Data?
        receiver.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: receiver.string.utf16.count)) { value, _, _ in
            if let attachment = value as? NSTextAttachment {
                attachmentCount += 1
                attachmentBytes = attachment.fileWrapper?.regularFileContents
            }
        }
        try require(attachmentCount == 1 && attachmentBytes == png, "RTFD paste lost, changed or duplicated its attachment")
    }
}

func testMixedSelectionTransfer(directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let png = try tinyImageData().png
    let image = Clip(source: "Image", bundle: "", payloads: [Payload(types: ["public.png": png])])
    let liveURL = directory.appendingPathComponent("live.custom-extension")
    let bytes = Data([0, 255, 9])
    try bytes.write(to: liveURL)
    let live = fileClip(liveURL)
    let missing = fileClip(directory.appendingPathComponent("missing-large.zip"))
    let pdf = Clip(source: "PDF", bundle: "", payloads: [Payload(types: ["com.adobe.pdf": Data("%PDF-1.4\n%%EOF".utf8)])])
    for dragging in [false, true] {
        let prepared = try preparedSelection([image, missing, live, pdf], dragging: dragging,
                                             directory: directory.appendingPathComponent(dragging ? "drag" : "copy"))
        try require(prepared.clipIDs == [image.id, live.id, pdf.id] && prepared.unavailableClipIDs == [missing.id], "Mixed preparation lost clip identity or invalid-record reporting")
        try advancedBoard { board in
            try require(board.writeObjects(prepared.writers), "Cannot publish mixed selection")
            let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            try require(files.count == 3 && files[0].pathExtension == "png" && files[1] == liveURL && files[2].pathExtension == "pdf", "File-only receiver lost image, PDF or selection ordering")
            try require(try Data(contentsOf: files[0]) == png && Data(contentsOf: files[1]) == bytes, "Mixed selection changed file content")
        }
    }
    let empty = try preparedSelection([missing], dragging: false, directory: directory.appendingPathComponent("empty"))
    try require(empty.writers.isEmpty && empty.unavailableClipIDs == [missing.id], "Expired-only selection produced phantom clipboard data")
}

func testEncodedFileCopy(directory: URL) throws {
    let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"><rect width=\"8\" height=\"8\" fill=\"red\"/></svg>".utf8)
    let variants: [(UTType, Data)] = [(.svg, svg), (.pdf, Data("%PDF-1.4\n%%EOF".utf8)),
                                    (UTType(filenameExtension: "docx")!, Data([0x50, 0x4b, 3, 4])),
                                    (.wav, Data("RIFF0000WAVE".utf8)), (.zip, Data([0x50, 0x4b, 5, 6]))]
    for (index, variant) in variants.enumerated() {
        let clip = Clip(source: "Encoded", bundle: "", payloads: [Payload(types: [variant.0.identifier: variant.1])])
        for dragging in [false, true] {
            let prepared = try preparedSelection([clip], dragging: dragging, directory: directory.appendingPathComponent("\(index)-\(dragging)"))
            try advancedBoard { board in
                try require(board.writeObjects(prepared.writers), "Cannot publish encoded file")
                let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                try require(files.count == 1 && UTType(filenameExtension: files[0].pathExtension) == variant.0, "Encoded copy is missing a usable native file URL")
                try require(try Data(contentsOf: files[0]) == variant.1, "Encoded file copy changed original bytes")
            }
        }
    }
}

func animatedGIFData() throws -> Data {
    let first = try tinyImageData().png
    let bitmap = NSBitmapImageRep(data: first)!
    bitmap.bitmapData![0] = 255
    let second = bitmap.representation(using: .png, properties: [:])!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil)!
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for bytes in [first, second] {
        let source = CGImageSourceCreateWithData(bytes as CFData, nil)!
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
    }
    try require(CGImageDestinationFinalize(destination), "Cannot encode animated GIF fixture")
    return data as Data
}

func testAnimatedImageTransfer(directory: URL) throws {
    let gif = try animatedGIFData()
    let payload = Payload(types: [UTType.gif.identifier: gif, "public.png": try tinyImageData().png])
    let clip = Clip(source: "Animated", bundle: "", payloads: [payload])
    try require(payload.hasMultipleImageFrames, "GIF fixture does not exercise animation")
    for dragging in [false, true] {
        let prepared = try preparedSelection([clip], dragging: dragging, directory: directory.appendingPathComponent(String(dragging)))
        try advancedBoard { board in
            try require(board.writeObjects(prepared.writers), "Cannot copy animated image")
            let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            try require(files.count == 1 && files[0].pathExtension == "gif", "Animated image was exported as its still-image alternative")
            let bytes = try Data(contentsOf: files[0])
            try require(bytes == gif && CGImageSourceGetCount(CGImageSourceCreateWithData(bytes as CFData, nil)!) == 2, "Animated image lost original frames")
        }
    }
}

func testExternalFormatFixtures(directory: URL, fixtures: URL) throws {
    let imageExtensions = ["webp", "avif", "psd", "jp2", "heif"]
    let files = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
        .filter { imageExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    try require(!files.isEmpty, "External format fixture directory is empty")
    for (index, file) in files.enumerated() {
        let bytes = try Data(contentsOf: file)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), let name = CGImageSourceGetType(source) else {
            throw SelfTestFailure(description: "System decoder rejected fixture \(file.lastPathComponent)")
        }
        let clip = Clip(source: "Codec Fixture", bundle: "", payloads: [Payload(types: [name as String: bytes])])
        try require(clip.image != nil, "Real image fixture cannot be previewed")
        let copy = try preparedSelection([clip], dragging: false, directory: directory.appendingPathComponent("\(index)-copy"))
        try advancedBoard { board in
            try require(board.writeObjects(copy.writers) && board.data(forType: .png) != nil, "Real image fixture lacks a compatible image paste")
        }
        let drag = try preparedSelection([clip], dragging: true, directory: directory.appendingPathComponent("\(index)-drag"))
        try advancedBoard { board in
            try require(board.writeObjects(drag.writers), "Cannot drag real image fixture")
            let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            try require(urls.count == 1 && (try Data(contentsOf: urls[0])) == bytes, "Real image fixture export changed its original data")
        }
    }
    let originals = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
    let copied = directory.appendingPathComponent("source-files")
    try FileManager.default.createDirectory(at: copied, withIntermediateDirectories: true)
    var clips: [Clip] = []
    for original in originals {
        let url = copied.appendingPathComponent(original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: url)
        clips.append(fileClip(url).preservingTemporaryFiles())
    }
    try FileManager.default.removeItem(at: copied)
    for dragging in [false, true] {
        let prepared = try preparedSelection(clips, dragging: dragging, directory: directory.appendingPathComponent("all-\(dragging)"))
        try require(prepared.unavailableClipIDs.isEmpty, "Stored real-file fixtures were marked expired")
        try advancedBoard { board in
            try require(board.writeObjects(prepared.writers), "Cannot publish real-file fixture selection")
            let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            try require(files.map(\.lastPathComponent) == originals.map(\.lastPathComponent), "Real file names or multi-selection ordering changed")
            for (file, original) in zip(files, originals) {
                try require(try Data(contentsOf: file) == Data(contentsOf: original), "Real file bytes changed after source removal")
            }
        }
    }
}

func testSelectionMemoryBound(directory: URL) throws {
    let data = Data(repeating: 7, count: 70 * 1024 * 1024)
    let clip = Clip(source: "Bounded Fixture", bundle: "", payloads: [Payload(types: ["local.prism.fixture.binary": data])])
    var clips = Array(repeating: clip, count: 4)
    for index in clips.indices { clips[index].id = UUID() }
    var rejected = false
    do { _ = try preparedSelection(clips, dragging: false, directory: directory.appendingPathComponent("large-content")) }
    catch { rejected = error.localizedDescription.contains("256") }
    try require(rejected, "Oversized inline selection was hydrated without a memory bound")

    let url = directory.appendingPathComponent("large-reference.bin")
    _ = FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 1024 * 1024 * 1024 + 1)
    try handle.close()
    let reference = fileClip(url)
    let prepared = try preparedSelection([reference, plainClip("annotation")], dragging: false,
                                         directory: directory.appendingPathComponent("large-reference"))
    try require(prepared.writers.count == 2 && prepared.unavailableClipIDs.isEmpty,
                "Large source-file reference was incorrectly limited by its physical file size")
}

