#if os(macOS)
import AppKit
import CoreGraphics
import Darwin
import ScreenCaptureKit
#elseif os(Windows)
import CChalkboardWin
#endif
import Foundation

#if os(macOS)
/// The stable, machine-readable decision made before asking macOS to capture a
/// display.  It is separate from the CoreGraphics prompt call so callers can
/// test denial/request behavior without opening System Settings in XCTest.
///
/// MACOS ONLY: this decision tree exists because macOS's TCC (Screen
/// Recording permission) has a genuine three-way outcome -- already granted,
/// denied-and-not-yet-prompted, denied-and-a-prompt-was-requested. Windows
/// has no analogous permission gate for a desktop Win32 process (see
/// `permissionStatus(requestPermission:)`'s Windows branch below), so this
/// type has no Windows counterpart at all rather than a degenerate one: a
/// type that can only ever resolve to `.granted` would misrepresent Windows
/// as having a permission system that merely always says yes.
public enum ScreenCapturePermissionDecision: Equatable {
    case granted
    case deniedWithoutPrompt
    case promptRequested

    static func resolve(preflightGranted: Bool, requestPermission: Bool) -> ScreenCapturePermissionDecision {
        if preflightGranted { return .granted }
        return requestPermission ? .promptRequested : .deniedWithoutPrompt
    }
}
#endif

public struct ScreenCapturePermissionStatus: Codable, Equatable {
    public let granted: Bool
    public let promptRequested: Bool
    public let note: String

    public init(granted: Bool, promptRequested: Bool, note: String) {
        self.granted = granted
        self.promptRequested = promptRequested
        self.note = note
    }
}

#if os(macOS)
public struct ScreenCaptureApplicationIdentity: Equatable {
    public let processID: pid_t
    public let bundleIdentifier: String?
    /// `SCApplication` does not itself expose an executable URL.  When the
    /// process is registered with LaunchServices, this value is resolved from
    /// `NSRunningApplication` and lets raw/unbundled development launches
    /// exclude sibling instances which do not have a bundle identifier.
    public let executablePath: String?

    public init(processID: pid_t, bundleIdentifier: String?, executablePath: String? = nil) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
    }
}
#endif

/// Describes the identity dimensions used for Chalkboard exclusion.  It is a
/// capability statement, not an occlusion guarantee: on macOS, ScreenCaptureKit
/// can exclude only the `SCApplication` objects it exposes for this capture;
/// on Windows, `note` explains why NONE of these dimensions ever apply -- see
/// its Windows-specific doc comment below.
public struct ScreenCaptureExclusionScope: Codable, Equatable {
    public let processID: Bool
    public let bundleIdentifier: Bool
    public let executablePath: Bool

    public init(processID: Bool, bundleIdentifier: Bool, executablePath: Bool) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
    }

    #if os(macOS)
    public var note: String {
        var identities = ["process ID"]
        if bundleIdentifier { identities.append("bundle identifier") }
        if executablePath { identities.append("executable path") }
        return "ScreenCaptureKit was configured to exclude exposed AI Chalkboard applications matching \(identities.joined(separator: ", ")). Other overlays and window occlusion are not raw-framebuffer proof."
    }
    #elseif os(Windows)
    /// WINDOWS: `chalk_capture_monitor` captures via BitBlt with the
    /// CAPTUREBLT flag, which -- per chalkboard_win.h's own doc comment on
    /// `chalk_window_set_excluded_from_capture` -- includes every window
    /// composited on screen UNCONDITIONALLY, this process's own overlay and
    /// any sibling AI Chalkboard instance's overlay included.
    /// `WDA_EXCLUDEFROMCAPTURE` (the one self-exclusion primitive Win32
    /// offers) is documented to affect only captures taken by OTHER
    /// applications (Zoom, OBS, Windows' built-in recorder, ...), not this
    /// capture route -- and Win32 has no analogue of ScreenCaptureKit's
    /// `excludingApplications` list at all, i.e. no "exclude these OTHER
    /// processes from MY capture" API exists to call in the first place.
    /// So unlike macOS this scope is never non-trivial: every dimension this
    /// type can express is always `false` for a Windows capture, and the
    /// resulting image can show this process's own overlay window, and any
    /// sibling AI Chalkboard instance's overlay window, layered on top of
    /// the desktop exactly as WindowServer composited them.
    public var note: String {
        "Windows has no capture-exclusion mechanism for this capture route: chalk_capture_monitor (BitBlt with CAPTUREBLT) includes every window composited on screen, including AI Chalkboard's own overlay and any sibling AI Chalkboard instance's overlay. Unlike macOS's ScreenCaptureKit-based capture, nothing is excluded from this image."
    }
    #endif
}

#if os(Windows)
/// Wraps the raw top-down BGRA buffer `chalk_capture_monitor` returns -- the
/// Windows analogue of the `CGImage` `ScreenCaptureResult.image` carries on
/// macOS. Unlike `CGImage`, this is NOT an opaque, ImageIO/GPU-backed image
/// object with its own drawing entry point: `chalk_capture_monitor`'s doc
/// comment is explicit that the buffer is straight (non-premultiplied)
/// alpha, typically 255 throughout for an ordinary opaque screen capture.
/// `chalkboard_win.h` exposes no "wrap this raw buffer as a drawable
/// `ChalkImage`" entry point, so `AnnotationVerificationCompositor` reads
/// these bytes directly for compositing rather than handing this to GDI+ --
/// see that file's Windows `composite(screenshot:)` overload.
public final class WindowsScreenCaptureImage {
    /// Owned: freed via `chalk_capture_free` in `deinit`. Never escapes this
    /// object as a raw pointer to a caller that could outlive it.
    let bgra: UnsafeMutablePointer<UInt8>
    let width: Int
    let height: Int
    /// Row pitch in bytes, per `chalk_capture_monitor`'s doc comment -- not
    /// assumed equal to `width * 4`; GDI can pad a row to a wider stride.
    let stride: Int

    init(bgra: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int) {
        self.bgra = bgra
        self.width = width
        self.height = height
        self.stride = stride
    }

    deinit {
        chalk_capture_free(bgra)
    }
}
#endif

/// The image never touches disk.  Exposing the excluded process IDs lets an
/// integration layer state exactly why a capture is clean without pretending
/// that macOS capture can prove unoccluded raw-framebuffer pixels.
///
/// `image`'s type is platform-specific (`CGImage` on macOS,
/// `WindowsScreenCaptureImage` on Windows) because the two platforms hand
/// back fundamentally different things: an opaque, drawable ImageIO/Core
/// Graphics object on macOS versus a raw pixel buffer on Windows (see
/// `WindowsScreenCaptureImage`'s doc comment). `excludedProcessIDs` is typed
/// `[Int32]` rather than `[pid_t]` purely because `pid_t` does not exist as
/// a name on Windows -- on Darwin `pid_t` is itself a transparent `Int32`
/// typealias, so this is a spelling change only, with no behavior
/// difference for any existing macOS caller.
public struct ScreenCaptureResult {
    #if os(macOS)
    public let image: CGImage
    #elseif os(Windows)
    public let image: WindowsScreenCaptureImage
    #endif
    public let screenID: String
    public let excludedProcessIDs: [Int32]
    public let exclusionScope: ScreenCaptureExclusionScope

    #if os(macOS)
    public init(image: CGImage, screenID: String, excludedProcessIDs: [Int32],
                exclusionScope: ScreenCaptureExclusionScope = .init(processID: true, bundleIdentifier: false, executablePath: false)) {
        self.image = image
        self.screenID = screenID
        self.excludedProcessIDs = excludedProcessIDs
        self.exclusionScope = exclusionScope
    }
    #elseif os(Windows)
    /// No default `exclusionScope` here (unlike macOS): defaulting it would
    /// invite a call site to silently claim SOME exclusion happened. Windows
    /// capture always passes `ScreenCaptureProvider.windowsExclusionScope`
    /// (every dimension `false`) explicitly -- see `capture(screen:requestPermission:)`
    /// below.
    public init(image: WindowsScreenCaptureImage, screenID: String, excludedProcessIDs: [Int32],
                exclusionScope: ScreenCaptureExclusionScope) {
        self.image = image
        self.screenID = screenID
        self.excludedProcessIDs = excludedProcessIDs
        self.exclusionScope = exclusionScope
    }
    #endif
}

public enum ScreenCaptureProviderError: LocalizedError, Equatable {
    case permissionDenied(promptWasRequested: Bool)
    case displayIdentifierUnavailable(screenID: String)
    case displayUnavailable(screenID: String)
    case captureFailed(String)

    public var errorDescription: String? {
        #if os(macOS)
        switch self {
        case .permissionDenied(let promptWasRequested):
            return promptWasRequested
                ? "Screen Recording permission is not available yet. macOS was asked to show its permission prompt; grant AI Chalkboard access in System Settings > Privacy & Security > Screen Recording, then restart the app and retry."
                : "AI Chalkboard does not have Screen Recording permission. Grant it in System Settings > Privacy & Security > Screen Recording, or explicitly request the system prompt before retrying."
        case .displayIdentifierUnavailable(let screenID):
            return "Screen \(screenID) has no usable CGDirectDisplayID, so ScreenCaptureKit cannot select it. Refresh get_screens after the display configuration settles."
        case .displayUnavailable(let screenID):
            return "Screen \(screenID) is no longer available to ScreenCaptureKit. It may have disconnected or Screen Recording access may have changed; refresh screens and retry."
        case .captureFailed(let message):
            return "ScreenCaptureKit could not capture the display: \(message)"
        }
        #elseif os(Windows)
        switch self {
        case .permissionDenied:
            // Not reachable from this file's Windows capture() below --
            // permissionStatus() always reports granted (see its doc
            // comment) -- kept only so a future caller of this shared error
            // type still gets an accurate message rather than macOS's
            // System-Settings wording.
            return "Screen capture is unexpectedly unavailable on this Windows system. Windows has no screen-capture permission model for a desktop application to be denied by; this indicates an internal error, not a permission that can be granted."
        case .displayIdentifierUnavailable(let screenID):
            return "Screen \(screenID) has no usable virtual-desktop rectangle, so it cannot be captured. Refresh get_screens after the display configuration settles."
        case .displayUnavailable(let screenID):
            return "Screen \(screenID) is no longer available to capture. It may have disconnected; refresh screens and retry."
        case .captureFailed(let message):
            return "chalk_capture_monitor could not capture the display: \(message)"
        }
        #endif
    }
}

/// A one-frame provider for verification. On macOS it goes through
/// ScreenCaptureKit, selects a display, and excludes every running instance
/// of the current Chalkboard app identity. On Windows it goes through
/// `chalk_capture_monitor` (BitBlt/CAPTUREBLT) and excludes nothing -- see
/// `ScreenCaptureExclusionScope`'s Windows doc comment above for exactly
/// why. Both branches return a captured image for direct composition rather
/// than writing a privacy-sensitive screenshot to a temporary file.
public final class ScreenCaptureProvider {
    public static let shared = ScreenCaptureProvider()

    private init() {}

    #if os(macOS)
    /// The non-prompting default is important for MCP: routine verification
    /// checks should not unexpectedly steal focus with a system permission UI.
    /// Pass `requestPermission: true` only from an explicit user-authorized
    /// tool parameter.
    /// Private: the only caller is `capture()` below. It was `public`, but no
    /// MCP tool or test ever invoked it standalone, so the wider surface was
    /// unused API rather than a supported entry point.
    private func permissionStatus(requestPermission: Bool = false) -> ScreenCapturePermissionStatus {
        let preflightGranted = CGPreflightScreenCaptureAccess()
        let decision = ScreenCapturePermissionDecision.resolve(
            preflightGranted: preflightGranted,
            requestPermission: requestPermission
        )
        switch decision {
        case .granted:
            return ScreenCapturePermissionStatus(
                granted: true, promptRequested: false,
                note: "Screen Recording access is available for Chalkboard-owned verification captures."
            )
        case .deniedWithoutPrompt:
            return ScreenCapturePermissionStatus(
                granted: false, promptRequested: false,
                note: "Screen Recording access is not granted. Request the system prompt explicitly or enable AI Chalkboard in System Settings > Privacy & Security > Screen Recording."
            )
        case .promptRequested:
            // The call is intentionally made only after the pure decision so
            // unit tests can verify the policy without invoking TCC.
            let granted = CGRequestScreenCaptureAccess()
            return ScreenCapturePermissionStatus(
                granted: granted, promptRequested: true,
                note: granted
                    ? "Screen Recording access is available for Chalkboard-owned verification captures."
                    : "macOS has been asked to grant Screen Recording access. Grant access in System Settings, restart AI Chalkboard if macOS requests it, then retry."
            )
        }
    }
    #elseif os(Windows)
    /// WINDOWS: THERE IS NO PERMISSION GATE. Any process able to execute
    /// code on this desktop session can already read the composited screen
    /// -- there is no TCC analogue, no consent dialog, and nothing for
    /// `requestPermission` to trigger. This ALWAYS reports `granted: true`.
    ///
    /// This is a deliberate honesty decision, not a placeholder: it would be
    /// easy (and wrong) to reuse macOS's three-way `ScreenCapturePermissionDecision`
    /// taxonomy here just to keep the two branches symmetric, but doing so
    /// would fabricate a permission system Windows does not have. Windows
    /// desktop apps historically COULD gain extra screen-capture-blocking
    /// power only by opting a WINDOW itself out via `SetWindowDisplayAffinity`
    /// (see `ScreenCaptureExclusionScope`'s Windows doc comment) -- that is a
    /// window protecting itself from other apps' capture, not a gate this
    /// process must pass to capture the screen itself. `requestPermission`
    /// is accepted (for API symmetry with the macOS signature every call
    /// site already uses) but is a documented no-op here.
    private func permissionStatus(requestPermission: Bool = false) -> ScreenCapturePermissionStatus {
        ScreenCapturePermissionStatus(
            granted: true,
            promptRequested: false,
            note: "Windows has no screen-capture permission model for a desktop application: any process that can run code on this session can already capture the screen. This always reports granted; \(requestPermission ? "request_permission was ignored (there is no prompt to show)." : "request_permission was not set.")"
        )
    }

    /// Every Windows capture reports the same trivial (all-`false`)
    /// exclusion scope -- see `ScreenCaptureExclusionScope`'s Windows doc
    /// comment for exactly why nothing can be excluded from this capture
    /// route. A single shared instance avoids re-explaining that at every
    /// call site.
    private static let windowsExclusionScope = ScreenCaptureExclusionScope(
        processID: false, bundleIdentifier: false, executablePath: false
    )
    #endif

    #if os(macOS)
    public func capture(screen: ScreenInfo, requestPermission: Bool = false) async throws -> ScreenCaptureResult {
        let permission = permissionStatus(requestPermission: requestPermission)
        guard permission.granted else {
            throw ScreenCaptureProviderError.permissionDenied(promptWasRequested: permission.promptRequested)
        }
        guard let rawDisplayID = screen.displayID else {
            throw ScreenCaptureProviderError.displayIdentifierUnavailable(screenID: screen.id)
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == CGDirectDisplayID(rawDisplayID) }) else {
                throw ScreenCaptureProviderError.displayUnavailable(screenID: screen.id)
            }

            let ownIdentity = ScreenCaptureApplicationIdentity(
                processID: ProcessInfo.processInfo.processIdentifier,
                bundleIdentifier: Bundle.main.bundleIdentifier,
                executablePath: Self.currentExecutablePath()
            )
            // The executable path is passed unresolved on purpose: resolving it
            // costs an `NSRunningApplication` lookup plus a 16 KB
            // `proc_pidpath` buffer PER shareable application, and the policy
            // below consults it only as a last resort. See the overload's doc
            // comment.
            let excluded = content.applications.filter {
                Self.shouldExclude(
                    processID: $0.processID,
                    bundleIdentifier: $0.bundleIdentifier,
                    executablePath: Self.executablePath(for: $0.processID),
                    for: ownIdentity
                )
            }
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            // Ask for the same backing-pixel size reported to free-draw
            // clients.  The compositor already validates/records dimensions.
            configuration.width = screen.widthPx
            configuration.height = screen.heightPx
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return ScreenCaptureResult(
                image: image,
                screenID: screen.id,
                excludedProcessIDs: excluded.map { $0.processID }.sorted(),
                exclusionScope: Self.exclusionScope(for: ownIdentity)
            )
        } catch let error as ScreenCaptureProviderError {
            throw error
        } catch {
            throw ScreenCaptureProviderError.captureFailed(error.localizedDescription)
        }
    }

    /// Pure identity policy used to build ScreenCaptureKit's application
    /// exclusion list.  Matching the bundle identifier catches sibling MCP
    /// processes; the PID condition always catches this process even when a
    /// development launch has no bundle identifier.
    static func shouldExclude(_ candidate: ScreenCaptureApplicationIdentity,
                              for ownIdentity: ScreenCaptureApplicationIdentity) -> Bool {
        shouldExclude(
            processID: candidate.processID,
            bundleIdentifier: candidate.bundleIdentifier,
            executablePath: candidate.executablePath,
            for: ownIdentity
        )
    }

    /// The same policy, expressed so the executable path can stay unresolved
    /// until the policy genuinely needs it.
    ///
    /// The path is the LAST of three checks and is consulted only when this
    /// process knows its own executable path, yet resolving a candidate's path
    /// is by far the most expensive part of building an identity (see
    /// `executablePath(for:)`). Taking it as an `@autoclosure` keeps the
    /// decision order identical while charging that cost only for the
    /// candidates that actually reach the final branch, instead of for every
    /// application ScreenCaptureKit exposes.
    static func shouldExclude(processID: pid_t,
                              bundleIdentifier: String?,
                              executablePath: @autoclosure () -> String?,
                              for ownIdentity: ScreenCaptureApplicationIdentity) -> Bool {
        if processID == ownIdentity.processID { return true }
        if let ownBundle = ownIdentity.bundleIdentifier,
           let candidateBundle = bundleIdentifier,
           candidateBundle == ownBundle {
            return true
        }
        guard let ownExecutable = ownIdentity.executablePath else { return false }
        return normalizedExecutablePath(executablePath()) == normalizedExecutablePath(ownExecutable)
    }

    static func exclusionScope(for ownIdentity: ScreenCaptureApplicationIdentity) -> ScreenCaptureExclusionScope {
        ScreenCaptureExclusionScope(
            processID: true,
            bundleIdentifier: ownIdentity.bundleIdentifier != nil,
            executablePath: ownIdentity.executablePath != nil
        )
    }

    private static func currentExecutablePath() -> String? {
        if let executableURL = Bundle.main.executableURL {
            return normalizedExecutablePath(executableURL.path)
        }
        guard let executable = CommandLine.arguments.first, !executable.isEmpty else { return nil }
        return normalizedExecutablePath(executable)
    }

    private static func executablePath(for processID: pid_t) -> String? {
        if let registeredPath = NSRunningApplication(processIdentifier: processID)?
            .executableURL?
            .standardizedFileURL
            .path {
            return normalizedExecutablePath(registeredPath)
        }

        // `SCApplication` has no executable URL.  `proc_pidpath` provides a
        // best-effort identity for a raw executable which LaunchServices has
        // not registered as an NSRunningApplication, such as a development
        // `swift run`/binary launch.  Failure is intentionally non-fatal: the
        // result's exclusion scope documents only dimensions available here.
        var buffer = [CChar](repeating: 0, count: 16_384) // 4 * MAXPATHLEN
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(processID, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return nil }
        let rawPath = String(cString: buffer)
        guard !rawPath.isEmpty else { return nil }
        return normalizedExecutablePath(rawPath)
    }

    /// `CommandLine.arguments` can retain the symlink a development process
    /// was launched through while `proc_pidpath` reports the resolved binary.
    /// Compare canonical paths so sibling unbundled overlays are excluded in
    /// either form; `standardizedFileURL` alone only removes `.`/`..`.
    private static func normalizedExecutablePath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            // Development launches commonly expose argv[0] as `./.build/...`.
            // `fileURLWithPath` does not attach that relative path to the
            // process working directory, while proc_pidpath always returns an
            // absolute path; make the two representations comparable.
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(path)
        }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }
    #elseif os(Windows)
    /// Captures `screen` via `chalk_capture_monitor` (BitBlt/CAPTUREBLT).
    ///
    /// `requestPermission` is accepted for API symmetry with the macOS
    /// signature (every existing call site already passes it) but has no
    /// effect -- see `permissionStatus(requestPermission:)`'s doc comment.
    /// `async throws` likewise matches the macOS signature exactly even
    /// though this implementation never actually suspends; changing the
    /// signature to a synchronous one would force every shared call site
    /// (outside this file) into a second, platform-conditional call
    /// convention for no benefit.
    public func capture(screen: ScreenInfo, requestPermission: Bool = false) async throws -> ScreenCaptureResult {
        let permission = permissionStatus(requestPermission: requestPermission)
        // permission.granted is unconditionally true on Windows (see
        // permissionStatus() above). This guard is kept anyway: it costs
        // nothing, keeps this method's shape identical to the macOS branch,
        // and fails closed rather than silently proceeding if that ever
        // changes.
        guard permission.granted else {
            throw ScreenCaptureProviderError.permissionDenied(promptWasRequested: permission.promptRequested)
        }

        // `windowServerFrame` carries the raw, physical-pixel, virtual-desktop
        // rectangle -- the same coordinate space `chalk_capture_monitor`
        // documents its x/y/w/h parameters in (Win32 screen coordinates,
        // which can be negative on a multi-monitor desktop). `appKitFrame`
        // is the point-space rectangle `AnnotationRenderer` draws in, which
        // is the wrong space for a pixel-addressed capture call.
        let rect = screen.windowServerFrame
        guard rect.width > 0, rect.height > 0 else {
            throw ScreenCaptureProviderError.displayIdentifierUnavailable(screenID: screen.id)
        }

        var outBGRA: UnsafeMutablePointer<UInt8>?
        var outWidth: Int32 = 0
        var outHeight: Int32 = 0
        var outStride: Int32 = 0
        let status = chalk_capture_monitor(rect.x, rect.y, rect.width, rect.height,
                                            &outBGRA, &outWidth, &outHeight, &outStride)
        guard status == 0, let buffer = outBGRA else {
            throw ScreenCaptureProviderError.captureFailed("chalk_capture_monitor failed for screen \(screen.id) with shim status \(status)")
        }

        let image = WindowsScreenCaptureImage(
            bgra: buffer, width: Int(outWidth), height: Int(outHeight), stride: Int(outStride)
        )
        return ScreenCaptureResult(
            image: image,
            screenID: screen.id,
            // No exclusion API exists to populate this with on Windows --
            // see ScreenCaptureExclusionScope's Windows doc comment.
            excludedProcessIDs: [],
            exclusionScope: Self.windowsExclusionScope
        )
    }
    #endif
}
