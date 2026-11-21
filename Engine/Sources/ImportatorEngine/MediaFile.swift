import Foundation

public enum MediaKind: Sendable, Equatable {
    case photo
    case video
}

/// One photo or video file. A RAW and its JPG are two MediaFiles; only the grid joins them (Cell).
public struct MediaFile: Hashable, Sendable {
    public let url: URL
    public let kind: MediaKind

    public init(url: URL, kind: MediaKind) {
        self.url = url
        self.kind = kind
    }

    public var path: String { url.path }
    public var fileExtension: String { url.pathExtension.lowercased() }
    public var isRaw: Bool { MediaTypes.raw.contains(fileExtension) }
    public var isJPG: Bool { MediaTypes.jpg.contains(fileExtension) }
    /// Base name compared case-insensitively and Unicode-normalised.
    public var pairName: String { url.deletingPathExtension().lastPathComponent.nfc.lowercased() }
    public var folderKey: String { url.deletingLastPathComponent().folderKey }
}

public enum MediaTypes {
    public static let raw: Set<String> = ["raf", "cr2", "cr3", "nef", "arw", "orf", "rw2", "pef", "srw", "dng"]
    public static let jpg: Set<String> = ["jpg", "jpeg"]
    public static let otherImage: Set<String> = ["heic", "heif", "png", "tif", "tiff"]
    public static let video: Set<String> = ["mov", "mp4", "m4v", "avi", "mts", "m2ts", "3gp"]

    public static func kind(ofExtension ext: String) -> MediaKind? {
        let ext = ext.lowercased()
        if raw.contains(ext) || jpg.contains(ext) || otherImage.contains(ext) { return .photo }
        if video.contains(ext) { return .video }
        return nil
    }
}

/// One grid cell: a RAW and its JPG of the same base name, or a single file.
public struct Cell: Hashable, Sendable {
    public let files: [MediaFile]  // RAW first for a pair

    /// `RAF+JPG`, `DNG`, `MOV`, …
    public var formatTag: String {
        files.map { $0.isJPG ? "JPG" : $0.fileExtension.uppercased() }.joined(separator: "+")
    }

    public var name: String { files[0].url.deletingPathExtension().lastPathComponent }
}

extension String {
    /// Unicode NFC, so decomposed folder names (`Noël 2013`) compare equal.
    public var nfc: String { precomposedStringWithCanonicalMapping }
}

extension URL {
    /// A folder's path in one normal form, with a trailing slash, for comparing and prefix checks.
    public var folderKey: String {
        let path = standardizedFileURL.path.nfc
        return path.hasSuffix("/") ? path : path + "/"
    }
}

extension Cell {
    /// Every file of the cell exists in the scope: the cell shows dimmed and unticked.
    public func isFullyFound(_ results: [MediaFile: FileResult]) -> Bool {
        files.allSatisfy { results[$0]?.isDuplicate == true }
    }

    /// The files a ticked cell imports: the ones not found, or all of them when every file was
    /// found (the user ticked a duplicate to import it again).
    public func filesToImport(_ results: [MediaFile: FileResult]) -> [MediaFile] {
        isFullyFound(results) ? files : files.filter { results[$0]?.isDuplicate != true }
    }

    /// The capture time used to sort and group the cell: the first file's capture time, else the
    /// date it would get. Nil when nothing gives one.
    public func sortDate(metadata: [MediaFile: Metadata], dateFixes: [MediaFile: DateFix]) -> String? {
        files.lazy.compactMap { metadata[$0]?.captureDate }.first
            ?? files.lazy.compactMap { dateFixes[$0]?.date }.first
    }
}
