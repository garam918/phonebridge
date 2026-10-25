import Foundation
import Security
import Testing
@testable import PhoneBridge

/// Requirement text for IPC clients (audit 2026-10-23, H2).
@Suite("PeerRequirement")
struct PeerRequirementTests {
    private func parses(_ text: String) -> Bool {
        var requirement: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess && requirement != nil
    }

    @Test func teamBuildsRequireAnAppleCertificateOfTheTeam() throws {
        let text = try #require(PeerRequirement.text(identifiers: ["com.a", "com.a.ext"], team: "ABCDE12345",
                                                     ownCDHash: Data([1, 2])))
        #expect(text == "(identifier \"com.a\" or identifier \"com.a.ext\") and anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\"")
        #expect(parses(text))
    }

    @Test func adHocBuildsRequireThisExactExecutable() throws {
        let hash = Data([0x0a, 0xff] + [UInt8](repeating: 0x10, count: 18)) // 20 bytes, like a real cdhash
        let text = try #require(PeerRequirement.text(identifiers: ["com.a"], team: nil, ownCDHash: hash))
        #expect(text == "(identifier \"com.a\") and cdhash H\"0aff\(String(repeating: "10", count: 18))\"")
        #expect(parses(text))
    }

    @Test func identifierAloneIsNeverEnough() {
        #expect(PeerRequirement.text(identifiers: ["com.a"], team: nil, ownCDHash: nil) == nil)
        #expect(PeerRequirement.text(identifiers: ["com.a"], team: "", ownCDHash: Data()) == nil)
        #expect(PeerRequirement.text(identifiers: [], team: "ABCDE12345", ownCDHash: nil) == nil)
    }

    @Test func ownSignatureYieldsAUsableRequirement() throws {
        let own = try #require(PeerRequirement.ownSignature())
        #expect(own.cdhash?.isEmpty == false)
        let text = try #require(PeerRequirement.forOwnSignature(identifiers: [FinderIPC.appBundleIdentifier]))
        #expect(parses(text))
        #expect(text.contains("anchor apple generic") || text.contains("cdhash H\""))
    }
}
