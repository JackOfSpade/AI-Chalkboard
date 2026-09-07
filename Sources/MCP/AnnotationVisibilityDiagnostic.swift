import Foundation

/// The pure visibility calculation used by verification metadata. Suspension
/// always wins over ordinary app/capture eligibility, while the intermediate
/// value explains whether the retained annotation will return on resume.
struct AnnotationVisibilityDiagnostic: Equatable {
    let annotationsSuspended: Bool
    let wouldBeVisibleWithoutSuspension: Bool
    let isVisibleNow: Bool

    /// `anchorPermitsPainting` is `Annotation.anchorPermitsPainting`: false
    /// only when this annotation is anchored to a window that is currently
    /// `hidden` (minimised, hidden app, another Space) or `lost` (closed).
    ///
    /// It gates `wouldBeVisibleWithoutSuspension` rather than only
    /// `isVisibleNow` because, unlike suspension, a lost anchor is NOT
    /// something a resume brings back -- reporting "it would be visible if
    /// you resumed" for a drawing whose window no longer exists would send a
    /// caller to `resume_annotations` for a problem resuming cannot solve.
    ///
    /// It is deliberately NOT overridden by `captureVisible`. Capture-debug
    /// exists to reveal drawings the per-app filter is hiding, which are
    /// correctly placed; an annotation whose anchor window is gone is not,
    /// and the live renderer suppresses it in capture-debug too (see
    /// `AnnotationStore.getForScreen(_:)`). This predicate must agree with
    /// what actually paints, or the metadata contradicts the pixels.
    init(annotationsSuspended: Bool, captureVisible: Bool,
         annotationAppId: String?, activeAppId: String?,
         anchorPermitsPainting: Bool = true) {
        self.annotationsSuspended = annotationsSuspended
        wouldBeVisibleWithoutSuspension = anchorPermitsPainting
            && (captureVisible
                || annotationAppId == nil
                || annotationAppId == activeAppId)
        isVisibleNow = !annotationsSuspended && wouldBeVisibleWithoutSuspension
    }
}
