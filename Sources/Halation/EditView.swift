import SwiftUI
import AppKit

struct EditView: View {
    @EnvironmentObject var model: ViewerModel
    @ObservedObject var session: EditSession

    var body: some View {
        HStack(spacing: 0) {
            canvas
            EditPanel(session: session)
                .frame(width: 300)
                .background(.regularMaterial)
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: model.canvasNSColor)
                if let img = session.preview {
                    let fitted = fitSize(img.size, in: CGSize(width: geo.size.width - 32,
                                                              height: geo.size.height - 32))
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .overlay {
                            if session.isCropping {
                                CropOverlay(norm: $session.cropDraft,
                                            aspect: session.cropAspect.ratio(imageSize: img.size))
                            }
                        }
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                } else {
                    ProgressView().controlSize(.large)
                }
                if session.showOriginal {
                    Text("Original")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .position(x: geo.size.width / 2, y: 28)
                }
            }
        }
    }

    private func fitSize(_ image: CGSize, in container: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0,
              container.width > 0, container.height > 0 else { return image }
        let scale = min(container.width / image.width, container.height / image.height, 1.5)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

// MARK: - Crop overlay

struct CropOverlay: View {
    @Binding var norm: CGRect        // normalized, top-left origin
    let aspect: CGFloat?             // target pixel aspect (w/h), nil = free

    @State private var startRect: CGRect?

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    var body: some View {
        GeometryReader { geo in
            let s = geo.size
            let r = viewRect(in: s)
            ZStack {
                // Dim everything outside the crop rect
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: s))
                    p.addRect(r)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

                // Border + rule-of-thirds grid
                Rectangle().path(in: r).stroke(Color.white, lineWidth: 1.5)
                Path { p in
                    for i in 1...2 {
                        let x = r.minX + r.width * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: r.minY))
                        p.addLine(to: CGPoint(x: x, y: r.maxY))
                        let y = r.minY + r.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: r.minX, y: y))
                        p.addLine(to: CGPoint(x: r.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 0.5)

                // Move gesture (whole rect)
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: max(r.width, 1), height: max(r.height, 1))
                    .position(x: r.midX, y: r.midY)
                    .gesture(moveGesture(in: s))

                // Resize handles
                ForEach(Array(Handle.allCases.enumerated()), id: \.offset) { _, handle in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                        .frame(width: 12, height: 12)
                        .position(position(of: handle, in: r))
                        .gesture(resizeGesture(handle, in: s))
                }
            }
            .onChange(of: aspect) {
                // Snap to the largest centered rect with the chosen ratio.
                // The overlay's view space is proportional to image pixels,
                // so the pixel ratio applies directly.
                guard let aspect, s.width > 0, s.height > 0 else { return }
                var w = s.width, h = w / aspect
                if h > s.height { h = s.height; w = h * aspect }
                setViewRect(CGRect(x: (s.width - w) / 2, y: (s.height - h) / 2,
                                   width: w, height: h), in: s)
            }
        }
    }

    private func viewRect(in s: CGSize) -> CGRect {
        CGRect(x: norm.minX * s.width, y: norm.minY * s.height,
               width: norm.width * s.width, height: norm.height * s.height)
    }

    private func setViewRect(_ r: CGRect, in s: CGSize) {
        guard s.width > 0, s.height > 0 else { return }
        norm = CGRect(x: r.minX / s.width, y: r.minY / s.height,
                      width: r.width / s.width, height: r.height / s.height)
    }

    private func position(of handle: Handle, in r: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }

    private func moveGesture(in s: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if startRect == nil { startRect = viewRect(in: s) }
                guard var r = startRect else { return }
                r.origin.x = min(max(0, r.origin.x + value.translation.width), s.width - r.width)
                r.origin.y = min(max(0, r.origin.y + value.translation.height), s.height - r.height)
                setViewRect(r, in: s)
            }
            .onEnded { _ in startRect = nil }
    }

    private func resizeGesture(_ handle: Handle, in s: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if startRect == nil { startRect = viewRect(in: s) }
                guard let r0 = startRect else { return }
                let minSide: CGFloat = 32
                var r = r0
                let dx = value.translation.width
                let dy = value.translation.height

                // Adjust the edges this handle controls
                switch handle {
                case .topLeft, .left, .bottomLeft:
                    let newX = min(max(0, r0.minX + dx), r0.maxX - minSide)
                    r.size.width = r0.maxX - newX
                    r.origin.x = newX
                case .topRight, .right, .bottomRight:
                    r.size.width = min(max(minSide, r0.width + dx), s.width - r0.minX)
                default: break
                }
                switch handle {
                case .topLeft, .top, .topRight:
                    let newY = min(max(0, r0.minY + dy), r0.maxY - minSide)
                    r.size.height = r0.maxY - newY
                    r.origin.y = newY
                case .bottomLeft, .bottom, .bottomRight:
                    r.size.height = min(max(minSide, r0.height + dy), s.height - r0.minY)
                default: break
                }

                // Enforce aspect ratio (view space shares the image's aspect,
                // so the pixel ratio applies directly)
                if let aspect {
                    let isCorner: Bool
                    switch handle {
                    case .topLeft, .topRight, .bottomLeft, .bottomRight: isCorner = true
                    default: isCorner = false
                    }
                    if isCorner || handle == .left || handle == .right {
                        r.size.height = r.width / aspect
                    } else {
                        r.size.width = r.height * aspect
                    }
                    // Keep the anchored corner fixed
                    switch handle {
                    case .topLeft, .top, .topRight, .left:
                        r.origin.y = r0.maxY - r.height
                    default: break
                    }
                    switch handle {
                    case .topLeft, .left, .bottomLeft, .top:
                        r.origin.x = r0.maxX - r.width
                    default: break
                    }
                    // Clamp inside bounds, preserving ratio
                    if r.minX < 0 || r.minY < 0 || r.maxX > s.width || r.maxY > s.height {
                        let scale = min(
                            r.minX < 0 ? (r.maxX) / r.width : 1,
                            r.minY < 0 ? (r.maxY) / r.height : 1,
                            r.maxX > s.width ? (s.width - r.minX) / r.width : 1,
                            r.maxY > s.height ? (s.height - r.minY) / r.height : 1)
                        let newW = r.width * scale
                        let newH = r.height * scale
                        if r.minX < 0 { r.origin.x = 0 } else if r.maxX > s.width { r.origin.x = s.width - newW }
                        if r.minY < 0 { r.origin.y = 0 } else if r.maxY > s.height { r.origin.y = s.height - newH }
                        r.size = CGSize(width: newW, height: newH)
                    }
                }
                setViewRect(r, in: s)
            }
            .onEnded { _ in startRect = nil }
    }

}

// MARK: - Panel

struct EditPanel: View {
    @EnvironmentObject var model: ViewerModel
    @ObservedObject var session: EditSession

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    presets
                    Divider()
                    geometry
                    Divider()
                    light
                    Divider()
                    color
                    Divider()
                    detail
                }
                .padding(16)
            }
            Divider()
            footer
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Presets")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(EditPreset.all) { preset in
                        Button(preset.name) {
                            var p = session.params
                            // Presets describe color; clear color, keep geometry
                            EditPreset.all[0].apply(&p)
                            if preset.name != "Original" { preset.apply(&p) }
                            session.params = p
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var geometry: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Geometry")
            HStack(spacing: 8) {
                Button { session.params.quarters = (session.params.quarters + 3) % 4 } label: {
                    Image(systemName: "rotate.left")
                }.help("Rotate counterclockwise")
                Button { session.params.quarters = (session.params.quarters + 1) % 4 } label: {
                    Image(systemName: "rotate.right")
                }.help("Rotate clockwise")
                Button { session.params.flipH.toggle() } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }.help("Flip horizontal")
                Button { session.params.flipV.toggle() } label: {
                    Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }.help("Flip vertical")
                Spacer()
                if session.isCropping {
                    Button("Cancel") { session.cancelCrop() }
                        .controlSize(.small)
                    Button("Apply") { session.applyCrop() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        session.beginCrop()
                    } label: {
                        Label(session.params.crop == nil ? "Crop" : "Crop ✓", systemImage: "crop")
                    }
                    .controlSize(.small)
                }
            }
            if session.isCropping {
                Picker("Aspect", selection: $session.cropAspect) {
                    ForEach(CropAspect.allCases) { a in Text(a.rawValue).tag(a) }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            EditSlider(label: "Straighten", value: $session.params.straighten,
                       range: -15...15, defaultValue: 0, unit: "°")
        }
    }

    private var light: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Light")
            EditSlider(label: "Exposure", value: $session.params.exposure,
                       range: -2...2, defaultValue: 0, decimals: 2)
            EditSlider(label: "Contrast", value: $session.params.contrast,
                       range: -50...50, defaultValue: 0)
            EditSlider(label: "Highlights", value: $session.params.highlights,
                       range: 0...100, defaultValue: 0)
            EditSlider(label: "Shadows", value: $session.params.shadows,
                       range: -100...100, defaultValue: 0)
        }
    }

    private var color: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Color")
            EditSlider(label: "Saturation", value: $session.params.saturation,
                       range: -100...100, defaultValue: 0)
            EditSlider(label: "Vibrance", value: $session.params.vibrance,
                       range: -100...100, defaultValue: 0)
            EditSlider(label: "Warmth", value: $session.params.warmth,
                       range: -100...100, defaultValue: 0)
            EditSlider(label: "Tint", value: $session.params.tint,
                       range: -100...100, defaultValue: 0)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Detail")
            EditSlider(label: "Sharpness", value: $session.params.sharpness,
                       range: 0...100, defaultValue: 0)
            EditSlider(label: "Vignette", value: $session.params.vignette,
                       range: 0...100, defaultValue: 0)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle(isOn: $session.showOriginal) {
                    Label("Compare", systemImage: "eye")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show the unedited original (C)")
                Spacer()
                Button("Reset All") { session.resetAll() }
                    .controlSize(.small)
                    .disabled(!session.isDirty)
            }
            HStack {
                Button("Cancel") { model.requestExitEdit() }
                Spacer()
                Button("Save As…") { model.saveEditsAs() }
                    .disabled(!session.isDirty)
                Button("Save") { model.saveEditsOverOriginal() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.isDirty)
                    .help("Overwrite the original file")
            }
        }
        .padding(12)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

struct EditSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var decimals: Int = 0
    var unit: String = ""

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .onTapGesture(count: 2) { value = defaultValue }
                Spacer()
                Text(formatted)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(value == defaultValue ? .tertiary : .secondary)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
        .help("Double-click the label to reset")
    }

    private var formatted: String {
        String(format: "%.\(decimals)f", value) + unit
    }
}
