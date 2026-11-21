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

    public init(rename: Bool = false, copy: CopyChoice = .rawAndJPG, fixDates: Bool = false) {
        self.rename = rename
        self.copy = copy
        self.fixDates = fixDates
    }
}

public struct ImportOutcome: Sendable {
    public var copied: [(source: MediaFile, copy: URL)] = []
    public var failed: [(source: MediaFile, reason: String)] = []
    public var datesFixed = 0
    public var leftoversRemoved = 0
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

    public func run(
        cells: [Cell], results: [MediaFile: FileResult], selected: Set<MediaFile>,
        sourceFolders: [URL], destination: URL, options: ImportOptions,
        onProgress: (_ done: Int64, _ total: Int64) -> Void = { _, _ in }
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
        onProgress(0, total)

        for group in groups {
            try Task.checkCancellation()
            let names = Self.names(for: group, results: results, rename: options.rename, taken: &taken)
            for (file, name) in zip(group, names) {
                let result = results[file]
                do {
                    let fixed = try copy(file, to: destination.appendingPathComponent(name),
                                         dateFix: options.fixDates ? result?.dateFix ?? .notNeeded : .notNeeded,
                                         metadata: result?.metadata)
                    outcome.copied.append((file, destination.appendingPathComponent(name)))
                    if fixed { outcome.datesFixed += 1 }
                } catch {
                    outcome.failed.append((file, "\(error)"))
                }
                done += Self.size(of: file.url)
                onProgress(done, total)
            }
        }
        return outcome
    }

    enum CopyError: Error, CustomStringConvertible {
        case dateNotWritten(String)
        case dateNotReadBack
        case imageDataChanged
        case nameTaken

        var description: String {
            switch self {
            case .dateNotWritten(let output): "date not written: \(output)"
            case .dateNotReadBack: "date not found in the copy after writing"
            case .imageDataChanged: "image data changed while writing the date"
            case .nameTaken: "name already taken"
            }
        }
    }

    /// Temp copy → optional date fix and checks → source dates → no-overwrite rename.
    /// Returns whether a date was written.
    private func copy(_ file: MediaFile, to target: URL, dateFix: DateFix, metadata: Metadata?) throws -> Bool {
        let folder = target.deletingLastPathComponent()
        let temp = folder.appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString).\(file.url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }

        try FileManager.default.copyItem(at: file.url, to: temp)

        var fixed = false
        if let date = dateFix.date {
            try Self.writeDate(date, into: temp, original: file, metadata: metadata, exifTool: exifTool)
            fixed = true
        }

        try Self.copyFileDates(from: file.url, to: temp)

        // RENAME_EXCL: fails instead of replacing an existing file.
        guard renamex_np(temp.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw CopyError.nameTaken }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fixed
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
