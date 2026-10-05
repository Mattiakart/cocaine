// The pure part of the in-app updater: versions, the signed release manifest, what GitHub's API says, where downloads may
// come from, Homebrew detection and when to check. No I/O here except reading paths in `Homebrew`, so it can all be tested.

import CryptoKit
import Foundation

// MARK: - Versions

/// A semantic version (2.0 rules): numeric core compared field by field (2.10 > 2.9), a pre-release ranks below its release,
/// pre-release fields compare numerically when both are numbers, numbers rank below words, and build metadata is ignored.
struct SemVer: Comparable, CustomStringConvertible {
    let major: Int, minor: Int, patch: Int
    let pre: [String]

    /// Accepts "2.3.0", "v2.3", "2.3.0-beta.2+45". Nil for anything else (no leading zeros games, no empty fields).
    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        var preText: String?
        if let dash = s.firstIndex(of: "-") { preText = String(s[s.index(after: dash)...]); s = String(s[..<dash]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 9, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            nums.append(n)
        }
        major = nums[0]; minor = nums[1]; patch = nums.count > 2 ? nums[2] : 0
        if let preText {
            let ids = preText.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !ids.contains(where: { $0.isEmpty || !$0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } })
            else { return nil }
            pre = ids
        } else { pre = [] }
    }

    var description: String { "\(major).\(minor).\(patch)" + (pre.isEmpty ? "" : "-" + pre.joined(separator: ".")) }
    var isPrerelease: Bool { !pre.isEmpty }

    static func == (a: SemVer, b: SemVer) -> Bool { a.major == b.major && a.minor == b.minor && a.patch == b.patch && a.pre == b.pre }

    static func < (a: SemVer, b: SemVer) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        if a.pre.isEmpty || b.pre.isEmpty { return !a.pre.isEmpty && b.pre.isEmpty }   // 1.0.0-x < 1.0.0
        for (x, y) in zip(a.pre, b.pre) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (_?, nil): return true                       // numeric identifiers rank below alphanumeric ones
            case (nil, _?): return false
            default: return x < y                             // ASCII order
            }
        }
        return a.pre.count < b.pre.count
    }
}

// MARK: - Signed manifest

/// The file published next to each DMG (`Cocaine-<version>.dmg.manifest.json`). The Ed25519 signature covers every other
/// field, so a manifest can't be moved to another DMG, version or build, and an old one can't pass for a new release.
struct UpdateManifest: Codable, Equatable {
    var format = 1
    var version: String
    var build: Int
    var sha256: String          // lowercase hex of the DMG
    var size: Int64             // bytes of the DMG
    var tier: String            // SigningTier raw value of the app inside, as found by release-sign.sh
    var asset: String           // the DMG's file name
    var signature: String = ""  // base64 Ed25519 over `signedMessage`

    static let maxDMGSize: Int64 = 300 * 1024 * 1024
    static let maxManifestSize = 16 * 1024

    var signedMessage: Data {
        Data("cocaine-update-v1\nversion=\(version)\nbuild=\(build)\nsha256=\(sha256)\nsize=\(size)\ntier=\(tier)\nasset=\(asset)\n".utf8)
    }

    func signed(with key: Curve25519.Signing.PrivateKey) throws -> UpdateManifest {
        var m = self
        m.signature = try key.signature(for: signedMessage).base64EncodedString()
        return m
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    static func decode(_ data: Data) -> UpdateManifest? {
        guard data.count <= maxManifestSize else { return nil }
        return try? JSONDecoder().decode(UpdateManifest.self, from: data)
    }
}

enum UpdateRejection: Error, Equatable {
    case noKey                   // this build has no public key to verify with
    case malformed(String)
    case badSignature            // tampered, or signed with another key
    case notNewer(String)        // a downgrade, or an old release replayed
    case mismatch(String)        // signed fields don't match the release it came with
}

enum UpdateVerifier {
    static func publicKey(base64: String) -> Curve25519.Signing.PublicKey? {
        guard let d = Data(base64Encoded: base64), d.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: d)
    }

    /// Checks a manifest against the embedded key and the running version. `release` is the GitHub release it came with.
    static func check(_ m: UpdateManifest, key: Curve25519.Signing.PublicKey?, currentVersion: String, currentBuild: Int,
                      release: ReleaseInfo? = nil) -> Result<SemVer, UpdateRejection> {
        guard let key else { return .failure(.noKey) }
        guard m.format == 1 else { return .failure(.malformed("format \(m.format)")) }
        guard let sig = Data(base64Encoded: m.signature), sig.count == 64 else { return .failure(.badSignature) }
        guard key.isValidSignature(sig, for: m.signedMessage) else { return .failure(.badSignature) }
        // Only signed fields from here on.
        guard let v = SemVer(m.version) else { return .failure(.malformed("version \(m.version)")) }
        guard m.sha256.count == 64, m.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { return .failure(.malformed("sha256")) }
        guard m.size > 0, m.size <= UpdateManifest.maxDMGSize else { return .failure(.malformed("size \(m.size)")) }
        guard m.asset == "Cocaine-\(m.version).dmg" else { return .failure(.mismatch("asset \(m.asset)")) }
        guard let cur = SemVer(currentVersion) else { return .failure(.malformed("running version \(currentVersion)")) }
        guard v > cur else { return .failure(.notNewer("\(v) is not newer than \(cur)")) }
        guard m.build > currentBuild else { return .failure(.notNewer("build \(m.build) is not newer than \(currentBuild)")) }
        if let release {
            guard release.version == v else { return .failure(.mismatch("release \(release.version) carries a manifest for \(v)")) }
            guard release.dmg.name == m.asset, release.dmg.size == m.size else { return .failure(.mismatch("DMG asset name or size")) }
        }
        return .success(v)
    }
}

// MARK: - GitHub releases

struct ReleaseAsset: Equatable { let name: String; let size: Int64; let url: URL }

struct ReleaseInfo: Equatable {
    let tag: String
    let version: SemVer
    let dmg: ReleaseAsset
    let manifest: ReleaseAsset
}

enum UpdateSource {
    /// Pinned: only this repository's latest published release (GitHub's /latest skips drafts and pre-releases).
    static let latestAPI = URL(string: "https://api.github.com/repos/Mattiakart/cocaine/releases/latest")!
    static let downloadPrefix = "https://github.com/Mattiakart/cocaine/releases/download/"
    static let releasesPage = URL(string: "https://github.com/Mattiakart/cocaine/releases/latest")!

    /// Parses /releases/latest. `prefix` is the only allowed start of asset URLs (tests pass their local server's).
    static func parse(_ data: Data, prefix: String = downloadPrefix) -> Result<ReleaseInfo, UpdateRejection> {
        guard data.count < 2_000_000,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.malformed("release JSON")) }
        if (o["draft"] as? Bool) == true || (o["prerelease"] as? Bool) == true { return .failure(.malformed("draft or pre-release")) }
        guard let tag = o["tag_name"] as? String, let v = SemVer(tag) else { return .failure(.malformed("tag")) }
        let assets = (o["assets"] as? [[String: Any]] ?? []).compactMap { a -> ReleaseAsset? in
            guard let n = a["name"] as? String, let s = (a["size"] as? NSNumber)?.int64Value,
                  let u = (a["browser_download_url"] as? String).flatMap(URL.init(string:)),
                  u.absoluteString.hasPrefix(prefix) else { return nil }
            return ReleaseAsset(name: n, size: s, url: u)
        }
        let dmgName = "Cocaine-\(v).dmg"
        guard let dmg = assets.first(where: { $0.name == dmgName }) else { return .failure(.malformed("no \(dmgName) asset")) }
        guard let man = assets.first(where: { $0.name == dmgName + ".manifest.json" })
        else { return .failure(.malformed("no signed manifest for \(dmgName)")) }
        return .success(ReleaseInfo(tag: tag, version: v, dmg: dmg, manifest: man))
    }
}

/// Where downloads (and their redirects) may go. Authenticity never depends on this (the manifest signature and the code
/// signature do that); it keeps the app from talking to anything but GitHub.
struct DownloadPolicy {
    var allowsHost: (URL) -> Bool

    static let github = DownloadPolicy { u in
        guard u.scheme == "https", let h = u.host?.lowercased() else { return false }
        return h == "github.com" || h == "api.github.com" || h.hasSuffix(".githubusercontent.com")
    }
    /// Tests: plain http to this Mac only.
    static let loopback = DownloadPolicy { u in u.scheme == "http" && u.host == "127.0.0.1" }
}

// MARK: - Homebrew

enum Homebrew {
    static let caskrooms = ["/opt/homebrew/Caskroom/cocaine", "/usr/local/Caskroom/cocaine"]

    /// True when the cask installed the app at `bundle`: Homebrew keeps `Caskroom/cocaine/<version>/Cocaine.app` as a symlink
    /// to the app it moved into place. Updating such a copy behind Homebrew's back would leave its records wrong.
    static func manages(bundle: URL, caskrooms: [String] = caskrooms) -> Bool {
        let fm = FileManager.default
        let target = bundle.resolvingSymlinksInPath().standardizedFileURL.path
        for room in caskrooms {
            guard let versions = try? fm.contentsOfDirectory(atPath: room) else { continue }
            for v in versions where !v.hasPrefix(".") {
                let link = URL(fileURLWithPath: room).appendingPathComponent(v).appendingPathComponent("Cocaine.app")
                guard (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil || fm.fileExists(atPath: link.path) else { continue }
                if link.resolvingSymlinksInPath().standardizedFileURL.path == target { return true }
            }
        }
        return false
    }

    static let upgradeCommand = "brew upgrade --cask cocaine"
}

// MARK: - When to check

enum UpdateSchedule {
    static let interval: TimeInterval = 24 * 3600

    /// At most once a day, never when switched off; a clock set back (last check in the future) counts as due.
    static func due(enabled: Bool, lastCheck: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now.addingTimeInterval(60)
    }
}
