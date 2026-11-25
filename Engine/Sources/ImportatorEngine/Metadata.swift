import Foundation
import ImageIO

/// What Importator knows about one file. Dates are kept as ExifTool/Exif strings
/// (`yyyy:MM:dd HH:mm:ss`), without time zone.
public struct Metadata: Hashable, Sendable, Codable {
    /// The content type: ImageIO's type for photos (a phone's `.jpg` can be HEIC), the
    /// extension for videos.
    public var contentType: String?
    public var exifDate: String?  // DateTimeOriginal in the Exif IFD
    public var ifd0Date: String?  // DateTimeOriginal in IFD0 (Xiaomi DNGs)
    public var xmpDate: String?  // XMP CreateDate
    public var subseconds: String?
    public var make: String?
    public var model: String?
    public var width: Int?
    public var height: Int?
    public var duration: Double?  // videos, seconds
    public var unreadable = false

    public init() {}

    /// The capture time used for the duplicate check: an unfixed DNG (IFD0) matches its fixed
    /// copy (Exif IFD).
    public var captureDate: String? { exifDate ?? ifd0Date ?? xmpDate }

    /// "no date": no DateTimeOriginal in the Exif IFD (videos have their own date).
    public var hasNoDate: Bool { exifDate == nil }
}

/// Where a missing capture time would come from (SPEC, Missing capture time).
public enum DateFix: Hashable, Sendable {
    case notNeeded
    case ifd0(String)  // green
    case xmp(String)  // green
    case fileName(String)  // orange
    case modificationDate(String)  // orange

    public var date: String? {
        switch self {
        case .notNeeded: nil
        case .ifd0(let d), .xmp(let d), .fileName(let d), .modificationDate(let d): d
        }
    }

    /// From the file itself (green) or guessed (orange).
    public var isGuess: Bool {
        switch self {
        case .fileName, .modificationDate: true
        default: false
        }
    }
}

/// Reads metadata with ImageIO where it can (fast), and with ExifTool where ImageIO misses:
/// photos without an Exif date (IFD0 and XMP dates) and all videos.
public final class MetadataReader {
    private let exifTool: ExifTool
    public static let batchSize = 200

    public init(exifTool: ExifTool) {
        self.exifTool = exifTool
    }

    public func read(_ files: [MediaFile], onProgress: (Int) -> Void = { _ in }) throws -> [MediaFile: Metadata] {
        let photos = files.filter { $0.kind == .photo }
        let videos = files.filter { $0.kind == .video }

        // In blocks, so a long read can be stopped and reports progress.
        var result: [MediaFile: Metadata] = [:]
        for block in photos.chunked(500) {
            try Task.checkCancellation()
            result.merge(Self.readWithImageIO(Array(block))) { a, _ in a }
            onProgress(result.count)
        }

        let missing = photos.filter { result[$0]?.exifDate == nil }
        for batch in missing.chunked(Self.batchSize) {
            try Task.checkCancellation()
            let found = try exifTool.readJSON(batch.map(\.url), options: [
                "-G1", "-fast2", "-IFD0:DateTimeOriginal", "-XMP-xmp:CreateDate",
                "-IFD0:Make", "-IFD0:Model", "-File:FileType",
            ])
            for file in batch {
                var metadata = result[file] ?? Metadata()
                if let tags = found[file.path] {
                    metadata.ifd0Date = Self.date(tags["IFD0:DateTimeOriginal"])
                    metadata.xmpDate = Self.date(tags["XMP-xmp:CreateDate"])
                    if metadata.unreadable {
                        metadata.make = Self.text(tags["IFD0:Make"])
                        metadata.model = Self.text(tags["IFD0:Model"])
                        metadata.contentType = Self.text(tags["File:FileType"])
                    }
                }
                result[file] = metadata
            }
        }

        for batch in videos.chunked(Self.batchSize) {
            try Task.checkCancellation()
            let found = try exifTool.readJSON(batch.map(\.url), options: [
                "-G0", "-n", "-QuickTime:CreateDate", "-QuickTime:Duration", "-QuickTime:ImageWidth",
                "-QuickTime:ImageHeight", "-QuickTime:Make", "-QuickTime:Model",
                "-QuickTime:AndroidMake", "-QuickTime:AndroidModel", "-EXIF:Make", "-EXIF:Model",
            ])
            for file in batch {
                var metadata = Metadata()
                metadata.contentType = file.fileExtension
                if let tags = found[file.path] {
                    metadata.exifDate = Self.date(tags["QuickTime:CreateDate"])
                    metadata.duration = (tags["QuickTime:Duration"] as? NSNumber)?.doubleValue
                    metadata.width = (tags["QuickTime:ImageWidth"] as? NSNumber)?.intValue
                    metadata.height = (tags["QuickTime:ImageHeight"] as? NSNumber)?.intValue
                    // Fuji keeps its camera in an EXIF block inside the MOV.
                    metadata.make = Self.text(tags["QuickTime:Make"]) ?? Self.text(tags["QuickTime:AndroidMake"])
                        ?? Self.text(tags["EXIF:Make"])
                    metadata.model = Self.text(tags["QuickTime:Model"]) ?? Self.text(tags["QuickTime:AndroidModel"])
                        ?? Self.text(tags["EXIF:Model"])
                } else {
                    metadata.unreadable = true
                }
                result[file] = metadata
            }
            onProgress(result.count)
        }
        return result
    }

    /// ImageIO reads only the headers; files are read in parallel.
    static func readWithImageIO(_ files: [MediaFile]) -> [MediaFile: Metadata] {
        let results = LockedArray<Metadata>(count: files.count)
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            autoreleasepool { results[index] = readWithImageIO(files[index].url) }
        }
        return Dictionary(uniqueKeysWithValues: zip(files, results.values))
    }

    static func readWithImageIO(_ url: URL) -> Metadata {
        var metadata = Metadata()
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else {
            metadata.unreadable = true
            return metadata
        }
        metadata.contentType = CGImageSourceGetType(source) as String?
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        metadata.exifDate = date(exif[kCGImagePropertyExifDateTimeOriginal])
        metadata.subseconds = text(exif[kCGImagePropertyExifSubsecTimeOriginal])
        metadata.make = text(tiff[kCGImagePropertyTIFFMake])
        metadata.model = text(tiff[kCGImagePropertyTIFFModel])
        metadata.width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        metadata.height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        return metadata
    }

    /// The first 19 characters of a date (`yyyy:MM:dd HH:mm:ss`): drops subseconds and zones,
    /// which ExifTool adds to XMP dates. Empty or zero dates count as none.
    static func date(_ value: Any?) -> String? {
        guard let text = text(value), text.count >= 19 else { return nil }
        let date = String(text.prefix(19))
        guard date.range(of: #"^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil,
              !date.hasPrefix("0000") else { return nil }
        return date
    }

    static func text(_ value: Any?) -> String? {
        guard let value else { return nil }
        let text = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return text.isEmpty ? nil : text
    }

    // MARK: Missing capture time

    /// Where the date for a "no date" file would come from, in the spec's order.
    public static func dateFix(for file: MediaFile, _ metadata: Metadata) -> DateFix {
        guard file.kind == .photo, metadata.hasNoDate else { return .notNeeded }
        if let date = metadata.ifd0Date { return .ifd0(date) }
        if let date = metadata.xmpDate { return .xmp(date) }
        let modified = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let date = dateInFileName(file.url.deletingPathExtension().lastPathComponent, modified: modified) {
            return .fileName(date)
        }
        if let modified { return .modificationDate(exifFormat(modified)) }
        return .notNeeded
    }

    /// `IMG_20261003_134702`, `PXL_20261003_134702123` → that date and time. `20260621-CAM52198`
    /// (a date only) → that date, with the time of the modification date if it's the same day,
    /// else midnight.
    static func dateInFileName(_ name: String, modified: Date? = nil) -> String? {
        let withTime = #"(?<!\d)((?:19|20)\d{2})(\d{2})(\d{2})[_-]?(\d{2})(\d{2})(\d{2})"#
        if let parts = match(withTime, in: name), valid(parts) {
            return "\(parts[0]):\(parts[1]):\(parts[2]) \(parts[3]):\(parts[4]):\(parts[5])"
        }
        let dateOnly = #"(?<!\d)((?:19|20)\d{2})(\d{2})(\d{2})(?!\d)"#
        if let parts = match(dateOnly, in: name), valid(parts + ["00", "00", "00"]) {
            let day = "\(parts[0]):\(parts[1]):\(parts[2])"
            if let modified {
                let stamp = exifFormat(modified)
                if stamp.hasPrefix(day) { return stamp }
            }
            return day + " 00:00:00"
        }
        return nil
    }

    private static func match(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<found.numberOfRanges).compactMap { Range(found.range(at: $0), in: text).map { String(text[$0]) } }
    }

    private static func valid(_ parts: [String]) -> Bool {
        let n = parts.compactMap(Int.init)
        guard n.count == 6 else { return false }
        return (1...12).contains(n[1]) && (1...31).contains(n[2]) && n[3] < 24 && n[4] < 60 && n[5] < 60
    }

    static func exifFormat(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// An array filled from several threads at once, one index each.
final class LockedArray<Element>: @unchecked Sendable {
    private var storage: [Element?]
    private let lock = NSLock()

    init(count: Int) { storage = Array(repeating: nil, count: count) }

    subscript(index: Int) -> Element? {
        get { lock.lock(); defer { lock.unlock() }; return storage[index] }
        set { lock.lock(); storage[index] = newValue; lock.unlock() }
    }

    var values: [Element] { lock.lock(); defer { lock.unlock() }; return storage.map { $0! } }
}

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
