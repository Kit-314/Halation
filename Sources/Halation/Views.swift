import SwiftUI
import AppKit

struct ViewerView: View {
    @EnvironmentObject var model: ViewerModel

    var body: some View {
        ZStack {
            Color(nsColor: model.canvasNSColor).ignoresSafeArea()
            if let session = model.editSession {
                EditView(session: session)
            } else {
                viewerContent
            }
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 16)
                    .transition(.opacity)
            }
        }
        .overlay {
            if model.showHelp { HelpOverlay() }
        }
        .animation(.easeOut(duration: 0.15), value: model.toast)
        .animation(.easeOut(duration: 0.15), value: model.showHelp)
        .background(WindowAccessor { window in
            model.viewerWindow = window
        })
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            return true
        }
        .navigationTitle(model.windowTitle)
    }

    @ViewBuilder
    private var viewerContent: some View {
        ZStack {
            if let display = model.display {
                ZoomableImageView(image: display.image, imageID: display.contentID,
                                  canvasColor: model.canvasNSColor, model: model)
                    .ignoresSafeArea()
                    .id(display.id)
                    .transition(model.photoTransition)
            } else if model.files.isEmpty {
                EmptyStateView()
            }
            if model.isLoading {
                ProgressView().controlSize(.large)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if model.showFilmstrip && !model.files.isEmpty { FilmstripView() }
                if model.showHUD && model.display != nil { HUDView() }
            }
            .padding(.bottom, 12)
        }
        .overlay(alignment: .topTrailing) {
            if model.showInfo, let info = model.info {
                InfoPanel(info: info).padding(12)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.showFilmstrip)
        .animation(.easeOut(duration: 0.15), value: model.showInfo)
    }
}

/// Grabs the hosting NSWindow so the key handler can scope itself to it.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: ViewerModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Drop a photo or folder here")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Open…") { model.openPanel() }
            Text("Press ? anytime for keyboard shortcuts")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

struct HUDView: View {
    @EnvironmentObject var model: ViewerModel

    var body: some View {
        HStack(spacing: 14) {
            Button { model.previous() } label: { Image(systemName: "chevron.left") }
                .help("Previous (←)")
            Button { model.toggleSlideshow() } label: {
                Image(systemName: model.isSlideshowRunning ? "pause.fill" : "play.fill")
            }
            .help(model.isSlideshowRunning ? "Stop slideshow (S)" : "Start slideshow (S)")
            Button { model.next() } label: { Image(systemName: "chevron.right") }
                .help("Next (→)")
            Divider().frame(height: 14)
            Text(hudText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
            Divider().frame(height: 14)
            Button { model.zoom?.zoomToFit() } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .help("Zoom to fit (0)")
            Button { model.toggleEdit() } label: { Image(systemName: "slider.horizontal.3") }
                .help("Edit (E)")
            Button { model.showInfo.toggle() } label: { Image(systemName: "info.circle") }
                .help("Info (I)")
            Button { model.showFilmstrip.toggle() } label: { Image(systemName: "rectangle.grid.1x2") }
                .help("Filmstrip (T)")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var hudText: String {
        var parts: [String] = []
        if let url = model.currentURL { parts.append(url.lastPathComponent) }
        parts.append("\(model.index + 1)/\(model.files.count)")
        if let info = model.info, info.pixelWidth > 0 {
            parts.append("\(info.pixelWidth)×\(info.pixelHeight)")
        }
        parts.append("\(Int((model.zoomLevel * 100).rounded()))%")
        return parts.joined(separator: "  ·  ")
    }
}

struct FilmstripView: View {
    @EnvironmentObject var model: ViewerModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(model.files.enumerated()), id: \.element) { i, url in
                        ThumbView(url: url, selected: i == model.index)
                            .id(url)
                            .onTapGesture { model.show(i) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(height: 86)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            .onAppear {
                if let url = model.currentURL { proxy.scrollTo(url, anchor: .center) }
            }
            .onChange(of: model.index) {
                if let url = model.currentURL {
                    withAnimation { proxy.scrollTo(url, anchor: .center) }
                }
            }
        }
    }
}

struct ThumbView: View {
    @EnvironmentObject var model: ViewerModel
    let url: URL
    let selected: Bool
    @State private var thumb: NSImage?

    var body: some View {
        ZStack {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 96, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15),
                              lineWidth: selected ? 2.5 : 1)
        )
        .task(id: url) {
            thumb = await model.loader.thumbnail(for: url)
        }
    }
}

struct InfoPanel: View {
    let info: ImageInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(info.fileName).font(.headline).lineLimit(2)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                row("Dimensions", info.pixelSize)
                row("File size", info.fileSize)
                row("Created", info.created)
                row("Modified", info.modified)
                if info.captureDate != nil || info.cameraModel != nil {
                    Divider().gridCellColumns(2)
                }
                row("Captured", info.captureDate)
                row("Camera", [info.cameraMake, info.cameraModel]
                    .compactMap { $0 }.joined(separator: " ").nilIfEmpty)
                row("Lens", info.lens)
                row("Focal length", info.focalLength)
                row("Aperture", info.aperture)
                row("Shutter", info.shutter)
                row("ISO", info.iso)
                row("Color", info.colorInfo)
            }
            if let lat = info.gpsLatitude, let lon = info.gpsLongitude {
                Button {
                    if let url = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=Photo") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open location in Maps", systemImage: "mappin.and.ellipse")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Text(info.folder)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .truncationMode(.head)
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Text(value).textSelection(.enabled)
            }
        }
    }
}

struct HelpOverlay: View {
    @EnvironmentObject var model: ViewerModel

    /// Built live from the keymap so remaps show up here automatically.
    private var shortcuts: [(String, String)] {
        var rows: [(String, String)] = []
        let order: [KeyAction] = [
            .nextPhoto, .previousPhoto, .firstPhoto, .lastPhoto,
            .toggleFullscreen, .zoomIn, .zoomOut, .zoomFit, .zoomActual,
            .rotateCW, .rotateCCW, .toggleInfo, .toggleFilmstrip,
            .toggleSlideshow, .toggleHUD, .moveToTrash, .toggleEdit, .toggleHelp,
        ]
        for action in order {
            let strokes = model.keymap.strokes(for: action)
            guard !strokes.isEmpty else { continue }
            rows.append((strokes.prefix(3).map(\.display).joined(separator: "  "), action.label))
        }
        rows.append(("Wheel / ⌥ Scroll / Pinch", "Zoom at cursor"))
        rows.append(("Double-click", "Toggle fit ↔ 100%"))
        rows.append(("⌘C / ⌘R", "Copy file / Reveal in Finder"))
        return rows
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { model.showHelp = false }
            VStack(spacing: 14) {
                Text("Keyboard Shortcuts").font(.title3.bold())
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                    ForEach(shortcuts, id: \.1) { item in
                        GridRow {
                            Text(item.0)
                                .font(.system(.callout, design: .monospaced).weight(.semibold))
                                .gridColumnAlignment(.trailing)
                            Text(item.1).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Remap any of these in Settings (⌘,) — press any key to dismiss")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
