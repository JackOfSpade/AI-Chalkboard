import XCTest
@testable import AIChalkboardCore

/// `ColorParser.parse` sits on every render path (`OverlayView.draw(_:)` looks
/// up `annotation.colorHex` through it on every repaint) and previously had
/// zero direct coverage. These tests pin down the documented named-color
/// table, every hex-length branch (3/6/8 digit), the RGBA-not-ARGB ordering
/// of the 8-digit branch, and the malformed-input fallbacks that a prior fix
/// hardened ("#12GG56", "#GGGGGG", "0xff0000", "#12345" all must fall back to
/// red rather than silently parsing a truncated prefix).
final class ColorParserTests: XCTestCase {
    private let defaultRed = (r: 1.0, g: 0.2, b: 0.2, a: 0.9)

    private func assertColor(
        _ color: ChalkColor,
        r: Double, g: Double, b: Double, a: Double,
        accuracy: Double = 0.005,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(color.red, r, accuracy: accuracy, "red", file: file, line: line)
        XCTAssertEqual(color.green, g, accuracy: accuracy, "green", file: file, line: line)
        XCTAssertEqual(color.blue, b, accuracy: accuracy, "blue", file: file, line: line)
        XCTAssertEqual(color.alpha, a, accuracy: accuracy, "alpha", file: file, line: line)
    }

    private func assertColorsEqual(
        _ lhs: ChalkColor, _ rhs: ChalkColor,
        accuracy: Double = 0.005,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(lhs.red, rhs.red, accuracy: accuracy, "red", file: file, line: line)
        XCTAssertEqual(lhs.green, rhs.green, accuracy: accuracy, "green", file: file, line: line)
        XCTAssertEqual(lhs.blue, rhs.blue, accuracy: accuracy, "blue", file: file, line: line)
        XCTAssertEqual(lhs.alpha, rhs.alpha, accuracy: accuracy, "alpha", file: file, line: line)
    }

    private func assertDefaultRed(_ input: String?, file: StaticString = #filePath, line: UInt = #line) {
        assertColor(ColorParser.parse(input), r: defaultRed.r, g: defaultRed.g, b: defaultRed.b, a: defaultRed.a, file: file, line: line)
    }

    // MARK: - Named colors

    func testEveryNamedColorMapsToItsDocumentedRGBA() {
        let expectations: [(String, Double, Double, Double, Double)] = [
            ("red", 1.0, 0.2, 0.2, 0.9),
            ("green", 0.2, 0.85, 0.3, 0.9),
            ("blue", 0.2, 0.5, 1.0, 0.9),
            ("yellow", 1.0, 0.8, 0.0, 0.9),
            ("orange", 1.0, 0.5, 0.0, 0.9),
            ("purple", 0.6, 0.3, 0.9, 0.9),
            ("pink", 1.0, 0.4, 0.7, 0.9),
            ("cyan", 0.0, 0.8, 0.9, 0.9),
            ("white", 1.0, 1.0, 1.0, 0.9),
            ("black", 0.1, 0.1, 0.1, 0.9)
        ]
        for (name, r, g, b, a) in expectations {
            assertColor(ColorParser.parse(name), r: r, g: g, b: b, a: a)
        }
    }

    // MARK: - Hex parsing

    func testHashPrefixedAndBareHexAgree() {
        assertColorsEqual(ColorParser.parse("#336699"), ColorParser.parse("336699"))
    }

    func test3DigitHexDoublesEachNibble() {
        assertColorsEqual(ColorParser.parse("#f00"), ColorParser.parse("#ff0000"))
        assertColor(ColorParser.parse("#f00"), r: 1.0, g: 0.0, b: 0.0, a: 1.0)
    }

    func test8DigitHexIsInterpretedAsRGBANotARGB() {
        // 0x11223344 -> r=0x11, g=0x22, b=0x33, a=0x44. If the code mistakenly
        // treated this as ARGB, alpha (0x11) would land in red instead.
        assertColor(
            ColorParser.parse("#11223344"),
            r: Double(0x11) / 255.0, g: Double(0x22) / 255.0, b: Double(0x33) / 255.0, a: Double(0x44) / 255.0
        )
    }

    func testHexParsingIsCaseInsensitive() {
        assertColorsEqual(ColorParser.parse("#AABBCC"), ColorParser.parse("#aabbcc"))
        assertColorsEqual(ColorParser.parse("RED"), ColorParser.parse("red"))
    }

    func testSurroundingWhitespaceIsTrimmed() {
        assertColorsEqual(ColorParser.parse("  red  "), ColorParser.parse("red"))
        assertColorsEqual(ColorParser.parse("  #112233  "), ColorParser.parse("#112233"))
    }

    // MARK: - Defaults / fallbacks

    func testNilAndEmptyGiveTheDefaultRed() {
        assertDefaultRed(nil)
        assertDefaultRed("")
        assertDefaultRed("   ") // trims to empty
    }

    func testMalformedHexInputsAllFallBackToDefaultRedRatherThanAPlausibleWrongColor() {
        // "#12GG56": Scanner.scanHexInt64 would otherwise stop at the first
        // invalid character and silently succeed with a truncated prefix.
        assertDefaultRed("#12GG56")
        // "#GGGGGG": right length, entirely invalid digits.
        assertDefaultRed("#GGGGGG")
        // "0xff0000": Scanner recognizes and skips a 0x prefix; without an
        // explicit hex-digit check this would be misrouted into the 8-digit
        // RGBA branch reading only "ff0000".
        assertDefaultRed("0xff0000")
        // "#12345": valid hex digits but a length (5) that is not 3, 6, or 8.
        assertDefaultRed("#12345")
    }
}
