import XCTest
@testable import AIChalkboardCore

final class AnnotationVisibilityDiagnosticTests: XCTestCase {
    func testSuspensionOverridesOtherwiseVisibleAnnotation() {
        let diagnostic = AnnotationVisibilityDiagnostic(
            annotationsSuspended: true,
            captureVisible: false,
            annotationAppId: "com.example.target",
            activeAppId: "com.example.target"
        )

        XCTAssertTrue(diagnostic.annotationsSuspended)
        XCTAssertTrue(diagnostic.wouldBeVisibleWithoutSuspension)
        XCTAssertFalse(diagnostic.isVisibleNow)
    }

    func testResumeRestoresOrdinaryVisibilityFilters() {
        XCTAssertEqual(
            AnnotationVisibilityDiagnostic(
                annotationsSuspended: false,
                captureVisible: false,
                annotationAppId: "com.example.target",
                activeAppId: "com.example.target"
            ).isVisibleNow,
            true
        )
        XCTAssertEqual(
            AnnotationVisibilityDiagnostic(
                annotationsSuspended: false,
                captureVisible: false,
                annotationAppId: "com.example.other",
                activeAppId: "com.example.target"
            ).isVisibleNow,
            false
        )
        XCTAssertEqual(
            AnnotationVisibilityDiagnostic(
                annotationsSuspended: false,
                captureVisible: true,
                annotationAppId: "com.example.other",
                activeAppId: "com.example.target"
            ).isVisibleNow,
            true
        )
    }
}
