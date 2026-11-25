import ImageIO
import QuickLook
import QuickLookThumbnailing
import SwiftUI

struct GridPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button("Check all") { model.checkAll(true) }.buttonStyle(.link)
                Text("·").foregroundColor(.secondary)
                Button("Uncheck all") { model.checkAll(false) }.buttonStyle(.link)
                Spacer()
                activity
                Image(systemName: "photo").imageScale(.small).foregroundColor(.secondary)
                Slider(value: $model.zoom, in: 110...480).frame(width: 140)
                Image(systemName: "photo").imageScale(.large).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            HStack(spacing: 8) {
                Text("Check duplicates in")
                    .lineLimit(1)
                    .fixedSize()
                Text(model.scope.map(DestinationPanel.shortPath) ?? "–")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundColor(.secondary)
                    .help(model.scope?.path ?? "")
                Button("Choose…") { model.chooseScope() }
                    .disabled(model.destination == nil)
                Picker("", selection: $model.fingerprints) {
                    Text("By metadata").tag(false)
                    Text("By content (slow)").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: model.zoom, maximum: model.zoom * 1.4), spacing: 10)],
                          alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.groups) { group in
                        Section {
                            ForEach(group.cells) { CellView(info: $0) }
                        } header: {
                            Text(group.title)
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                }
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor).onTapGesture { model.clearSelection() })
            .quickLookPreview($model.previewURL, in: model.previewItems)
        }
    }

    @ViewBuilder private var activity: some View {
        switch model.activity {
        case .readingSource:
            ProgressView().controlSize(.small)
        case .checking(let done, let total):
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total)).frame(width: 140)
            } else {
                ProgressView().controlSize(.small)
            }
        default:
            EmptyView()
        }
    }
}

struct CellView: View {
    let info: CellInfo
    @EnvironmentObject private var model: AppModel

    @State private var hovering = false
    @State private var showTooltip = false

    var body: some View {
        let selected = model.selection.contains(info.id)
        let checked = model.isChecked(info)
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                ThumbnailView(url: info.thumbnailURL, isVideo: info.isVideo, side: model.zoom)
                    .frame(height: model.zoom * 0.75)
                    .frame(maxWidth: .infinity)
                Toggle("", isOn: Binding(get: { checked }, set: { _ in model.toggleCheck(info) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .padding(4)
            }
            HStack(spacing: 4) {
                Tag(text: info.formatTag, color: .secondary)
                if info.hasNoDate { Tag(text: "no date", color: model.noDateColor(info)) }
            }
            Text(info.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Color.accentColor.opacity(0.22) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .opacity(info.fullyFound && !checked ? 0.4 : 1)
        // SwiftUI's .help tooltips stop showing in grids on recent macOS; hover is tracked by AppKit.
        .overlay(alignment: .bottom) {
            if showTooltip, let tooltip = info.tooltip {
                Text(tooltip)
                    .font(.caption)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.4)))
                    .shadow(radius: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .background(HoverTracker { hovering = $0 })
        .task(id: hovering) {
            guard hovering else { showTooltip = false; return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            showTooltip = !Task.isCancelled && hovering
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(info, modifiers: NSEvent.modifierFlags) }
    }
}

/// Reports the mouse entering and leaving through an AppKit tracking area. It never takes clicks.
struct HoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) { view.onChange = onChange }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { onChange?(true) }
        override func mouseExited(with event: NSEvent) { onChange?(false) }
    }
}

struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundColor(color)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.15)))
    }
}

struct ThumbnailView: View {
    let url: URL
    let isVideo: Bool
    let side: Double
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.06)
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            }
        }
        .task(id: "\(url.path)|\(Thumbnails.bucket(for: side))") {
            image = await Thumbnails.shared.image(for: url, isVideo: isVideo, pixels: Thumbnails.bucket(for: side))
        }
    }
}

/// Thumbnails from the JPEG embedded in each file (ImageIO), Quick Look for videos.
final class Thumbnails: @unchecked Sendable {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 6
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Thumbnails come in two sizes, so zooming doesn't reload every step.
    static func bucket(for side: Double) -> Int { side <= 230 ? 400 : 1000 }

    func image(for url: URL, isVideo: Bool, pixels: Int) async -> NSImage? {
        let key = "\(pixels)|\(url.path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let made: NSImage? = isVideo
            ? await video(url, pixels: pixels)
            : await withCheckedContinuation { done in queue.addOperation { done.resume(returning: Self.photo(url, pixels: pixels)) } }
        if let made { cache.setObject(made, forKey: key) }
        return made
    }

    static func photo(_ url: URL, pixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        func thumbnail(always: Bool) -> CGImage? {
            let options: [CFString: Any] = [
                always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        var image = thumbnail(always: false)
        // A JPG's own Exif thumbnail is tiny; JPEG and HEIC decode quickly at a reduced size.
        let type = CGImageSourceGetType(source) as String?
        if (image?.width ?? 0) < pixels * 3 / 4, type == "public.jpeg" || type == "public.heic" {
            image = thumbnail(always: true) ?? image
        }
        guard let image else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func video(_ url: URL, pixels: Int) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: pixels / 2, height: pixels / 2), scale: 2,
                                                   representationTypes: .thumbnail)
        return await withCheckedContinuation { done in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                done.resume(returning: representation?.nsImage)
            }
        }
    }
}
