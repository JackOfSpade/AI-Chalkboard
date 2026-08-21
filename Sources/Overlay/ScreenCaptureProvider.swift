import AppKit
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit

/// The stable, machine-readable decision made before asking macOS to capture a
/// display.  It is separate from the CoreGraphics prompt call so callers can
/// test denial/request behavior without opening System Settings in XCTest.
public enum ScreenCapturePermissionDecision: Equatable {
    case granted
    case deniedWithoutPrompt
    case promptRequested

    static func resolve(preflightGranted: Bool, requestPermission: Bool) -> ScreenCapturePermissionDecision {
        if preflightGranted { return .granted }
        return requestPermission ? .promptRequested : .deniedWithoutPrompt
    }
}

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

/// Describes the identity dimensions used for Chalkboard exclusion.  It is a
/// capability statement, not an occlusion guarantee: ScreenCaptureKit can
/// exclude only the `SCApplication` objects it exposes for this capture.
public struct ScreenCaptureExclusionScope: Codable, Equatable {
    public let processID: Bool
    public let bundleIdentifier: Bool
    public let executablePath: Bool

    public init(processID: Bool, bundleIdentifier: Bool, executablePath: Bool) {
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
    }

    public var note: String {
        var identities = ["process ID"]
        if bundleIdentifier { identities.append("bundle identifier") }
        if executablePath { identities.append("executable path") }
        return "ScreenCaptureKit was configured to exclude exposed AI Chalkboard applications matching \(identities.joined(separator: ", ")). Other overlays and window occlusion are not raw-framebuffer proof."
    }
}

/// The image never touches disk.  Exposing the excluded process IDs lets an
/// integration layer state exactly why a capture is clean without pretending
/// that macOS capture can prove unoccluded raw-framebuffer pixels.
public struct ScreenCaptureResult {
    public let image: CGImage
    public let screenID: String
    public let excludedProcessIDs: [pid_t]
    public let exclusionScope: ScreenCaptureExclusionScope

    public init(image: CGImage, screenID: String, excludedProcessIDs: [pid_t],
                exclusionScope: ScreenCaptureExclusionScope = .init(processID: true, bundleIdentifier: false, executablePath: false)) {
        self.image = image
        self.screenID = screenID
        self.excludedProcessIDs = excludedProcessIDs
        self.exclusionScope = exclusionScope
    }
}

public enum ScreenCaptureProviderError: LocalizedError, Equatable {
    case permissionDenied(promptWasRequested: Bool)
    case displayIdentifierUnavailable(screenID: String)
    case displayUnavailable(screenID: String)
    case captureFailed(String)

    public var errorDescription: String? {
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
    }
}

/// A one-frame ScreenCaptureKit provider for verification.  It selects a
/// display, excludes every running instance of the current Chalkboard app
/// identity, and returns a CGImage for direct composition rather than writing
/// a privacy-sensitive screenshot to a temporary file.
public final class ScreenCaptureProvider {
    public static let shared = ScreenCaptureProvider()

    private init() {}

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
        return executablePath() == ownExecutable
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
            return executableURL.standardizedFileURL.path
        }
        guard let executable = CommandLine.arguments.first, !executable.isEmpty else { return nil }
        return URL(fileURLWithPath: executable).standardizedFileURL.path
    }

    private static func executablePath(for processID: pid_t) -> String? {
        if let registeredPath = NSRunningApplication(processIdentifier: processID)?
            .executableURL?
            .standardizedFileURL
            .path {
            return registeredPath
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
        return URL(fileURLWithPath: rawPath).standardizedFileURL.path
    }
}
