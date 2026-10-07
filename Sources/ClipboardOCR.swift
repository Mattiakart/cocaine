// Text in copied images (Vision, on this Mac, off the main thread, no permission): "Copy text from image" on demand, and, when
// the setting is on, the text of each new image kept with it (masked secrets, bounded) so search finds screenshots by their words.

import AppKit
import ImageIO
import Vision

enum ClipOCR {
    /// Images are read at most this big on their long side (a big screenshot is scaled down first).
    static let maxSide = 4_096

    /// The recognised lines, top to bottom (nil: no text, or not an image). Slow: never on the main thread.
    static func recognize(_ png: Data, languages: [String] = ClipOCR.languages()) -> String? {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: maxSide,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let supported = (try? req.supportedRecognitionLanguages()) ?? []
        let langs = languages.filter { l in supported.contains { $0 == l || $0.hasPrefix(l + "-") || l.hasPrefix($0) } }
        if !langs.isEmpty { req.recognitionLanguages = langs }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([req])) != nil, let obs = req.results, !obs.isEmpty else { return nil }
        let lines = obs.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }.compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The app's language first, then English.
    static func languages() -> [String] {
        let map = ["zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant", "it": "it-IT", "es": "es-ES", "fr": "fr-FR", "de": "de-DE", "ja": "ja-JP", "en": "en-US"]
        let code = Language.locale.identifier.replacingOccurrences(of: "_", with: "-")
        let mine = map.first { code.hasPrefix($0.key) }?.value
        return [mine, "en-US"].compactMap { $0 }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// What is kept for search: secrets masked, at most ClipItem.maxOCR characters.
    static func stored(_ text: String) -> String { String(ClipRules.masked(text).prefix(ClipItem.maxOCR)) }
}

extension ClipboardHistory {
    private static let ocrQueue = DispatchQueue(label: "local.cocaine.clipboard.ocr", qos: .utility)

    /// Recognises the text of an image item off the main thread. `store`: keep it with the item (masked) for search.
    /// `done` gets the full text (for "Copy text"), on the main thread.
    func recognizeText(_ item: ClipItem, store keep: Bool, done: @escaping (String?) -> Void = { _ in }) {
        guard item.kind == .image, let png = imageData(item) else { done(nil); return }
        Self.ocrQueue.async { [weak self] in
            let text = ClipOCR.recognize(png)
            DispatchQueue.main.async {
                if keep, let self { self.modify(item.id) { $0.ocr = text.map(ClipOCR.stored) ?? "" } }   // "": looked, nothing found
                done(text)
            }
        }
    }

    /// A new image, with the setting on: its text, for search (not on battery in Low Power Mode).
    func indexImage(_ item: ClipItem) {
        guard settings.ocr, item.ocr == nil, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        recognizeText(item, store: true)
    }
}
