import Foundation

/// The bundled ExifTool, run with macOS's Perl and kept running between commands (`-stay_open`).
/// Adapted from Ratingmator: the bundle is found through the package's resources, so the
/// command-line tool can use it too, and errors go to /dev/null so JSON output stays clean.
public final class ExifTool {
    public enum ToolError: Error, Equatable {
        case notBundled
        case stopped
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    public init(folder: URL? = nil) throws {
        guard let folder = folder ?? Self.bundled else {
            throw ToolError.notBundled
        }
        signal(SIGPIPE, SIG_IGN)  // a stopped ExifTool should show as an error, not end the app
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [folder.appendingPathComponent("exiftool").path, "-stay_open", "True", "-@", "-"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// In the package (command-line tool, tests) it's a package resource; in the app it sits in
    /// the app's Resources.
    static var bundled: URL? {
        #if SWIFT_PACKAGE
        Bundle.module.url(forResource: "ExifTool", withExtension: "bundle")
        #else
        Bundle.main.url(forResource: "ExifTool", withExtension: "bundle")
        #endif
    }

    deinit { close() }

    /// Runs one command and returns what it printed. Paths are passed as UTF-8, so the on-disk
    /// spelling of accented names is kept.
    @discardableResult
    public func run(_ arguments: [String]) throws -> String {
        let lines = (["-charset", "filename=utf8"] + arguments + ["-execute"]).joined(separator: "\n") + "\n"
        try input.fileHandleForWriting.write(contentsOf: Data(lines.utf8))

        var printed = Data()
        let ready = Data("{ready}\n".utf8)
        while !printed.suffix(ready.count).elementsEqual(ready) {
            let more = output.fileHandleForReading.availableData
            guard !more.isEmpty else { throw ToolError.stopped }
            printed += more
        }
        return String(decoding: printed.dropLast(ready.count), as: UTF8.self)
    }

    /// Reads tags as JSON (`-j`) for a batch of files. Returns one dictionary per file that
    /// ExifTool could read, keyed by its path.
    public func readJSON(_ files: [URL], options: [String]) throws -> [String: [String: Any]] {
        guard !files.isEmpty else { return [:] }
        let printed = try run(["-j"] + options + files.map(\.path))
        guard let data = printed.data(using: .utf8), !printed.isEmpty,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var byPath: [String: [String: Any]] = [:]
        for entry in list {
            if let path = entry["SourceFile"] as? String { byPath[path] = entry }
        }
        return byPath
    }

    public func close() {
        guard process.isRunning else { return }
        try? input.fileHandleForWriting.write(contentsOf: Data("-stay_open\nFalse\n".utf8))
        process.waitUntilExit()
    }
}
