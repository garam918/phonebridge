import Foundation
import Security

/// Who may talk to PhoneBridge's IPC endpoints, as a code-signing requirement
/// checked against the kernel's audit token for the peer. A signing identifier
/// alone proves nothing: any local binary can be ad-hoc signed with any
/// identifier (audit 2026-10-23, H2).
enum PeerRequirement {
    /// `identifiers` signed with an Apple-issued certificate of `team`. Without
    /// a team (ad-hoc development builds, unit tests) nothing but this exact
    /// executable, by its code directory hash; nil when even that is unknown.
    static func text(identifiers: [String], team: String?, ownCDHash: Data?) -> String? {
        guard !identifiers.isEmpty else { return nil }
        let allowed = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        if let team, !team.isEmpty {
            return "(\(allowed)) and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        guard let ownCDHash, !ownCDHash.isEmpty else { return nil }
        let hex = ownCDHash.map { String(format: "%02x", $0) }.joined()
        return "(\(allowed)) and cdhash H\"\(hex)\""
    }

    /// `text` for this process's own signature.
    static func forOwnSignature(identifiers: [String]) -> String? {
        let own = ownSignature()
        return text(identifiers: identifiers, team: own?.team, ownCDHash: own?.cdhash)
    }

    /// Team identifier and code directory hash of the running process.
    static func ownSignature() -> (team: String?, cdhash: Data?)? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any]
        else { return nil }
        return (values[kSecCodeInfoTeamIdentifier as String] as? String, values[kSecCodeInfoUnique as String] as? Data)
    }

    /// True when the process behind `auditToken` has a valid signature that
    /// satisfies `requirement`.
    static func isSatisfied(by auditToken: audit_token_t, requirement: String) -> Bool {
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess, let parsed else { return false }
        let token = withUnsafeBytes(of: auditToken) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: token] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidity(code, [], parsed) == errSecSuccess
    }
}
