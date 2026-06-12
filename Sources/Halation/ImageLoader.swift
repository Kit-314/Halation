import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ImageInfo {
    var fileName = ""
    var folder = ""
    var pixelWidth = 0
    var pixelHeight = 0
    var pixelSize: String?
    var fileSize: String?
    var created: String?
    var modified: String?
    var captureDate: String?
    var cameraMake: String?
    var cameraModel: String?
    var lens: String?
    var focalLength: String?
    var aperture: String?
    var shutter: String?
    var iso: String?
    var colorInfo: String?
    var gpsLatitude: Double?
    var gpsLongitude: Double?
}

/// Decodes images off the main thread, honors EXIF orientation, and keeps
/// small caches of full-size images and filmstrip thumbnails.
final class ImageLoader {
    private let cache = NSCache<NSURL, NSImage>()
    private let thumbCache = NSCache<NSURL, NSImage>()
    private let previewCache = NSCache<NSURL, NSImage>()

    init() {
        cache.countLimit = 12
        thumbCache.countLimit = 600
        previewCache.countLimit = 16
    }

    func evict(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
        thumbCache.removeObject(forKey: url as NSURL)
        previewCache.removeObject(forKey: url as NSURL)
    }

    /// Cache lookup without the async hop, for instant display while the user
    /// is flicking through a folder.
    func cachedFullImage(for url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Screen-sized decode, roughly 3x faster than decoding the full image.
    /// Shown immediately while the real decode catches up.
    func quickPreview(for url: URL) async -> NSImage? {
        if let hit = previewCache.object(forKey: url as NSURL) { return hit }
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let img { previewCache.setObject(img, forKey: url as NSURL) }
        return img
    }

    func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let img = await Task.detached(priority: .userInitiated) { Self.decode(url) }.value
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
    }

    func preload(_ url: URL) {
        let cache = self.cache
        Task.detached(priority: .utility) {
            if cache.object(forKey: url as NSURL) == nil, let img = Self.decode(url) {
                cache.setObject(img, forKey: url as NSURL)
            }
        }
    }

    func thumbnail(for url: URL, maxPixel: CGFloat = 320) async -> NSImage? {
        if let hit = thumbCache.object(forKey: url as NSURL) { return hit }
        let img = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let img { thumbCache.setObject(img, forKey: url as NSURL) }
        return img
    }

    func info(for url: URL) async -> ImageInfo {
        await Task.detached(priority: .userInitiated) { Self.buildInfo(url) }.value
    }

    // MARK: - Decoding

    static func decode(_ url: URL) -> NSImage? {
        let ext = url.pathExtension.lowercased()
        // NSImage preserves GIF animation; ImageIO path below would flatten it.
        if ext == "gif", let img = NSImage(contentsOf: url) {
            return img
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        // ImageIO quirk: CGImageSourceCreateImageAtIndex ignores EXIF
        // orientation but the thumbnail API respects it, so ask for a
        // "thumbnail" at full size to get a correctly rotated image.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - Metadata

    static func buildInfo(_ url: URL) -> ImageInfo {
        var info = ImageInfo()
        info.fileName = url.lastPathComponent
        info.folder = url.deletingLastPathComponent().path

        if let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]) {
            if let s = rv.fileSize {
                info.fileSize = ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)
            }
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            if let d = rv.creationDate { info.created = df.string(from: d) }
            if let d = rv.contentModificationDate { info.modified = df.string(from: d) }
        }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return info
        }

        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            info.pixelWidth = w
            info.pixelHeight = h
            let mp = Double(w * h) / 1_000_000
            info.pixelSize = mp >= 0.95
                ? "\(w) × \(h)  (\(String(format: "%.1f", mp)) MP)"
                : "\(w) × \(h)"
        }
        if let model = props[kCGImagePropertyColorModel] as? String {
            if let depth = props[kCGImagePropertyDepth] as? Int {
                info.colorInfo = "\(model), \(depth)-bit"
            } else {
                info.colorInfo = model
            }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            info.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?
                .trimmingCharacters(in: .whitespaces)
            info.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?
                .trimmingCharacters(in: .whitespaces)
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            info.captureDate = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            info.lens = exif[kCGImagePropertyExifLensModel] as? String
            if let f = exif[kCGImagePropertyExifFNumber] as? Double {
                info.aperture = String(format: "ƒ/%.1f", f)
            }
            if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
                info.shutter = t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s"
            }
            if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [Any], let i = isos.first {
                info.iso = "ISO \(i)"
            }
            if let fl35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int {
                info.focalLength = "\(fl35) mm (35mm eq.)"
            } else if let fl = exif[kCGImagePropertyExifFocalLength] as? Double {
                info.focalLength = String(format: "%.0f mm", fl)
            }
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           var lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           var lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = -lon }
            info.gpsLatitude = lat
            info.gpsLongitude = lon
        }
        return info
    }
}
