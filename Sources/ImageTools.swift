// Image tools for the shelf, with ImageIO only: resize (by width, percent or longest side; never upscaled), convert (PNG, JPEG,
// HEIC when this Mac can encode it, TIFF), quality, strip metadata (GPS, camera, XMP; the colour profile stays), keep the
// originals or replace them (the originals go to the Trash); a PDF from images (PDFKit); images stitched into one. New files
// never overwrite anything ("name 2.jpg"). Tested by --shelf-test on generated images.

import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct ImageJob: Equatable, Codable {
    enum Resize: Equatable, Codable { case none, width(Int), percent(Int), maxSide(Int) }
    enum Format: String, Equatable, Codable, CaseIterable { case same, png, jpeg, heic, tiff }
    var resize = Resize.none
    var format = Format.same
    var quality = 0.85
    var stripMetadata = false
    /// Replace the originals (they go to the Trash); off: new files next to them.
    var replace = false

    var isIdentity: Bool { resize == .none && format == .same && !stripMetadata }
}

enum ImageTools {
    enum Failure: Error, LocalizedError, Equatable {
        case unreadable(String), cantWrite(String), unsupported(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let n): return String(format: L("%@ isn't an image Cocaine can read"), n)
            case .cantWrite(let n): return String(format: L("Couldn't write %@"), n)
            case .unsupported(let f): return String(format: L("This Mac can't write %@ images"), f)
            }
        }
    }

    /// The types this Mac's ImageIO can write (HEIC needs a hardware encoder some Intel Macs lack).
    static var writable: Set<String> { Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []) }
    static var canHEIC: Bool { writable.contains(UTType.heic.identifier) }
    /// The formats offered in the island: HEIC only when it can be written here.
    static var formats: [ImageJob.Format] { ImageJob.Format.allCases.filter { $0 != .heic || canHEIC } }

    static func isImage(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return t.conforms(to: .image) && !t.conforms(to: .pdf)
    }
    static func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }

    static func type(for f: ImageJob.Format, source: URL) -> UTType {
        switch f {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        case .same:
            let t = UTType(filenameExtension: source.pathExtension.lowercased()) ?? .png
            // Formats ImageIO reads but can't write (RAW, WebP on some systems…) come out as PNG.
            return writable.contains(t.identifier) ? t : .png
        }
    }

    /// The longest side to draw, or nil to keep the size (never larger than the original).
    static func targetMaxSide(_ r: ImageJob.Resize, width: Int, height: Int) -> Int? {
        let long = max(width, height)
        guard long > 0 else { return nil }
        let want: Int
        switch r {
        case .none: return nil
        case .maxSide(let m): want = m
        case .percent(let p): want = Int((Double(long) * Double(max(1, min(100, p))) / 100).rounded())
        case .width(let w):
            guard width > 0 else { return nil }
            want = Int((Double(w) / Double(width) * Double(long)).rounded())
        }
        return want > 0 && want < long ? want : nil
    }

    /// "photo-1200.jpg", "photo.png": what a processed file is called (before making it unique).
    static func outputName(_ source: URL, job: ImageJob, size: (Int, Int)?) -> String {
        let base = source.deletingPathExtension().lastPathComponent
        let ext = type(for: job.format, source: source).preferredFilenameExtension ?? "png"
        if job.replace { return base + "." + ext }
        if let s = size { return "\(base)-\(max(s.0, s.1)).\(ext)" }
        return base + (job.stripMetadata && job.format == .same ? "-clean" : "") + "." + ext
    }

    /// Processes one image; returns the new file. `trash` takes the original away when replacing (FileManager's Trash; tests
    /// pass a fake).
    static func process(_ url: URL, job: ImageJob, into dir: URL? = nil,
                        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { throw Failure.unreadable(url.lastPathComponent) }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let target = targetMaxSide(job.resize, width: w, height: h)
        // Pixels: the thumbnail call scales and applies the EXIF orientation in one go (then the output's orientation is 1).
        let image: CGImage?
        if let t = target {
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                 kCGImageSourceCreateThumbnailWithTransform: true,
                                                                 kCGImageSourceThumbnailMaxPixelSize: t,
                                                                 kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard let img = image else { throw Failure.unreadable(url.lastPathComponent) }
        let ut = type(for: job.format, source: url)
        guard writable.contains(ut.identifier) else { throw Failure.unsupported(ut.preferredFilenameExtension?.uppercased() ?? ut.identifier) }
        let folder = dir ?? url.deletingLastPathComponent()
        let size = target.map { _ in (img.width, img.height) }
        var name = outputName(url, job: job, size: size)
        if job.replace && name == url.lastPathComponent { name = "." + name + ".cocaine-new" }       // written aside, then swapped in
        let out = FileNames.unique(folder.appendingPathComponent(name))
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, ut.identifier as CFString, 1, nil) else { throw Failure.cantWrite(out.lastPathComponent) }
        var opts: [CFString: Any] = [:]
        if [UTType.jpeg, .heic].contains(ut) { opts[kCGImageDestinationLossyCompressionQuality] = max(0.05, min(1, job.quality)) }
        if !job.stripMetadata {
            // The original's metadata, minus what no longer holds (size, orientation once the pixels are turned).
            var keep = props
            for k in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation] { keep.removeValue(forKey: k) }
            if var tiff = keep[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation); keep[kCGImagePropertyTIFFDictionary] = tiff }
            if target == nil { keep[kCGImagePropertyOrientation] = orientation }      // pixels untouched: the flag still applies
            for (k, v) in keep { opts[k] = v }
        } else {
            opts[kCGImageMetadataShouldExcludeGPS] = true
            opts[kCGImageMetadataShouldExcludeXMP] = true
            if target == nil && orientation != 1 {
                // The pixels weren't turned: keep only the orientation flag, or the image would show sideways.
                opts[kCGImagePropertyOrientation] = orientation
            }
        }
        CGImageDestinationAddImage(dest, img, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: out); throw Failure.cantWrite(out.lastPathComponent) }
        guard job.replace else { return out }
        // Replacing: the original to the Trash (it can come back), the new file under the original's name when the type is the same.
        do { try trash(url) } catch { try? FileManager.default.removeItem(at: out); throw error }
        guard out.pathExtension == "cocaine-new" else { return out }          // another type: already under its own name
        let final = url.deletingPathExtension().appendingPathExtension(ut.preferredFilenameExtension ?? "png")
        let to = FileNames.unique(final)
        try FileManager.default.moveItem(at: out, to: to)
        return to
    }

    /// One PDF with a page per image, in order, next to the first one.
    static func makePDF(_ urls: [URL], to out: URL) throws -> URL {
        let doc = PDFDocument()
        for u in urls {
            guard let img = NSImage(contentsOf: u), let page = PDFPage(image: img) else { throw Failure.unreadable(u.lastPathComponent) }
            doc.insert(page, at: doc.pageCount)
        }
        let to = FileNames.unique(out)
        guard doc.pageCount > 0, doc.write(to: to) else { throw Failure.cantWrite(to.lastPathComponent) }
        return to
    }

    /// The images one under the other (or side by side), at the width (height) of the widest (tallest), as PNG.
    static func stitch(_ urls: [URL], vertical: Bool, to out: URL) throws -> URL {
        var images: [CGImage] = []
        for u in urls {
            guard let s = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let i = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                                                      kCGImageSourceThumbnailMaxPixelSize: 8192] as CFDictionary)
            else { throw Failure.unreadable(u.lastPathComponent) }
            images.append(i)
        }
        guard !images.isEmpty else { throw Failure.unreadable("") }
        let side = vertical ? images.map(\.width).max()! : images.map(\.height).max()!
        let scaled = images.map { i -> (CGImage, Int, Int) in
            let k = Double(side) / Double(vertical ? i.width : i.height)
            return (i, Int((Double(i.width) * k).rounded()), Int((Double(i.height) * k).rounded()))
        }
        let W = vertical ? side : scaled.map(\.1).reduce(0, +), H = vertical ? scaled.map(\.2).reduce(0, +) : side
        guard W > 0, H > 0, W * H <= 400_000_000,
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.cantWrite(out.lastPathComponent) }
        ctx.interpolationQuality = .high
        var offset = 0
        for (i, w, h) in scaled {
            if vertical { ctx.draw(i, in: CGRect(x: 0, y: H - offset - h, width: w, height: h)); offset += h }
            else { ctx.draw(i, in: CGRect(x: offset, y: 0, width: w, height: h)); offset += w }
        }
        guard let result = ctx.makeImage() else { throw Failure.cantWrite(out.lastPathComponent) }
        let to = FileNames.unique(out)
        guard let d = CGImageDestinationCreateWithURL(to as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw Failure.cantWrite(to.lastPathComponent) }
        CGImageDestinationAddImage(d, result, nil)
        guard CGImageDestinationFinalize(d) else { throw Failure.cantWrite(to.lastPathComponent) }
        return to
    }
}

/// Names that never overwrite: "name.ext", else "name 2.ext", "name 3.ext"…
enum FileNames {
    static func unique(_ url: URL, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL {
        guard exists(url.path) else { return url }
        let dir = url.deletingLastPathComponent(), ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        for n in 2...9999 {
            let name = "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
            let u = dir.appendingPathComponent(name)
            if !exists(u.path) { return u }
        }
        return dir.appendingPathComponent("\(base) \(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)"))
    }
}
