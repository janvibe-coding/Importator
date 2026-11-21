import Foundation

/// Photomator's sidebar folders, read from its list (`FilesLibrary.plist`). Read only: Importator
/// never writes anything of Photomator's. Adapted from Ratingmator's `PhotomatorList`; unlike
/// Ratingmator it doesn't refuse unknown keys, since it changes nothing.
public enum SidebarReader {
    public enum ReadError: Error, Equatable {
        case notAPropertyList
        case unsupportedVersion
        case unexpectedStructure
    }

    public static let listLocation = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Group Containers/4R6749AYRE.com.pixelmator/Library/Files Library/FilesLibrary.plist"
    )

    public static func folders(inListAt url: URL = listLocation) throws -> [URL] {
        try folders(inList: Data(contentsOf: url))
    }

    public static func folders(inList data: Data) throws -> [URL] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any] else { throw ReadError.notAPropertyList }
        guard root["version"] as? Int == 3 else { throw ReadError.unsupportedVersion }
        guard var directories = root["directories"] as? [[String: Any]] else { throw ReadError.unexpectedStructure }
        // The sidebar's order: `directoryOrder` lists the directories' ids.
        if let order = root["directoryOrder"] as? [Any] {
            let ranks = Dictionary(order.enumerated().map { ("\($0.element)", $0.offset) }, uniquingKeysWith: { a, _ in a })
            directories = directories.enumerated().sorted { a, b in
                let ra = a.element["id"].flatMap { ranks["\($0)"] } ?? order.count + a.offset
                let rb = b.element["id"].flatMap { ranks["\($0)"] } ?? order.count + b.offset
                return ra < rb
            }.map(\.element)
        }
        return try directories.map { directory in
            guard let url = directory["url"] as? [String: Any],
                  let relative = url["relative"] as? String,
                  let path = URL(string: relative)?.path else { throw ReadError.unexpectedStructure }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }
}
