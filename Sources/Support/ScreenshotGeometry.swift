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
