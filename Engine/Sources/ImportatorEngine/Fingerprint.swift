import CryptoKit
import Foundation

/// Content fingerprints, used only to confirm a metadata match (SPEC, Duplicate check).
public enum Fingerprint {
    public enum Method: Sendable, Equatable {
        case wholeFile  // camera RAW, video, HEIC: nothing writes into them
        case jpegImageData  // from the first SOS marker to the end: Photomator writes into JPGs
        case dngImageData  // the main image's strips or tiles: Importator writes a date into DNGs
    }

    public enum FingerprintError: Error, Equatable, CustomStringConvertible {
        case notAJPEG
        case notATIFF
        case noMainImage

        public var description: String {
            switch self {
            case .notAJPEG: "The file's JPG structure couldn't be read, so its image data couldn't be checked."
            case .notATIFF: "The file's DNG structure couldn't be read, so its image data couldn't be checked."
            case .noMainImage: "No main image was found in the DNG, so its image data couldn't be checked."
            }
        }
    }

    /// Decided by content, not extension: a phone's `.jpg` can be HEIC.
    public static func method(for file: MediaFile, _ metadata: Metadata) -> Method {
        switch metadata.contentType {
        case "public.jpeg": .jpegImageData
        case "com.adobe.raw-image": .dngImageData
        default: .wholeFile
        }
    }

    public static func compute(_ url: URL, method: Method) throws -> String {
        switch method {
        case .wholeFile: try wholeFile(url)
        case .jpegImageData: try jpegImageData(Data(contentsOf: url))
        case .dngImageData: try dngImageData(Data(contentsOf: url))
        }
    }

    static func wholeFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hex(hash.finalize())
    }

    /// SHA-256 from the first Start Of Scan marker to the end of the file. Everything before it
    /// (Exif, XMP, ICC) is metadata.
    static func jpegImageData(_ data: Data) throws -> String {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw FingerprintError.notAJPEG }
        var i = 2
        while i + 4 <= bytes.count {
            guard bytes[i] == 0xFF else { throw FingerprintError.notAJPEG }
            let marker = bytes[i + 1]
            if marker == 0xFF { i += 1; continue }  // fill byte
            if marker == 0xDA {
                return hex(SHA256.hash(data: data[data.startIndex + i ..< data.endIndex]))
            }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            guard length >= 2 else { throw FingerprintError.notAJPEG }
            i += 2 + length
        }
        throw FingerprintError.notAJPEG
    }

    /// SHA-256 of the strips or tiles of the main image: the first IFD (IFD0, then its SubIFDs)
    /// with NewSubfileType 0.
    static func dngImageData(_ data: Data) throws -> String {
        let tiff = try TIFF(data)
        var queue = [tiff.firstIFD]
        var visited = Set<Int>()
        while !queue.isEmpty {
            let offset = queue.removeFirst()
            guard offset > 0, visited.insert(offset).inserted else { continue }
            let tags = try tiff.ifd(at: offset)
            queue += tags[0x14A] ?? []  // SubIFDs
            guard (tags[0xFE]?.first ?? 0) == 0,
                  let offsets = tags[0x144] ?? tags[0x111],
                  let counts = tags[0x145] ?? tags[0x117],
                  offsets.count == counts.count, !offsets.isEmpty else { continue }
            var hash = SHA256()
            for (start, count) in zip(offsets, counts) {
                guard start >= 0, count >= 0, start + count <= data.count else { throw FingerprintError.notATIFF }
                hash.update(data: data[data.startIndex + start ..< data.startIndex + start + count])
            }
            return hex(hash.finalize())
        }
        throw FingerprintError.noMainImage
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Just enough TIFF to find image data: integer tags of one IFD.
private struct TIFF {
    let bytes: [UInt8]
    let littleEndian: Bool
    private(set) var firstIFD = 0

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 8 else { throw Fingerprint.FingerprintError.notATIFF }
        switch (bytes[0], bytes[1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: throw Fingerprint.FingerprintError.notATIFF
        }
        firstIFD = try uint(at: 4, size: 4)
    }

    func uint(at offset: Int, size: Int) throws -> Int {
        guard offset >= 0, offset + size <= bytes.count else { throw Fingerprint.FingerprintError.notATIFF }
        var value = 0
        for k in 0..<size {
            let byte = Int(bytes[offset + (littleEndian ? size - 1 - k : k)])
            value = value << 8 | byte
        }
        return value
    }

    /// The BYTE, SHORT, LONG and IFD values of an IFD's tags.
    func ifd(at offset: Int) throws -> [Int: [Int]] {
        let count = try uint(at: offset, size: 2)
        var tags: [Int: [Int]] = [:]
        for n in 0..<count {
            let entry = offset + 2 + 12 * n
            let tag = try uint(at: entry, size: 2)
            let type = try uint(at: entry + 2, size: 2)
            let values = try uint(at: entry + 4, size: 4)
            let size: Int
            switch type {
            case 1: size = 1
            case 3: size = 2
            case 4, 13: size = 4
            default: continue
            }
            let start = size * values <= 4 ? entry + 8 : try uint(at: entry + 8, size: 4)
            tags[tag] = try (0..<values).map { try uint(at: start + $0 * size, size: size) }
        }
        return tags
    }
}
