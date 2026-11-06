import AppKit
import CryptoKit
import Vision
import ImageIO
import UniformTypeIdentifiers
import CSQLite
import Darwin

struct Board: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var color: Int = 0
    var itemIDs: [UUID] = []
    init(id: UUID = UUID(), name: String, color: Int = 0, itemIDs: [UUID] = []) {
        self.id = id; self.name = name; self.color = color; self.itemIDs = itemIDs
    }
    private enum CodingKeys: String, CodingKey { case id, name, color, itemIDs }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(Int.self, forKey: .color) ?? 0
        itemIDs = try c.decodeIfPresent([UUID].self, forKey: .itemIDs) ?? []
    }
}

struct Payload: Codable, Equatable {
    var types: [String: Data]
    func data(_ type: NSPasteboard.PasteboardType) -> Data? { types[type.rawValue] }
    func string(_ type: NSPasteboard.PasteboardType) -> String? {
        guard let bytes = data(type) else { return nil }
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .utf16)
    }
    func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for (type, bytes) in types { item.setData(bytes, forType: .init(type)) }
        return item
    }
}

// Only this small record is loaded at launch. Original representations and full text
// live in immutable sidecars; SQLite commits the references after those files exist.
private struct ClipRecord: Codable, Equatable {
    var id: UUID
    var date: Date
    var source: String
    var bundle: String
    var title: String
    var boardIDs: [UUID]
    var fingerprint: String
    var kind: String
    var preview: String
    var recognizedPreview: String
    var files: [URL]
    var typeNames: [String]
    var bytes: Int
    var itemCount: Int
    var characterCount: Int
    var payloadRevision: UUID
    var recognitionRevision: UUID
    var payloadFile: String
    var textFile: String
    var thumbnailFile: String?
    var referencedFiles: [String] { [payloadFile, textFile] + [thumbnailFile].compactMap { $0 } }
}
private struct PayloadDocument: Codable { var payloads: [Payload] }
private struct TextDocument: Codable { var text: String; var recognizedText: String }
// A snapshot keeps its immutable files alive until previews/exports finish.
// Deletion is deferred when the UI or a background reader still holds that version.
private final class DiskFileLeases {
    static let shared = DiskFileLeases()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var retired: Set<String> = []
    private let deletion = DispatchQueue(label: "local.prism.file-retirement", qos: .utility)
    func acquire(_ urls: [URL]) {
        lock.lock(); defer { lock.unlock() }
        for url in urls { counts[url.path, default: 0] += 1 }
    }
    func release(_ urls: [URL]) {
        var ready: [URL] = []
        lock.lock()
        for url in urls {
            let count = (counts[url.path] ?? 1) - 1
            if count <= 0 {
                counts.removeValue(forKey: url.path)
                if retired.remove(url.path) != nil { ready.append(url) }
            } else { counts[url.path] = count }
        }
        lock.unlock()
        for url in ready { delete(url) }
    }
    func retire(_ url: URL) {
        lock.lock()
        if (counts[url.path] ?? 0) > 0 { retired.insert(url.path); lock.unlock() }
        else { lock.unlock(); delete(url) }
    }
    private func delete(_ url: URL) {
        deletion.async { PayloadCache.shared.discard(url); try? FileManager.default.removeItem(at: url) }
    }
}
private final class ClipLocation {
    let folder: URL
    let record: ClipRecord
    private var urls: [URL] { record.referencedFiles.map { folder.appendingPathComponent($0) } }
    init(folder: URL, record: ClipRecord) {
        self.folder = folder; self.record = record
        DiskFileLeases.shared.acquire(urls)
    }
    deinit { DiskFileLeases.shared.release(urls) }
    func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
}
private final class FingerprintBox {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    func get(_ payloads: () -> [Payload]) -> String {
        lock.lock(); defer { lock.unlock() }
        if let value { return value }
        var digest = SHA256()
        func length(_ count: Int) {
            var number = UInt64(count).bigEndian
            withUnsafeBytes(of: &number) { digest.update(data: Data($0)) }
        }
        let values = payloads(); length(values.count)
        for item in values {
            length(item.types.count)
            for key in item.types.keys.sorted() {
                let keyData = Data(key.utf8), bytes = item.types[key]!
                length(keyData.count); digest.update(data: keyData)
                length(bytes.count); digest.update(data: bytes)
            }
        }
        let result = digest.finalize().map { String(format: "%02x", $0) }.joined()
        value = result; return result
    }
}

// Deterministic, thread-safe LRU. Oversized entries are returned directly rather
// than retained. There is one shared 32 MiB budget, including across store windows.
private final class PayloadCache {
    static let shared = PayloadCache()
    static let limit = 32 * 1024 * 1024
    private struct Entry { var value: [Payload]; var cost: Int; var access: UInt64 }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var total = 0
    private var tick: UInt64 = 0
    var byteCount: Int { lock.lock(); defer { lock.unlock() }; return total }
    func load(_ url: URL) throws -> [Payload] {
        let key = url.path
        lock.lock(); tick &+= 1
        if var entry = entries[key] {
            entry.access = tick; entries[key] = entry; lock.unlock(); return entry.value
        }
        lock.unlock()
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let value = try PropertyListDecoder().decode(PayloadDocument.self, from: data).payloads
        let payloadCost = value.reduce(0) { $0 + $1.types.values.reduce(0) { $0 + $1.count } }
        let overhead = 256 + value.reduce(0) { $0 + 128 + $1.types.keys.reduce(0) { $0 + $1.utf8.count + 128 } }
        let cost = payloadCost + overhead
        guard cost <= Self.limit else { return value }
        lock.lock(); defer { lock.unlock() }
        if let old = entries.removeValue(forKey: key) { total -= old.cost }
        while total + cost > Self.limit, let oldest = entries.min(by: { $0.value.access < $1.value.access }) {
            total -= oldest.value.cost; entries.removeValue(forKey: oldest.key)
        }
        tick &+= 1; entries[key] = Entry(value: value, cost: cost, access: tick); total += cost
        return value
    }
    func discard(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        if let entry = entries.removeValue(forKey: url.path) { total -= entry.cost }
    }
}

struct Clip: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var source: String
    var bundle: String
    var title = ""
    var boardIDs: [UUID] = []
    private var inlinePayloads: [Payload]?
    private var location: ClipLocation?
    private var fingerprintBox = FingerprintBox()
    fileprivate var payloadRevision = UUID()
    fileprivate var recognitionRevision = UUID()
    private var inlineRecognition: String?
    private var previewValue = ""
    private var recognitionPreview = ""
    private var fileValues: [URL] = []
    private var typeValues: [String] = []
    private var bytesValue = 0
    private var countValue = 0
    private var characterCountValue = 0
    private var kindValue = "数据"

    init(source: String, bundle: String, payloads: [Payload]) {
        self.source = source; self.bundle = bundle; inlinePayloads = payloads; inlineRecognition = ""
        refreshMetadata(payloads)
    }
    var payloads: [Payload] {
        get { (try? loadPayloads()) ?? [] }
        set {
            inlinePayloads = newValue; location = nil; payloadRevision = UUID()
            fingerprintBox = FingerprintBox(); inlineRecognition = ""; recognitionRevision = UUID()
            refreshMetadata(newValue)
        }
    }
    // Use the throwing variant for copy/export so a missing disk file never
    // silently becomes an empty clipboard or an incomplete backup.
    func loadPayloads() throws -> [Payload] {
        if let inlinePayloads { return inlinePayloads }
        guard let location else { throw StorageError.message("此条目的原始内容位置丢失。") }
        return try PayloadCache.shared.load(location.url(location.record.payloadFile))
    }
    // File representations must be written as native URLs. Replaying Finder's
    // accompanying filename text/icon can make a destination create a clipping.
    // Keep the stored payload untouched and preserve every non-file item's UTIs.
    func pasteboardWriters(forDragging: Bool = false) throws -> [NSPasteboardWriting] {
        try loadPayloads().flatMap { payload -> [NSPasteboardWriting] in
            let urls: [NSURL]
            if payload.data(.fileURL) != nil {
                guard let value = payload.string(.fileURL), let url = NSURL(string: value), url.isFileURL else {
                    throw StorageError.message("记录中的文件地址无效，请重新复制原文件。")
                }
                urls = [url]
            } else if let data = payload.types["NSFilenamesPboardType"] {
                guard let paths = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String],
                      !paths.isEmpty, paths.allSatisfy({ ($0 as NSString).isAbsolutePath }) else {
                    throw StorageError.message("记录中的文件路径列表无效，请重新复制原文件。")
                }
                urls = paths.map { NSURL(fileURLWithPath: $0) }
            } else if let value = payload.string(.URL), let url = NSURL(string: value), url.isFileURL {
                urls = [url]
            } else {
                if forDragging, let promise = ImageDragPromiseProvider(payload: payload) {
                    return [promise]
                }
                return [payload.pasteboardItem()]
            }
            return try urls.map { url -> NSPasteboardWriting in
                // Finder can supply file:///.file/id=… references. Resolve those
                // before testing existence or standardizing a filesystem path.
                guard let pathURL = url.filePathURL?.standardizedFileURL,
                      FileManager.default.fileExists(atPath: pathURL.path) else {
                    throw StorageError.message("原文件已移动、删除或暂时无法访问，请重新复制：\(url.path ?? "未知文件")")
                }
                return pathURL as NSURL
            }
        }
    }
    var fingerprint: String { fingerprintBox.get { payloads } }
    var files: [URL] { fileValues }
    var fileCount: Int { fileValues.count }
    var itemCount: Int { countValue }
    var characterCount: Int { characterCountValue }
    var isIndexed: Bool { location != nil }
    var isDiskBound: Bool { location != nil && inlinePayloads == nil }
    var typeNames: [String] { typeValues }
    var byteCount: Int { bytesValue }
    var kind: String { kindValue }
    var textPreview: String { previewValue }
    var heading: String { title.isEmpty ? (kind == "文件" ? "\(fileCount) 个文件" : kind) : title }
    var text: String {
        if let document = try? loadTextDocument() { return document.text }
        return Self.extractText(payloads)
    }
    var recognizedText: String {
        get {
            if let inlineRecognition { return inlineRecognition }
            return (try? loadTextDocument().recognizedText) ?? recognitionPreview
        }
        set {
            inlineRecognition = newValue; recognitionPreview = String(newValue.prefix(2048))
            recognitionRevision = UUID()
        }
    }
    var searchable: String { [title, text, source, bundle, recognizedText, files.map(\.path).joined(separator: " ")].joined(separator: " ") }
    var pdf: Data? { payloads.lazy.compactMap { $0.data(.pdf) }.first }
    // Preview images are intentionally bounded; edits should use original payloads.
    var image: NSImage? { thumbnail(maxPixelSize: 1600) }
    func thumbnail(maxPixelSize: Int = 600) -> NSImage? {
        let size = min(2400, max(32, maxPixelSize))
        if size <= 768, let location, let file = location.record.thumbnailFile,
           let source = CGImageSourceCreateWithURL(location.url(file) as CFURL, nil),
           let image = Self.downsample(source, size: size) {
            return NSImage(cgImage: image, size: .zero)
        }
        guard let payloads = try? loadPayloads(), let cg = Self.makeThumbnail(payloads, size: size) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
    static var payloadCacheByteCount: Int { PayloadCache.shared.byteCount }
    static let payloadCacheLimit = PayloadCache.limit

    private mutating func refreshMetadata(_ payloads: [Payload]) {
        countValue = payloads.count
        bytesValue = payloads.reduce(0) { $0 + $1.types.values.reduce(0) { $0 + $1.count } }
        typeValues = Array(Set(payloads.flatMap { $0.types.keys })).sorted()
        fileValues = payloads.compactMap { $0.string(.fileURL).flatMap(URL.init(string:)) }
        let plain = payloads.compactMap { item -> String? in
            if let bytes = item.data(.string) { return String(decoding: bytes.prefix(8192), as: UTF8.self) }
            for type in ["public.utf16-external-plain-text", "public.utf16-plain-text", "public.plain-text"] {
                if let bytes = item.types[type] {
                    let prefix = Data(bytes.prefix(8192))
                    if let string = String(data: prefix, encoding: type == "public.plain-text" ? .utf8 : .utf16) { return string }
                }
            }
            return item.string(.URL)
        }.joined(separator: "\n")
        previewValue = String(plain.prefix(2048)); characterCountValue = plain.count
        if !fileValues.isEmpty { kindValue = "文件" }
        else if typeValues.contains(NSPasteboard.PasteboardType.png.rawValue) || typeValues.contains(NSPasteboard.PasteboardType.tiff.rawValue) || typeValues.contains(where: Self.isImageType) { kindValue = "图片" }
        else if typeValues.contains(NSPasteboard.PasteboardType.pdf.rawValue) { kindValue = "PDF" }
        else if typeValues.contains(NSPasteboard.PasteboardType.URL.rawValue) || plain.trimmingCharacters(in: .whitespacesAndNewlines).range(of: "^https?://\\S+$", options: .regularExpression) != nil { kindValue = "链接" }
        else if typeValues.contains(NSPasteboard.PasteboardType.rtf.rawValue) || typeValues.contains(NSPasteboard.PasteboardType.html.rawValue) { kindValue = "富文本" }
        else if !plain.isEmpty { kindValue = "文本" }
        else { kindValue = "数据" }
    }
    fileprivate static func isImageType(_ type: String) -> Bool {
        UTType(type)?.conforms(to: .image) == true && type != NSPasteboard.PasteboardType.pdf.rawValue
    }
    fileprivate static func extractText(_ payloads: [Payload]) -> String {
        payloads.compactMap { item -> String? in
            if let string = item.string(.string) { return string }
            for type in ["public.utf16-external-plain-text", "public.utf16-plain-text", "public.plain-text"] {
                if let bytes = item.types[type], let string = String(data: bytes, encoding: .utf16) ?? String(data: bytes, encoding: .utf8) { return string }
            }
            if let data = item.data(.rtf), let attributed = NSAttributedString(rtf: data, documentAttributes: nil) { return attributed.string }
            if let html = item.string(.html) { return plainHTML(html) }
            return item.string(.URL)
        }.joined(separator: "\n")
    }
    // Avoid NSAttributedString's HTML importer, which can invoke WebKit on the
    // main thread or fetch remote resources. Exact HTML remains in the payload.
    private static func plainHTML(_ html: String) -> String {
        var result = html.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?i)</?(p|div|br|li|tr|h[1-6])\\b[^>]*>", with: "\n", options: .regularExpression)
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] { result = result.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9A-Fa-f]+|[0-9]+);") {
            let original = result as NSString
            for match in regex.matches(in: result, range: NSRange(location: 0, length: original.length)).reversed() {
                let token = original.substring(with: match.range(at: 1))
                let number = token.hasPrefix("x") ? UInt32(token.dropFirst(), radix: 16) : UInt32(token)
                if let number, let scalar = UnicodeScalar(number), let range = Range(match.range, in: result) { result.replaceSubrange(range, with: String(scalar)) }
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    fileprivate static func downsample(_ source: CGImageSource, size: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: size
        ] as CFDictionary)
    }
    fileprivate static func makeThumbnail(_ payloads: [Payload], size: Int) -> CGImage? {
        for item in payloads {
            let names = [NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue] + item.types.keys.filter(isImageType)
            for type in names {
                if let bytes = item.types[type], let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), let image = downsample(source, size: size) { return image }
            }
            if let bytes = item.data(.pdf), let provider = CGDataProvider(data: bytes as CFData), let document = CGPDFDocument(provider), let page = document.page(at: 1) {
                let rect = page.getBoxRect(.mediaBox)
                guard rect.width > 0, rect.height > 0 else { continue }
                let scale = CGFloat(size) / max(rect.width, rect.height)
                let width = max(1, Int(rect.width * scale)), height = max(1, Int(rect.height * scale))
                if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    context.setFillColor(CGColor.white); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    context.scaleBy(x: scale, y: scale); context.translateBy(x: -rect.minX, y: -rect.minY)
                    context.drawPDFPage(page); return context.makeImage()
                }
            }
        }
        return nil
    }
    private func loadTextDocument() throws -> TextDocument {
        guard let location else { return TextDocument(text: Self.extractText(try loadPayloads()), recognizedText: inlineRecognition ?? "") }
        return try PropertyListDecoder().decode(TextDocument.self, from: Data(contentsOf: location.url(location.record.textFile), options: [.mappedIfSafe]))
    }
    fileprivate init(record: ClipRecord, folder: URL) {
        id = record.id; date = record.date; source = record.source; bundle = record.bundle
        title = record.title; boardIDs = record.boardIDs
        location = ClipLocation(folder: folder, record: record)
        fingerprintBox = FingerprintBox(record.fingerprint)
        payloadRevision = record.payloadRevision; recognitionRevision = record.recognitionRevision
        previewValue = record.preview; recognitionPreview = record.recognizedPreview
        fileValues = record.files; typeValues = record.typeNames; bytesValue = record.bytes
        countValue = record.itemCount; characterCountValue = record.characterCount; kindValue = record.kind
    }
    fileprivate func record(previous: ClipRecord?) -> ClipRecord {
        ClipRecord(id: id, date: date, source: source, bundle: bundle, title: title, boardIDs: boardIDs, fingerprint: fingerprint,
                   kind: kind, preview: previewValue, recognizedPreview: recognitionPreview, files: files, typeNames: typeNames,
                   bytes: byteCount, itemCount: itemCount, characterCount: characterCount, payloadRevision: payloadRevision, recognitionRevision: recognitionRevision,
                   payloadFile: previous?.payloadFile ?? location?.record.payloadFile ?? "",
                   textFile: previous?.textFile ?? location?.record.textFile ?? "", thumbnailFile: previous?.thumbnailFile ?? location?.record.thumbnailFile)
    }
    fileprivate mutating func bind(_ record: ClipRecord, folder: URL) {
        guard payloadRevision == record.payloadRevision && recognitionRevision == record.recognitionRevision else { return }
        location = ClipLocation(folder: folder, record: record); inlinePayloads = nil
        fingerprintBox = FingerprintBox(record.fingerprint); previewValue = record.preview; characterCountValue = record.characterCount
        if recognitionRevision == record.recognitionRevision { inlineRecognition = nil; recognitionPreview = record.recognizedPreview }
    }
    private enum CodingKeys: String, CodingKey { case id, date, source, bundle, payloads, title, boardIDs, recognizedText }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let values = try c.decode([Payload].self, forKey: .payloads)
        self.init(source: try c.decode(String.self, forKey: .source), bundle: try c.decode(String.self, forKey: .bundle), payloads: values)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        boardIDs = try c.decodeIfPresent([UUID].self, forKey: .boardIDs) ?? []
        recognizedText = try c.decodeIfPresent(String.self, forKey: .recognizedText) ?? ""
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(date, forKey: .date)
        try c.encode(source, forKey: .source); try c.encode(bundle, forKey: .bundle)
        try c.encode(try loadPayloads(), forKey: .payloads)
        try c.encode(title, forKey: .title); try c.encode(boardIDs, forKey: .boardIDs)
        try c.encode(recognizedText, forKey: .recognizedText)
    }
}
struct Archive: Codable { var version = 1; var clips: [Clip]; var boards: [Board] }

private enum StorageError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private final class LocalDatabase {
    var handle: OpaquePointer?
    init(url: URL, readOnly: Bool = false) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite无法打开。"
            if let handle { sqlite3_close(handle) }; handle = nil
            throw StorageError.message(message)
        }
        sqlite3_busy_timeout(handle, 3000)
        if !readOnly {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA auto_vacuum=INCREMENTAL; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-4096;")
            try execute("CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, created REAL NOT NULL, metadata BLOB NOT NULL); CREATE INDEX IF NOT EXISTS records_fingerprint ON records(fingerprint); CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value BLOB NOT NULL);")
            // Trigrams support Chinese and substrings as well as English words.
            try execute("CREATE VIRTUAL TABLE IF NOT EXISTS records_fts USING fts5(id UNINDEXED, title, body, source, bundle, ocr, files, tokenize='trigram');")
        }
    }
    deinit { if let handle { sqlite3_close(handle) } }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }
    func error() -> Error { StorageError.message(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite连接已关闭。") }
    func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), sqliteTransient) }
    }
    func bind(_ value: Data, to index: Int32, in statement: OpaquePointer) {
        _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), sqliteTransient) }
    }
    func finish(_ statement: OpaquePointer) throws { guard sqlite3_step(statement) == SQLITE_DONE else { throw error() } }
    func records() throws -> [ClipRecord] {
        let statement = try prepare("SELECT metadata FROM records ORDER BY created DESC"); defer { sqlite3_finalize(statement) }
        var result: [ClipRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw error() }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            result.append(try JSONDecoder().decode(ClipRecord.self, from: data))
        }
    }
    func boards() throws -> [Board] {
        let statement = try prepare("SELECT value FROM settings WHERE key='boards'"); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return [] }
        return try JSONDecoder().decode([Board].self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }
    func upsert(_ record: ClipRecord) throws {
        let statement = try prepare("INSERT INTO records(id,fingerprint,created,metadata) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET fingerprint=excluded.fingerprint,created=excluded.created,metadata=excluded.metadata")
        defer { sqlite3_finalize(statement) }
        bind(record.id.uuidString, to: 1, in: statement); bind(record.fingerprint, to: 2, in: statement)
        sqlite3_bind_double(statement, 3, record.date.timeIntervalSince1970)
        bind(try JSONEncoder().encode(record), to: 4, in: statement); try finish(statement)
    }
    func index(_ record: ClipRecord, text: TextDocument) throws {
        try deleteIndex(record.id)
        let statement = try prepare("INSERT INTO records_fts(id,title,body,source,bundle,ocr,files) VALUES(?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        let values = [record.id.uuidString, record.title, text.text, record.source, record.bundle, text.recognizedText, record.files.map(\.path).joined(separator: " ")]
        for (index, value) in values.enumerated() { bind(value, to: Int32(index + 1), in: statement) }; try finish(statement)
    }
    func deleteIndex(_ id: UUID) throws {
        let statement = try prepare("DELETE FROM records_fts WHERE id=?"); defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement); try finish(statement)
    }
    func delete(_ id: UUID) throws {
        let statement = try prepare("DELETE FROM records WHERE id=?"); defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement); try finish(statement); try deleteIndex(id)
    }
    func hasSetting(_ key: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM settings WHERE key=?"); defer { sqlite3_finalize(statement) }
        bind(key, to: 1, in: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw error() }
        return result == SQLITE_ROW
    }
    func markLegacyMigrated() throws {
        try execute("INSERT OR REPLACE INTO settings(key,value) VALUES('legacy_migrated',X'31')")
    }
    func setBoards(_ boards: [Board]) throws {
        let statement = try prepare("INSERT INTO settings(key,value) VALUES('boards',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        defer { sqlite3_finalize(statement) }; bind(try JSONEncoder().encode(boards), to: 1, in: statement); try finish(statement)
    }
    func search(_ query: String) throws -> Set<UUID> {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let long = tokens.filter { $0.count >= 3 }
        let short = tokens.filter { $0.count < 3 }
        var conditions: [String] = []; var values: [String] = []
        if !long.isEmpty {
            conditions.append("records_fts MATCH ?")
            values.append(long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND "))
        }
        for token in short {
            conditions.append("instr(lower(title || char(10) || body || char(10) || source || char(10) || bundle || char(10) || ocr || char(10) || files), lower(?)) > 0")
            values.append(token)
        }
        let statement = try prepare("SELECT id FROM records_fts WHERE " + conditions.joined(separator: " AND "))
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { bind(value, to: Int32(index + 1), in: statement) }
        var result: Set<UUID> = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw error() }
            if let bytes = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: bytes)) { result.insert(id) }
        }
    }
}

/// Cancellation crosses from the main-thread UI to the search worker only.
/// A token never owns a snapshot, so superseded requests can release it promptly.
final class ClipSearchToken {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

// The public collection is owned by the main thread. All payload encoding, disk
// writes, image decoding, OCR and migration run on utility queues.
final class ClipStore {
    static let sensitiveTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword", "com.1password.1password", "de.petermaurer.TransientPasteboardType"]
    static let maxBytes = 100 * 1024 * 1024
    let directory: URL
    private let objects: URL
    var clips: [Clip] = []
    var boards: [Board] = []
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)? { didSet { if let lastError { onError?(lastError) } } }
    private(set) var lastError: String?
    private let io = DispatchQueue(label: "local.prism.storage", qos: .utility)
    private let ocr = DispatchQueue(label: "local.prism.ocr", qos: .utility)
    private let searchLock = NSLock()
    private let searchQueue = DispatchQueue(label: "local.prism.search", qos: .userInitiated)
    private struct SearchRequest {
        let snapshot: [Clip]
        let query: String
        let kind: String
        let app: String
        let days: Int
        let token: ClipSearchToken
        let completion: ([Clip]) -> Void
    }
    // Main-thread state: at most one executing request and one newest pending
    // snapshot. Rapid typing cannot build an unbounded queue of old searches.
    private var searchRunning = false
    private var activeSearchToken: ClipSearchToken?
    private var pendingSearch: SearchRequest?
    private var database: LocalDatabase?
    private var searchDatabase: LocalDatabase?
    // The following state belongs exclusively to io.
    private var persisted: [UUID: ClipRecord] = [:]
    private var persistedBoards: [Board] = []
    private var writeError: String?
    private var pruningResult: Set<UUID>?
    // The remaining state belongs to the main thread.
    private var fingerprintIDs: [String: UUID] = [:]
    private var saveWork: DispatchWorkItem?
    private var pendingSave = false
    private var batchDepth = 0
    private var recognizing: Set<UUID> = []
    private var diskPrunePending = false
    private var legacyMigrationPending = false

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Prism", isDirectory: true)
        objects = self.directory.appendingPathComponent("Objects", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
            let url = self.directory.appendingPathComponent("index.sqlite3")
            try io.sync {
                let db = try LocalDatabase(url: url); database = db
                let records = try db.records(); persisted = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
                persistedBoards = try db.boards(); boards = persistedBoards
                clips = records.map { Clip(record: $0, folder: objects) }
                searchDatabase = try LocalDatabase(url: url, readOnly: true)
            }
            for clip in clips { fingerprintIDs[clip.fingerprint] = clip.id }
            let legacyMigrated = try io.sync { try database?.hasSetting("legacy_migrated") ?? false }
            if !legacyMigrated && clips.isEmpty && FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("index.json").path) { migrateLegacy() }
            else { io.async { [weak self] in self?.removeOrphans() } }
        } catch { database = nil; searchDatabase = nil; lastError = "无法读取历史记录：\(error.localizedDescription)"; writeError = lastError }
    }
    struct Index: Codable { var ids: [UUID]; var boards: [Board] }
    static func read(_ pb: NSPasteboard, source: String, bundle: String) -> Clip? {
        let sensitive = Set(sensitiveTypes)
        guard !(pb.types ?? []).contains(where: { sensitive.contains($0.rawValue) }) else { return nil }
        var size = 0; var payloads: [Payload] = []
        for item in pb.pasteboardItems ?? [] {
            if item.types.contains(where: { sensitive.contains($0.rawValue) }) { return nil }
            var types: [String: Data] = [:]
            for type in item.types {
                guard type.rawValue != "local.prism.clip-id", let bytes = item.data(forType: type) else { continue }
                guard bytes.count <= maxBytes - size else { return nil }
                size += bytes.count; types[type.rawValue] = bytes
            }
            if !types.isEmpty { payloads.append(Payload(types: types)) }
        }
        return payloads.isEmpty ? nil : Clip(source: source, bundle: bundle, payloads: payloads)
    }
    @discardableResult func add(_ clip: Clip, board: UUID? = nil) -> UUID {
        guard clip.byteCount <= Self.maxBytes else {
            report("此条目超过100 MB上限，未加入历史记录。")
            return clip.id
        }
        var c = clip
        let fingerprint = c.fingerprint
        if let oldID = fingerprintIDs[fingerprint], let index = clips.firstIndex(where: { $0.id == oldID }) {
            var existing = clips.remove(at: index); existing.date = max(existing.date, c.date)
            if let board, !existing.boardIDs.contains(board) { existing.boardIDs.append(board) }
            for id in c.boardIDs where !existing.boardIDs.contains(id) { existing.boardIDs.append(id) }
            clips.insert(existing, at: 0); save(); return existing.id
        }
        // Imported or edited records can carry an ID already used by another payload.
        if clips.contains(where: { $0.id == c.id }) { c.id = UUID() }
        if let board, !c.boardIDs.contains(board) { c.boardIDs.append(board) }
        fingerprintIDs[fingerprint] = c.id; clips.insert(c, at: 0); save()
        return c.id
    }
    func diskBoundClip(id: UUID) -> Clip? {
        clips.first { $0.id == id && $0.isDiskBound }
    }
    func update(_ clip: Clip) {
        guard clip.byteCount <= Self.maxBytes else {
            report("修改后的内容超过100 MB上限，原条目已保留。")
            return
        }
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        let old = clips[index].fingerprint
        if fingerprintIDs[old] == clip.id { fingerprintIDs.removeValue(forKey: old) }
        clips[index] = clip; fingerprintIDs[clip.fingerprint] = clip.id; save()
    }
    func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        clips.removeAll { ids.contains($0.id) }
        fingerprintIDs = fingerprintIDs.filter { !ids.contains($0.value) }
        for index in boards.indices { boards[index].itemIDs.removeAll { ids.contains($0) } }
        save()
    }
    func pin(_ ids: Set<UUID>, board: UUID?, remove: Bool = false) {
        for index in clips.indices where ids.contains(clips[index].id) {
            if let board {
                if remove { clips[index].boardIDs.removeAll { $0 == board } }
                else if !clips[index].boardIDs.contains(board) { clips[index].boardIDs.append(board) }
            } else { clips[index].boardIDs = [] }
        }
        save()
    }
    func reorder(ids: [UUID], board: UUID, before: UUID? = nil) {
        guard let index = boards.firstIndex(where: { $0.id == board }) else { return }
        let members = clips.filter { $0.boardIDs.contains(board) }.map(\.id)
        let valid = Set(members); let moving = ids.filter { valid.contains($0) }
        let movingSet = Set(moving)
        var order = boards[index].itemIDs.filter { valid.contains($0) && !movingSet.contains($0) }
        for id in members where !order.contains(id) && !movingSet.contains(id) { order.append(id) }
        let insertion = before.flatMap { order.firstIndex(of: $0) } ?? order.count
        order.insert(contentsOf: moving, at: insertion); boards[index].itemIDs = order; save()
    }
    func importArchive(_ archive: Archive) {
        guard archive.clips.allSatisfy({ $0.byteCount <= Self.maxBytes }) else {
            report("备份含超过100 MB的条目，未导入。")
            return
        }
        batchDepth += 1
        for board in archive.boards where !boards.contains(where: { $0.id == board.id }) { boards.append(board) }
        // Oldest first keeps the imported chronological order when prepending.
        for clip in archive.clips.sorted(by: { $0.date < $1.date }) { add(clip) }
        batchDepth -= 1; save()
    }
    func prune(days: Int, limit: Int) {
        let cutoff = Date().addingTimeInterval(-Double(max(0, days)) * 86400)
        var count = 0
        let ids = Set(clips.sorted { $0.date > $1.date }.filter { clip in
            guard clip.boardIDs.isEmpty else { return false }
            count += 1; return (days > 0 && clip.date < cutoff) || (limit > 0 && count > limit)
        }.map(\.id))
        if !ids.isEmpty { remove(ids) }
    }
    func save() {
        pendingSave = true
        guard batchDepth == 0 else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveImmediately() }
        saveWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        onChange?()
    }
    private func saveImmediately() {
        saveWork?.cancel(); saveWork = nil
        guard pendingSave else { return }
        pendingSave = false
        let snapshot = clips, boards = self.boards, migrated = legacyMigrationPending
        io.async { [weak self] in
            autoreleasepool { self?.persist(snapshot, boards: boards, markLegacyMigrated: migrated) }
        }
    }
    @discardableResult func flush() -> Bool {
        // All store mutation methods, including flush, are called on main.
        if io.sync(execute: { writeError != nil }) { pendingSave = true }
        saveImmediately()
        io.sync {}
        applyStoragePruning()
        saveImmediately()
        let state = io.sync { (writeError, persisted) }
        for index in clips.indices {
            if let record = state.1[clips[index].id] { clips[index].bind(record, folder: objects) }
        }
        lastError = state.0
        return state.0 == nil
    }
    func flush(completion: @escaping (Bool) -> Void) {
        if pendingSave == false { pendingSave = true }
        saveImmediately()
        io.async { [weak self] in
            guard let self else { return }
            let error = self.writeError, records = self.persisted
            DispatchQueue.main.async {
                self.applyStoragePruning()
                if self.pendingSave { self.flush(completion: completion); return }
                for index in self.clips.indices {
                    if let record = records[self.clips[index].id] { self.clips[index].bind(record, folder: self.objects) }
                }
                self.lastError = error; completion(error == nil)
            }
        }
    }
    func search(query: String, kind: String = "全部", app: String = "全部", days: Int = 0) -> [Clip] {
        let result = performSearch(snapshot: clips, query: query, kind: kind, app: app, days: days)
        if let error = result.error { report("无法搜索本地索引：\(error.localizedDescription)") }
        return result.clips
    }

    /// Call on main to capture the lightweight directory. SQLite and matching
    /// then run off main; results and relevant errors return on main. The caller
    /// still validates its UI generation before applying a result.
    @discardableResult
    func searchAsync(query: String, kind: String = "全部", app: String = "全部", days: Int = 0,
                     completion: @escaping ([Clip]) -> Void) -> ClipSearchToken {
        precondition(Thread.isMainThread)
        activeSearchToken?.cancel()
        pendingSearch?.token.cancel()
        let token = ClipSearchToken()
        pendingSearch = SearchRequest(snapshot: clips, query: query, kind: kind, app: app,
                                      days: days, token: token, completion: completion)
        startNextSearch()
        return token
    }

    private func startNextSearch() {
        precondition(Thread.isMainThread)
        guard !searchRunning, let request = pendingSearch else { return }
        pendingSearch = nil
        guard !request.token.isCancelled else { return }
        searchRunning = true
        activeSearchToken = request.token
        searchQueue.async { [weak self] in
            guard let self else { return }
            let result = autoreleasepool {
                self.performSearch(snapshot: request.snapshot, query: request.query, kind: request.kind,
                                   app: request.app, days: request.days, token: request.token)
            }
            DispatchQueue.main.async {
                self.searchRunning = false
                self.activeSearchToken = nil
                if !request.token.isCancelled {
                    if let error = result.error { self.report("无法搜索本地索引：\(error.localizedDescription)") }
                    if !request.token.isCancelled { request.completion(result.clips) }
                }
                // A completion may itself submit a new request. The running
                // guard keeps that request from starting a second worker.
                self.startNextSearch()
            }
        }
    }

    private func performSearch(snapshot: [Clip], query: String, kind: String, app: String, days: Int,
                               token: ClipSearchToken? = nil) -> (clips: [Clip], error: Error?) {
        guard token?.isCancelled != true else { return ([], nil) }
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let cutoff = days > 0 ? Date().addingTimeInterval(-Double(days) * 86400) : nil
        var ids: Set<UUID> = []
        var searchError: Error?
        if !tokens.isEmpty {
            searchLock.lock()
            if token?.isCancelled != true {
                do { ids = try searchDatabase?.search(query) ?? [] }
                catch { searchError = error }
            }
            searchLock.unlock()
        }
        var result: [Clip] = []
        for clip in snapshot {
            guard token?.isCancelled != true else { return ([], nil) }
            guard (kind == "全部" || clip.kind == kind),
                  (app == "全部" || clip.source == app || clip.bundle == app),
                  cutoff == nil || clip.date >= cutoff! else { continue }
            if tokens.isEmpty || ids.contains(clip.id) { result.append(clip); continue }
            // Newly captured items remain searchable during the short write delay.
            let fields = [clip.title, clip.source, clip.bundle, clip.files.map(\.path).joined(separator: " ")]
            let preview = (clip.isIndexed ? fields : fields + [clip.textPreview]).joined(separator: " ")
            if tokens.allSatisfy({ preview.localizedStandardContains($0) }) { result.append(clip) }
        }
        return (result, searchError)
    }
    func matches(_ clip: Clip, query: String, kind: String = "全部", app: String = "全部", days: Int = 0) -> Bool {
        guard filters(clip, kind: kind, app: app, days: days) else { return false }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return search(query: query, kind: kind, app: app, days: days).contains { $0.id == clip.id }
    }
    private func filters(_ clip: Clip, kind: String, app: String, days: Int) -> Bool {
        (kind == "全部" || clip.kind == kind) && (app == "全部" || clip.source == app || clip.bundle == app) && (days <= 0 || clip.date >= Date().addingTimeInterval(-Double(days) * 86400))
    }
    func recognize(_ clip: Clip) {
        guard clip.kind == "图片", recognizing.insert(clip.id).inserted else { return }
        ocr.async { [weak self] in
            let result: String = autoreleasepool {
                guard let values = try? clip.loadPayloads(), let image = Clip.makeThumbnail(values, size: 2400) else { return "" }
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = true
                do { try VNImageRequestHandler(cgImage: image).perform([request]) }
                catch { return "" }
                return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
            }
            DispatchQueue.main.async {
                guard let self else { return }; self.recognizing.remove(clip.id)
                guard !result.isEmpty, let index = self.clips.firstIndex(where: { $0.id == clip.id && $0.payloadRevision == clip.payloadRevision }) else { return }
                self.clips[index].recognizedText = result; self.save()
            }
        }
    }
    func diskUsage() -> Int64 { io.sync { allocatedBytes() } }
    func enforceDiskLimit(megabytes: Int) { if megabytes > 0 { pruneStorage(maxBytes: Int64(megabytes) * 1024 * 1024) } }
    func pruneStorage(maxBytes: Int64) {
        guard maxBytes > 0, !diskPrunePending else { return }
        diskPrunePending = true; saveImmediately()
        let snapshot = clips
        io.async { [weak self] in
            guard let self else { return }
            var usage = self.allocatedBytes(); var ids: Set<UUID> = []
            let records = self.persisted
            for clip in snapshot.sorted(by: { $0.date < $1.date }) where usage > maxBytes && clip.boardIDs.isEmpty {
                guard let record = records[clip.id] else { continue }
                let size = record.referencedFiles.reduce(Int64(0)) { $0 + self.allocatedSize(self.objects.appendingPathComponent($1)) }
                usage -= size; ids.insert(clip.id)
            }
            self.pruningResult = ids
            DispatchQueue.main.async { self.applyStoragePruning() }
        }
    }
    private func applyStoragePruning() {
        let result: Set<UUID>? = io.sync {
            let result = pruningResult; pruningResult = nil; return result
        }
        guard let ids = result else { return }
        diskPrunePending = false
        let eligible = Set(clips.filter { ids.contains($0.id) && $0.boardIDs.isEmpty }.map(\.id))
        if !eligible.isEmpty { remove(eligible) }
    }
    private func allocatedSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0)
    }
    private func allocatedBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var size: Int64 = 0
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { size += allocatedSize(url) }
        return size
    }
    private func report(_ message: String) {
        if Thread.isMainThread { lastError = message; onError?(message) }
        else { DispatchQueue.main.async { [weak self] in self?.lastError = message; self?.onError?(message) } }
    }
    private func persist(_ snapshot: [Clip], boards: [Board], markLegacyMigrated: Bool = false) {
        guard let database else { writeError = "本地数据库不可用，记录尚未保存。"; report(writeError!); return }
        var next: [UUID: ClipRecord] = [:]
        var prepared: [(ClipRecord, TextDocument?)] = []
        var needsRecognition: Set<UUID> = []
        var created: [URL] = []
        do {
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            for clip in snapshot {
                let old = persisted[clip.id]
                var record = clip.record(previous: old)
                let payloadChanged = old?.payloadRevision != clip.payloadRevision || record.payloadFile.isEmpty
                let recognitionChanged = old?.recognitionRevision != clip.recognitionRevision || record.textFile.isEmpty
                if !payloadChanged, let old { record.preview = old.preview; record.characterCount = old.characterCount }
                if !recognitionChanged, let old { record.recognizedPreview = old.recognizedPreview }
                let indexChanged = payloadChanged || recognitionChanged || old?.title != clip.title || old?.source != clip.source || old?.bundle != clip.bundle
                var text: TextDocument?
                if payloadChanged {
                    let payloads = try clip.loadPayloads()
                    let stem = "\(clip.id.uuidString)-\(clip.payloadRevision.uuidString)"
                    record.payloadFile = stem + ".payload"
                    let url = objects.appendingPathComponent(record.payloadFile)
                    // A repeated queued snapshot may refer to a file written by an
                    // earlier successful transaction. Never rewrite immutable data.
                    if !FileManager.default.fileExists(atPath: url.path) {
                        try write(try encoder.encode(PayloadDocument(payloads: payloads)), to: url); created.append(url)
                    }
                    text = TextDocument(text: Clip.extractText(payloads), recognizedText: clip.recognizedText)
                    record.preview = String(text!.text.prefix(2048)); record.characterCount = text!.text.count
                    if record.kind == "图片" && text!.recognizedText.isEmpty { needsRecognition.insert(record.id) }
                    record.thumbnailFile = nil
                    if let image = Clip.makeThumbnail(payloads, size: 768) {
                        let data = NSMutableData()
                        if let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) {
                            CGImageDestinationAddImage(destination, image, nil)
                            if CGImageDestinationFinalize(destination) {
                                let name = stem + ".png", url = objects.appendingPathComponent(stem + ".png")
                                try write(data as Data, to: url); created.append(url); record.thumbnailFile = name
                            }
                        }
                    }
                }
                if payloadChanged || recognitionChanged {
                    if text == nil { text = TextDocument(text: clip.text, recognizedText: clip.recognizedText) }
                    record.recognizedPreview = String(text!.recognizedText.prefix(2048))
                    record.textFile = "\(clip.id.uuidString)-\(clip.payloadRevision.uuidString)-\(clip.recognitionRevision.uuidString).text"
                    let url = objects.appendingPathComponent(record.textFile)
                    if !FileManager.default.fileExists(atPath: url.path) { try write(try encoder.encode(text!), to: url); created.append(url) }
                } else if indexChanged { text = TextDocument(text: clip.text, recognizedText: clip.recognizedText) }
                next[clip.id] = record
                if record != old { prepared.append((record, indexChanged ? text : nil)) }
            }
            let removed = Set(persisted.keys).subtracting(next.keys)
            if !created.isEmpty { syncDirectory(objects) }
            try database.execute("BEGIN IMMEDIATE")
            do {
                for (record, text) in prepared {
                    try database.upsert(record)
                    if let text { try database.index(record, text: text) }
                }
                for id in removed { try database.delete(id) }
                if boards != persistedBoards { try database.setBoards(boards) }
                if markLegacyMigrated { try database.markLegacyMigrated() }
                try database.execute("COMMIT")
            } catch { try? database.execute("ROLLBACK"); throw error }
            let oldFiles = Set(persisted.values.flatMap(\.referencedFiles))
            let validFiles = Set(next.values.flatMap(\.referencedFiles))
            persisted = next; persistedBoards = boards; writeError = nil
            for name in oldFiles.subtracting(validFiles) {
                let url = objects.appendingPathComponent(name)
                DiskFileLeases.shared.retire(url)
            }
            // Keep WAL bounded and return deleted index pages to the free list.
            if !removed.isEmpty {
                try? database.execute("PRAGMA incremental_vacuum; PRAGMA wal_checkpoint(TRUNCATE)")
            }
            let records = next
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for index in self.clips.indices {
                    if let record = records[self.clips[index].id] { self.clips[index].bind(record, folder: self.objects) }
                }
                if markLegacyMigrated { self.legacyMigrationPending = false }
                self.lastError = nil; self.onChange?()
                for clip in self.clips where needsRecognition.contains(clip.id) { self.recognize(clip) }
            }
        } catch {
            // On failure no published metadata points at these new files.
            let committed = Set(persisted.values.flatMap(\.referencedFiles))
            for url in created where !committed.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
            writeError = "无法保存历史记录，内容暂保留在内存中：\(error.localizedDescription)"
            report(writeError!)
        }
    }
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.synchronize()
    }
    private func syncDirectory(_ url: URL) {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        if descriptor >= 0 { _ = Darwin.fsync(descriptor); Darwin.close(descriptor) }
    }
    private func removeOrphans() {
        let valid = Set(persisted.values.flatMap(\.referencedFiles))
        for url in (try? FileManager.default.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil)) ?? [] where !valid.contains(url.lastPathComponent) {
            DiskFileLeases.shared.retire(url)
        }
    }
    private func migrateLegacy() {
        let folder = directory
        io.async { [weak self] in
            guard let self else { return }
            do {
                let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: folder.appendingPathComponent("index.json")))
                var migrated: [Clip] = []
                for id in index.ids {
                    let url = folder.appendingPathComponent("\(id).plist")
                    migrated.append(try PropertyListDecoder().decode(Clip.self, from: Data(contentsOf: url)))
                }
                // Preserve the complete old archive as a recovery source. Migration
                // is additive, and a partially unreadable archive is never truncated.
                DispatchQueue.main.async {
                    self.batchDepth += 1
                    for board in index.boards where !self.boards.contains(where: { $0.id == board.id }) { self.boards.append(board) }
                    for clip in migrated.reversed() { self.add(clip) }
                    self.batchDepth -= 1; self.legacyMigrationPending = true; self.save()
                }
            } catch { self.report("旧版历史记录迁移失败，原文件已保留：\(error.localizedDescription)") }
        }
    }
}

struct BackupEntry: Codable {
    var id: UUID
    var bytes: Int
    var sha256: String
}
struct BackupManifest: Codable {
    var version = 2
    var format = "local.prism.folder-backup"
    var created = Date()
    var clips: [BackupEntry]
    var boards: [Board]
    var ids: [UUID] { clips.map(\.id) }
}

extension ClipStore {
    // Run these static APIs on a utility queue. A snapshot's ClipLocation leases
    // keep its immutable originals alive even if history is edited during export.
    // Peak working memory is bounded by one record, rather than the whole archive.
    static func exportBackup(_ archive: Archive, to destination: URL) throws {
        guard destination.pathExtension.lowercased() == "prismbackup" else {
            throw StorageError.message("备份名称应以 .prismbackup 结尾。")
        }
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: true)
        var committed = false
        defer { if !committed { try? manager.removeItem(at: staging) } }
        try manager.createDirectory(at: staging.appendingPathComponent("Records"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var entries: [BackupEntry] = []
        for clip in archive.clips {
            let entry: BackupEntry = try autoreleasepool {
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                let data = try encoder.encode(clip)
                let file = staging.appendingPathComponent("Records").appendingPathComponent(clip.id.uuidString + ".plist")
                try durableBackupWrite(data, to: file)
                return BackupEntry(id: clip.id, bytes: data.count, sha256: checksum(data))
            }
            entries.append(entry)
        }
        guard Set(entries.map(\.id)).count == entries.count else { throw StorageError.message("备份条目ID重复，已停止导出。") }
        let manifest = BackupManifest(clips: entries, boards: archive.boards)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try durableBackupWrite(try encoder.encode(manifest), to: staging.appendingPathComponent("manifest.json"))
        syncBackupDirectory(staging.appendingPathComponent("Records")); syncBackupDirectory(staging)
        if manager.fileExists(atPath: destination.path) {
            // Refuse to replace an unrelated directory. Swapping the two sibling
            // packages keeps the previous complete backup until the new one exists.
            _ = try readBackupManifest(at: destination)
            guard Darwin.renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            syncBackupDirectory(parent)
            try? manager.removeItem(at: staging)
        } else {
            guard Darwin.rename(staging.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            syncBackupDirectory(parent)
        }
        committed = true
    }
    static func readBackupManifest(at directory: URL) throws -> BackupManifest {
        let file = directory.appendingPathComponent("manifest.json")
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw StorageError.message("备份目录清单大小异常。") }
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: file))
        guard manifest.version == 2, manifest.format == "local.prism.folder-backup", Set(manifest.ids).count == manifest.ids.count else {
            throw StorageError.message("备份格式不受支持或条目ID重复。")
        }
        return manifest
    }
    static func readBackupClip(id: UUID, at directory: URL, manifest: BackupManifest? = nil) throws -> Clip {
        let metadata = try manifest ?? readBackupManifest(at: directory)
        guard let entry = metadata.clips.first(where: { $0.id == id }) else { throw StorageError.message("备份清单中没有此条目。") }
        return try readBackupClip(entry: entry, at: directory)
    }
    static func readBackupClip(entry: BackupEntry, at directory: URL) throws -> Clip {
        let folder = directory.appendingPathComponent("Records", isDirectory: true)
        let file = folder.appendingPathComponent(entry.id.uuidString + ".plist")
        let resolvedFolder = folder.resolvingSymlinksInPath()
        let resolvedDirectory = directory.resolvingSymlinksInPath()
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard resolvedFolder.deletingLastPathComponent().path == resolvedDirectory.path,
              values.isSymbolicLink != true, values.isRegularFile == true,
              let size = values.fileSize, size == entry.bytes, size <= maxBytes * 2 else {
            throw StorageError.message("备份条目路径、大小或文件类型异常：\(entry.id)。")
        }
        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        guard checksum(data) == entry.sha256 else { throw StorageError.message("备份校验失败：\(entry.id)。") }
        let clip = try PropertyListDecoder().decode(Clip.self, from: data)
        guard clip.id == entry.id, clip.byteCount <= maxBytes else { throw StorageError.message("备份条目ID或原始内容大小异常。") }
        return clip
    }
    private static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func durableBackupWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.synchronize()
    }
    private static func syncBackupDirectory(_ url: URL) {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        if descriptor >= 0 { _ = Darwin.fsync(descriptor); Darwin.close(descriptor) }
    }
}
