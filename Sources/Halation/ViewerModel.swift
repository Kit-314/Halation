import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case dateModified = "Date Modified"
    case dateCreated = "Date Created"
    case size = "Size"
    var id: String { rawValue }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }
}

enum TransitionStyle: String, CaseIterable, Identifiable {
    case none = "None"
    case fade = "Fade"
    case slide = "Slide"
    case cinematic = "Cinematic"
    var id: String { rawValue }
}

/// The image currently on screen, kept as one value so photo + identity
/// change atomically (required for clean SwiftUI transitions).
struct DisplayedImage {
    let image: NSImage
    let url: URL
    let rotation: Int
    var isPreview = false

    /// Transition identity. Stays the same when a preview is upgraded to
    /// full res, so the upgrade doesn't re-run the photo transition.
    var id: String { "\(url.path)#r\(rotation)" }
    /// Content identity, so the scroll view knows when pixels actually changed.
    var contentID: String { "\(id)#\(isPreview ? "p" : "f")" }
}

@MainActor
final class ViewerModel: ObservableObject {
    static let shared = ViewerModel()

    @Published private(set) var files: [URL] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var display: DisplayedImage?
    @Published private(set) var isLoading = false
    @Published private(set) var info: ImageInfo?
    @Published var showInfo = false
    @Published var showFilmstrip = false
    @Published var showHUD = true
    @Published var showHelp = false
    @Published var zoomLevel: CGFloat = 1
    @Published private(set) var isSlideshowRunning = false
    @Published var toast: String?
    @Published private(set) var navDirection: CGFloat = 1
    @Published private(set) var editSession: EditSession?

    @Published var slideshowInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(slideshowInterval, forKey: "slideshowInterval")
            if isSlideshowRunning { startSlideshow() }
        }
    }
    @Published var sortOrder: SortOrder {
        didSet {
            UserDefaults.standard.set(sortOrder.rawValue, forKey: "sortOrder")
            resort()
        }
    }
    @Published var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }
    @Published var transitionStyle: TransitionStyle {
        didSet { UserDefaults.standard.set(transitionStyle.rawValue, forKey: "transitionStyle") }
    }

    weak var zoom: ZoomControlling?
    weak var viewerWindow: NSWindow?
    let loader = ImageLoader()
    let keymap = Keymap()

    private(set) var rotationQuarters = 0
    private var baseImage: NSImage?
    private var generation = 0
    private var slideshowTimer: Timer?
    private var toastTask: Task<Void, Never>?
    private var lastNavDate = Date.distantPast

    var isEditing: Bool { editSession != nil }
    var image: NSImage? { display?.image }

    private init() {
        slideshowInterval = UserDefaults.standard.object(forKey: "slideshowInterval") as? TimeInterval ?? 3
        sortOrder = SortOrder(rawValue: UserDefaults.standard.string(forKey: "sortOrder") ?? "") ?? .name
        appearance = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
        transitionStyle = TransitionStyle(rawValue: UserDefaults.standard.string(forKey: "transitionStyle") ?? "") ?? .cinematic
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(systemAppearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    }

    @objc private func systemAppearanceChanged() {
        Task { @MainActor in self.objectWillChange.send() }
    }

    var currentURL: URL? { files.indices.contains(index) ? files[index] : nil }

    var windowTitle: String {
        guard let url = currentURL else { return "Halation" }
        let base = "\(url.lastPathComponent) — \(index + 1) of \(files.count)"
        return isEditing ? "Editing: \(base)" : base
    }

    // MARK: - Appearance

    var isDarkCanvas: Bool {
        switch appearance {
        case .dark: return true
        case .light: return false
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    var canvasNSColor: NSColor {
        isDarkCanvas ? .black : NSColor(calibratedWhite: 0.91, alpha: 1)
    }

    /// The app delegate checks this so it doesn't quit the app while SwiftUI
    /// churns windows during an appearance switch.
    private(set) var lastAppearanceChange = Date.distantPast

    func applyAppearance() {
        lastAppearanceChange = Date()
        let mode = appearance
        // Setting NSApp.appearance synchronously from the Settings picker's
        // binding write re-enters AppKit mid view update, so defer it a tick.
        DispatchQueue.main.async {
            switch mode {
            case .system: NSApp.appearance = nil
            case .light: NSApp.appearance = NSAppearance(named: .aqua)
            case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
            }
        }
    }

    // MARK: - Opening

    func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        exitEditDiscarding()
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir)
        let folder = isDir.boolValue ? first : first.deletingLastPathComponent()
        UserDefaults.standard.set(folder, forKey: "lastFolder")
        scan(folder: folder, selecting: isDir.boolValue ? nil : first)
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a photo, or a folder of photos"
        if let last = UserDefaults.standard.url(forKey: "lastFolder") {
            panel.directoryURL = last
        }
        if panel.runModal() == .OK, let url = panel.url {
            open([url])
        }
    }

    private func scan(folder: URL, selecting: URL?) {
        let keys: [URLResourceKey] = [.contentTypeKey, .contentModificationDateKey,
                                      .creationDateKey, .fileSizeKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var images = contents.filter { url in
            guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
            return type.conforms(to: .image)
        }
        sortInPlace(&images)
        files = images

        if let sel = selecting, let i = images.firstIndex(where: { $0.path == sel.path }) {
            show(i, animated: false)
        } else if !images.isEmpty {
            show(0, animated: false)
        } else {
            display = nil; baseImage = nil; info = nil
            showToast("No images found in \(folder.lastPathComponent)")
        }
    }

    private func sortInPlace(_ urls: inout [URL]) {
        func date(_ u: URL, _ key: URLResourceKey) -> Date {
            let rv = try? u.resourceValues(forKeys: [key])
            return (key == .creationDateKey ? rv?.creationDate : rv?.contentModificationDate) ?? .distantPast
        }
        switch sortOrder {
        case .name:
            urls.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        case .dateModified:
            urls.sort { date($0, .contentModificationDateKey) < date($1, .contentModificationDateKey) }
        case .dateCreated:
            urls.sort { date($0, .creationDateKey) < date($1, .creationDateKey) }
        case .size:
            func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
            urls.sort { size($0) < size($1) }
        }
    }

    private func resort() {
        guard let current = currentURL else { return }
        var f = files
        sortInPlace(&f)
        files = f
        if let i = f.firstIndex(of: current) { index = i }
    }

    // MARK: - Display

    func show(_ newIndex: Int, animated: Bool = true) {
        guard files.indices.contains(newIndex), !isEditing else { return }
        index = newIndex
        rotationQuarters = 0
        generation += 1
        let gen = generation
        guard let url = currentURL else { return }

        // Don't animate while keys are repeating, the transition can't keep up
        // and the whole thing starts to feel laggy.
        let now = Date()
        let rapid = now.timeIntervalSince(lastNavDate) < 0.35
        lastNavDate = now
        let useTransition = animated && transitionStyle != .none && !rapid

        if let cached = loader.cachedFullImage(for: url) {
            // already decoded, show it on this very keypress
            baseImage = cached
            isLoading = false
            setDisplay(DisplayedImage(image: cached, url: url, rotation: 0),
                       animated: useTransition)
        } else {
            // not cached yet: get a cheap screen-sized preview up fast
            if display == nil { isLoading = true }
            Task { [weak self] in
                guard let self else { return }
                let preview = await self.loader.quickPreview(for: url)
                guard self.generation == gen, let preview else { return }
                // bail if the full-res load beat us to it
                if let d = self.display, d.url == url, !d.isPreview { return }
                self.isLoading = false
                self.setDisplay(DisplayedImage(image: preview, url: url,
                                               rotation: 0, isPreview: true),
                                animated: useTransition)
            }
        }

        // Full-res decode and metadata. Swaps in over the preview without
        // animating so the upgrade is invisible.
        Task { [weak self] in
            guard let self else { return }
            let img = await self.loader.image(for: url)
            let inf = await self.loader.info(for: url)
            guard self.generation == gen else { return }
            self.isLoading = false
            self.info = inf
            if let img {
                self.baseImage = img
                let alreadyShowingFull = self.display?.url == url && self.display?.isPreview == false
                if !alreadyShowingFull && self.rotationQuarters == 0 {
                    self.setDisplay(DisplayedImage(image: img, url: url, rotation: 0),
                                    animated: false)
                }
            } else if self.display?.url != url {
                self.display = nil
                self.showToast("Couldn't load \(url.lastPathComponent)")
            }
            self.preloadNeighbors()
        }
    }

    private func setDisplay(_ newDisplay: DisplayedImage, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.3)) { display = newDisplay }
        } else {
            display = newDisplay
        }
    }

    private func preloadNeighbors() {
        for offset in [1, -1, 2, -2, 3] {
            let i = index + offset
            if files.indices.contains(i) { loader.preload(files[i]) }
        }
    }

    /// The SwiftUI transition for the current style and direction.
    var photoTransition: AnyTransition {
        let dir = navDirection
        switch transitionStyle {
        case .none:
            return .identity
        case .fade:
            return .opacity
        case .slide:
            return .asymmetric(
                insertion: .offset(x: 60 * dir).combined(with: .opacity),
                removal: .offset(x: -60 * dir).combined(with: .opacity))
        case .cinematic:
            return .asymmetric(
                insertion: .offset(x: 26 * dir)
                    .combined(with: .scale(scale: 1.035))
                    .combined(with: .opacity),
                removal: .scale(scale: 0.985).combined(with: .opacity))
        }
    }

    // MARK: - Navigation

    func next(wrap: Bool = false) {
        guard !files.isEmpty, !isEditing else { return }
        navDirection = 1
        if index + 1 < files.count { show(index + 1) }
        else if wrap { show(0) }
        else { showToast("Last photo") }
    }

    func previous() {
        guard !files.isEmpty, !isEditing else { return }
        navDirection = -1
        if index > 0 { show(index - 1) }
        else { showToast("First photo") }
    }

    func first() { navDirection = -1; show(0) }
    func last() { navDirection = 1; show(files.count - 1) }

    // MARK: - Rotation (viewer-only, non-destructive)

    func rotate(clockwise: Bool) {
        guard let base = baseImage, let url = currentURL else { return }
        rotationQuarters = ((rotationQuarters + (clockwise ? 1 : -1)) % 4 + 4) % 4
        let img = rotationQuarters == 0 ? base : Self.rotated(base, quarters: rotationQuarters)
        display = DisplayedImage(image: img, url: url, rotation: rotationQuarters)
    }

    private static func rotated(_ image: NSImage, quarters: Int) -> NSImage {
        let q = ((quarters % 4) + 4) % 4
        guard q != 0 else { return image }
        let size = image.size
        let newSize = q % 2 == 0 ? size : NSSize(width: size.height, height: size.width)
        return NSImage(size: newSize, flipped: false) { rect in
            let t = NSAffineTransform()
            t.translateX(by: rect.width / 2, yBy: rect.height / 2)
            t.rotate(byDegrees: CGFloat(-90 * q))
            t.translateX(by: -size.width / 2, yBy: -size.height / 2)
            t.concat()
            image.draw(in: NSRect(origin: .zero, size: size))
            return true
        }
    }

    // MARK: - File operations

    func moveToTrash() {
        guard let url = currentURL, !isEditing else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            loader.evict(url)
            var f = files
            f.remove(at: index)
            files = f
            showToast("Moved to Trash: \(url.lastPathComponent)")
            if f.isEmpty {
                display = nil; baseImage = nil; info = nil
            } else {
                show(min(index, f.count - 1), animated: false)
            }
        } catch {
            showToast("Couldn't move to Trash: \(error.localizedDescription)")
        }
    }

    func copyFile() {
        guard let url = currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        showToast("File copied — paste in Finder, Mail, Slack…")
    }

    func copyImage() {
        guard let img = image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        showToast("Image pixels copied")
    }

    func revealInFinder() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInDefaultApp() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.open(url)
    }

    func setAsWallpaper() {
        guard let url = currentURL, let screen = NSScreen.main else { return }
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            showToast("Wallpaper set")
        } catch {
            showToast("Couldn't set wallpaper: \(error.localizedDescription)")
        }
    }

    // MARK: - Edit mode

    func toggleEdit() {
        isEditing ? requestExitEdit() : enterEdit()
    }

    func enterEdit() {
        guard let url = currentURL, editSession == nil else { return }
        stopSlideshow()
        guard let session = EditSession(url: url) else {
            showToast("Can't edit \(url.lastPathComponent)")
            return
        }
        editSession = session
    }

    /// Exit edit mode, confirming first if there are unsaved changes.
    func requestExitEdit() {
        guard let session = editSession else { return }
        if session.isDirty {
            let alert = NSAlert()
            alert.messageText = "Discard edits?"
            alert.informativeText = "Your changes to \(session.url.lastPathComponent) haven't been saved."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Keep Editing")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        exitEditDiscarding()
    }

    func exitEditDiscarding() {
        editSession = nil
    }

    func saveEditsOverOriginal() {
        guard let session = editSession else { return }
        let alert = NSAlert()
        alert.messageText = "Replace the original file?"
        alert.informativeText = "\(session.url.lastPathComponent) will be overwritten. This can't be undone."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await save(session: session, to: session.url) }
    }

    func saveEditsAs() {
        guard let session = editSession else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        panel.allowsOtherFileTypes = false
        panel.directoryURL = session.url.deletingLastPathComponent()
        let stem = session.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(stem)-edited.\(session.url.pathExtension.lowercased())"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task { await save(session: session, to: dest) }
    }

    private func save(session: EditSession, to destination: URL) async {
        showToast("Saving…")
        guard let cg = await session.renderFullResolution() else {
            showToast("Render failed — nothing was written")
            return
        }
        let overwriting = destination == session.url
        do {
            if overwriting {
                // Write to a temp file, then atomically swap in.
                let tmp = destination.deletingLastPathComponent()
                    .appendingPathComponent(".\(destination.lastPathComponent).tmp-\(ProcessInfo.processInfo.processIdentifier)")
                try EditEngine.export(cg, to: tmp, type: EditEngine.exportType(for: destination),
                                      quality: 0.92, copyingMetadataFrom: session.url)
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmp)
            } else {
                try EditEngine.export(cg, to: destination, type: EditEngine.exportType(for: destination),
                                      quality: 0.92, copyingMetadataFrom: session.url)
            }
            loader.evict(destination)
            loader.evict(session.url)
            exitEditDiscarding()
            // Rescan so a new file appears in the strip; select what we saved.
            scan(folder: destination.deletingLastPathComponent(), selecting: destination)
            showToast("Saved \(destination.lastPathComponent)")
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Slideshow

    func toggleSlideshow() {
        isSlideshowRunning ? stopSlideshow() : startSlideshow()
    }

    func startSlideshow() {
        guard !isEditing else { return }
        slideshowTimer?.invalidate()
        isSlideshowRunning = true
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: slideshowInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.next(wrap: true) }
        }
        let secs = slideshowInterval == slideshowInterval.rounded()
            ? "\(Int(slideshowInterval))" : String(format: "%.1f", slideshowInterval)
        showToast("Slideshow: \(secs)s per photo — press S to stop")
    }

    func stopSlideshow() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        if isSlideshowRunning {
            isSlideshowRunning = false
            showToast("Slideshow stopped")
        }
    }

    // MARK: - Fullscreen / toast

    func toggleFullscreen() {
        (viewerWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: - Keyboard

    /// Returns true if the key was handled (event will be swallowed).
    func handleKey(_ event: NSEvent) -> Bool {
        guard NSApp.modalWindow == nil else { return false }
        guard let kw = NSApp.keyWindow, kw === viewerWindow else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return false }

        if showHelp {  // any key dismisses the help overlay
            showHelp = false
            return true
        }

        if isEditing { return handleEditKey(event) }

        if event.keyCode == 53 {  // esc, deliberately not remappable
            if showInfo || showFilmstrip { showInfo = false; showFilmstrip = false; return true }
            if isSlideshowRunning { stopSlideshow(); return true }
            if let w = viewerWindow, w.styleMask.contains(.fullScreen) {
                w.toggleFullScreen(nil)
                return true
            }
            return false
        }

        guard let action = keymap.action(for: event) else { return false }
        perform(action)
        return true
    }

    private func handleEditKey(_ event: NSEvent) -> Bool {
        guard let session = editSession else { return false }
        if event.keyCode == 53 {  // esc
            if session.isCropping { session.cancelCrop(); return true }
            requestExitEdit()
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": session.showOriginal.toggle(); return true
        case "f": toggleFullscreen(); return true
        case "e": requestExitEdit(); return true
        default: return false
        }
    }

    func perform(_ action: KeyAction) {
        switch action {
        case .nextPhoto: next()
        case .previousPhoto: previous()
        case .firstPhoto: first()
        case .lastPhoto: last()
        case .toggleFullscreen: toggleFullscreen()
        case .zoomIn: zoom?.zoomIn()
        case .zoomOut: zoom?.zoomOut()
        case .zoomFit: zoom?.zoomToFit()
        case .zoomActual: zoom?.zoomTo(1)
        case .zoom200: zoom?.zoomTo(2)
        case .zoom300: zoom?.zoomTo(3)
        case .rotateCW: rotate(clockwise: true)
        case .rotateCCW: rotate(clockwise: false)
        case .toggleInfo: showInfo.toggle()
        case .toggleFilmstrip: showFilmstrip.toggle()
        case .toggleSlideshow: toggleSlideshow()
        case .toggleHUD: showHUD.toggle()
        case .toggleHelp: showHelp.toggle()
        case .moveToTrash: moveToTrash()
        case .toggleEdit: toggleEdit()
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
