import Foundation

extension Error {
    /// Domain and code only, safe for the public log and for messages that
    /// cross to the Finder extension: Cocoa's `localizedDescription` quotes file
    /// names and paths (audit 2026-10-23, M13).
    var publicSummary: String {
        let error = self as NSError
        return "\(error.domain) \(error.code)"
    }
}
