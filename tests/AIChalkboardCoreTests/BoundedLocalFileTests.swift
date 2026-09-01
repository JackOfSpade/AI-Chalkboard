import XCTest
#if os(macOS)
import Darwin
#elseif os(Windows)
import WinSDK
#endif
@testable import AIChalkboardCore

final class BoundedLocalFileTests: XCTestCase {
    private func writeTempFile(bytes: Int, byte: UInt8 = 0x41) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-chalkboard-bounded-local-file-\(UUID().uuidString).bin")
        try Data(repeating: byte, count: bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadsRegularFileWithinBudget() throws {
        let url = try writeTempFile(bytes: 128)
        let data = try BoundedLocalFile.read(path: url.path, maxBytes: 1_024)
        XCTAssertEqual(data, Data(repeating: 0x41, count: 128))
    }

    func testReadsFileExactlyAtTheByteCap() throws {
        let url = try writeTempFile(bytes: 64)
        let data = try BoundedLocalFile.read(path: url.path, maxBytes: 64)
        XCTAssertEqual(data.count, 64)
    }

    func testRejectsFileOverTheByteCap() throws {
        let url = try writeTempFile(bytes: 65)
        XCTAssertThrowsError(try BoundedLocalFile.read(path: url.path, maxBytes: 64)) { error in
            XCTAssertEqual(error as? BoundedLocalFileError, .unreadable)
        }
    }

    func testRejectsNonRegularFile() {
        let directory = FileManager.default.temporaryDirectory.path
        XCTAssertThrowsError(try BoundedLocalFile.read(path: directory, maxBytes: 1_024)) { error in
            XCTAssertEqual(error as? BoundedLocalFileError, .unreadable)
        }
    }

    #if os(macOS)
    /// A FIFO with no writer must be REJECTED, and must be rejected without
    /// blocking. This is the regression test for the open(2)-on-a-FIFO hang:
    /// with a blocking open, this test does not fail -- it never returns, and
    /// in production it took the MCP server's single read loop with it (the
    /// path is reachable from `draw_image`'s image_path and
    /// `verify_annotation`'s screenshot_path). The XCTest timeout below is
    /// therefore load-bearing: it is what turns "hung forever" into a failure.
    func testRejectsFifoWithoutBlocking() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-chalkboard-bounded-local-file-fifo-\(UUID().uuidString)")
        guard mkfifo(url.path, 0o600) == 0 else {
            throw XCTSkip("mkfifo failed (errno \(errno)); cannot exercise the FIFO path here.")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let finished = expectation(description: "BoundedLocalFile.read returned on a writer-less FIFO")
        DispatchQueue.global().async {
            do {
                _ = try BoundedLocalFile.read(path: url.path, maxBytes: 1_024)
                XCTFail("Expected a FIFO to be rejected as not-a-regular-file")
            } catch {
                XCTAssertEqual(error as? BoundedLocalFileError, .unreadable)
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
    }
    #elseif os(Windows)
    /// Windows equivalent of the macOS FIFO test above. Windows has no
    /// ordinary-path equivalent of a writer-less POSIX FIFO -- named pipes
    /// live in the separate `\\.\pipe\` namespace, and a client `CreateFileW`
    /// against an instance a server has already created connects
    /// immediately rather than blocking the way `open()` on a FIFO does --
    /// so this is not a hang regression test the way the macOS one is. What
    /// it DOES verify is the type check that stands in for the macOS
    /// branch's `S_IFREG` guard: `GetFileType` must report the pipe as not
    /// `FILE_TYPE_DISK`, so `BoundedLocalFile.read` rejects it. The
    /// expectation/timeout scaffolding is kept for parity with the macOS
    /// test and as a backstop in case that assumption about client-open
    /// behavior is ever wrong on some Windows version.
    func testRejectsNamedPipeWithoutBlocking() throws {
        let pipeName = "\\\\.\\pipe\\ai-chalkboard-bounded-local-file-\(UUID().uuidString)"
        let serverHandle: HANDLE = pipeName.withCString(encodedAs: UTF16.self) { widePipeName in
            CreateNamedPipeW(
                widePipeName,
                DWORD(PIPE_ACCESS_DUPLEX),
                DWORD(PIPE_TYPE_BYTE) | DWORD(PIPE_WAIT),
                1,
                0,
                0,
                0,
                nil
            )
        }
        guard serverHandle != INVALID_HANDLE_VALUE else {
            throw XCTSkip("CreateNamedPipeW failed (Win32 error \(GetLastError())); cannot exercise the named-pipe path here.")
        }
        addTeardownBlock { CloseHandle(serverHandle) }

        let finished = expectation(description: "BoundedLocalFile.read returned on a named pipe path")
        DispatchQueue.global().async {
            do {
                _ = try BoundedLocalFile.read(path: pipeName, maxBytes: 1_024)
                XCTFail("Expected a named pipe to be rejected as not-a-regular-disk-file")
            } catch {
                XCTAssertEqual(error as? BoundedLocalFileError, .unreadable)
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
    }
    #endif

    func testRejectsRelativePath() {
        XCTAssertThrowsError(try BoundedLocalFile.read(path: "relative.bin", maxBytes: 1_024)) { error in
            XCTAssertEqual(error as? BoundedLocalFileError, .invalidPath)
        }
    }
}
