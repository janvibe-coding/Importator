import AppKit
import Combine
import SwiftUI

/// One grid cell as the window shows it.
struct CellInfo: Identifiable {
    let id: String
    let cell: Cell
    let name: String
    let sortDate: String?
    let formatTag: String
    /// The date fixes of the cell's "no date" files; empty when every file has a date.
    let fixes: [DateFix]
    let fullyFound: Bool
    let tooltip: String?
    let thumbnailURL: URL
    let previewURL: URL
    let isVideo: Bool

    var hasNoDate: Bool { !fixes.isEmpty }
}

struct DayGroup: Identifiable {
    let id: String
    let title: String
    let cells: [CellInfo]
}

enum Activity: Equatable {
    case idle
    case readingSource
    case checking(done: Int, total: Int)
    case importing(done: Int64, total: Int64)
}

@MainActor
final class AppModel: ObservableObject {
    private let worker = EngineWorker()
    private let defaults = UserDefaults.standard

    // Source
    @Published private(set) var drives: [FolderNode] = []
    @Published private(set) var sourceFolders: [FolderNode] = []

    // Grid
    @Published private(set) var groups: [DayGroup] = []
    @Published private(set) var allCells: [CellInfo] = []
    @Published private var overrides: [String: Bool] = [:]
    @Published var selection: Set<String> = []
    @Published var previewURL: URL?
    @Published private(set) var previewItems: [URL] = []
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var lastResult: String?
    @Published var failures: [String] = []
    @Published var showFailures = false
    private var anchor: String?

    // Destination
    /// Photomator's sidebar folders, read only from its list.
    @Published private(set) var sidebarFolders: [FolderNode] = []
    @Published private(set) var destinationRoots: [FolderNode] = []
    @Published private(set) var destination: URL?
    @Published private(set) var scope: URL?
    @Published var useSubfolder = false
    @Published var subfolderName = ""
    @Published var rename: Bool { didSet { defaults.set(rename, forKey: "rename") } }
    @Published var copyChoice: CopyChoice { didSet { defaults.set(copyChoice.rawValue, forKey: "copy") } }
    @Published var fixDates: Bool { didSet { defaults.set(fixDates, forKey: "fixDates") } }
    @Published var zoom: Double { didSet { defaults.set(zoom, forKey: "zoom") } }
    @Published var fingerprints = false {
        didSet { if fingerprints != oldValue { refresh(readSource: false, readScope: false) } }
    }

    private var source: SourceRead?
    private var results: [MediaFile: FileResult] = [:]
    private var index: ScopeIndex?
    private var checkTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var observers: [Any] = []

    init() {
        rename = defaults.bool(forKey: "rename")
        copyChoice = CopyChoice(rawValue: defaults.string(forKey: "copy") ?? "") ?? .rawAndJPG
        fixDates = defaults.bool(forKey: "fixDates")
        zoom = defaults.object(forKey: "zoom") as? Double ?? 160
        sourceFolders = (defaults.stringArray(forKey: "sourceFolders") ?? []).map {
            FolderNode(url: URL(fileURLWithPath: $0, isDirectory: true), kind: .folder)
        }
        destinationRoots = (defaults.stringArray(forKey: "destinationFolders") ?? []).map {
            FolderNode(url: URL(fileURLWithPath: $0, isDirectory: true), kind: .folder)
        }
        sidebarFolders = ((try? SidebarReader.folders()) ?? []).map { FolderNode(url: $0, kind: .folder) }
        // First start without Photomator's sidebar: offer the Pictures folder.
        if !defaults.bool(forKey: "seeded") {
            defaults.set(true, forKey: "seeded")
            if sidebarFolders.isEmpty, destinationRoots.isEmpty,
               let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
                destinationRoots = [FolderNode(url: pictures, kind: .folder)]
                saveFolders()
            }
        }
        drives = Drives.mounted()
        for card in drives where card.kind == .card { tickPictures(on: card) }
        if let saved = defaults.string(forKey: "destination") {
            setDestination(URL(fileURLWithPath: saved, isDirectory: true))
        }

        #if DEBUG
        // Development only: `-tick <folder>` ticks that source folder at launch.
        if let path = defaults.string(forKey: "tick"),
           let node = sourceFolders.first(where: { $0.url.path == path }) {
            setTicked(node, true)
        }
        // `-snapshot <file.png>` saves the window as an image after a few seconds. With
        // `-autoImport YES` it then presses Import and saves `<file>-after.png`.
        if let path = defaults.string(forKey: "snapshot") {
            func snapshot(_ file: String) {
                guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: file))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                snapshot(path)
                guard let self, self.defaults.bool(forKey: "autoImport") else { return }
                print("before import: \(self.checkedCount) of \(self.allCells.count), canImport \(self.canImport)")
                self.startImport()
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    print("after import: \(self.lastResult ?? "-"), \(self.checkedCount) of \(self.allCells.count), failures \(self.failures)")
                    snapshot(path.replacingOccurrences(of: ".png", with: "-after.png"))
                }
            }
        }
        #endif

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.drivesChanged() }
            })
        }
        // The check reads the files that are there: read again when coming back to the app.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.activity == .idle, self.source != nil else { return }
                self.refresh(readSource: true, readScope: true)
            }
        })
        observers.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49, !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            self?.toggleQuickLook()
            return nil
        } as Any)
        if !picks.isEmpty { refresh(readSource: true, readScope: false) }
    }

    // MARK: Source

    func setTicked(_ node: FolderNode, _ on: Bool) {
        node.setTicked(on)
        sourceChanged()
    }

    func addSourceFolders() {
        for url in FolderChooser.choose(multiple: true)
        where !sourceFolders.contains(where: { $0.url.folderKey == url.folderKey }) {
            sourceFolders.append(FolderNode(url: url, kind: .folder))
        }
        saveFolders()
    }

    func removeSourceFolder(_ node: FolderNode) {
        let wasTicked = node.anyTicked
        sourceFolders.removeAll { $0 === node }
        saveFolders()
        if wasTicked { sourceChanged() }
    }

    /// Drives keep their tree and ticks; a card that appears gets its DCIM folder ticked.
    private func drivesChanged() {
        let old = Dictionary(drives.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Drives.mounted().map { old[$0.url] ?? $0 }
        let lostTicked = drives.contains { drive in drive.anyTicked && !now.contains { $0 === drive } }
        let newCards = now.filter { $0.kind == .card && old[$0.url] == nil }
        drives = now
        newCards.forEach(tickPictures)
        if lostTicked || !newCards.isEmpty { sourceChanged() }
    }

    /// Opens a card and ticks its DCIM folder.
    private func tickPictures(on card: FolderNode) {
        card.isExpanded = true
        guard let dcim = Drives.dcim(on: card.url),
              let node = card.children?.first(where: { $0.url.folderKey == dcim.folderKey }) else { return }
        node.setTicked(true)
    }

    private func sourceChanged() {
        overrides = [:]
        selection = []
        lastResult = nil
        refresh(readSource: true, readScope: false)
    }

    private var picks: [FolderPick] { (drives + sourceFolders).flatMap(\.picks) }

    // MARK: Checking

    /// Reads the source and/or the scope as needed, then matches. A new call cancels a running one.
    func refresh(readSource: Bool, readScope: Bool) {
        checkTask?.cancel()
        let picks = picks
        let scope = scope
        let fingerprints = fingerprints
        checkTask = Task { [weak self, worker] in
            guard let self else { return }
            do {
                if readSource || self.source == nil {
                    guard !picks.isEmpty else {
                        self.source = nil
                        self.results = [:]
                        self.rebuild()
                        self.activity = .idle
                        return
                    }
                    self.activity = .readingSource
                    let read = try await worker.readSource(picks)
                    try Task.checkCancellation()
                    self.source = read
                    self.rebuild()
                }
                guard let source = self.source, let scope else {
                    self.activity = .idle
                    return
                }
                if readScope || self.index?.scope != scope {
                    self.activity = .checking(done: 0, total: 0)
                    let index = try await worker.readScope(scope, progress: Self.reporter(self))
                    try Task.checkCancellation()
                    self.index = index
                }
                self.activity = .checking(done: 0, total: 0)
                let results = try await worker.match(source, in: self.index!, fingerprints: fingerprints,
                                                     progress: Self.reporter(self))
                try Task.checkCancellation()
                self.results = results
                self.rebuild()
                self.activity = .idle
            } catch is CancellationError {
            } catch {
                self.activity = .idle
            }
        }
    }

    private nonisolated static func reporter(_ model: AppModel) -> @Sendable (Int, Int) -> Void {
        { done, total in
            guard done == total || done % 50 == 0 else { return }
            Task { @MainActor in
                guard case .checking = model.activity else { return }
                model.activity = .checking(done: done, total: total)
            }
        }
    }

    // MARK: Grid

    private func rebuild() {
        guard let source else {
            groups = []
            allCells = []
            return
        }
        let base = scope?.deletingLastPathComponent().folderKey
        func place(_ url: URL) -> String {
            let folder = url.deletingLastPathComponent().folderKey
            if let base, folder.hasPrefix(base) { return String(folder.dropFirst(base.count).dropLast()) }
            return String(folder.dropLast())
        }

        let infos = source.cells.map { cell -> CellInfo in
            let found = cell.files.filter { results[$0]?.isDuplicate == true }
            var tooltip: String?
            if !found.isEmpty {
                let folders = found.map { Set(results[$0]!.existing.map(place)).sorted().joined(separator: ", ") }
                tooltip = Set(folders).count == 1 && found.count == cell.files.count
                    ? folders[0]
                    : zip(found, folders).map { "\($0.url.lastPathComponent): \($1)" }.joined(separator: "\n")
            }
            let jpg = cell.files.first { $0.isJPG } ?? cell.files[0]
            return CellInfo(
                id: cell.files[0].path, cell: cell, name: cell.name,
                sortDate: cell.sortDate(metadata: source.metadata, dateFixes: source.dateFixes),
                formatTag: cell.formatTag,
                fixes: cell.files.compactMap { source.dateFixes[$0] }.filter { $0 != .notNeeded },
                fullyFound: cell.isFullyFound(results), tooltip: tooltip,
                thumbnailURL: jpg.url, previewURL: jpg.url, isVideo: cell.files[0].kind == .video
            )
        }
        .sorted { ($0.sortDate ?? "~", $0.name) < ($1.sortDate ?? "~", $1.name) }

        allCells = infos
        var byDay: [(String, [CellInfo])] = []
        for info in infos {
            let day = info.sortDate.map { String($0.prefix(10)) } ?? ""
            if byDay.last?.0 == day { byDay[byDay.count - 1].1.append(info) } else { byDay.append((day, [info])) }
        }
        groups = byDay.map { DayGroup(id: $0.0, title: Self.dayTitle($0.0), cells: $0.1) }
        selection = selection.filter { id in infos.contains { $0.id == id } }
    }

    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()

    static func dayTitle(_ day: String) -> String {
        guard let date = dayParser.date(from: day) else { return "No date" }
        return dayFormatter.string(from: date)
    }

    func isChecked(_ info: CellInfo) -> Bool { overrides[info.id] ?? !info.fullyFound }

    var checkedCount: Int { allCells.filter(isChecked).count }

    /// The tick box of a selected cell sets all selected cells.
    func toggleCheck(_ info: CellInfo) {
        let value = !isChecked(info)
        for id in selection.contains(info.id) ? selection : [info.id] { overrides[id] = value }
    }

    func checkAll(_ on: Bool) {
        for info in allCells { overrides[info.id] = on }
    }

    func select(_ info: CellInfo, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(info.id) { selection.remove(info.id) } else { selection.insert(info.id) }
            anchor = info.id
        } else if modifiers.contains(.shift), let anchor,
                  let from = allCells.firstIndex(where: { $0.id == anchor }),
                  let to = allCells.firstIndex(where: { $0.id == info.id }) {
            selection = Set(allCells[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [info.id]
            anchor = info.id
        }
    }

    func clearSelection() { selection = [] }

    func toggleQuickLook() {
        if previewURL != nil {
            previewURL = nil
            return
        }
        let chosen = allCells.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        previewItems = chosen.map(\.previewURL)
        previewURL = previewItems.first
    }

    func noDateColor(_ info: CellInfo) -> Color {
        guard fixDates else { return .red }
        return info.fixes.contains(where: \.isGuess) ? .orange : .green
    }

    // MARK: Destination

    func addDestinationFolder() {
        guard let url = FolderChooser.choose(multiple: false).first else { return }
        if !destinationRoots.contains(where: { $0.url.folderKey == url.folderKey }) {
            destinationRoots.append(FolderNode(url: url, kind: .folder))
            saveFolders()
        }
        setDestination(url)
    }

    func removeDestinationFolder(_ node: FolderNode) {
        destinationRoots.removeAll { $0 === node }
        saveFolders()
    }

    func setDestination(_ url: URL) {
        destination = url
        defaults.set(url.path, forKey: "destination")
        let scopes = defaults.dictionary(forKey: "scopes") as? [String: String] ?? [:]
        let saved = scopes[url.path].map { URL(fileURLWithPath: $0, isDirectory: true) }
        setScope(saved ?? Self.defaultScope(for: url), remember: false)
    }

    func chooseScope() {
        guard let url = FolderChooser.choose(multiple: false).first else { return }
        setScope(url, remember: true)
    }

    private func setScope(_ url: URL, remember: Bool) {
        if remember, let destination {
            var scopes = defaults.dictionary(forKey: "scopes") as? [String: String] ?? [:]
            scopes[destination.path] = url.path
            defaults.set(scopes, forKey: "scopes")
        }
        guard scope?.folderKey != url.folderKey else { return }
        scope = url
        if source != nil { refresh(readSource: false, readScope: true) }
    }

    /// The destination's parent, unless that is a volume list or a home folder.
    static func defaultScope(for destination: URL) -> URL {
        let parent = destination.deletingLastPathComponent()
        let tooWide = ["/", "/Volumes/", URL(fileURLWithPath: NSHomeDirectory()).folderKey]
        return tooWide.contains(parent.folderKey) ? destination : parent
    }

    var importTarget: URL? {
        guard let destination else { return nil }
        let name = subfolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard useSubfolder else { return destination }
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return destination.appendingPathComponent(name, isDirectory: true)
    }

    private func saveFolders() {
        defaults.set(sourceFolders.map(\.url.path), forKey: "sourceFolders")
        defaults.set(destinationRoots.map(\.url.path), forKey: "destinationFolders")
    }

    // MARK: Import

    var canImport: Bool {
        guard activity == .idle, importTarget != nil, let source, checkedCount > 0 else { return false }
        return source.files.allSatisfy { results[$0] != nil }
    }

    func startImport() {
        guard canImport, let source, let target = importTarget else { return }
        let selected = Set(allCells.filter(isChecked).flatMap { $0.cell.filesToImport(results) })
        let options = ImportOptions(rename: rename, copy: copyChoice, fixDates: fixDates)
        let cells = source.cells
        let results = results
        let sourceFolders = picks.map(\.url)
        activity = .importing(done: 0, total: 1)
        lastResult = nil

        let progress: @Sendable (Int64, Int64) -> Void = { [weak self] done, total in
            Task { @MainActor in
                guard let self, case .importing = self.activity else { return }
                self.activity = .importing(done: done, total: max(total, 1))
            }
        }
        importTask = Task { [weak self, worker] in
            var message: String
            var failed: [String] = []
            do {
                let outcome = try await worker.runImport(
                    cells: cells, results: results, selected: selected, sourceFolders: sourceFolders,
                    destination: target, options: options, progress: progress
                )
                message = "\(outcome.copied.count) copied"
                failed = outcome.failed.map { "\($0.source.path)\n\($0.reason)" }
            } catch is CancellationError {
                message = "Stopped"
            } catch CopierError.notEnoughSpace(let needed, let available) {
                message = "Not copied"
                let format = ByteCountFormatter()
                failed = ["Not enough space: \(format.string(fromByteCount: needed)) needed, \(format.string(fromByteCount: available)) free."]
            } catch {
                message = "Not copied"
                failed = ["\(error)"]
            }
            guard let self else { return }
            self.activity = .idle
            self.lastResult = message
            self.failures = failed
            self.showFailures = !failed.isEmpty
            self.overrides = [:]
            self.refresh(readSource: true, readScope: true)
        }
    }

    func cancelImport() { importTask?.cancel() }
}
