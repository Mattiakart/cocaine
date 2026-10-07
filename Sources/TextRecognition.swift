// Text recognition (OCR) for the shelf: Vision's VNRecognizeTextRequest, accurate, with language correction and automatic
// language detection, the user's preferred languages first. Images, and the first pages of PDFs (rendered with PDFKit). Runs off
// the main thread (the caller's queue); everything stays on this Mac. Tested by --shelf-test on an image drawn with text.

import AppKit
import Foundation
import ImageIO
import PDFKit
import Vision

enum TextRecognition {
    static let maxPDFPages = 5

    /// The languages to ask for: the user's preferred ones that Vision supports, then English (Vision's own default).
    static func languages(preferred: [String] = Locale.preferredLanguages) -> [String] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        let supported = (try? req.supportedRecognitionLanguages()) ?? ["en-US"]
        var out: [String] = []
        for p in preferred {
            let lang = Locale(identifier: p).language.languageCode?.identifier ?? p
            if let m = supported.first(where: { $0 == p }) ?? supported.first(where: { $0.hasPrefix(lang) }), !out.contains(m) { out.append(m) }
        }
        if let en = supported.first(where: { $0.hasPrefix("en") }), !out.contains(en) { out.append(en) }
        return out
    }

    /// The text in one image, top to bottom, left to right on a line; empty when there is none.
    static func recognize(_ image: CGImage, languages: [String]? = nil) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        req.recognitionLanguages = languages ?? Self.languages()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        let obs = (req.results ?? []).compactMap { o -> (CGRect, String)? in
            guard let s = o.topCandidates(1).first?.string else { return nil }
            return (o.boundingBox, s)
        }
        return order(obs)
    }

    /// Reading order from Vision's boxes (origin bottom-left, 0…1): rows by their middle, within a row left to right.
    static func order(_ obs: [(CGRect, String)]) -> String {
        let sorted = obs.sorted { $0.0.midY > $1.0.midY }
        var lines: [[(CGRect, String)]] = []
        for o in sorted {
            if let last = lines.last?.first, abs(last.0.midY - o.0.midY) < max(0.01, min(last.0.height, o.0.height) * 0.5) {
                lines[lines.count - 1].append(o)
            } else { lines.append([o]) }
        }
        return lines.map { $0.sorted { $0.0.minX < $1.0.minX }.map(\.1).joined(separator: " ") }.joined(separator: "\n")
    }

    /// The text of an image file or of a PDF's first pages.
    static func recognize(url: URL) throws -> String {
        if ImageTools.isPDF(url) {
            guard let doc = PDFDocument(url: url) else { throw ImageTools.Failure.unreadable(url.lastPathComponent) }
            var parts: [String] = []
            for i in 0..<min(doc.pageCount, maxPDFPages) {
                guard let page = doc.page(at: i) else { continue }
                // A PDF with real text: that text, exactly (no recognition needed).
                if let s = page.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(s); continue }
                if let img = render(page) { parts.append(try recognize(img)) }
            }
            return parts.joined(separator: "\n\n")
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                                                      kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary)
        else { throw ImageTools.Failure.unreadable(url.lastPathComponent) }
        return try recognize(img)
    }

    /// A PDF page as pixels (2× its size, at most 4096 on the long side), white behind it.
    static func render(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let scale = min(2, 4096 / max(1, max(box.width, box.height)))
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }
}
