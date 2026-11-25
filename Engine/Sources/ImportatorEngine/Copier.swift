import CryptoKit
import Darwin
import Foundation
import ImageIO

/// Which files of a RAW+JPG cell are copied. Single files and videos are always copied.
public enum CopyChoice: String, Sendable, CaseIterable {
    case rawAndJPG = "raw+jpg"
    case raw
    case jpg
}

public struct ImportOptions: Sendable {
    public var rename: Bool
    public var copy: CopyChoice
    public var fixDates: Bool
    public var verify: Bool

    public init(rename: Bool = false, copy: CopyChoice = .rawAndJPG, fixDates: Bool = false, verify: Bool = false) {
        self.rename = rename
        self.copy = copy
        self.fixDates = fixDates
        self.verify = verify
    }
}

public struct ImportOutcome: Sendable {
    public var copied: [(source: MediaFile, copy: URL)] = []
    /// Not copied: the reason is written for the user.
    public var failed: [(source: MediaFile, reason: String)] = []
    /// Copied, but the missing date couldn't be written: the copy is the unchanged original.
    public var dateNotFixed: [(source: MediaFile, copy: URL, reason: String)] = []
    public var datesFixed = 0
    /// Copies checked against their original (Verify copies).
    public var verified = 0
    /// Copies that differed from their original and were copied again.
    public var recopied = 0
    public var leftoversRemoved = 0
}

/// Where an import is: copying (bytes) or fixing dates (files).
public struct ImportProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case copying, fixingDates }
    public let stage: Stage
    public let done: Int64
    public let total: Int64
}

public enum CopierError: Error, Equatable {
    case notEnoughSpace(needed: Int64, available: Int64)
    case destinationInsideSource
}

/// Copies files into the destination (SPEC, Copying). Never changes the source and never
/// overwrites a file at the destination.
public final class Copier {
    static let tempPrefix = ".importator-"
    private let exifTool: ExifTool

    public init(exifTool: ExifTool) {
        self.exifTool = exifTool
    }

    /// The files of the cells that will be copied: the selected ones, with the copy choice
    /// applied to RAW+JPG cells.
    public static func files(of cells: [Cell], selected: Set<MediaFile>, copy: CopyChoice) -> [[MediaFile]] {
        cells.compactMap { cell in
            var files = cell.files.filter(selected.contains)
            if cell.files.count == 2 {
                switch copy {
                case .rawAndJPG: break
                case .raw: files = files.filter(\.isRaw)
                case .jpg: files = files.filter { !$0.isRaw }
                }
            }
            return files.isEmpty ? nil : files
        }
    }

    static let attempts = 3
    /// Tests only: file name → how many of its next copies get damaged before the check.
    static let damage = DamagePlan()

    /// Copies first, checks the copies (with `verify`), and only then writes missing dates into
    /// the copies. A copy always lands as the unchanged original; a date that can't be written
    /// leaves it that way. The photo matters more than its date.
    public func run(
        cells: [Cell], results: [MediaFile: FileResult], selected: Set<MediaFile>,
        sourceFolders: [URL], destination: URL, options: ImportOptions,
        onProgress: (ImportProgress) -> Void = { _ in }
    ) throws -> ImportOutcome {
        let destinationKey = destination.folderKey
        if sourceFolders.contains(where: { destinationKey.hasPrefix($0.folderKey) }) {
            throw CopierError.destinationInsideSource
        }
        var outcome = ImportOutcome()
        outcome.leftoversRemoved = Self.removeLeftovers(in: destination)

        let groups = Self.files(of: cells, selected: selected, copy: options.copy)
        guard !groups.isEmpty else { return outcome }
        let total = groups.joined().reduce(Int64(0)) { $0 + Self.size(of: $1.url) }
        let available = Self.availableSpace(at: destination)
        let margin: Int64 = 100 << 20
        guard available >= total + margin else {
            throw CopierError.notEnoughSpace(needed: total + margin, available: available)
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var taken = Self.existingNames(in: destination)
        var done: Int64 = 0
        onProgress(ImportProgress(stage: .copying, done: 0, total: total))

        // 1. Copy, and check each copy straight away. A copy that differs is copied again.
        for group in groups {
            try Task.checkCancellation()
            let names = Self.names(for: group, results: results, rename: options.rename, taken: &taken)
            for (file, name) in zip(group, names) {
                let target = destination.appendingPathComponent(name)
                do {
                    let tries = try land(file, at: target, verify: options.verify)
                    outcome.copied.append((file, target))
                    if options.verify { outcome.verified += 1 }
                    outcome.recopied += tries - 1
                } catch {
                    outcome.failed.append((file, Self.explain(error)))
                }
                done += Self.size(of: file.url)
                onProgress(ImportProgress(stage: .copying, done: done, total: total))
            }
        }

        // 2. Missing dates, only into copies that landed (and passed the check).
        guard options.fixDates else { return outcome }
        let toFix = outcome.copied.compactMap { item -> (MediaFile, URL, String, Metadata?)? in
            guard let result = results[item.source], let date = result.dateFix.date else { return nil }
            return (item.source, item.copy, date, result.metadata)
        }
        for (number, (source, copy, date, metadata)) in toFix.enumerated() {
            try Task.checkCancellation()
            onProgress(ImportProgress(stage: .fixingDates, done: Int64(number), total: Int64(toFix.count)))
            do {
                try DateFixer.fixInPlace(MediaFile(url: copy, kind: source.kind), date: date, metadata: metadata, exifTool: exifTool)
                outcome.datesFixed += 1
            } catch {
                outcome.dateNotFixed.append((source, copy, Self.explain(error)))
            }
        }
        onProgress(ImportProgress(stage: .fixingDates, done: Int64(toFix.count), total: Int64(toFix.count)))
        return outcome
    }

    enum CopyError: Error, CustomStringConvertible {
        case dateNotWritten(String)
        case dateNotReadBack
        case imageDataChanged
        case nameTaken
        case keptDiffering(Int)

        var description: String {
            switch self {
            case .dateNotWritten(let output): "ExifTool couldn't write the date: \(output)"
            case .dateNotReadBack: "The date wasn't found in the file after writing it."
            case .imageDataChanged: "Writing the date would have changed the image data."
            case .nameTaken: "A file with this name appeared at the destination during the import."
            case .keptDiffering(let attempts):
                "The copy differed from the original \(attempts) times in a row. The card or the destination disk may be faulty."
            }
        }
    }

    /// A reason the user can act on.
    static func explain(_ error: Error) -> String {
        if let error = error as? CopyError { return error.description }
        if let error = error as? Fingerprint.FingerprintError { return error.description }
        return (error as NSError).localizedDescription
    }

    /// Lands one file at `target` as an exact copy with the original's file dates. With `verify`,
    /// the copy is read back and compared; a copy that differs is removed and made again, up to
    /// three times. Returns how many attempts it took.
    private func land(_ file: MediaFile, at target: URL, verify: Bool) throws -> Int {
        for attempt in 1...Self.attempts {
            let temp = target.deletingLastPathComponent()
                .appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString).\(file.url.pathExtension)")
            defer { try? FileManager.default.removeItem(at: temp) }
            if verify {
                let original = try Self.copyHashing(from: file.url, to: temp)
                if Self.damage.take(file.url.lastPathComponent) {
                    let handle = try FileHandle(forWritingTo: temp)
                    try handle.seek(toOffset: 10)
                    try handle.write(contentsOf: Data([0x42]))
                    try handle.close()
                }
                guard try Self.hashUncached(temp) == original else { continue }
            } else {
                try FileManager.default.copyItem(at: file.url, to: temp)
            }
            try Self.copyFileDates(from: file.url, to: temp)
            // RENAME_EXCL: fails instead of replacing an existing file.
            guard renamex_np(temp.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw CopyError.nameTaken }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return attempt
        }
        throw CopyError.keptDiffering(Self.attempts)
    }

    /// Copies in 8 MB blocks and returns the SHA-256 of what was read from the original. The copy
    /// is written past the file cache and flushed to the disk, so reading it back afterwards
    /// reads the disk.
    static func copyHashing(from source: URL, to target: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        _ = fcntl(input.fileDescriptor, F_NOCACHE, 1)
        let mode = ((try? FileManager.default.attributesOfItem(atPath: source.path))?[.posixPermissions] as? NSNumber)?.int16Value ?? 0o644
        guard FileManager.default.createFile(atPath: target.path, contents: nil,
                                             attributes: [.posixPermissions: NSNumber(value: mode | 0o600)]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
        }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        _ = fcntl(output.fileDescriptor, F_NOCACHE, 1)
        var hash = SHA256()
        while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        _ = fcntl(output.fileDescriptor, F_FULLFSYNC)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of a file, read past the file cache.
    static func hashUncached(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Writes DateTimeOriginal and CreateDate into the Exif IFD of `temp`, a copy of `original`.
    /// Throws unless the date reads back and, for JPG and DNG, the image data is unchanged.
    static func writeDate(_ date: String, into temp: URL, original: MediaFile, metadata: Metadata?, exifTool: ExifTool) throws {
        let printed = try exifTool.run([
            "-P", "-overwrite_original",
            "-ExifIFD:DateTimeOriginal=\(date)", "-ExifIFD:CreateDate=\(date)", temp.path,
        ])
        guard printed.contains("1 image files updated") else {
            throw CopyError.dateNotWritten(printed.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard MetadataReader.readWithImageIO(temp).exifDate == date else { throw CopyError.dateNotReadBack }
        if let metadata {
            let method = Fingerprint.method(for: original, metadata)
            if method != .wholeFile {
                guard try Fingerprint.compute(original.url, method: method) == Fingerprint.compute(temp, method: method)
                else { throw CopyError.imageDataChanged }
            }
        }
    }

    static func copyFileDates(from source: URL, to target: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        var dates: [FileAttributeKey: Any] = [:]
        dates[.creationDate] = attributes[.creationDate]
        dates[.modificationDate] = attributes[.modificationDate]
        try FileManager.default.setAttributes(dates, ofItemAtPath: target.path)
    }

    // MARK: Names

    /// The new names for one cell's files. With rename, `yyyyMMdd-<original name>`. A taken name
    /// gets `-2`, `-3`, …, the same suffix for every file of the cell so a pair stays a pair.
    static func names(for group: [MediaFile], results: [MediaFile: FileResult], rename: Bool, taken: inout Set<String>) -> [String] {
        let prefix = rename ? day(of: group, results: results).map { $0 + "-" } ?? "" : ""
        let bases = group.map { prefix + $0.url.deletingPathExtension().lastPathComponent }
        var suffix = 1
        while true {
            let names = zip(bases, group).map { base, file in
                (suffix == 1 ? base : "\(base)-\(suffix)") + "." + file.url.pathExtension
            }
            let keys = names.map(nameKey)
            if Set(keys).count == keys.count, keys.allSatisfy({ !taken.contains($0) }) {
                taken.formUnion(keys)
                return names
            }
            suffix += 1
        }
    }

    /// `yyyyMMdd` of the cell's capture time, else the date it would get, else the file date.
    /// The same for every file of a pair.
    static func day(of group: [MediaFile], results: [MediaFile: FileResult]) -> String? {
        let date = group.lazy.compactMap { results[$0]?.metadata.captureDate }.first
            ?? group.lazy.compactMap { results[$0]?.dateFix.date }.first
            ?? group.lazy.compactMap { file -> String? in
                (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate.map(MetadataReader.exifFormat)
            }.first
        guard let date, date.count >= 10 else { return nil }
        return date.prefix(10).replacingOccurrences(of: ":", with: "")
    }

    /// Names compare case-insensitively and in NFC, as APFS and exFAT do.
    static func nameKey(_ name: String) -> String { name.nfc.lowercased() }

    static func existingNames(in folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.map(nameKey))
    }

    // MARK: Housekeeping

    /// Removes temporary files a cut-off import left behind (ExifTool's own included).
    static func removeLeftovers(in folder: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var removed = 0
        for name in names where name.hasPrefix(tempPrefix) {
            if (try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }

    static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// Free space on the volume of the folder, or of the nearest folder above it that exists.
    static func availableSpace(at folder: URL) -> Int64 {
        var folder = folder
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            folder = folder.deletingLastPathComponent()
        }
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }
}

/// Tests only: damages chosen copies so the check after copying can be tested.
final class DamagePlan: @unchecked Sendable {
    private var counts: [String: Int] = [:]
    private let lock = NSLock()

    func set(_ name: String, times: Int) {
        lock.lock(); counts[name] = times; lock.unlock()
    }

    func take(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let left = counts[name], left > 0 else { return false }
        counts[name] = left - 1
        return true
    }
}
