// Command-line entry points for distribution: release tooling (key generation, manifest signing and verification, the
// signing tier of a bundle, localization consistency) and the regression tests of the updater and of tier detection.
// main.swift calls `DistCLI.run` before starting the app.

import CryptoKit
import Foundation

enum DistCLI {
    /// Nil when the arguments aren't ours.
    static func run(_ a: [String]) -> Int32? {
        guard a.count >= 2 else { return nil }
        switch a[1] {
        case "--update-test": return UpdateTests.run()
        case "--signature-test": return SignatureTests.run()
        case "--signature-tier" where a.count == 3: return tier(a[2])
        case "--update-keygen" where a.count == 3: return keygen(a[2])
        case "--update-public-key" where a.count == 3: return publicKey(a[2])
        case "--update-sign" where a.count == 8: return sign(key: a[2], dmg: a[3], version: a[4], build: a[5], tier: a[6], out: a[7])
        case "--update-verify" where a.count >= 4: return verify(manifest: a[2], dmg: a[3], key: a.count > 4 ? a[4] : nil)
        case "--l10n-check" where a.count >= 3: return L10nCheck.run(dir: a[2], sources: Array(a.dropFirst(3)))
        default: return nil
        }
    }

    static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    /// `tier=… valid=… adhoc=… runtime=… leaf=… team=… ticket=…` then the designated requirement.
    private static func tier(_ path: String) -> Int32 {
        let f = SigningTier.facts(of: URL(fileURLWithPath: path))
        print("tier=\(SigningTier.classify(f).rawValue) valid=\(f.valid) adhoc=\(f.adhoc) runtime=\(f.hardenedRuntime)"
              + " leaf=\"\(f.leafCommonName ?? "")\" team=\(f.teamID ?? "-") ticket=\(f.stapledTicket)")
        print("designated=\(f.designatedRequirement ?? "-")")
        return 0
    }

    /// Makes a release key pair. The private key goes only into `out` (created 0600, never overwritten, never printed);
    /// the public key is printed for UpdateKey.swift.
    private static func keygen(_ out: String) -> Int32 {
        let key = Curve25519.Signing.PrivateKey()
        let fd = open(out, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { err("refusing: \(out) exists or can't be created (\(String(cString: strerror(errno))))"); return 1 }
        let text = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
        let ok = text.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == text.count
        close(fd)
        guard ok else { unlink(out); err("couldn't write \(out)"); return 1 }
        print(key.publicKey.rawRepresentation.base64EncodedString())
        return 0
    }

    private static func loadKey(_ path: String) -> Curve25519.Signing.PrivateKey? {
        var st = stat()
        guard stat(path, &st) == 0 else { err("no key at \(path)"); return nil }
        if st.st_mode & 0o077 != 0 { err("refusing: \(path) is readable by others (chmod 600 it)"); return nil }
        guard let s = try? String(contentsOfFile: path, encoding: .utf8),
              let d = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) else { err("\(path) isn't a release key"); return nil }
        return k
    }

    private static func publicKey(_ path: String) -> Int32 {
        guard let k = loadKey(path) else { return 1 }
        print(k.publicKey.rawRepresentation.base64EncodedString())
        return 0
    }

    private static func sign(key: String, dmg: String, version: String, build: String, tier: String, out: String) -> Int32 {
        guard let k = loadKey(key) else { return 1 }
        let embedded = UpdateKey.publicKeyBase64
        guard !embedded.isEmpty, k.publicKey.rawRepresentation.base64EncodedString() == embedded else {
            err(embedded.isEmpty ? "this build has no embedded update key: run tools/update-key.sh init and rebuild"
                                 : "the key doesn't match the public key embedded in this build"); return 1
        }
        guard SemVer(version) != nil, let b = Int(build), b > 0, SigningTier(rawValue: tier) != nil else { err("bad version, build or tier"); return 1 }
        let url = URL(fileURLWithPath: dmg)
        guard url.lastPathComponent == "Cocaine-\(version).dmg" else { err("the DMG must be named Cocaine-\(version).dmg"); return 1 }
        guard let sha = UpdateFiles.sha256(of: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: dmg))?[.size] as? NSNumber else { err("can't read \(dmg)"); return 1 }
        do {
            let m = try UpdateManifest(version: version, build: b, sha256: sha, size: size.int64Value, tier: tier, asset: url.lastPathComponent).signed(with: k)
            guard k.publicKey.isValidSignature(Data(base64Encoded: m.signature)!, for: m.signedMessage) else { err("self-check failed"); return 1 }
            try m.encoded().write(to: URL(fileURLWithPath: out), options: .atomic)
        } catch { err("\(error)"); return 1 }
        print("signed \(out)")
        return 0
    }

    private static func verify(manifest: String, dmg: String, key: String?) -> Int32 {
        guard let data = FileManager.default.contents(atPath: manifest), let m = UpdateManifest.decode(data) else { err("unreadable manifest"); return 1 }
        let pk = UpdateVerifier.publicKey(base64: key ?? UpdateKey.publicKeyBase64)
        switch UpdateVerifier.check(m, key: pk, currentVersion: "0.0.0", currentBuild: 0) {
        case .failure(let e): err("manifest rejected: \(e)"); return 1
        case .success: break
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: dmg))?[.size] as? NSNumber)?.int64Value
        guard size == m.size, UpdateFiles.sha256(of: URL(fileURLWithPath: dmg)) == m.sha256 else { err("the DMG doesn't match the manifest"); return 1 }
        print("ok version=\(m.version) build=\(m.build) tier=\(m.tier)")
        return 0
    }
}

/// Every key of every string table exists in all languages, every table parses, and every literal key used in the code
/// (string literals passed to L or updatesText) is in some table of every language.
enum L10nCheck {
    /// A Swift string literal's escapes (\\ \" \n \t), read left to right so `\\n` stays a backslash and an n.
    static func unescape(_ raw: String) -> String {
        var out = "", it = raw.makeIterator()
        while let c = it.next() {
            guard c == "\\", let n = it.next() else { out.append(c); continue }
            switch n { case "n": out.append("\n"); case "t": out.append("\t"); default: out.append(n) }
        }
        return out
    }
    static func run(dir: String, sources: [String]) -> Int32 {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: dir)
        let langs = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".lproj") }.sorted()
        guard langs.contains("en.lproj") else { DistCLI.err("no en.lproj in \(dir)"); return 1 }
        let tables = ((try? fm.contentsOfDirectory(atPath: base.appendingPathComponent("en.lproj").path)) ?? [])
            .filter { $0.hasSuffix(".strings") }.sorted()
        var problems = 0
        var all: [String: Set<String>] = [:]                     // language → every key in any table
        for t in tables {
            var keysEn: Set<String>?
            for l in langs {
                let p = base.appendingPathComponent(l).appendingPathComponent(t)
                guard fm.fileExists(atPath: p.path) else { print("FAIL  \(l)/\(t) is missing"); problems += 1; continue }
                guard let d = NSDictionary(contentsOf: p) as? [String: String] else { print("FAIL  \(l)/\(t) doesn't parse"); problems += 1; continue }
                let keys = Set(d.keys)
                all[l, default: []].formUnion(keys)
                if l == "en.lproj" { keysEn = keys }
                if let en = keysEn ?? (NSDictionary(contentsOf: base.appendingPathComponent("en.lproj/\(t)")) as? [String: String]).map({ Set($0.keys) }) {
                    for k in en.subtracting(keys).sorted() { print("FAIL  \(l)/\(t) lacks \"\(k)\""); problems += 1 }
                    for k in keys.subtracting(en).sorted() { print("FAIL  \(l)/\(t) has \"\(k)\" that en.lproj doesn't"); problems += 1 }
                }
                for (k, v) in d where (k.components(separatedBy: "%").count != v.components(separatedBy: "%").count) {
                    print("FAIL  \(l)/\(t) \"\(k)\": the translation's format specifiers differ"); problems += 1
                }
            }
        }
        let pattern = try! NSRegularExpression(pattern: #"\b(?:L|updatesText)\("((?:[^"\\]|\\.)*)"\)"#)
        var used = Set<String>()
        for s in sources {
            guard let text = try? String(contentsOfFile: s, encoding: .utf8) else { print("FAIL  can't read \(s)"); problems += 1; continue }
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                let raw = String(text[r])
                if raw.contains("\\(") { continue }                  // interpolated: not a fixed key
                used.insert(unescape(raw))
            }
        }
        for k in used.sorted() {
            let missing = langs.filter { !(all[$0]?.contains(k) ?? false) }
            if !missing.isEmpty { print("FAIL  \"\(k)\" isn't translated in \(missing.joined(separator: ", "))"); problems += 1 }
        }
        print(problems == 0 ? "PASS  localization: \(langs.count) languages, \(tables.count) tables, \(used.count) keys used in code"
                            : "localization: \(problems) problem(s)")
        return problems == 0 ? 0 : 1
    }
}
