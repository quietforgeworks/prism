import AppKit
import ImageIO
import UniformTypeIdentifiers

final class TransferFileAccess {
    private let urls: [URL]
    private let scoped: [URL]
    init(_ urls: [URL]) {
        self.urls = urls
        scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
    }
    deinit { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
}

struct StoredTransferFile: Codable {
    var originalURL: String
    var name: String
    var contents: Data

    static func read(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= limit else {
            throw StorageError.message("文件无法读取或超过单条记录的 100 MB 上限。")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while let chunk = try handle.read(upToCount: min(1024 * 1024, limit - result.count + 1)), !chunk.isEmpty {
            guard chunk.count <= limit - result.count else { throw StorageError.message("文件超过单条记录的 100 MB 上限。") }
            result.append(chunk)
        }
        guard result.count == size else { throw StorageError.message("文件正在变化，请重新复制。") }
        return result
    }
}

extension Payload {
    static let storedFilesType = "local.prism.stored-files"
    static let qtImageType = "com.trolltech.anymime.application--x-qt-image"
    static let uriListTypes = ["text/uri-list", "public.url-list", "com.trolltech.anymime.text--uri-list"]
    static let legacyFilesType = "NSFilenamesPboardType"

    private static func transferString(_ bytes: Data) -> String? {
        if let value = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? String {
            return value
        }
        if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) {
            return String(data: bytes, encoding: .utf16)
        }
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .utf16)
    }

    /// Interpret only explicit file representations. Ordinary copied path text
    /// continues to behave as text, including strings beginning with file://.
    func transferFileURLs() throws -> [NSURL] {
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))
        func fileURL(_ value: String) -> NSURL? {
            let value = value.trimmingCharacters(in: trim)
            if (value as NSString).isAbsolutePath { return NSURL(fileURLWithPath: value) }
            guard let url = NSURL(string: value), url.isFileURL else { return nil }
            return url
        }
        if let bytes = data(.fileURL), !bytes.isEmpty {
            guard let value = Self.transferString(bytes), let url = fileURL(value) else {
                throw StorageError.message("记录中的文件地址无效，请重新复制原文件。")
            }
            return [url]
        }
        if let bytes = types[Self.legacyFilesType], !bytes.isEmpty {
            guard let paths = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String],
                  !paths.isEmpty else {
                throw StorageError.message("记录中的文件路径列表无效，请重新复制原文件。")
            }
            return try paths.map {
                guard let url = fileURL($0) else { throw StorageError.message("记录中的文件路径无效。") }
                return url
            }
        }
        for type in Self.uriListTypes {
            guard let bytes = types[type], !bytes.isEmpty, let text = Self.transferString(bytes) else { continue }
            let entries = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: trim) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            let urls = entries.compactMap(fileURL)
            // A URI list may contain web links, which remain URL/text content.
            if !urls.isEmpty {
                guard urls.count == entries.count else { throw StorageError.message("文件地址列表包含无效地址。") }
                return urls
            }
        }
        if let value = string(.URL), let url = NSURL(string: value.trimmingCharacters(in: trim)), url.isFileURL {
            return [url]
        }
        return []
    }

    func storedTransferFiles() throws -> [StoredTransferFile] {
        guard let data = types[Self.storedFilesType] else { return [] }
        return try PropertyListDecoder().decode([StoredTransferFile].self, from: data)
    }

    static func imageType(_ name: String) -> UTType? {
        if let type = UTType(name), type.conforms(to: .image), type != .icns { return type }
        var mime = name
        if name.hasPrefix("com.trolltech.anymime.") {
            mime = String(name.dropFirst("com.trolltech.anymime.".count)).replacingOccurrences(of: "--", with: "/")
        }
        guard let type = UTType(mimeType: mime), type.conforms(to: .image), type != .icns else { return nil }
        return type
    }

    static func fileExportType(_ name: String) -> UTType? {
        guard name != NSPasteboard.PasteboardType.rtfd.rawValue,
              name != "com.apple.rtfd", name != "com.apple.flat-rtfd",
              let type = imageType(name) ?? UTType(name) ?? UTType(mimeType: name),
              type.preferredFilenameExtension != nil,
              type != .url, type != .fileURL, type != .icns,
              !type.conforms(to: .text) || type.conforms(to: .image) || type == .pdf,
              !type.conforms(to: .directory),
              type.conforms(to: .data) || type == .pdf || type.conforms(to: .image) else { return nil }
        return type
    }

    var hasMultipleImageFrames: Bool {
        types.contains { name, bytes in
            guard Self.imageType(name) != nil,
                  let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
            return CGImageSourceGetCount(source) > 1
        }
    }

    static func representsInlineImage(typeNames: [String], files: [URL]) -> Bool {
        guard typeNames.contains(where: { imageType($0) != nil }) || typeNames.contains(storedFilesType) else { return false }
        if files.isEmpty { return true }
        guard files.count == 1 else { return false }
        return typeNames.contains(qtImageType) || UTType(filenameExtension: files[0].pathExtension)?.conforms(to: .image) == true
    }

    /// Normalize replay data without changing the persisted original formats.
    /// ImageIO identifies the encoding from bytes, including MIME/Qt aliases.
    func replayImage(addPNG: Bool) -> Payload? {
        let files = (try? transferFileURLs()) ?? []
        guard Self.representsInlineImage(typeNames: Array(types.keys), files: files.map { $0 as URL }) else { return nil }
        var result = self
        var best: (source: CGImageSource, area: Double)?
        var canonical: [String: (bytes: Data, area: Double)] = [:]
        var found = false
        for name in types.keys.sorted() where Self.imageType(name) != nil {
            guard let bytes = types[name], !bytes.isEmpty,
                  let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let identifier = CGImageSourceGetType(source),
                  let actual = UTType(identifier as String), actual.conforms(to: .image), actual != .icns,
                  CGImageSourceGetCount(source) > 0 else { continue }
            found = true
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
            let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
            if Self.imageType(name)?.identifier != actual.identifier { result.types.removeValue(forKey: name) }
            if canonical[actual.identifier] == nil || width * height > canonical[actual.identifier]!.area {
                canonical[actual.identifier] = (bytes, width * height)
            }
            if best == nil || width * height > best!.area { best = (source, width * height) }
        }
        for (name, image) in canonical { result.types[name] = image.bytes }
        // Vector images keep their original representation and export encoding.
        if !found, let svg = types.first(where: { Self.imageType($0.key) == .svg }), !svg.value.isEmpty {
            result.types[UTType.svg.identifier] = svg.value
            found = true
        }
        guard found else { return nil }
        if addPNG, result.types[UTType.png.identifier] == nil, let best,
           best.area > 0, best.area <= 64 * 1024 * 1024,
           let image = CGImageSourceCreateImageAtIndex(best.source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) {
            let png = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) {
                let properties = CGImageSourceCopyPropertiesAtIndex(best.source, 0, nil)
                CGImageDestinationAddImage(destination, image, properties)
                if CGImageDestinationFinalize(destination) { result.types[UTType.png.identifier] = png as Data }
            }
        }
        result.types.removeValue(forKey: NSPasteboard.PasteboardType.fileURL.rawValue)
        result.types.removeValue(forKey: Self.legacyFilesType)
        for name in Self.uriListTypes { result.types.removeValue(forKey: name) }
        if let value = result.string(.URL), NSURL(string: value)?.isFileURL == true {
            result.types.removeValue(forKey: NSPasteboard.PasteboardType.URL.rawValue)
        }
        result.types.removeValue(forKey: Self.storedFilesType)
        return result
    }

    static func isTemporaryFile(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return path.hasPrefix(temporary + "/") || path.hasPrefix("/private/tmp/") ||
            path.contains("/Library/Caches/") ||
            (path.contains("/Library/Containers/") && (path.contains("/temp/") || path.contains("/tmp/")))
    }
}

extension Clip {
    var temporaryCaptureReservation: Int {
        let hasTemporary = files.contains(where: Payload.isTemporaryFile)
        return hasTemporary ? ClipStore.maxBytes : byteCount
    }

    /// Called on the capture worker while source-owned temporary files still
    /// exist. Snapshots live inside the existing immutable payload sidecars,
    /// so retention, backups and deletion use the store's usual ownership.
    func preservingTemporaryFiles() -> Clip {
        guard var payloads = try? loadPayloads() else { return self }
        var result = self
        result.transferFileAccess = nil
        var total = byteCount
        var changed = false
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        for index in payloads.indices {
            guard payloads[index].types[Payload.storedFilesType] == nil,
                  let urls = try? payloads[index].transferFileURLs() else { continue }
            var stored: [StoredTransferFile] = []
            for native in urls {
                guard let url = native.filePathURL?.standardizedFileURL,
                      Payload.isTemporaryFile(url), total < ClipStore.maxBytes else { continue }
                let used = (try? encoder.encode(stored).count) ?? 0
                guard let bytes = try? StoredTransferFile.read(url, limit: max(0, ClipStore.maxBytes - total - used)) else { continue }
                let file = StoredTransferFile(originalURL: native.absoluteString ?? url.absoluteString,
                                              name: url.lastPathComponent, contents: bytes)
                guard let encoded = try? encoder.encode(stored + [file]), encoded.count <= ClipStore.maxBytes - total else { continue }
                stored.append(file)
            }
            if !stored.isEmpty, let encoded = try? encoder.encode(stored), encoded.count <= ClipStore.maxBytes - total {
                payloads[index].types[Payload.storedFilesType] = encoded
                total += encoded.count
                changed = true
            }
        }
        guard changed else { return result }
        result.payloads = payloads
        return result
    }
}
