import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// All edit parameters. `identity` means "no change".
struct EditParams: Equatable {
    var exposure: Double = 0        // EV, -2...2
    var contrast: Double = 0        // -50...50 (0 = neutral)
    var saturation: Double = 0      // -100...100
    var vibrance: Double = 0        // -100...100
    var highlights: Double = 0      // 0...100 (recovery)
    var shadows: Double = 0         // -100...100
    var warmth: Double = 0          // -100...100
    var tint: Double = 0            // -100...100
    var sharpness: Double = 0       // 0...100
    var vignette: Double = 0        // 0...100

    var quarters: Int = 0           // clockwise 90° steps
    var flipH = false
    var flipV = false
    var straighten: Double = 0      // degrees, -15...15
    var crop: CGRect?               // normalized, top-left origin, post-geometry

    static let identity = EditParams()

    var hasColorEdits: Bool {
        exposure != 0 || contrast != 0 || saturation != 0 || vibrance != 0
            || highlights != 0 || shadows != 0 || warmth != 0 || tint != 0
            || sharpness != 0 || vignette != 0
    }
}

enum EditEngine {
    static let context = CIContext(options: [.cacheIntermediates: false])

    // MARK: - Pipeline

    static func apply(_ params: EditParams, to input: CIImage) -> CIImage {
        var image = input

        // --- Geometry ---
        if params.quarters % 4 != 0 {
            let orientations: [Int: CGImagePropertyOrientation] = [1: .right, 2: .down, 3: .left]
            let q = ((params.quarters % 4) + 4) % 4
            if let o = orientations[q] { image = image.oriented(o) }
        }
        if params.flipH { image = image.oriented(.upMirrored) }
        if params.flipV { image = image.oriented(.downMirrored) }
        image = normalized(image)

        if params.straighten != 0 {
            let radians = params.straighten * .pi / 180
            let extent = image.extent
            image = image.transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
                .transformed(by: CGAffineTransform(rotationAngle: CGFloat(-radians)))
            // Crop to largest axis-aligned rect that fits inside the rotated frame
            let inner = largestInscribedRect(width: extent.width, height: extent.height, angle: radians)
            image = image.cropped(to: CGRect(x: -inner.width / 2, y: -inner.height / 2,
                                             width: inner.width, height: inner.height))
            image = normalized(image)
        }

        if let crop = params.crop {
            let e = image.extent
            // crop is top-left normalized; CIImage is bottom-left
            let rect = CGRect(x: e.minX + crop.minX * e.width,
                              y: e.minY + (1 - crop.minY - crop.height) * e.height,
                              width: crop.width * e.width,
                              height: crop.height * e.height)
            image = normalized(image.cropped(to: rect.integral.intersection(e)))
        }

        // --- Color ---
        if params.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(params.exposure)
            image = f.outputImage ?? image
        }
        if params.contrast != 0 || params.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.contrast = Float(1 + params.contrast / 125)         // slider +-50 maps to +-0.4
            f.saturation = Float(1 + params.saturation / 100)     // slider +-100 maps to 0...2
            f.brightness = 0
            image = f.outputImage ?? image
        }
        if params.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = image
            f.amount = Float(params.vibrance / 100)
            image = f.outputImage ?? image
        }
        if params.highlights != 0 || params.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            f.highlightAmount = Float(1 - params.highlights / 100)  // 1 = unchanged
            f.shadowAmount = Float(params.shadows / 100)
            f.radius = 2
            image = f.outputImage ?? image
        }
        if params.warmth != 0 || params.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - params.warmth * 22, y: params.tint)
            image = f.outputImage ?? image
        }
        if params.sharpness != 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image
            f.sharpness = Float(params.sharpness / 60)
            image = f.outputImage ?? image
        }
        if params.vignette != 0 {
            let f = CIFilter.vignette()
            f.inputImage = image
            f.intensity = Float(params.vignette / 50)
            f.radius = 2
            image = f.outputImage ?? image
        }
        return image
    }

    private static func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                y: -image.extent.minY))
    }

    /// Biggest axis-aligned rectangle that still fits inside a w by h rect
    /// after rotating it by `angle` radians. Standard formula.
    static func largestInscribedRect(width w: CGFloat, height h: CGFloat, angle: Double) -> CGSize {
        guard w > 0, h > 0 else { return .zero }
        let sinA = abs(sin(angle)), cosA = abs(cos(angle))
        let longSide = max(w, h), shortSide = min(w, h)
        if shortSide <= 2 * sinA * cosA * longSide || abs(sinA - cosA) < 1e-10 {
            let x = 0.5 * shortSide
            return w >= h ? CGSize(width: x / sinA, height: x / cosA)
                          : CGSize(width: x / cosA, height: x / sinA)
        }
        let cos2A = cosA * cosA - sinA * sinA
        return CGSize(width: (w * cosA - h * sinA) / cos2A,
                      height: (h * cosA - w * sinA) / cos2A)
    }

    // MARK: - Rendering

    static func renderNSImage(_ input: CIImage, params: EditParams) -> NSImage? {
        let output = apply(params, to: input)
        guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func renderCGImage(_ input: CIImage, params: EditParams) -> CGImage? {
        let output = apply(params, to: input)
        return context.createCGImage(output, from: output.extent)
    }

    // MARK: - Export

    /// Writes `image` to `destination`, carrying over the original file's
    /// metadata (minus orientation/size, which the edit baked in).
    static func export(_ image: CGImage, to destination: URL, type: UTType,
                       quality: Double, copyingMetadataFrom source: URL?) throws {
        var properties: [CFString: Any] = [:]
        if let source,
           let src = CGImageSourceCreateWithURL(source as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            properties = props
            properties.removeValue(forKey: kCGImagePropertyOrientation)
            properties.removeValue(forKey: kCGImagePropertyPixelWidth)
            properties.removeValue(forKey: kCGImagePropertyPixelHeight)
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        properties[kCGImageDestinationLossyCompressionQuality] = quality

        guard let dest = CGImageDestinationCreateWithURL(
            destination as CFURL, type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "EditEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Can't create \(type.identifier) file"])
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "EditEngine", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed writing \(destination.lastPathComponent)"])
        }
    }

    static func exportType(for url: URL) -> UTType {
        switch url.pathExtension.lowercased() {
        case "png": .png
        case "heic", "heif": .heic
        case "tif", "tiff": .tiff
        case "bmp": .bmp
        default: .jpeg
        }
    }
}

// MARK: - Edit session

enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free"
    case original = "Original"
    case square = "1:1"
    case r4x3 = "4:3"
    case r3x2 = "3:2"
    case r16x9 = "16:9"

    var id: String { rawValue }

    func ratio(imageSize: CGSize) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: imageSize.height > 0 ? imageSize.width / imageSize.height : nil
        case .square: 1
        case .r4x3: 4.0 / 3.0
        case .r3x2: 3.0 / 2.0
        case .r16x9: 16.0 / 9.0
        }
    }
}

struct EditPreset: Identifiable {
    let name: String
    let apply: (inout EditParams) -> Void
    var id: String { name }

    static let all: [EditPreset] = [
        EditPreset(name: "Original") { p in
            let g = (p.quarters, p.flipH, p.flipV, p.straighten, p.crop)
            p = .identity
            (p.quarters, p.flipH, p.flipV, p.straighten, p.crop) = g
        },
        EditPreset(name: "Punch") { p in
            p.contrast = 18; p.vibrance = 30; p.saturation = 5; p.sharpness = 20
        },
        EditPreset(name: "Soft") { p in
            p.contrast = -15; p.highlights = 30; p.shadows = 25; p.saturation = -10
        },
        EditPreset(name: "Warm") { p in
            p.warmth = 35; p.vibrance = 10; p.contrast = 5
        },
        EditPreset(name: "Cool") { p in
            p.warmth = -30; p.tint = 5; p.contrast = 8
        },
        EditPreset(name: "Mono") { p in
            p.saturation = -100; p.contrast = 20; p.sharpness = 15
        },
        EditPreset(name: "Fade") { p in
            p.contrast = -20; p.exposure = 0.15; p.saturation = -25; p.vignette = 15
        },
    ]
}

@MainActor
final class EditSession: ObservableObject {
    let url: URL
    private let fullRes: CIImage
    private let previewBase: CIImage

    @Published var params = EditParams() { didSet { schedulePreview() } }
    @Published private(set) var preview: NSImage?
    @Published var isCropping = false { didSet { schedulePreview() } }
    @Published var cropDraft = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var cropAspect: CropAspect = .free
    @Published var showOriginal = false { didSet { schedulePreview() } }

    private var renderTask: Task<Void, Never>?

    var isDirty: Bool { params != .identity }

    init?(url: URL) {
        guard let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        self.url = url
        fullRes = ci
        let maxDim = max(ci.extent.width, ci.extent.height)
        let scale = min(1, 2200 / max(maxDim, 1))
        previewBase = scale < 1
            ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : ci
        schedulePreview()
    }

    /// Params used for the live preview: crop is suspended while the crop
    /// overlay is active so the user can see the full frame.
    private var previewParams: EditParams {
        if showOriginal { return .identity }
        var p = params
        if isCropping { p.crop = nil }
        return p
    }

    private func schedulePreview() {
        renderTask?.cancel()
        let base = previewBase
        let p = previewParams
        renderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000)
            guard !Task.isCancelled else { return }
            let img = await Task.detached(priority: .userInitiated) {
                EditEngine.renderNSImage(base, params: p)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.preview = img
        }
    }

    func beginCrop() {
        cropDraft = params.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        isCropping = true
    }

    func applyCrop() {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        params.crop = cropDraft == full ? nil : cropDraft
        isCropping = false
    }

    func cancelCrop() {
        isCropping = false
    }

    func resetAll() {
        params = .identity
        cropDraft = CGRect(x: 0, y: 0, width: 1, height: 1)
        isCropping = false
    }

    func renderFullResolution() async -> CGImage? {
        let base = fullRes
        let p = params
        return await Task.detached(priority: .userInitiated) {
            EditEngine.renderCGImage(base, params: p)
        }.value
    }
}
