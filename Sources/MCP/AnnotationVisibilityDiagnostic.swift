import Foundation

/// The pure visibility calculation used by verification metadata. Suspension
/// always wins over ordinary app/capture eligibility, while the intermediate
/// value explains whether the retained annotation will return on resume.
struct AnnotationVisibilityDiagnostic: Equatable {
    let annotationsSuspended: Bool
    let wouldBeVisibleWithoutSuspension: Bool
    let isVisibleNow: Bool

    init(annotationsSuspended: Bool, captureVisible: Bool,
         annotationAppId: String?, activeAppId: String?) {
        self.annotationsSuspended = annotationsSuspended
        wouldBeVisibleWithoutSuspension = captureVisible
            || annotationAppId == nil
            || annotationAppId == activeAppId
        isVisibleNow = !annotationsSuspended && wouldBeVisibleWithoutSuspension
    }
}
