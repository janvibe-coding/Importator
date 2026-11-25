import CryptoKit
import Foundation

/// A file's size and modification date: when both are unchanged, its metadata is too.
struct FileStamp: Codable, Hashable, Sendable {
    let size: Int64
    let modified: Double

    init?(_ url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        self.size = Int64(size)
        self.modified = modified.timeIntervalSinceReferenceDate
    }
}

/// The metadata of a check folder from its last read, so the next read only reads files that are
/// new or changed. Rebuilt from the files on every read and never trusted over them: an entry is
/// used only while the file's size and modification date are the same.
struct ScopeCache {
    struct Entry: Codable {
        let stamp: FileStamp
        let metadata: Metadata
    }

    let file: URL
    private(set) var entries: [String: Entry] = [:]

    init(folder: URL, scope: URL) {
        let name = SHA256.hash(data: Data(scope.folderKey.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        file = folder.appendingPathComponent("scope-\(name).plist")
        if let data = try? Data(contentsOf: file),
           let saved = try? PropertyListDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    func metadata(for url: URL, stamp: FileStamp?) -> Metadata? {
        guard let stamp, let entry = entries[url.path], entry.stamp == stamp else { return nil }
        return entry.metadata
    }

    /// Replaces the whole cache with what this read found: files that are gone drop out.
    mutating func save(_ fresh: [String: Entry]) {
        entries = fresh
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(fresh) { try? data.write(to: file, options: .atomic) }
    }
}
