import AppKit
import SwiftUI

@MainActor
protocol ZoomControlling: AnyObject {
    func zoomIn()
    func zoomOut()
    func zoomToFit()
    func zoomTo(_ scale: CGFloat)
}

/// The image canvas. An NSScrollView under the hood, which gets us trackpad
/// pinch and smooth panning for free; the rest (wheel zoom, drag to pan,
/// double-click, refit on resize) is layered on top.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let imageID: String
    /// Has to be a stored property rather than read off the model inside
    /// updateNSView, or SwiftUI won't re-run the update when the theme flips.
    let canvasColor: NSColor
    let model: ViewerModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ImageScrollView {
        let scrollView = ImageScrollView()
        context.coordinator.setup(scrollView)
        context.coordinator.onZoomChange = { [weak model] mag in
            DispatchQueue.main.async {
                guard let model else { return }
                if abs(model.zoomLevel - mag) > 0.0005 { model.zoomLevel = mag }
            }
        }
        model.zoom = context.coordinator
        return scrollView
    }

    func updateNSView(_ nsView: ImageScrollView, context: Context) {
        model.zoom = context.coordinator
        if nsView.backgroundColor != canvasColor {
            nsView.backgroundColor = canvasColor
            (nsView.contentView as? CenteringClipView)?.backgroundColor = canvasColor
        }
        if context.coordinator.currentID != imageID {
            context.coordinator.display(image, id: imageID)
        }
    }

    @MainActor
    final class Coordinator: NSObject, ZoomControlling {
        private(set) var currentID: String?
        var onZoomChange: ((CGFloat) -> Void)?
        var userZoomed = false
        weak var scrollView: ImageScrollView?
        let imageView = DraggableImageView()

        func setup(_ scrollView: ImageScrollView) {
            self.scrollView = scrollView
            scrollView.coordinator = self
            scrollView.hasHorizontalScroller = true
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            scrollView.drawsBackground = true
            scrollView.backgroundColor = .black
            scrollView.allowsMagnification = true
            scrollView.minMagnification = 0.02
            scrollView.maxMagnification = 60

            let clipView = CenteringClipView()
            clipView.drawsBackground = true
            clipView.backgroundColor = .black
            scrollView.contentView = clipView
            scrollView.documentView = imageView

            imageView.imageScaling = .scaleAxesIndependently
            imageView.animates = true
            imageView.coordinator = self

            NotificationCenter.default.addObserver(
                self, selector: #selector(magnifyEnded),
                name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification, object: clipView)
        }

        @objc private func magnifyEnded(_ note: Notification) {
            userZoomed = true
        }

        @objc private func boundsChanged(_ note: Notification) {
            guard let sv = scrollView else { return }
            onZoomChange?(sv.magnification)
        }

        func display(_ image: NSImage, id: String) {
            currentID = id
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: image.size)
            userZoomed = false
            zoomToFit()
        }

        var fitMagnification: CGFloat {
            guard let sv = scrollView, let img = imageView.image,
                  img.size.width > 0, img.size.height > 0,
                  sv.bounds.width > 1, sv.bounds.height > 1 else { return 1 }
            let fit = min(sv.bounds.width / img.size.width, sv.bounds.height / img.size.height)
            return min(fit, 1)  // never upscale past 100% for "fit"
        }

        func zoomToFit() {
            guard let sv = scrollView else { return }
            sv.magnification = fitMagnification
            centerDocument()
            userZoomed = false
            onZoomChange?(sv.magnification)
        }

        func zoomIn() { applyZoom((scrollView?.magnification ?? 1) * 1.25) }
        func zoomOut() { applyZoom((scrollView?.magnification ?? 1) / 1.25) }
        func zoomTo(_ scale: CGFloat) { applyZoom(scale) }

        private func applyZoom(_ magnification: CGFloat) {
            guard let sv = scrollView else { return }
            userZoomed = true
            let clamped = max(sv.minMagnification, min(sv.maxMagnification, magnification))
            let visible = sv.contentView.bounds
            sv.setMagnification(clamped, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
            onZoomChange?(clamped)
        }

        func toggleZoom(at documentPoint: NSPoint) {
            guard let sv = scrollView else { return }
            if sv.magnification < 0.999 {
                userZoomed = true
                sv.setMagnification(1, centeredAt: documentPoint)
                onZoomChange?(1)
            } else {
                zoomToFit()
            }
        }

        private func centerDocument() {
            guard let sv = scrollView else { return }
            let doc = imageView.frame
            let clip = sv.contentView.bounds.size
            imageView.scroll(NSPoint(x: doc.midX - clip.width / 2, y: doc.midY - clip.height / 2))
        }
    }
}

final class ImageScrollView: NSScrollView {
    weak var coordinator: ZoomableImageView.Coordinator?
    private var lastSize: NSSize = .zero

    override func layout() {
        super.layout()
        if bounds.size != lastSize {
            lastSize = bounds.size
            if coordinator?.userZoomed == false {
                coordinator?.zoomToFit()
            }
        }
    }

    // Mouse wheels zoom, trackpads pan, and option-scroll zooms on both.
    // Wheels are recognisable by their non-precise deltas and lack of a
    // gesture phase.
    override func scrollWheel(with event: NSEvent) {
        let isMouseWheel = !event.hasPreciseScrollingDeltas
            && event.phase == [] && event.momentumPhase == []
        if event.modifierFlags.contains(.option) || isMouseWheel {
            guard event.scrollingDeltaY != 0 else { return }
            // wheel notches are far coarser than trackpad deltas
            let rate = event.hasPreciseScrollingDeltas ? 0.01 : 0.05
            let factor = exp(event.scrollingDeltaY * rate)
            let newMag = max(minMagnification, min(maxMagnification, magnification * factor))
            let point = contentView.convert(event.locationInWindow, from: nil)
            setMagnification(newMag, centeredAt: point)
            coordinator?.userZoomed = true
            coordinator?.onZoomChange?(newMag)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Keeps the image centered when it's smaller than the viewport.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if doc.frame.width < rect.width {
            rect.origin.x = doc.frame.minX - (rect.width - doc.frame.width) / 2
        }
        if doc.frame.height < rect.height {
            rect.origin.y = doc.frame.minY - (rect.height - doc.frame.height) / 2
        }
        return rect
    }
}

final class DraggableImageView: NSImageView {
    weak var coordinator: ZoomableImageView.Coordinator?
    private var dragStart: NSPoint?
    private var clipOriginAtDragStart: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            coordinator?.toggleZoom(at: convert(event.locationInWindow, from: nil))
            return
        }
        dragStart = event.locationInWindow
        clipOriginAtDragStart = enclosingScrollView?.contentView.bounds.origin ?? .zero
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let sv = enclosingScrollView else { return }
        let mag = max(sv.magnification, 0.0001)
        let dx = (event.locationInWindow.x - start.x) / mag
        let dy = (event.locationInWindow.y - start.y) / mag
        let desired = NSPoint(x: clipOriginAtDragStart.x - dx, y: clipOriginAtDragStart.y - dy)
        let clip = sv.contentView
        let constrained = clip.constrainBoundsRect(NSRect(origin: desired, size: clip.bounds.size))
        clip.setBoundsOrigin(constrained.origin)
        sv.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        NSCursor.arrow.set()
    }
}
