import Foundation

/// Release identity exposed to MCP clients so a desktop session can identify
/// exactly which bundled Chalkboard process it is talking to.  A bare
/// SwiftPM executable has no generated Info.plist, so it intentionally uses
/// the stable `source` fallback rather than pretending to know a Git revision.
enum BuildMetadata {
    static let productVersion = "2.1.0"

    /// `CFBundleVersion` for distributed bundles. Increment this before every
    /// distribution, independently of the user-facing product version. Apple
    /// accepts one to three period-separated non-negative integer components;
    /// `1` is the initial distributed build number.
    static let bundleVersion = "1"

    static let buildIdentifierInfoKey = "AIChalkboardBuildIdentifier"
    static let sourceBuildIdentifier = "source"

    static var buildIdentifier: String {
        buildIdentifier(infoDictionary: Bundle.main.infoDictionary)
    }

    static func buildIdentifier(infoDictionary: [String: Any]?) -> String {
        guard let rawIdentifier = infoDictionary?[buildIdentifierInfoKey] as? String else {
            return sourceBuildIdentifier
        }
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? sourceBuildIdentifier : identifier
    }
}
