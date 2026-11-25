import Foundation

/// Runs the engine off the main thread. One ExifTool process, used by one task at a time.
actor EngineWorker {
    private var exifTool: ExifTool?
    private var scanner: ImportScanner?
    private let cacheFolder: URL?

    init(cacheFolder: URL? = nil) {
        self.cacheFolder = cacheFolder
    }

    private func tool() throws -> ExifTool {
        if let exifTool { return exifTool }
        let made = try ExifTool()
        exifTool = made
        scanner = ImportScanner(exifTool: made, cacheFolder: cacheFolder)
        return made
    }

    private func importScanner() throws -> ImportScanner {
        _ = try tool()
        return scanner!
    }

    func readSource(_ picks: [FolderPick]) throws -> SourceRead {
        try importScanner().readSource(picks)
    }

    func readScope(_ scope: URL, progress: @escaping @Sendable (Int, Int) -> Void) throws -> ScopeIndex {
        try importScanner().readScope(scope, onProgress: progress)
    }

    func match(_ source: SourceRead, in scope: ScopeIndex, fingerprints: Bool,
               progress: @escaping @Sendable (Int, Int) -> Void) throws -> [MediaFile: FileResult] {
        try importScanner().match(source, in: scope, fingerprints: fingerprints, onProgress: progress)
    }

    func runImport(cells: [Cell], results: [MediaFile: FileResult], selected: Set<MediaFile>,
                   sourceFolders: [URL], destination: URL, options: ImportOptions,
                   progress: @escaping @Sendable (ImportProgress) -> Void) throws -> ImportOutcome {
        try Copier(exifTool: tool()).run(
            cells: cells, results: results, selected: selected, sourceFolders: sourceFolders,
            destination: destination, options: options, onProgress: progress
        )
    }

    func fixDates(_ items: [(file: MediaFile, fix: DateFix)], metadata: [MediaFile: Metadata],
                  progress: @escaping @Sendable (Int, Int) -> Void) throws -> DateFixer.Outcome {
        try DateFixer(exifTool: tool()).fix(items, metadata: metadata, onProgress: progress)
    }
}
