import Foundation
import ImportatorEngine

// importator scan --source <folder> [--source <folder> …] --scope <folder> [--fingerprints] [--flat]
// importator info <file> …
// scan and info only read. import copies into the destination; it never changes the source.

let usage = """
usage: importator scan --source <folder> [--source <folder> …] --scope <folder> [--fingerprints] [--flat]
       importator import --source <folder> [--source …] --dest <folder> [--subfolder <name>]
                         [--scope <folder>] [--rename] [--copy raw+jpg|raw|jpg] [--fix-dates]
                         [--fingerprints] [--include-duplicates]
       importator info <file> …
       importator sidebar
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func folderURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage) }
arguments.removeFirst()

func describe(_ fix: DateFix) -> String {
    switch fix {
    case .notNeeded: ""
    case .ifd0(let d): "no date  green  IFD0 \(d)"
    case .xmp(let d): "no date  green  XMP \(d)"
    case .fileName(let d): "no date  orange name \(d)"
    case .modificationDate(let d): "no date  orange file date \(d)"
    }
}

do {
    let exifTool = try ExifTool()
    defer { exifTool.close() }

    switch command {
    case "sidebar":
        for folder in try SidebarReader.folders() { print(folder.path) }

    case "info":
        let files = arguments.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .compactMap { url in MediaTypes.kind(ofExtension: url.pathExtension).map { MediaFile(url: url, kind: $0) } }
        let metadata = try MetadataReader(exifTool: exifTool).read(files)
        for file in files {
            let m = metadata[file]!
            print(file.path)
            print("  type \(m.contentType ?? "-")  \(m.width ?? 0)x\(m.height ?? 0)  \(m.make ?? "-") / \(m.model ?? "-")")
            print("  exif \(m.exifDate ?? "-")  sub \(m.subseconds ?? "-")  ifd0 \(m.ifd0Date ?? "-")  xmp \(m.xmpDate ?? "-")  duration \(m.duration.map { "\($0)" } ?? "-")")
            print("  \(describe(MetadataReader.dateFix(for: file, m)))")
            let method = Fingerprint.method(for: file, m)
            print("  fingerprint \(method): \((try? Fingerprint.compute(file.url, method: method)) ?? "failed")")
        }

    case "scan":
        var sources: [URL] = []
        var scope: URL?
        var fingerprints = false
        var recursive = true
        var i = 0
        func value() -> String {
            i += 1
            guard i < arguments.count, !arguments[i].hasPrefix("--") else { fail(usage) }
            return arguments[i]
        }
        while i < arguments.count {
            switch arguments[i] {
            case "--source": sources.append(folderURL(value()))
            case "--scope": scope = folderURL(value())
            case "--fingerprints": fingerprints = true
            case "--flat": recursive = false
            default: fail(usage)
            }
            i += 1
        }
        guard let scope, !sources.isEmpty else { fail(usage) }

        let start = Date()
        let report = try ImportScanner(exifTool: exifTool).scan(
            sources: sources, recursive: recursive, scope: scope, fingerprints: fingerprints
        )
        let scopePrefix = scope.folderKey

        func place(_ url: URL) -> String {
            let folder = url.deletingLastPathComponent().folderKey
            return folder.hasPrefix(scopePrefix) ? String(folder.dropFirst(scopePrefix.count).dropLast()) : folder
        }

        var newFiles = 0, duplicateFiles = 0, noDate = 0
        for cell in report.cells {
            let results = cell.files.map { report.results[$0]! }
            let state = results.allSatisfy(\.isDuplicate) ? "DUP " : results.contains(where: \.isDuplicate) ? "PART" : "NEW "
            let date = results.compactMap(\.metadata.captureDate).first ?? "-"
            print("\(state)  \(cell.formatTag.padding(toLength: 8, withPad: " ", startingAt: 0))  \(cell.name.padding(toLength: 24, withPad: " ", startingAt: 0))  \(date)")
            for result in results {
                let name = result.file.url.lastPathComponent
                if result.isDuplicate {
                    duplicateFiles += 1
                    print("        \(name): in \(Set(result.existing.map(place)).sorted().joined(separator: ", "))")
                } else {
                    newFiles += 1
                }
                if result.dateFix != .notNeeded {
                    noDate += 1
                    print("        \(name): \(describe(result.dateFix))")
                }
            }
        }
        print("")
        print("\(report.results.count) files in \(report.cells.count) cells: \(duplicateFiles) duplicate, \(newFiles) new, \(noDate) without date. Scope: \(report.scopeFileCount) files.\(fingerprints ? " Fingerprints on." : "")")
        for (label, seconds) in report.timings { print(String(format: "  %@: %.1f s", label, seconds)) }
        print(String(format: "  total: %.1f s", Date().timeIntervalSince(start)))
        if !report.unreadableFolders.isEmpty {
            print("Unreadable: " + report.unreadableFolders.map(\.path).joined(separator: ", "))
        }

    case "import":
        var sources: [URL] = []
        var destination: URL?
        var subfolder: String?
        var scope: URL?
        var options = ImportOptions()
        var fingerprints = false
        var includeDuplicates = false
        var i = 0
        func value() -> String {
            i += 1
            guard i < arguments.count, !arguments[i].hasPrefix("--") else { fail(usage) }
            return arguments[i]
        }
        while i < arguments.count {
            switch arguments[i] {
            case "--source": sources.append(folderURL(value()))
            case "--dest": destination = folderURL(value())
            case "--subfolder": subfolder = value()
            case "--scope": scope = folderURL(value())
            case "--rename": options.rename = true
            case "--fix-dates": options.fixDates = true
            case "--fingerprints": fingerprints = true
            case "--include-duplicates": includeDuplicates = true
            case "--copy":
                guard let choice = CopyChoice(rawValue: value().lowercased()) else { fail(usage) }
                options.copy = choice
            default: fail(usage)
            }
            i += 1
        }
        guard let destination, !sources.isEmpty else { fail(usage) }
        let target = subfolder.map { destination.appendingPathComponent($0, isDirectory: true) } ?? destination
        let checkIn = scope ?? destination.deletingLastPathComponent()

        let start = Date()
        let report = try ImportScanner(exifTool: exifTool).scan(
            sources: sources, scope: checkIn, fingerprints: fingerprints
        )
        let selected = Set(report.results.values.filter { includeDuplicates || !$0.isDuplicate }.map(\.file))
        print("Checked against \(checkIn.path): \(report.results.count - selected.count) of \(report.results.count) files already there.")

        var lastShown = -1
        let outcome = try Copier(exifTool: exifTool).run(
            cells: report.cells, results: report.results, selected: selected,
            sourceFolders: sources, destination: target, options: options
        ) { done, total in
            let percent = total == 0 ? 100 : Int(done * 100 / total)
            if percent / 10 != lastShown / 10 { lastShown = percent; print("  \(percent)%") }
        }

        if outcome.leftoversRemoved > 0 { print("Removed \(outcome.leftoversRemoved) leftover temporary files.") }
        print("Copied \(outcome.copied.count) files to \(target.path), \(outcome.datesFixed) with a date written.")
        for failure in outcome.failed {
            print("FAILED \(failure.source.path): \(failure.reason)")
        }
        print(String(format: "  total: %.1f s", Date().timeIntervalSince(start)))

    default:
        fail(usage)
    }
} catch {
    fail("error: \(error)")
}
