import AppKit
import Combine
import Foundation

/// A folder in the source or destination tree. Subfolders are read the first time it opens.
final class FolderNode: ObservableObject, Identifiable {
    enum Kind { case drive, card, folder, subfolder }

    let url: URL
    let title: String
    let kind: Kind
    weak var parent: FolderNode?

    @Published var isExpanded = false {
        didSet { if isExpanded { loadChildren() } }
    }
    @Published private(set) var children: [FolderNode]?
    /// Source tree only: this folder's own files are included.
    @Published private(set) var isTicked = false

    var id: URL { url }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    init(url: URL, title: String? = nil, kind: Kind, parent: FolderNode? = nil) {
        self.url = url
        self.title = title ?? url.lastPathComponent
        self.kind = kind
        self.parent = parent
        self.isTicked = parent?.isTicked ?? false
    }

    private var knownToHaveSubfolders: Bool?

    var hasSubfolders: Bool {
        if let children { return !children.isEmpty }
        if let knownToHaveSubfolders { return knownToHaveSubfolders }
        let found = !Self.subfolders(of: url).isEmpty
        knownToHaveSubfolders = found
        return found
    }

    func loadChildren() {
        guard children == nil else { return }
        children = Self.subfolders(of: url).map { FolderNode(url: $0, kind: .subfolder, parent: self) }
    }

    static func subfolders(of url: URL) -> [URL] {
        let found = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles]
        )) ?? []
        return found
            .filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                return values?.isDirectory == true && values?.isPackage != true
                    && $0.pathExtension.lowercased() != "photo-edit"
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Ticking a folder ticks all its subfolders; each can then be unticked on its own.
    func setTicked(_ on: Bool) {
        isTicked = on
        children?.forEach { $0.setTicked(on) }
    }

    /// What to read. A ticked folder whose subfolders were never opened stands for all of them.
    var picks: [FolderPick] {
        guard let children else { return isTicked ? [FolderPick(url: url, recursive: true)] : [] }
        return (isTicked ? [FolderPick(url: url, recursive: false)] : []) + children.flatMap(\.picks)
    }

    var anyTicked: Bool { isTicked || (children?.contains { $0.anyTicked } ?? false) }
}

/// Mounted volumes. A volume with a DCIM folder is a card.
enum Drives {
    static func mounted() -> [FolderNode] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]
        ) ?? []
        return volumes.map { volume in
            let name = (try? volume.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? volume.lastPathComponent
            return FolderNode(url: volume, title: name, kind: dcim(on: volume) == nil ? .drive : .card)
        }
    }

    static func dcim(on volume: URL) -> URL? {
        let dcim = volume.appendingPathComponent("DCIM", isDirectory: true)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dcim.path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        return dcim
    }
}

enum FolderChooser {
    @MainActor
    static func choose(multiple: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = multiple
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.urls : []
    }
}
