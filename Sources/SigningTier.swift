// What signs an app bundle, read from its own code signature (never from a build flag), so the panel and the release
// tooling report the same thing: ad hoc, the local self-signed identity, Developer ID, or Developer ID with a stapled
// notarization ticket.

import Foundation
import Security

enum SigningTier: String, CaseIterable {
    case unsigned          // no signature, or one that doesn't validate
    case adhoc             // no identity: the requirement is the build's own hash, so every build is a "new app" to macOS
    case local             // the self-signed "Cocaine Local Signing" certificate (make-signing-identity.sh)
    case otherCertificate  // some other certificate that isn't a Developer ID
    case developerID       // Developer ID Application, not notarized (or the ticket isn't stapled)
    case notarized         // Developer ID Application with a stapled notarization ticket

    static let localCommonName = "Cocaine Local Signing"
    /// Apple's requirement for Developer ID application signatures (Apple anchor, Developer ID intermediate, leaf marker).
    static let developerIDRequirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    /// What a signature says, independent of how it was read (so the decision is testable without real certificates).
    struct Facts: Equatable {
        var signed = false
        var valid = false
        var adhoc = false
        var leafCommonName: String?
        var certificateCount = 0
        var developerID = false      // satisfies developerIDRequirement
        var stapledTicket = false    // Contents/CodeResources, where stapler puts an app's ticket
        var hardenedRuntime = false
        var teamID: String?
        var designatedRequirement: String?
    }

    static func classify(_ f: Facts) -> SigningTier {
        guard f.signed, f.valid else { return .unsigned }
        if f.adhoc || f.certificateCount == 0 { return .adhoc }
        if f.developerID { return f.stapledTicket ? .notarized : .developerID }
        if f.leafCommonName == localCommonName && f.certificateCount == 1 { return .local }
        return .otherCertificate
    }

    static let strictFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)

    /// Reads the facts of the bundle (or binary) at `url`. Offline: notarization is only seen as a stapled ticket.
    static func facts(of url: URL) -> Facts {
        var f = Facts()
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return f }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return f }
        f.signed = d[kSecCodeInfoIdentifier as String] != nil
        guard f.signed else { return f }
        f.valid = SecStaticCodeCheckValidity(code, strictFlags, nil) == errSecSuccess
        let flags = (d[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        f.adhoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        f.hardenedRuntime = flags & SecCodeSignatureFlags.runtime.rawValue != 0
        let certs = (d[kSecCodeInfoCertificates as String] as? [SecCertificate]) ?? []
        f.certificateCount = certs.count
        if let leaf = certs.first {
            var cn: CFString?
            if SecCertificateCopyCommonName(leaf, &cn) == errSecSuccess { f.leafCommonName = cn as String? }
        }
        f.teamID = d[kSecCodeInfoTeamIdentifier as String] as? String
        var req: SecRequirement?
        if SecRequirementCreateWithString(developerIDRequirement as CFString, [], &req) == errSecSuccess, let req {
            f.developerID = SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
        }
        f.designatedRequirement = designatedRequirement(of: code)
        f.stapledTicket = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/CodeResources").path)
        return f
    }

    static func designatedRequirement(of code: SecStaticCode) -> String? {
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess, let req else { return nil }
        var s: CFString?
        guard SecRequirementCopyString(req, [], &s) == errSecSuccess else { return nil }
        return s as String?
    }

    /// The running app's tier, read once.
    static let current: SigningTier = classify(facts(of: Bundle.main.bundleURL))

    /// One honest line for the panel: what the signature is and what it means for the permissions you gave.
    var panelLine: String {
        switch self {
        case .unsigned: return updatesText("Signature: missing or damaged. Reinstall Cocaine.")
        case .adhoc: return updatesText("Signature: ad hoc. macOS forgets the permissions at every update.")
        case .local: return updatesText("Signature: self-signed, not verified by Apple. Permissions carry over only to updates signed with the same certificate.")
        case .otherCertificate: return updatesText("Signature: a certificate that isn't Cocaine's or Apple's.")
        case .developerID: return updatesText("Signature: Developer ID, not notarized.")
        case .notarized: return updatesText("Signature: Developer ID, notarized by Apple.")
        }
    }
}
