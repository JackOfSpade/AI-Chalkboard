import Foundation

/// Answers one question, once, for the whole process: are we running inside a
/// test bundle rather than as the real app?
///
/// WHY THIS EXISTS: this package writes to several per-user, machine-wide
/// locations -- the diagnostic log, the suspension lease registry, the
/// single-instance election lock, and a session-wide broadcast channel. Every
/// one of them has a test-only environment override, and every one of those
/// overrides has to be set by the test that needs it. That is opt-in
/// isolation, and it failed in exactly the way opt-in isolation always fails:
/// of 32 test files, one set any of them. The rest ran against the live
/// locations a running connector uses.
///
/// The consequences were not all cosmetic:
///
///   * The log. `swift test` wrote synthetic WARN records into the user's real
///     `ai_chalkboard.log`, competing for the 5 MB rotation budget that
///     retains genuine diagnostics.
///   * The lease registry. A test touching `SuspensionLeaseCoordinator.shared`
///     read and wrote the same `annotations-suspension-v3.json` a live
///     connector polls.
///   * The election lock. A test touching `InstanceLock.shared` contended for
///     the same `instance.lock` the live primary holds, and could demote it.
///   * The broadcast channel. Worst of the four: it is session-wide and
///     unauthenticated, and carries `quitAll` -- so a test that posted one
///     could terminate the user's running connector.
///
/// So detection moves here, and every default resolution consults it. Tests
/// are then isolated BY CONSTRUCTION rather than by remembering to opt in, and
/// a test file added next year inherits the isolation without knowing this
/// type exists.
///
/// Explicit overrides still win everywhere. This only changes what the
/// DEFAULT is when nothing was specified, so the real app is unaffected: none
/// of these checks can be true in a normally-launched `AIChalkboard.exe`.
public enum TestHarness {

    /// Whether `path` names a Swift test-bundle executable.
    ///
    /// Pure over its input rather than reading `CommandLine` itself, so the
    /// matching rule is unit-testable on both platforms without having to be
    /// inside a test bundle to exercise it -- the same shape
    /// `SuspensionLeaseCoordinator.overrideStorageDirectory
    /// (fromEnvironmentValue:)` uses for its own environment input.
    ///
    /// Splits on BOTH separators for the reason `AbsolutePath` exists in this
    /// repo: a Windows path handed to a POSIX-flavoured path API is silently
    /// mis-parsed, and this must give identical answers on both platforms
    /// because its tests run on both.
    public static func isTestBundleExecutablePath(_ path: String) -> Bool {
        let lastComponent = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
        // `contains`, not `hasSuffix`: SwiftPM names the Windows runner
        // `<Package>PackageTests.xctest` with no further extension, while other
        // toolchains append one (`...xctest.exe`). Both must match.
        return lastComponent.lowercased().contains(".xctest")
    }

    /// True when this process is a test bundle.
    ///
    /// Resolved ONCE. Every consumer is a default-path decision made during
    /// singleton construction, and a value that changed mid-process would mean
    /// two singletons disagreeing about where the registry lives.
    ///
    /// Three signals, because no single one covers both platforms:
    ///
    ///   * The executable name. The only one that works under `swift test` on
    ///     Windows, where -- verified on this toolchain -- neither environment
    ///     variable below is exported. Without it the Windows side had no
    ///     working detection at all.
    ///   * `XCTestCase` being loaded (macOS only; there is no Objective-C
    ///     runtime lookup on Windows). True exactly when a test bundle is
    ///     loaded, under both the command-line runner and Xcode.
    ///   * The XCTest environment variables, which Xcode does export.
    public static let isActive: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return true
        }
        #if os(macOS)
        if NSClassFromString("XCTestCase") != nil { return true }
        #endif
        return isTestBundleExecutablePath(CommandLine.arguments.first ?? "")
    }()

    /// A namespace suffix unique to this process, for channels that are
    /// otherwise session-wide.
    ///
    /// Scoped per PID, not per run: a test bundle is a single process, so this
    /// keeps in-process siblings talking to each other while walling them off
    /// from any other process on the machine -- which is exactly the boundary
    /// that matters, since the thing being isolated FROM is the user's live
    /// connector.
    ///
    /// Restricted to characters that are safe in both a `Notification.Name`
    /// and a Win32 window class name.
    public static let processScopedNamespace: String = "xctest-\(ProcessInfo.processInfo.processIdentifier)"

    /// Per-process scratch directory standing in for the real per-user state
    /// directory while under test.
    ///
    /// Deliberately NOT cleaned up here. Deleting it would race the very
    /// file-locking code most of these tests exercise, and the OS reclaims the
    /// temp directory anyway; a few kilobytes of leftover JSON is a far better
    /// outcome than a test that intermittently deletes a lock out from under
    /// itself.
    ///
    /// CREATED EAGERLY, WITH INTERMEDIATES, and that is load-bearing rather
    /// than convenience: this path is two levels below the temp directory,
    /// while both consumers create only a SINGLE level for themselves --
    /// `SuspensionLeaseStorage.openSecureDirectory` calls bare
    /// `CreateDirectoryW`/`mkdir` on the leaf, and `InstanceLockPolicy` only
    /// runs its `withIntermediateDirectories` helper on the NON-overridden
    /// production path. Left to them, the missing `AIChalkboardTestSandbox`
    /// parent would surface as `ERROR_PATH_NOT_FOUND` and the registry would
    /// report itself permanently unavailable under test.
    ///
    /// `try?` because a failure here is not this type's to report: the
    /// consumers already fail loudly and specifically when their directory is
    /// unusable, and duplicating that as a fatal error would turn a
    /// diagnosable problem into an unexplained crash at first log line.
    public static let sandboxDirectory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIChalkboardTestSandbox", isDirectory: true)
            .appendingPathComponent(processScopedNamespace, isDirectory: true)
            .standardizedFileURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
