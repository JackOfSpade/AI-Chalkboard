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

    // MARK: - anchorPermitsPainting gates visibility, independent of captureVisible
    //
    // `anchorPermitsPainting` defaults to `true`, so every test above (which
    // never passes it) already pins that the default leaves every existing
    // case unchanged -- they still pass unmodified. The tests below cover the
    // new parameter itself: `false` must force both
    // `wouldBeVisibleWithoutSuspension` and `isVisibleNow` to `false`, even in
    // the two cases that would otherwise report `true` -- `captureVisible`
    // (deliberately NOT a bypass here, unlike the app filter) and a global
    // annotation (`annotationAppId: nil`, which ordinarily matches every
    // active app).

    func testAnchorNotPermittedToPaintForcesInvisibleEvenWhenCaptureVisible() {
        let diagnostic = AnnotationVisibilityDiagnostic(
            annotationsSuspended: false,
            captureVisible: true,
            annotationAppId: "com.example.other",
            activeAppId: "com.example.target",
            anchorPermitsPainting: false
        )

        XCTAssertFalse(diagnostic.wouldBeVisibleWithoutSuspension,
                       "captureVisible would otherwise make this true; a hidden/lost anchor must still win")
        XCTAssertFalse(diagnostic.isVisibleNow)
    }

    func testAnchorNotPermittedToPaintForcesInvisibleForAGlobalAnnotation() {
        let diagnostic = AnnotationVisibilityDiagnostic(
            annotationsSuspended: false,
            captureVisible: false,
            annotationAppId: nil,
            activeAppId: "com.example.target",
            anchorPermitsPainting: false
        )

        XCTAssertFalse(diagnostic.wouldBeVisibleWithoutSuspension,
                       "a global (nil appId) annotation would otherwise always be visible; a hidden/lost anchor must still win")
        XCTAssertFalse(diagnostic.isVisibleNow)
    }
}
