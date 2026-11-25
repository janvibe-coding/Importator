import Darwin
import Foundation

/// Writes a missing capture time into files that are already in the library. Each file is copied
/// beside itself under a temporary name, the date is written and checked there, and only then
/// does the copy replace the original. The original's creation and modification dates are kept.
public final class DateFixer {
    public struct Outcome: Sendable {
        public var fixed: [MediaFile] = []
        public var failed: [(file: MediaFile, reason: String)] = []
    }

    private let exifTool: ExifTool

    public init(exifTool: ExifTool) {
        self.exifTool = exifTool
    }

    /// The files of a read folder that would get a date, with where it comes from.
    public static func candidates(in source: SourceRead) -> [(file: MediaFile, fix: DateFix)] {
        source.files.compactMap { file in
            guard let fix = source.dateFixes[file], fix != .notNeeded else { return nil }
            return (file, fix)
        }
    }

    public func fix(
        _ items: [(file: MediaFile, fix: DateFix)], metadata: [MediaFile: Metadata],
        onProgress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> Outcome {
        var outcome = Outcome()
        var cleaned = Set<String>()
        for (number, item) in items.enumerated() {
            try Task.checkCancellation()
            let folder = item.file.url.deletingLastPathComponent()
            if cleaned.insert(folder.folderKey).inserted { _ = Copier.removeLeftovers(in: folder) }
            do {
                guard let date = item.fix.date else { continue }
                try Self.fixInPlace(item.file, date: date, metadata: metadata[item.file], exifTool: exifTool)
                outcome.fixed.append(item.file)
            } catch {
                outcome.failed.append((item.file, Copier.explain(error)))
            }
            onProgress(number + 1, items.count)
        }
        return outcome
    }

    /// Writes the date into `file` through a checked temporary copy beside it, which then
    /// replaces it. When anything fails, `file` is left exactly as it was.
    static func fixInPlace(_ file: MediaFile, date: String, metadata: Metadata?, exifTool: ExifTool) throws {
        let folder = file.url.deletingLastPathComponent()
        let temp = folder.appendingPathComponent("\(Copier.tempPrefix)\(UUID().uuidString).\(file.url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.copyItem(at: file.url, to: temp)
        try Copier.writeDate(date, into: temp, original: file, metadata: metadata, exifTool: exifTool)
        try Copier.copyFileDates(from: file.url, to: temp)
        // rename replaces the original in one step: there is never a moment without the file.
        guard rename(temp.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
