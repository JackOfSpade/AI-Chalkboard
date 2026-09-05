import XCTest
@testable import AIChalkboardCore

/// `AbsolutePath.isAbsolute` gates every environment-path override in the app
/// (the suspension registry root, the instance-lock path, the log directory)
/// and the only-absolute rule in `BoundedLocalFile.read`. Those call sites rely
/// on it rejecting anything that would otherwise be resolved against the
/// process's current directory, so the platform matrix is pinned here directly
/// rather than only through its callers.
final class AbsolutePathTests: XCTestCase {
    func testRejectsValuesThatWouldResolveAgainstTheCurrentDirectory() {
        XCTAssertFalse(AbsolutePath.isAbsolute(""))
        XCTAssertFalse(AbsolutePath.isAbsolute("relative"))
        XCTAssertFalse(AbsolutePath.isAbsolute("relative/dir"))
        XCTAssertFalse(AbsolutePath.isAbsolute("./relative"))
        XCTAssertFalse(AbsolutePath.isAbsolute("../relative"))
    }

    #if os(Windows)
    func testAcceptsWindowsAbsoluteForms() {
        XCTAssertTrue(AbsolutePath.isAbsolute(#"C:\Users\example"#))
        XCTAssertTrue(AbsolutePath.isAbsolute(#"C:/Users/example"#), "Win32 accepts forward slashes too")
        XCTAssertTrue(AbsolutePath.isAbsolute(#"c:\lowercase\drive"#))
        XCTAssertTrue(AbsolutePath.isAbsolute(#"\\server\share\dir"#), "UNC")
        XCTAssertTrue(AbsolutePath.isAbsolute(#"\\?\C:\extended\length"#), "extended-length prefix is UNC-shaped")
    }

    /// The case Foundation's `NSString.isAbsolutePath` gets wrong on Windows,
    /// and the reason this helper exists: `C:relative` is relative to the
    /// current directory OF DRIVE C:, so `URL(fileURLWithPath:)` resolves it
    /// against the process's cwd. Accepting it would defeat every guard above.
    func testRejectsDriveRelativeAndOtherNearMissWindowsForms() {
        XCTAssertFalse(AbsolutePath.isAbsolute(#"C:relative"#))
        XCTAssertFalse(AbsolutePath.isAbsolute("C:"))
        XCTAssertFalse(AbsolutePath.isAbsolute("C"))
        XCTAssertFalse(AbsolutePath.isAbsolute(#"1:\not\a\drive\letter"#))
        XCTAssertFalse(AbsolutePath.isAbsolute(#"\single\backslash"#),
                       "a single leading backslash is drive-relative, not absolute")
    }

    /// A POSIX path is not absolute on Windows -- it has no drive, so it would
    /// be resolved against the current drive.
    func testRejectsPosixAbsoluteFormOnWindows() {
        XCTAssertFalse(AbsolutePath.isAbsolute("/tmp/example"))
    }
    #else
    func testAcceptsPosixAbsoluteFormAndRejectsWindowsForms() {
        XCTAssertTrue(AbsolutePath.isAbsolute("/tmp/example"))
        XCTAssertTrue(AbsolutePath.isAbsolute("/"))
        XCTAssertFalse(AbsolutePath.isAbsolute(#"C:\Users\example"#),
                       "a Windows path carries no meaning as an absolute POSIX path")
    }
    #endif
}
