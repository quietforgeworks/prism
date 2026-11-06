import Foundation
import CryptoKit
import Darwin

/// Materialized drag files outlive the drag session: a receiver may open them
/// after drop. This cache owns only its dedicated directory, never clip history.
final class ImageDragFileCache {
    static let shared = ImageDragFileCache()
    static let maximumPendingBytes: Int64 = 256 * 1024 * 1024
    private static let maximumPendingRequests = 64
    private static let maximumFiles = 4096
    private static let defaultDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Prism-ImageDragFiles-\(getuid())", isDirectory: true)

    enum CacheError: LocalizedError {
        case invalidExtension, emptyImage, pendingLimit, capacity, unsafeEntry, io(Int32)
        var errorDescription: String? {
            switch self {
            case .invalidExtension: return "图片文件扩展名无效。"
            case .emptyImage: return "图片没有可导出的数据。"
            case .pendingLimit: return "图片导出繁忙或待处理数据超过 256 MB，请减少图片数量。"
            case .capacity: return "图片拖拽缓存已满。近期文件需要保留供接收应用读取，请稍后重试。"
            case .unsafeEntry: return "图片拖拽缓存包含不安全的文件或目录。"
            case .io(let code): return "无法准备图片拖拽文件：\(String(cString: strerror(code)))。"
            }
        }
    }

    private let directory: URL
    private let byteLimit: Int64
    private let retention: TimeInterval
    private let worker = DispatchQueue(label: "Prism.ImageDragFileCache", qos: .userInitiated)
    private let lock = NSLock()
    private var pendingBytes: Int64 = 0
    private var pendingRequests = 0

    /// `directory` must be a dedicated cache directory. Test callers may supply
    /// disposable storage. Existing source files must never be placed here.
    init(directory: URL = ImageDragFileCache.defaultDirectory,
         byteLimit: Int64 = 512 * 1024 * 1024, retention: TimeInterval = 24 * 3600) {
        self.directory = directory
        self.byteLimit = max(0, byteLimit)
        self.retention = max(0, retention)
    }

    func prepare(bytes: Data, fileExtension: String,
                 completion: @escaping (Result<URL, Error>) -> Void) {
        let ext = fileExtension.lowercased()
        guard !ext.isEmpty, ext.utf8.count <= 16,
              ext.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }) else {
            DispatchQueue.main.async { completion(.failure(CacheError.invalidExtension)) }; return
        }
        guard !bytes.isEmpty else {
            DispatchQueue.main.async { completion(.failure(CacheError.emptyImage)) }; return
        }
        let size = Int64(bytes.count)
        lock.lock()
        let accepted = pendingRequests < Self.maximumPendingRequests &&
            size <= Self.maximumPendingBytes - pendingBytes
        if accepted { pendingBytes += size; pendingRequests += 1 }
        lock.unlock()
        guard accepted else {
            DispatchQueue.main.async { completion(.failure(CacheError.pendingLimit)) }; return
        }
        worker.async {
            let result = Result { try self.materialize(bytes, ext: ext) }
            // The queued main callback retains only the URL/result, not bytes.
            // Retaining the reservation until delivery also bounds callbacks.
            DispatchQueue.main.async {
                self.lock.lock()
                self.pendingBytes -= size; self.pendingRequests -= 1
                self.lock.unlock()
                completion(result)
            }
        }
    }

    private func openDirectory() throws -> Int32 {
        guard directory.isFileURL else { throw CacheError.unsafeEntry }
        let path = directory.path
        if mkdir(path, 0o700) != 0 && errno != EEXIST { throw CacheError.io(errno) }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CacheError.io(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == S_IFDIR else {
            close(fd); throw CacheError.unsafeEntry
        }
        guard fchmod(fd, 0o700) == 0 else { let code = errno; close(fd); throw CacheError.io(code) }
        return fd
    }

    private func isOwnedName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 2, parts[0].count == 64, (1...16).contains(parts[1].count) {
            return parts[0].utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
                parts[1].utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
        }
        return name.hasPrefix(".pending-") && UUID(uuidString: String(name.dropFirst(9))) != nil
    }

    /// Enumerate through the pinned descriptor, never through a replaced path.
    private func inventory(_ fd: Int32, keeping name: String) throws -> (bytes: Int64, count: Int) {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw CacheError.io(errno) }
        guard let stream = fdopendir(duplicate) else { let code = errno; close(duplicate); throw CacheError.io(code) }
        defer { closedir(stream) }
        var total: Int64 = 0
        var count = 0
        let cutoff = Date().timeIntervalSince1970 - retention
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw CacheError.io(errno) }
                break
            }
            let child = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if child == "." || child == ".." { continue }
            guard isOwnedName(child) else { throw CacheError.unsafeEntry }
            var info = stat()
            guard fstatat(fd, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw CacheError.io(errno) }
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                  info.st_size >= 0 else { throw CacheError.unsafeEntry }
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            if child != name && modified < cutoff {
                guard unlinkat(fd, child, 0) == 0 else { throw CacheError.io(errno) }
                continue
            }
            guard Int64(info.st_size) <= Int64.max - total else { throw CacheError.capacity }
            total += Int64(info.st_size); count += 1
            guard count <= Self.maximumFiles else { throw CacheError.capacity }
        }
        return (total, count)
    }

    private func reuse(_ name: String, in fd: Int32, matching bytes: Data) throws -> Bool {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if file < 0 {
            if errno == ENOENT { return false }
            throw CacheError.io(errno)
        }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size == bytes.count else {
            throw CacheError.unsafeEntry
        }
        // Compare bounded chunks; do not load a second full-size image.
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < bytes.count {
                let amount = read(file, &buffer, min(buffer.count, bytes.count - offset))
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw CacheError.io(amount == 0 ? EIO : errno) }
                guard memcmp(buffer, raw.baseAddress!.advanced(by: offset), amount) == 0 else { throw CacheError.unsafeEntry }
                offset += amount
            }
        }
        guard fchmod(file, 0o600) == 0, futimes(file, nil) == 0 else { throw CacheError.io(errno) }
        return true
    }

    private func materialize(_ bytes: Data, ext: String) throws -> URL {
        let name = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + "." + ext
        let fd = try openDirectory()
        defer { close(fd) }
        let inventory = try inventory(fd, keeping: name)
        guard inventory.bytes <= byteLimit else { throw CacheError.capacity }
        if try reuse(name, in: fd, matching: bytes) { return directory.appendingPathComponent(name) }
        guard Int64(bytes.count) <= byteLimit, inventory.bytes <= byteLimit - Int64(bytes.count),
              inventory.count < Self.maximumFiles else { throw CacheError.capacity }
        let temporary = ".pending-" + UUID().uuidString
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw CacheError.io(errno) }
        defer { close(file); unlinkat(fd, temporary, 0) }
        guard fchmod(file, 0o600) == 0 else { throw CacheError.io(errno) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < bytes.count {
                let amount = write(file, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw CacheError.io(amount == 0 ? EIO : errno) }
                offset += amount
            }
        }
        guard fsync(file) == 0 else { throw CacheError.io(errno) }
        // Atomic no-replace publication. Never follow or overwrite a collision.
        guard linkat(fd, temporary, fd, name, 0) == 0 else { throw CacheError.io(errno) }
        return directory.appendingPathComponent(name)
    }
}
