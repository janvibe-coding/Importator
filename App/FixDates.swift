import SwiftUI

/// Fixes missing capture times in folders that are already imported: the date goes into the
/// files themselves (DateFixer). Separate from the import window, so a source is never changed.
@MainActor
final class FixDatesModel: ObservableObject {
    struct Item: Identifiable {
        let file: MediaFile
        let fix: DateFix
        let folder: String
        var id: String { file.path }
    }

    enum Activity: Equatable { case idle, reading, fixing(done: Int, total: Int) }

    private let worker = EngineWorker()
    @Published private(set) var folder: URL?
    @Published private(set) var items: [Item] = []
    @Published private(set) var activity: Activity = .idle
    @Published var includeFromFile = true
    @Published var includeGuessed = false
    @Published private(set) var result: String?
    @Published private(set) var failures: [String] = []
    private var metadata: [MediaFile: Metadata] = [:]
    private var task: Task<Void, Never>?

    var fromFileCount: Int { items.filter { !$0.fix.isGuess }.count }
    var guessedCount: Int { items.filter { $0.fix.isGuess }.count }
    var chosen: [Item] { items.filter { $0.fix.isGuess ? includeGuessed : includeFromFile } }

    func chooseFolder() {
        guard let url = FolderChooser.choose(multiple: false).first else { return }
        folder = url
        read()
    }

    func read() {
        guard let folder else { return }
        task?.cancel()
        items = []
        result = nil
        failures = []
        activity = .reading
        task = Task { [worker] in
            do {
                let source = try await worker.readSource([FolderPick(url: folder, recursive: true)])
                let base = folder.folderKey
                self.metadata = source.metadata
                self.items = DateFixer.candidates(in: source).map { file, fix in
                    let parent = file.url.deletingLastPathComponent().folderKey
                    let relative = parent.hasPrefix(base) ? String(parent.dropFirst(base.count).dropLast()) : parent
                    return Item(file: file, fix: fix, folder: relative)
                }
            } catch {}
            self.activity = .idle
        }
    }

    func fix() {
        let chosen = chosen.map { (file: $0.file, fix: $0.fix) }
        guard !chosen.isEmpty, activity == .idle else { return }
        activity = .fixing(done: 0, total: chosen.count)
        let metadata = metadata
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in self?.activity = .fixing(done: done, total: total) }
        }
        task = Task { [worker] in
            var message = ""
            var failed: [String] = []
            do {
                let outcome = try await worker.fixDates(chosen, metadata: metadata, progress: progress)
                message = "\(outcome.fixed.count) fixed"
                failed = outcome.failed.map { "\($0.file.path)\n\($0.reason)" }
            } catch is CancellationError {
                message = "Stopped"
            } catch {
                failed = ["\(error)"]
            }
            self.activity = .idle
            self.read()
            self.result = message
            self.failures = failed
        }
    }

    func stop() { task?.cancel() }
}

struct FixDatesView: View {
    @StateObject private var model = FixDatesModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.folder?.path ?? "–")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Choose folder…") { model.chooseFolder() }
                    .disabled(model.activity != .idle)
            }
            .padding(12)
            Divider()
            List(model.items) { item in
                HStack(spacing: 8) {
                    Tag(text: "no date", color: item.fix.isGuess ? .orange : .green)
                    Text(item.file.url.lastPathComponent).lineLimit(1)
                    Text(item.folder).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(item.fix.date ?? "").monospacedDigit().foregroundColor(.secondary)
                }
                .opacity((item.fix.isGuess ? model.includeGuessed : model.includeFromFile) ? 1 : 0.4)
            }
            .overlay {
                if model.activity == .reading { ProgressView() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $model.includeFromFile) {
                    HStack(spacing: 6) { Tag(text: "no date", color: .green); Text("\(model.fromFileCount)") }
                }
                Toggle(isOn: $model.includeGuessed) {
                    HStack(spacing: 6) { Tag(text: "no date", color: .orange); Text("\(model.guessedCount)") }
                }
                ForEach(model.failures, id: \.self) { Text($0).font(.caption).foregroundColor(.red).textSelection(.enabled) }
            }
            .toggleStyle(.checkbox)
            .padding(12)
            Divider()
            HStack(spacing: 12) {
                if case .fixing(let done, let total) = model.activity {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    Button("Stop") { model.stop() }
                } else {
                    if let result = model.result { Text(result).foregroundColor(.secondary) }
                    Spacer()
                    Button("Fix \(model.chosen.count)") { model.fix() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.chosen.isEmpty || model.activity != .idle)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}
