// AWS Signature Version 4 (the S3 API and every S3-compatible store: R2, B2, Wasabi, MinIO, Spaces), written out with CryptoKit:
// the canonical request, the string to sign, the signing key, the Authorization header and presigned (query-string) URLs.
// Pure: no network, no clock (the caller passes the date). Checked by --cloud-test against AWS's published examples.

import CryptoKit
import Foundation

enum SigV4 {
    struct Credentials: Equatable {
        var accessKey: String
        var secretKey: String
        var sessionToken: String? = nil
    }

    static let algorithm = "AWS4-HMAC-SHA256"
    static let unsignedPayload = "UNSIGNED-PAYLOAD"
    static let emptyHash = sha256Hex(Data())
    /// S3 refuses presigned URLs that live longer than 7 days.
    static let maxPresign = 7 * 24 * 3600

    static func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func sha256Hex(_ d: Data) -> String { hex(SHA256.hash(data: d)) }
    static func sha256Hex(_ s: String) -> String { sha256Hex(Data(s.utf8)) }

    static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    /// "20130524T000000Z" and "20130524" in UTC.
    static func stamps(_ date: Date) -> (amz: String, day: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amz = f.string(from: date)
        return (amz, String(amz.prefix(8)))
    }

    static func signingKey(secret: String, day: String, region: String, service: String) -> Data {
        let kDate = hmac(Data(("AWS4" + secret).utf8), day)
        let kRegion = hmac(kDate, region)
        let kService = hmac(kRegion, service)
        return hmac(kService, "aws4_request")
    }

    /// RFC 3986 encoding as SigV4 wants it: only A–Z a–z 0–9 - _ . ~ stay; "/" stays when `keepSlash` (an object key's path).
    static func encode(_ s: String, keepSlash: Bool = false) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E: out.append(Character(UnicodeScalar(b)))
            case 0x2F where keepSlash: out.append("/")
            default: out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// Query parameters, encoded and sorted by name then value.
    static func canonicalQuery(_ q: [(String, String)]) -> String {
        let pairs: [(String, String)] = q.map { (encode($0.0), encode($0.1)) }
        let sorted = pairs.sorted { (a: (String, String), b: (String, String)) -> Bool in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
        return sorted.map { (p: (String, String)) -> String in p.0 + "=" + p.1 }.joined(separator: "&")
    }

    /// A header value as signed: trimmed, runs of spaces made one.
    static func canonicalValue(_ v: String) -> String {
        v.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// `path` is the canonical URI, already encoded (e.g. "/bucket/my%20file.txt"). `headers` names are matched without case.
    static func canonicalRequest(method: String, path: String, query: [(String, String)], headers: [String: String], payloadHash: String) -> (text: String, signed: String) {
        var lower: [String: String] = [:]
        for (k, v) in headers { lower[k.lowercased()] = canonicalValue(v) }
        let names = lower.keys.sorted()
        let canonHeaders = names.map { "\($0):\(lower[$0]!)\n" }.joined()
        let signed = names.joined(separator: ";")
        let text = [method, path.isEmpty ? "/" : path, canonicalQuery(query), canonHeaders, signed, payloadHash].joined(separator: "\n")
        return (text, signed)
    }

    static func scope(day: String, region: String, service: String) -> String { "\(day)/\(region)/\(service)/aws4_request" }

    static func stringToSign(amz: String, scope: String, canonical: String) -> String {
        [algorithm, amz, scope, sha256Hex(canonical)].joined(separator: "\n")
    }

    struct Signed: Equatable {
        var authorization: String
        var signature: String
        var signedHeaders: String
        var canonical: String
    }

    /// Signs a request whose headers already hold host and x-amz-date (and x-amz-content-sha256 for S3).
    static func sign(method: String, path: String, query: [(String, String)] = [], headers: [String: String], payloadHash: String,
                     credentials c: Credentials, region: String, service: String, date: Date) -> Signed {
        let (amz, day) = stamps(date)
        let cr = canonicalRequest(method: method, path: path, query: query, headers: headers, payloadHash: payloadHash)
        let sc = scope(day: day, region: region, service: service)
        let sts = stringToSign(amz: amz, scope: sc, canonical: cr.text)
        let sig = hex(hmac(signingKey(secret: c.secretKey, day: day, region: region, service: service), sts))
        let auth = "\(algorithm) Credential=\(c.accessKey)/\(sc), SignedHeaders=\(cr.signed), Signature=\(sig)"
        return Signed(authorization: auth, signature: sig, signedHeaders: cr.signed, canonical: cr.text)
    }

    /// A presigned URL: everything in the query (only `host` signed, the payload unsigned), valid for `expires` seconds.
    /// `base` is scheme + host (+ port), `path` the encoded canonical URI.
    static func presign(method: String = "GET", base: String, host: String, path: String, extraQuery: [(String, String)] = [],
                        credentials c: Credentials, region: String, service: String = "s3", date: Date, expires: Int) -> URL? {
        let (amz, day) = stamps(date)
        let sc = scope(day: day, region: region, service: service)
        var q: [(String, String)] = extraQuery + [
            ("X-Amz-Algorithm", algorithm),
            ("X-Amz-Credential", "\(c.accessKey)/\(sc)"),
            ("X-Amz-Date", amz),
            ("X-Amz-Expires", String(max(1, min(maxPresign, expires)))),
            ("X-Amz-SignedHeaders", "host"),
        ]
        if let t = c.sessionToken { q.append(("X-Amz-Security-Token", t)) }
        let cr = canonicalRequest(method: method, path: path, query: q, headers: ["host": host], payloadHash: unsignedPayload)
        let sts = stringToSign(amz: amz, scope: sc, canonical: cr.text)
        let sig = hex(hmac(signingKey(secret: c.secretKey, day: day, region: region, service: service), sts))
        return URL(string: base + (path.isEmpty ? "/" : path) + "?" + canonicalQuery(q) + "&X-Amz-Signature=" + sig)
    }

    /// Reads a presigned URL's parts back (tests, and the history's expiry).
    static func presignedParts(_ u: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }

    /// When a presigned URL stops working (X-Amz-Date + X-Amz-Expires), or nil when it isn't one.
    static func expiry(of u: URL) -> Date? {
        let p = presignedParts(u)
        guard let d = p["X-Amz-Date"], let e = p["X-Amz-Expires"].flatMap(Int.init) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.date(from: d).map { $0.addingTimeInterval(TimeInterval(e)) }
    }
}
