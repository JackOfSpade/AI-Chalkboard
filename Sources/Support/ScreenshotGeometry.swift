import Foundation

/// Shared validation for mapping a raster screenshot onto a display.
///
/// A full-display screenshot may be uniformly downsampled, with each output
/// dimension rounded to an integer pixel. That can make its X and Y scales
/// differ slightly, but only by the amount explained by at most one rounded
/// output pixel on each axis. A larger difference means the image is cropped,
/// window-only, or otherwise not safely mappable to the whole display.
enum ScreenshotGeometry {
    struct Scale: Equatable {
        let x: Double
        let y: Double
        let relativeDifference: Double
        let maximumRelativeDifference: Double
    }

    /// Whether the image could plausibly BE a full-display capture of the
    /// given display: its dimensions map uniformly (`fullDisplayScale`) AND
    /// the image is no LARGER than the display's backing pixels.
    ///
    /// WHY THE SIZE HALF MATTERS: `fullDisplayScale` alone accepts ANY
    /// uniform scale, including an enlargement -- so every display sharing
    /// the image's aspect ratio "fits", regardless of size. That is the
    /// right question for "can these declared dimensions be mapped onto the
    /// display I am drawing on" (a draw call names its display; the scale
    /// only converts units), but it is the WRONG question for "which display
    /// is this image a picture of": no capture pipeline upscales a
    /// screenshot, so an image larger than a display can only describe it
    /// via an enlargement that never happens in practice. Counting such a
    /// display as a candidate made which-display ambiguity guards fire on a
    /// 4K-primary-plus-QHD-sibling desktop (both 16:9) for a NATIVE 4K
    /// capture -- an image that identifies its display beyond reasonable
    /// doubt.
    ///
    /// The tolerance admits scale exactly 1 (a native capture) and every
    /// downsample; integer rounding of a genuine downsample can never push a
    /// dimension ABOVE the display's own, so anything meaningfully past 1 is
    /// an upscale, not noise.
    static func isPlausibleFullDisplayCapture(
        screenshotWidth: Double,
        screenshotHeight: Double,
        screenWidth: Double,
        screenHeight: Double
    ) -> Bool {
        guard let scale = fullDisplayScale(
            screenshotWidth: screenshotWidth,
            screenshotHeight: screenshotHeight,
            screenWidth: screenWidth,
            screenHeight: screenHeight
        ) else { return false }
        let noUpscaleTolerance = 1.0 + 1e-6
        return scale.x <= noUpscaleTolerance && scale.y <= noUpscaleTolerance
    }

    static func fullDisplayScale(
        screenshotWidth: Double,
        screenshotHeight: Double,
        screenWidth: Double,
        screenHeight: Double
    ) -> Scale? {
        guard screenshotWidth.isFinite, screenshotHeight.isFinite,
              screenWidth.isFinite, screenHeight.isFinite,
              screenshotWidth > 0, screenshotHeight > 0,
              screenWidth > 0, screenHeight > 0 else { return nil }

        let scaleX = screenshotWidth / screenWidth
        let scaleY = screenshotHeight / screenHeight
        let largestScale = max(scaleX, scaleY)
        guard scaleX.isFinite, scaleY.isFinite, largestScale > 0 else { return nil }

        let relativeDifference = abs(scaleX - scaleY) / largestScale
        // Nearest-integer output dimensions can each differ from the ideal by
        // at most half a pixel. Their scale intervals overlap exactly within
        // this combined half-pixel-per-axis tolerance.
        let absoluteRoundingTolerance = (0.5 / screenWidth) + (0.5 / screenHeight)
        let maximumRelativeDifference = absoluteRoundingTolerance / largestScale
        guard relativeDifference <= maximumRelativeDifference else { return nil }

        return Scale(
            x: scaleX,
            y: scaleY,
            relativeDifference: relativeDifference,
            maximumRelativeDifference: maximumRelativeDifference
        )
    }
}
