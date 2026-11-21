import Foundation
import Testing
@testable import ImportatorEngine

private func sha(_ url: URL) throws -> String { try Fingerprint.compute(url, method: .wholeFile) }

/// Scans `card` against `library` and imports everything new into `destination`.
private func importAll(
    _ tool: ExifTool, card: URL, library: URL, destination: URL, options: ImportOptions
) throws -> (ScanReport, ImportOutcome) {
    let report = try ImportScanner(exifTool: tool).scan(sources: [card], scope: library, fingerprints: false)
    let selected = Set(report.results.values.filter { !$0.isDuplicate }.map(\.file))
    let outcome = try Copier(exifTool: tool).run(
        cells: report.cells, results: report.results, selected: selected,
        sourceFolders: [card], destination: destination, options: options
    )
    return (report, outcome)
}

private func names(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

@Test func renamesPairsAlikeAndKeepsDatesAndSource() throws {
    let root = try makeTempFolder()
    let card = root.appendingPathComponent("card/DCIM/100_FUJI")
    let destination = root.appendingPathComponent("library/autumn 26")
    try writeJPEG(card.appendingPathComponent("CAM54016.JPG"), date: "2026:10:03 13:47:02")
    try FileManager.default.copyItem(at: card.appendingPathComponent("CAM54016.JPG"),
                                     to: card.appendingPathComponent("CAM54016.RAF"))  // stands in for the RAW
    let old = Date(timeIntervalSince1970: 1_790_000_000)
    try FileManager.default.setAttributes([.modificationDate: old, .creationDate: old],
                                          ofItemAtPath: card.appendingPathComponent("CAM54016.RAF").path)
    let before = try sha(card.appendingPathComponent("CAM54016.RAF"))

    let tool = try ExifTool()
    defer { tool.close() }
    let (_, outcome) = try importAll(tool, card: card, library: root.appendingPathComponent("library"),
                                     destination: destination, options: ImportOptions(rename: true))
    #expect(outcome.failed.isEmpty)
    #expect(try names(destination) == ["20261003-CAM54016.JPG", "20261003-CAM54016.RAF"])
    let copy = destination.appendingPathComponent("20261003-CAM54016.RAF")
    let attributes = try FileManager.default.attributesOfItem(atPath: copy.path)
    #expect(attributes[.modificationDate] as? Date == old)
    #expect(attributes[.creationDate] as? Date == old)
    #expect(try sha(copy) == before)
    #expect(try sha(card.appendingPathComponent("CAM54016.RAF")) == before)
}

@Test func takenNameGetsSuffixForTheWholePairAndNothingIsOverwritten() throws {
    let root = try makeTempFolder()
    let card = root.appendingPathComponent("card")
    let destination = root.appendingPathComponent("library/import")
    try writeJPEG(card.appendingPathComponent("A.JPG"), date: "2026:10:03 13:47:02")
    try FileManager.default.copyItem(at: card.appendingPathComponent("A.JPG"), to: card.appendingPathComponent("A.RAF"))
    // Only the RAF's name is taken, by another file.
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("keep me".utf8).write(to: destination.appendingPathComponent("a.raf"))

    let tool = try ExifTool()
    defer { tool.close() }
    let (_, outcome) = try importAll(tool, card: card, library: root.appendingPathComponent("library"),
                                     destination: destination, options: ImportOptions())
    #expect(outcome.copied.count == 2)
    #expect(try names(destination) == ["A-2.JPG", "A-2.RAF", "a.raf"])
    #expect(try String(contentsOf: destination.appendingPathComponent("a.raf"), encoding: .utf8) == "keep me")
}

@Test func copyChoiceAppliesToPairsOnly() throws {
    let root = try makeTempFolder()
    let card = root.appendingPathComponent("card")
    try writeJPEG(card.appendingPathComponent("P.JPG"), date: "2026:10:03 13:47:02")
    try FileManager.default.copyItem(at: card.appendingPathComponent("P.JPG"), to: card.appendingPathComponent("P.RAF"))
    try writeJPEG(card.appendingPathComponent("SOLO.JPG"), date: "2026:10:03 13:47:03")

    let tool = try ExifTool()
    defer { tool.close() }
    for (choice, expected) in [(CopyChoice.raw, ["P.RAF", "SOLO.JPG"]), (.jpg, ["P.JPG", "SOLO.JPG"]),
                               (.rawAndJPG, ["P.JPG", "P.RAF", "SOLO.JPG"])] {
        let destination = root.appendingPathComponent("out-\(choice.rawValue)/import")
        _ = try importAll(tool, card: card, library: destination.deletingLastPathComponent(),
                          destination: destination, options: ImportOptions(copy: choice))
        #expect(try names(destination) == expected)
    }
}

@Test func leftoverTemporaryFilesAreRemoved() throws {
    let root = try makeTempFolder()
    let card = root.appendingPathComponent("card")
    let destination = root.appendingPathComponent("library/import")
    try writeJPEG(card.appendingPathComponent("A.JPG"), date: "2026:10:03 13:47:02")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data().write(to: destination.appendingPathComponent(".importator-1234.JPG"))
    try Data().write(to: destination.appendingPathComponent(".importator-5678.dng_exiftool_tmp"))

    let tool = try ExifTool()
    defer { tool.close() }
    let (_, outcome) = try importAll(tool, card: card, library: root.appendingPathComponent("library"),
                                     destination: destination, options: ImportOptions())
    #expect(outcome.leftoversRemoved == 2)
    #expect(try names(destination) == ["A.JPG"])
}

@Test func fixesMissingDateOnTheCopyOnly() throws {
    let root = try makeTempFolder()
    let card = root.appendingPathComponent("card")
    let destination = root.appendingPathComponent("library/import")
    let source = card.appendingPathComponent("IMG_20261003_134702.jpg")
    try writeJPEG(source, date: nil)
    let before = try sha(source)

    let tool = try ExifTool()
    defer { tool.close() }
    let (report, outcome) = try importAll(tool, card: card, library: root.appendingPathComponent("library"),
                                          destination: destination, options: ImportOptions(fixDates: true))
    #expect(report.results.values.first!.dateFix == .fileName("2026:10:03 13:47:02"))
    #expect(outcome.datesFixed == 1)
    let copy = destination.appendingPathComponent("IMG_20261003_134702.jpg")
    #expect(MetadataReader.readWithImageIO(copy).exifDate == "2026:10:03 13:47:02")
    #expect(try Fingerprint.compute(copy, method: .jpegImageData) == Fingerprint.compute(source, method: .jpegImageData))
    #expect(try sha(source) == before)
    #expect(MetadataReader.readWithImageIO(source).exifDate == nil)
}

@Test func withoutFixTheFileIsCopiedAsItIs() throws {
    let root = try makeTempFolder()
    let card = root.appendingPathComponent("card")
    let destination = root.appendingPathComponent("library/import")
    try writeJPEG(card.appendingPathComponent("IMG_20261003_134702.jpg"), date: nil)

    let tool = try ExifTool()
    defer { tool.close() }
    let (_, outcome) = try importAll(tool, card: card, library: root.appendingPathComponent("library"),
                                     destination: destination, options: ImportOptions())
    #expect(outcome.datesFixed == 0)
    #expect(try sha(destination.appendingPathComponent("IMG_20261003_134702.jpg"))
        == sha(card.appendingPathComponent("IMG_20261003_134702.jpg")))
}

@Test func secondImportCopiesNothing() throws {
    let root = try makeTempFolder()
    let card = root.appendingPathComponent("card")
    let library = root.appendingPathComponent("library")
    try writeJPEG(card.appendingPathComponent("A.JPG"), date: "2026:10:03 13:47:02", subseconds: "12")
    try writeJPEG(card.appendingPathComponent("IMG_20261003_134705.jpg"), date: nil)

    let tool = try ExifTool()
    defer { tool.close() }
    let options = ImportOptions(rename: true, fixDates: true)
    let (_, first) = try importAll(tool, card: card, library: library,
                                   destination: library.appendingPathComponent("autumn"), options: options)
    #expect(first.copied.count == 2)
    let (report, second) = try importAll(tool, card: card, library: library,
                                         destination: library.appendingPathComponent("winter"), options: options)
    // The JPG without a date matches its fixed copy through the date in its name.
    #expect(report.results.values.allSatisfy { $0.isDuplicate })
    #expect(second.copied.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("winter").path))
}

@Test func destinationInsideSourceIsRefused() throws {
    let root = try makeTempFolder()
    let tool = try ExifTool()
    defer { tool.close() }
    #expect(throws: CopierError.destinationInsideSource) {
        try Copier(exifTool: tool).run(cells: [], results: [:], selected: [], sourceFolders: [root],
                                       destination: root.appendingPathComponent("in"), options: ImportOptions())
    }
}

@Test(.enabled(if: hasTestData)) func xiaomiDNGGetsExifDateAndKeepsImageData() throws {
    let root = try makeTempFolder()
    let card = root.appendingPathComponent("card")
    try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
    let source = card.appendingPathComponent("IMG_20261003_134702.dng")
    try FileManager.default.copyItem(at: testData.appendingPathComponent("dng/IMG_20261003_134702.dng"), to: source)
    let destination = root.appendingPathComponent("library/import")

    let tool = try ExifTool()
    defer { tool.close() }
    let (report, outcome) = try importAll(tool, card: card, library: root.appendingPathComponent("library"),
                                          destination: destination, options: ImportOptions(fixDates: true))
    #expect(report.results.values.first!.dateFix == .ifd0("2026:10:03 13:47:02"))
    #expect(outcome.failed.isEmpty && outcome.datesFixed == 1)
    let copy = destination.appendingPathComponent("IMG_20261003_134702.dng")
    #expect(MetadataReader.readWithImageIO(copy).exifDate == "2026:10:03 13:47:02")
    #expect(try Fingerprint.compute(copy, method: .dngImageData) == Fingerprint.compute(source, method: .dngImageData))
}

@Test func fixesDatesInPlaceAndKeepsFileDates() throws {
    let folder = try makeTempFolder().appendingPathComponent("library/autumn")
    let undated = folder.appendingPathComponent("IMG_20261003_134702.jpg")
    let dated = folder.appendingPathComponent("CAM1.JPG")
    try writeJPEG(undated, date: nil)
    try writeJPEG(dated, date: "2026:10:03 13:47:05")
    let old = Date(timeIntervalSince1970: 1_790_000_000)
    try FileManager.default.setAttributes([.modificationDate: old, .creationDate: old], ofItemAtPath: undated.path)
    let datedBefore = try Data(contentsOf: dated)

    let tool = try ExifTool()
    defer { tool.close() }
    let source = try ImportScanner(exifTool: tool).readSource([FolderPick(url: folder.deletingLastPathComponent(), recursive: true)])
    let items = DateFixer.candidates(in: source)
    #expect(items.map(\.file.url.lastPathComponent) == ["IMG_20261003_134702.jpg"])
    let outcome = try DateFixer(exifTool: tool).fix(items, metadata: source.metadata)
    #expect(outcome.fixed.count == 1 && outcome.failed.isEmpty)
    #expect(MetadataReader.readWithImageIO(undated).exifDate == "2026:10:03 13:47:02")
    let attributes = try FileManager.default.attributesOfItem(atPath: undated.path)
    #expect(attributes[.modificationDate] as? Date == old)
    #expect(attributes[.creationDate] as? Date == old)
    #expect(try Data(contentsOf: dated) == datedBefore)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["CAM1.JPG", "IMG_20261003_134702.jpg"])
}

@Test func sidebarFoldersComeInSidebarOrder() throws {
    let list: [String: Any] = [
        "version": 3,
        "directories": [
            ["id": [1, ["B"]], "url": ["relative": "file:///Volumes/photos/jpg%20library/"]],
            ["id": [1, ["A"]], "url": ["relative": "file:///Volumes/photos/library/"]],
        ],
        "directoryOrder": [[1, ["A"]], [1, ["B"]]],
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
    #expect(try SidebarReader.folders(inList: data).map(\.lastPathComponent) == ["library", "jpg library"])
}
