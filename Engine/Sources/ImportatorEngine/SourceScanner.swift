import Foundation

/// A ticked folder: its own files, and with `recursive` those of all its subfolders.
public struct FolderPick: Hashable, Sendable {
    public let url: URL
    public let recursive: Bool

    public init(url: URL, recursive: Bool) {
        self.url = url
        self.recursive = recursive
    }
}

/// Finds photo and video files in folders. Never writes.
public enum SourceScanner {
    public struct Found: Sendable {
        public let files: [MediaFile]
        /// Every folder that was read, as `folderKey`s. Used to leave the source out of the
        /// duplicate check.
        public let folders: Set<String>
        public let unreadable: [URL]
    }

    /// The media files directly in each folder, or also in all subfolders with `recursive`.
    /// Hidden files and Photomator's `.photo-edit` packages are skipped.
    public static func scan(_ roots: [URL], recursive: Bool) -> Found {
        scan(roots.map { FolderPick(url: $0, recursive: recursive) })
    }

    public static func scan(_ picks: [FolderPick]) -> Found {
        var files: [MediaFile] = []
        var folders = Set<String>()
        var unreadable: [URL] = []
        var seen = Set<String>()

        for pick in picks {
            let root = pick.url, recursive = pick.recursive
            folders.insert(root.folderKey)
            let options: FileManager.DirectoryEnumerationOptions = recursive
                ? [.skipsHiddenFiles, .skipsPackageDescendants]
                : [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: options,
                errorHandler: { url, _ in unreadable.append(url); return true }
            ) else {
                unreadable.append(root)
                continue
            }
            while let url = enumerator.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                if values?.isDirectory == true {
                    if url.pathExtension.lowercased() == "photo-edit" || url.lastPathComponent.hasPrefix(".") {
                        enumerator.skipDescendants()
                    } else if recursive {
                        folders.insert(url.folderKey)
                    }
                    continue
                }
                guard values?.isRegularFile == true,
                      let kind = MediaTypes.kind(ofExtension: url.pathExtension),
                      seen.insert(url.standardizedFileURL.path.nfc).inserted else { continue }
                files.append(MediaFile(url: url, kind: kind))
            }
        }
        files.sort { $0.path.nfc < $1.path.nfc }
        return Found(files: files, folders: folders, unreadable: unreadable)
    }

    /// Joins each RAW with the JPG of the same base name in the same folder into one cell.
    /// Everything else gets a cell of its own.
    public static func cells(_ files: [MediaFile]) -> [Cell] {
        struct Key: Hashable { let folder: String; let name: String }
        var raws: [Key: [MediaFile]] = [:]
        var jpgs: [Key: [MediaFile]] = [:]
        var cells: [Cell] = []

        for file in files {
            let key = Key(folder: file.folderKey, name: file.pairName)
            if file.isRaw { raws[key, default: []].append(file) }
            else if file.isJPG { jpgs[key, default: []].append(file) }
            else { cells.append(Cell(files: [file])) }
        }
        for (key, rawFiles) in raws {
            var rest = rawFiles
            if var jpgFiles = jpgs[key], !jpgFiles.isEmpty {
                cells.append(Cell(files: [rest.removeFirst(), jpgFiles.removeFirst()]))
                jpgs[key] = jpgFiles
            }
            cells += rest.map { Cell(files: [$0]) }
        }
        for jpgFiles in jpgs.values { cells += jpgFiles.map { Cell(files: [$0]) } }
        return cells.sorted { $0.files[0].path.nfc < $1.files[0].path.nfc }
    }
}
