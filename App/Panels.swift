import SwiftUI

// MARK: Source

struct SourcePanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Source")
            List {
                Section("Drives") {
                    ForEach(model.drives) { FolderRow(node: $0, mode: .source) }
                }
                Section("Folders") {
                    ForEach(model.sourceFolders) { node in
                        FolderRow(node: node, mode: .source)
                            .contextMenu { Button("Remove") { model.removeSourceFolder(node) } }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button("Choose folder…") { model.addSourceFolders() }
                Spacer()
            }
            .padding(10)
        }
    }
}

/// A folder in the source tree (tick box) or the destination tree (select one).
struct FolderRow: View {
    enum Mode { case source, destination }

    @ObservedObject var node: FolderNode
    let mode: Mode
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if node.exists, node.hasSubfolders {
            DisclosureGroup(isExpanded: $node.isExpanded) {
                ForEach(node.children ?? []) { FolderRow(node: $0, mode: mode) }
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var icon: String {
        if !node.exists { return "questionmark.folder" }
        switch node.kind {
        case .card: return "sdcard"
        case .drive: return "externaldrive"
        default: return "folder"
        }
    }

    @ViewBuilder private var label: some View {
        switch mode {
        case .source:
            Toggle(isOn: Binding(get: { node.isTicked }, set: { model.setTicked(node, $0) })) {
                Label(node.title, systemImage: icon).lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .disabled(!node.exists)
            .help(node.url.path)
        case .destination:
            let chosen = model.destination?.folderKey == node.url.folderKey
            Label(node.title, systemImage: icon)
                .lineLimit(1)
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(chosen ? Color.accentColor.opacity(0.3) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { if node.exists { model.setDestination(node.url) } }
                .foregroundColor(node.exists ? .primary : .secondary)
                .help(node.url.path)
        }
    }
}

// MARK: Destination

struct DestinationPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Destination")
            List {
                if !model.sidebarFolders.isEmpty {
                    Section("Photomator") {
                        ForEach(model.sidebarFolders) { FolderRow(node: $0, mode: .destination) }
                    }
                }
                Section("Folders") {
                    ForEach(model.destinationRoots) { node in
                        FolderRow(node: node, mode: .destination)
                            .contextMenu { Button("Remove") { model.removeDestinationFolder(node) } }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button("Choose folder…") { model.addDestinationFolder() }
                Spacer()
            }
            .padding(10)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Toggle("Subfolder", isOn: $model.useSubfolder).toggleStyle(.checkbox)
                    TextField("", text: $model.subfolderName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.useSubfolder)
                }
                Toggle("Rename: date + original name", isOn: $model.rename).toggleStyle(.checkbox)
                Picker("Copy", selection: $model.copyChoice) {
                    Text("RAW+JPG").tag(CopyChoice.rawAndJPG)
                    Text("RAW").tag(CopyChoice.raw)
                    Text("JPG").tag(CopyChoice.jpg)
                }
                .pickerStyle(.segmented)
                Toggle("Fix missing date", isOn: $model.fixDates).toggleStyle(.checkbox)
                Toggle("Compare fingerprints", isOn: $model.fingerprints).toggleStyle(.checkbox)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Check duplicates in")
                    HStack {
                        Text(model.scope.map(Self.shortPath) ?? "–")
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundColor(.secondary)
                            .help(model.scope?.path ?? "")
                        Spacer()
                        Button("Choose…") { model.chooseScope() }
                            .disabled(model.destination == nil)
                    }
                }
            }
            .padding(12)
        }
    }

    static func shortPath(_ url: URL) -> String {
        url.pathComponents.suffix(2).joined(separator: "/")
    }
}

struct PanelHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        Divider()
    }
}

// MARK: Bottom bar

struct BottomBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if case .importing(let done, let total) = model.activity {
                ProgressView(value: Double(done), total: Double(total))
                    .frame(maxWidth: .infinity)
                Button("Stop") { model.cancelImport() }
            } else {
                Text("\(model.checkedCount) of \(model.allCells.count) selected")
                if let result = model.lastResult {
                    Text(result).foregroundColor(.secondary)
                }
                Spacer()
                Button("Import") { model.startImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canImport)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}

struct FailuresView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.failures.count) not copied").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.failures, id: \.self) { Text($0).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("OK") { model.showFailures = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 360)
    }
}
