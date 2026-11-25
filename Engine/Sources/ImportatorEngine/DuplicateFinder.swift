import Foundation

/// What a duplicate is matched on (SPEC, Duplicate check). File names are never used.
public enum MatchKey: Hashable, Sendable {
    case photo(type: String, date: String, subseconds: String?, make: String?, model: String?, width: Int?, height: Int?)
    case video(date: String, durationMilliseconds: Int?, make: String?, model: String?, width: Int?, height: Int?)

    /// Without a capture time, the date the file would get (from its name or file date) is used,
    /// so a source matches its own fixed copy. No date at all: no key, the file counts as new.
    public init?(_ file: MediaFile, _ metadata: Metadata, guessedDate: String? = nil) {
        guard !metadata.unreadable, let date = metadata.captureDate ?? guessedDate else { return nil }
        switch file.kind {
        case .photo:
            self = .photo(type: metadata.contentType ?? file.fileExtension, date: date,
                          subseconds: metadata.subseconds, make: metadata.make, model: metadata.model,
                          width: metadata.width, height: metadata.height)
        case .video:
            self = .video(date: date, durationMilliseconds: metadata.duration.map { Int(($0 * 1000).rounded()) },
                          make: metadata.make, model: metadata.model, width: metadata.width, height: metadata.height)
        }
    }
}

public struct FileResult: Sendable {
    public let file: MediaFile
    public let metadata: Metadata
    public let dateFix: DateFix
    /// The existing copies in the scope. Empty: the file is new.
    public let existing: [URL]

    public var isDuplicate: Bool { !existing.isEmpty }
}

public struct ScanReport: Sendable {
    public let cells: [Cell]
    public let results: [MediaFile: FileResult]
    public let scopeFileCount: Int
    public let unreadableFolders: [URL]
    public let timings: [(String, TimeInterval)]
}

/// The source as read: its files, their metadata and date fixes, and the grid cells.
public struct SourceRead: Sendable {
    public let files: [MediaFile]
    /// Every folder that was read, as `folderKey`s: left out of the duplicate check.
    public let folders: Set<String>
    public let unreadable: [URL]
    public let metadata: [MediaFile: Metadata]
    public let dateFixes: [MediaFile: DateFix]
    public let cells: [Cell]
}

/// The files under a check folder, by match key. Built from the files themselves on every
/// check; never stored.
public struct ScopeIndex: Sendable {
    public let scope: URL
    public let files: [MediaFile]
    public let metadata: [MediaFile: Metadata]
    public let unreadable: [URL]
    let index: [MatchKey: [MediaFile]]

    /// The files with this key, outside the given folders.
    func candidates(for key: MatchKey, excluding folders: Set<String>) -> [MediaFile] {
        (index[key] ?? []).filter { !folders.contains($0.folderKey) }
    }
}

/// Reads the source, reads the scope and marks each source file new or duplicate. Never writes.
/// Not thread-safe: use one instance from one thread or queue at a time.
public final class ImportScanner {
    private let reader: MetadataReader
    private var hashes: [URL: (stamp: FileStamp?, value: String?)] = [:]
    /// The app's cache folder: ~/Library/Caches/io.github.janvibe-coding.Importator.
    public static var defaultCacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.github.janvibe-coding.Importator", isDirectory: true)
    }

    /// Where check-folder caches are kept; nil reads everything every time.
    private let cacheFolder: URL?

    public init(exifTool: ExifTool, cacheFolder: URL? = nil) {
        reader = MetadataReader(exifTool: exifTool)
        self.cacheFolder = cacheFolder
    }

    public func readSource(_ picks: [FolderPick], onProgress: (Int) -> Void = { _ in }) throws -> SourceRead {
        let found = SourceScanner.scan(picks)
        let metadata = try reader.read(found.files, onProgress: onProgress)
        let fixes = Dictionary(uniqueKeysWithValues: found.files.map { ($0, MetadataReader.dateFix(for: $0, metadata[$0]!)) })
        return SourceRead(files: found.files, folders: found.folders, unreadable: found.unreadable,
                          metadata: metadata, dateFixes: fixes, cells: SourceScanner.cells(found.files))
    }

    /// Reads every media file under the scope. Fingerprints computed before are forgotten, since
    /// the files may have changed.
    public func readScope(_ scope: URL, onProgress: (_ done: Int, _ total: Int) -> Void = { _, _ in }) throws -> ScopeIndex {
        let found = SourceScanner.scan([scope], recursive: true)
        try Task.checkCancellation()
        onProgress(0, found.files.count)

        // Files unchanged since the last read keep their metadata; the rest are read.
        var cache = cacheFolder.map { ScopeCache(folder: $0, scope: scope) }
        let stamps = Dictionary(uniqueKeysWithValues: found.files.map { ($0, FileStamp($0.url)) })
        var metadata: [MediaFile: Metadata] = [:]
        var toRead: [MediaFile] = []
        for file in found.files {
            if let known = cache?.metadata(for: file.url, stamp: stamps[file] ?? nil) {
                metadata[file] = known
            } else {
                toRead.append(file)
            }
        }
        let reused = metadata.count
        onProgress(reused, found.files.count)
        metadata.merge(try reader.read(toRead) { onProgress(reused + $0, found.files.count) }) { a, _ in a }
        if cache != nil {
            var fresh: [String: ScopeCache.Entry] = [:]
            for file in found.files {
                if let stamp = stamps[file] ?? nil, let known = metadata[file], !known.unreadable {
                    fresh[file.url.path] = ScopeCache.Entry(stamp: stamp, metadata: known)
                }
            }
            cache!.save(fresh)
        }
        var index: [MatchKey: [MediaFile]] = [:]
        for file in found.files {
            let fileMetadata = metadata[file]!
            let guess = MetadataReader.dateFix(for: file, fileMetadata).date
            if let key = MatchKey(file, fileMetadata, guessedDate: guess) { index[key, default: []].append(file) }
        }
        return ScopeIndex(scope: scope, files: found.files, metadata: metadata, unreadable: found.unreadable, index: index)
    }

    /// Each source file on its own, against the scope minus the source's folders. With
    /// fingerprints, only metadata matches are hashed, and each file is hashed once.
    public func match(
        _ source: SourceRead, in scope: ScopeIndex, fingerprints: Bool,
        onProgress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> [MediaFile: FileResult] {
        var results: [MediaFile: FileResult] = [:]
        for (number, file) in source.files.enumerated() {
            try Task.checkCancellation()
            let metadata = source.metadata[file]!
            let dateFix = source.dateFixes[file]!
            var existing = MatchKey(file, metadata, guessedDate: dateFix.date)
                .map { scope.candidates(for: $0, excluding: source.folders) } ?? []
            if fingerprints, !existing.isEmpty {
                let own = fingerprint(file, metadata)
                existing = own == nil ? [] : existing.filter { fingerprint($0, scope.metadata[$0]!) == own }
            }
            results[file] = FileResult(file: file, metadata: metadata, dateFix: dateFix, existing: existing.map(\.url))
            onProgress(number + 1, source.files.count)
        }
        return results
    }

    /// Each file is hashed once, until its size or modification date changes.
    private func fingerprint(_ file: MediaFile, _ metadata: Metadata) -> String? {
        let stamp = FileStamp(file.url)
        if let cached = hashes[file.url], cached.stamp == stamp { return cached.value }
        let value = try? Fingerprint.compute(file.url, method: Fingerprint.method(for: file, metadata))
        hashes[file.url] = (stamp, value)
        return value
    }

    /// All three steps at once, for the command-line tool and tests.
    public func scan(sources: [URL], recursive: Bool = true, scope: URL, fingerprints: Bool) throws -> ScanReport {
        var timings: [(String, TimeInterval)] = []
        func timed<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
            let start = Date()
            let value = try work()
            timings.append((label, Date().timeIntervalSince(start)))
            return value
        }
        let source = try timed("source") { try readSource(sources.map { FolderPick(url: $0, recursive: recursive) }) }
        let index = try timed("scope (\(scope.lastPathComponent))") { try readScope(scope) }
        let results = try timed(fingerprints ? "matching + fingerprints" : "matching") {
            try match(source, in: index, fingerprints: fingerprints)
        }
        let scopeCount = index.files.filter { !source.folders.contains($0.folderKey) }.count
        return ScanReport(cells: source.cells, results: results, scopeFileCount: scopeCount,
                          unreadableFolders: source.unreadable + index.unreadable, timings: timings)
    }
}
