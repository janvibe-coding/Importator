import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ImportatorEngine

// MARK: Helpers

func makeTempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("importator-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func touch(_ folder: URL, _ names: [String]) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in names { try Data().write(to: folder.appendingPathComponent(name)) }
}

/// A small JPEG with an Exif capture time, camera and a colour that sets its image data.
func writeJPEG(_ url: URL, date: String?, subseconds: String? = nil, model: String = "X-E5", shade: CGFloat = 0.5) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: shade, green: 0.2, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    var exif: [CFString: Any] = [:]
    if let date { exif[kCGImagePropertyExifDateTimeOriginal] = date }
    if let subseconds { exif[kCGImagePropertyExifSubsecTimeOriginal] = subseconds }
    let properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: exif,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "FUJIFILM", kCGImagePropertyTIFFModel: model],
    ]
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
}

let testData = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Importator-testdata")
let hasTestData = FileManager.default.fileExists(atPath: testData.appendingPathComponent("dng").path)

// MARK: Scanner and cells

@Test func pairsRawWithJPGOfSameNameOnly() throws {
    let folder = try makeTempFolder()
    try touch(folder, ["CAM1.RAF", "cam1.jpg", "IMG_2.dng", "IMG_2.JPG", "IMG_3.dng", "CLIP.MOV", "only.jpg",
                       "CAM1.xmp", "notes.txt", ".hidden.jpg"])
    try touch(folder.appendingPathComponent("CAM1.photo-edit"), ["inner.jpg"])
    let found = SourceScanner.scan([folder], recursive: true)
    #expect(found.files.count == 7)
    let tags = SourceScanner.cells(found.files).map(\.formatTag).sorted()
    #expect(tags == ["DNG", "DNG+JPG", "JPG", "MOV", "RAF+JPG"])
}

@Test func flatScanSkipsSubfolders() throws {
    let folder = try makeTempFolder()
    try touch(folder, ["a.jpg"])
    try touch(folder.appendingPathComponent("sub"), ["b.jpg"])
    #expect(SourceScanner.scan([folder], recursive: false).files.count == 1)
    let deep = SourceScanner.scan([folder], recursive: true)
    #expect(deep.files.count == 2)
    #expect(deep.folders.contains(folder.appendingPathComponent("sub").folderKey))
}

@Test func folderKeysCompareInNFC() {
    let decomposed = URL(fileURLWithPath: "/x/Noe\u{0308}l 2013")
    let composed = URL(fileURLWithPath: "/x/No\u{00EB}l 2013/")
    #expect(decomposed.folderKey == composed.folderKey)
}

// MARK: Dates

@Test func datesInFileNames() {
    #expect(MetadataReader.dateInFileName("IMG_20261003_134702") == "2026:10:03 13:47:02")
    #expect(MetadataReader.dateInFileName("PXL_20261003_134702123") == "2026:10:03 13:47:02")
    #expect(MetadataReader.dateInFileName("20260621-CAM52198") == "2026:06:21 00:00:00")
    #expect(MetadataReader.dateInFileName("CAM52198") == nil)
    #expect(MetadataReader.dateInFileName("IMG_20261399_134702") == nil)
}

@Test func dateOnlyNameTakesTimeFromSameDayFileDate() {
    var parts = DateComponents()
    (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 6, 21, 14, 3, 9)
    let sameDay = Calendar.current.date(from: parts)!
    #expect(MetadataReader.dateInFileName("20260621-CAM52198", modified: sameDay) == "2026:06:21 14:03:09")
    let otherDay = sameDay.addingTimeInterval(3 * 86400)
    #expect(MetadataReader.dateInFileName("20260621-CAM52198", modified: otherDay) == "2026:06:21 00:00:00")
}

@Test func dateStringsAreCutToSeconds() {
    #expect(MetadataReader.date("2026:10:03 13:47:02+02:00") == "2026:10:03 13:47:02")
    #expect(MetadataReader.date("2026:10:03 13:47:02.123") == "2026:10:03 13:47:02")
    #expect(MetadataReader.date("0000:00:00 00:00:00") == nil)
    #expect(MetadataReader.date("") == nil)
}

@Test func dateFixOrder() throws {
    let file = MediaFile(url: URL(fileURLWithPath: "/nowhere/IMG_20261003_134702.dng"), kind: .photo)
    var metadata = Metadata()
    metadata.exifDate = "2026:10:03 13:47:02"
    #expect(MetadataReader.dateFix(for: file, metadata) == .notNeeded)
    metadata.exifDate = nil
    metadata.xmpDate = "2026:10:03 13:47:01"
    #expect(MetadataReader.dateFix(for: file, metadata) == .xmp("2026:10:03 13:47:01"))
    metadata.ifd0Date = "2026:10:03 13:47:02"
    #expect(MetadataReader.dateFix(for: file, metadata) == .ifd0("2026:10:03 13:47:02"))
    #expect(MetadataReader.dateFix(for: file, Metadata()) == .fileName("2026:10:03 13:47:02"))
}

// MARK: Fingerprints

@Test func jpegFingerprintIgnoresMetadataWrites() throws {
    let folder = try makeTempFolder()
    let original = folder.appendingPathComponent("a.jpg")
    let rated = folder.appendingPathComponent("b.jpg")
    try writeJPEG(original, date: "2026:09:20 20:48:25")
    try FileManager.default.copyItem(at: original, to: rated)
    let tool = try ExifTool()
    defer { tool.close() }
    try tool.run(["-overwrite_original", "-XMP-xmp:Rating=4", "-XMP-xmpDM:Pick=1", rated.path])
    #expect(try Data(contentsOf: original) != Data(contentsOf: rated))
    #expect(try Fingerprint.compute(original, method: .jpegImageData) == Fingerprint.compute(rated, method: .jpegImageData))
    #expect(try Fingerprint.compute(original, method: .wholeFile) != Fingerprint.compute(rated, method: .wholeFile))
}

@Test func jpegFingerprintSeesDifferentPictures() throws {
    let folder = try makeTempFolder()
    try writeJPEG(folder.appendingPathComponent("a.jpg"), date: "2026:09:20 20:48:25", shade: 0.1)
    try writeJPEG(folder.appendingPathComponent("b.jpg"), date: "2026:09:20 20:48:25", shade: 0.9)
    #expect(try Fingerprint.compute(folder.appendingPathComponent("a.jpg"), method: .jpegImageData)
        != Fingerprint.compute(folder.appendingPathComponent("b.jpg"), method: .jpegImageData))
}

@Test func nonJPEGIsRefused() {
    #expect(throws: Fingerprint.FingerprintError.notAJPEG) { try Fingerprint.jpegImageData(Data([1, 2, 3, 4, 5])) }
    #expect(throws: Fingerprint.FingerprintError.notATIFF) { try Fingerprint.dngImageData(Data([1, 2, 3, 4, 5, 6, 7, 8])) }
}

@Test(.enabled(if: hasTestData)) func dngFingerprintSurvivesDateFix() throws {
    let folder = try makeTempFolder()
    let source = testData.appendingPathComponent("dng/IMG_20261003_134702.dng")
    let copy = folder.appendingPathComponent("IMG_20261003_134702.dng")
    try FileManager.default.copyItem(at: source, to: copy)
    let tool = try ExifTool()
    defer { tool.close() }
    try tool.run(["-P", "-overwrite_original", "-ExifIFD:DateTimeOriginal<IFD0:DateTimeOriginal",
                  "-ExifIFD:CreateDate<IFD0:DateTimeOriginal", copy.path])
    #expect(try Fingerprint.compute(source, method: .dngImageData) == Fingerprint.compute(copy, method: .dngImageData))

    let files = [MediaFile(url: source, kind: .photo), MediaFile(url: copy, kind: .photo)]
    let metadata = try MetadataReader(exifTool: tool).read(files)
    #expect(metadata[files[0]]!.ifd0Date == "2026:10:03 13:47:02")
    #expect(metadata[files[1]]!.exifDate == "2026:10:03 13:47:02")
    #expect(MatchKey(files[0], metadata[files[0]]!) == MatchKey(files[1], metadata[files[1]]!))
}

// MARK: Duplicate check

@Test func findsDuplicatesByMetadataNotName() throws {
    let root = try makeTempFolder()
    let card = root.appendingPathComponent("card")
    let library = root.appendingPathComponent("library")
    try writeJPEG(card.appendingPathComponent("CAM0001.JPG"), date: "2026:09:20 20:48:25", subseconds: "24")
    try writeJPEG(card.appendingPathComponent("CAM0002.JPG"), date: "2026:09:20 20:48:26")
    try writeJPEG(card.appendingPathComponent("CAM0003.JPG"), date: "2026:09:20 20:48:25", subseconds: "24", model: "X-T5")
    try writeJPEG(card.appendingPathComponent("NODATE.JPG"), date: nil)
    // Renamed copy of CAM0001 in the library; CAM0002's name exists there with another picture.
    try FileManager.default.createDirectory(at: library.appendingPathComponent("autumn"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: card.appendingPathComponent("CAM0001.JPG"),
                                     to: library.appendingPathComponent("autumn/20260920-CAM0001.JPG"))
    try writeJPEG(library.appendingPathComponent("summer/CAM0002.JPG"), date: "2026:07:01 10:00:00")
    try writeJPEG(library.appendingPathComponent("summer/NODATE.JPG"), date: nil)

    // Undated: matched on the guessed date (file date), which differs here.
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_790_000_000)],
                                          ofItemAtPath: library.appendingPathComponent("summer/NODATE.JPG").path)

    let tool = try ExifTool()
    defer { tool.close() }
    let report = try ImportScanner(exifTool: tool).scan(sources: [card], scope: library, fingerprints: false)
    let byName = Dictionary(uniqueKeysWithValues: report.results.values.map { ($0.file.url.lastPathComponent, $0) })
    #expect(byName["CAM0001.JPG"]!.existing.map(\.lastPathComponent) == ["20260920-CAM0001.JPG"])
    #expect(!byName["CAM0002.JPG"]!.isDuplicate)
    #expect(!byName["CAM0003.JPG"]!.isDuplicate)  // other camera
    #expect(!byName["NODATE.JPG"]!.isDuplicate)  // other guessed date
}

@Test func undatedFilesMatchOnTheirGuessedDate() throws {
    let root = try makeTempFolder()
    let card = root.appendingPathComponent("card")
    let library = root.appendingPathComponent("library")
    try writeJPEG(card.appendingPathComponent("scan.jpg"), date: nil)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: card.appendingPathComponent("scan.jpg"), to: library.appendingPathComponent("renamed.jpg"))

    let tool = try ExifTool()
    defer { tool.close() }
    let result = try ImportScanner(exifTool: tool).scan(sources: [card], scope: library, fingerprints: true).results.values.first!
    #expect(result.existing.map(\.lastPathComponent) == ["renamed.jpg"])
    #expect(result.dateFix.isGuess)
}

@Test func fingerprintsOverruleAMetadataMatch() throws {
    let root = try makeTempFolder()
    let card = root.appendingPathComponent("card")
    let library = root.appendingPathComponent("library")
    // Same second, no subseconds, different picture: the Xiaomi limit.
    try writeJPEG(card.appendingPathComponent("a.jpg"), date: "2026:09:20 20:48:25", shade: 0.1)
    try writeJPEG(library.appendingPathComponent("b.jpg"), date: "2026:09:20 20:48:25", shade: 0.9)

    let tool = try ExifTool()
    defer { tool.close() }
    let scanner = ImportScanner(exifTool: tool)
    #expect(try scanner.scan(sources: [card], scope: library, fingerprints: false).results.values.first!.isDuplicate)
    #expect(try !scanner.scan(sources: [card], scope: library, fingerprints: true).results.values.first!.isDuplicate)
}

@Test func sourceInsideScopeDoesNotFindItself() throws {
    let library = try makeTempFolder()
    let source = library.appendingPathComponent("import")
    try writeJPEG(source.appendingPathComponent("a.jpg"), date: "2026:09:20 20:48:25")
    try writeJPEG(source.appendingPathComponent("sub/b.jpg"), date: "2026:09:20 20:48:26")
    try FileManager.default.copyItem(at: source.appendingPathComponent("sub/b.jpg"),
                                     to: library.appendingPathComponent("b-copy.jpg"))

    let tool = try ExifTool()
    defer { tool.close() }
    let report = try ImportScanner(exifTool: tool).scan(sources: [source], scope: library, fingerprints: true)
    let byName = Dictionary(uniqueKeysWithValues: report.results.values.map { ($0.file.url.lastPathComponent, $0) })
    #expect(!byName["a.jpg"]!.isDuplicate)
    #expect(byName["b.jpg"]!.existing.map(\.lastPathComponent) == ["b-copy.jpg"])
}

// MARK: Sidebar

@Test func readsSidebarFolders() throws {
    let list: [String: Any] = [
        "version": 3,
        "directories": [["url": ["relative": "file:///Volumes/photos/01%20Library/"]]],
        "somethingNew": true,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
    #expect(try SidebarReader.folders(inList: data).map(\.path) == ["/Volumes/photos/01 Library"])
    let old = try PropertyListSerialization.data(fromPropertyList: ["version": 2, "directories": []], format: .binary, options: 0)
    #expect(throws: SidebarReader.ReadError.unsupportedVersion) { try SidebarReader.folders(inList: old) }
}

// MARK: Cells in the grid

@Test func halfFoundCellImportsOnlyTheMissingFile() {
    let raw = MediaFile(url: URL(fileURLWithPath: "/card/IMG_1.dng"), kind: .photo)
    let jpg = MediaFile(url: URL(fileURLWithPath: "/card/IMG_1.jpg"), kind: .photo)
    let cell = Cell(files: [raw, jpg])
    func result(_ file: MediaFile, found: Bool) -> FileResult {
        FileResult(file: file, metadata: Metadata(), dateFix: .notNeeded,
                   existing: found ? [URL(fileURLWithPath: "/lib/raw/IMG_1.dng")] : [])
    }
    let half = [raw: result(raw, found: true), jpg: result(jpg, found: false)]
    #expect(!cell.isFullyFound(half))
    #expect(cell.filesToImport(half) == [jpg])
    let both = [raw: result(raw, found: true), jpg: result(jpg, found: true)]
    #expect(cell.isFullyFound(both))
    #expect(cell.filesToImport(both) == [raw, jpg])
}
