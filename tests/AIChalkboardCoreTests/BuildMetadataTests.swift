import XCTest
@testable import AIChalkboardCore

final class BuildMetadataTests: XCTestCase {
    func testProductVersionMatchesMCPReleaseVersion() {
        XCTAssertEqual(BuildMetadata.productVersion, "2.1.0")
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
}
