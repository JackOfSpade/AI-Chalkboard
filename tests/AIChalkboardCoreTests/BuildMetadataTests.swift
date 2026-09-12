import XCTest
@testable import AIChalkboardCore

final class BuildMetadataTests: XCTestCase {
    func testProductVersionMatchesMCPReleaseVersion() {
        XCTAssertEqual(BuildMetadata.productVersion, "2.4.0")
    }

    func testBundleVersionStartsAtTheFirstDistributedBuild() {
        XCTAssertEqual(BuildMetadata.bundleVersion, "8")
    }

    func testBuildIdentifierUsesBundledValueWhenPresent() {
        XCTAssertEqual(
            BuildMetadata.buildIdentifier(infoDictionary: [
                BuildMetadata.buildIdentifierInfoKey: " 419fc746afac ",
            ]),
            "419fc746afac"
        )
    }

    func testBuildIdentifierUsesExplicitSourceFallbackWhenBundleMetadataIsUnavailable() {
        XCTAssertEqual(BuildMetadata.buildIdentifier(infoDictionary: nil), "source")
        XCTAssertEqual(
            BuildMetadata.buildIdentifier(infoDictionary: [BuildMetadata.buildIdentifierInfoKey: " \n "]),
            "source"
        )
    }

    #if os(Windows)
    /// Windows counterpart of the Info.plist-driven tests above, exercising
    /// `buildIdentifier(sidecarDirectory:)` directly against a scratch
    /// directory -- NOT a real dist\AIChalkboard deployment and NOT the
    /// running test binary's own GetModuleFileNameW-resolved directory, so
    /// this is deterministic and independent of how (or whether) this
    /// package has ever been packaged.
    private func writeSidecarDirectory(contents: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-chalkboard-build-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        if let contents {
            let sidecar = directory.appendingPathComponent(BuildMetadata.windowsSidecarFileName)
            try contents.write(to: sidecar, atomically: true, encoding: .utf8)
        }
        return directory
    }

    func testWindowsBuildIdentifierUsesSidecarValueWhenPresent() throws {
        let directory = try writeSidecarDirectory(contents: " 419fc746afac \n")
        XCTAssertEqual(BuildMetadata.buildIdentifier(sidecarDirectory: directory.path), "419fc746afac")
    }

    func testWindowsBuildIdentifierFallsBackToSourceWhenSidecarMissing() throws {
        let directory = try writeSidecarDirectory(contents: nil)
        XCTAssertEqual(BuildMetadata.buildIdentifier(sidecarDirectory: directory.path), "source")
    }

    func testWindowsBuildIdentifierFallsBackToSourceWhenSidecarIsBlank() throws {
        let directory = try writeSidecarDirectory(contents: "  \n  ")
        XCTAssertEqual(BuildMetadata.buildIdentifier(sidecarDirectory: directory.path), "source")
    }

    func testWindowsBuildIdentifierFallsBackToSourceWhenNoDirectoryIsKnown() {
        XCTAssertEqual(BuildMetadata.buildIdentifier(sidecarDirectory: nil), "source")
    }

    func testWindowsBuildIdentifierFallsBackToSourceWhenDirectoryDoesNotExist() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-chalkboard-build-metadata-missing-\(UUID().uuidString)")
        XCTAssertEqual(BuildMetadata.buildIdentifier(sidecarDirectory: missing.path), "source")
    }
    #endif
}
