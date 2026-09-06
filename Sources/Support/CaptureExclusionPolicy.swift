import Foundation

/// Decides whether overlay windows should ask the OS to hide themselves from
/// screen captures taken by OTHER applications -- `NSWindow.SharingType.none`
/// on macOS, `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` on Windows.
///
/// WHY THIS EXISTS: that exclusion has always been a *preference* ("don't let
/// the AI's annotations leak into the user's OBS recording or Zoom share"),
/// never a security boundary -- README's "Platform differences" section says
/// so outright, and both platform primitives are documented as best-effort
/// hints that any capture path is free to ignore. But on a machine whose own
/// display IS a capture -- a cloud PC (Shadow, Parsec, Sunshine/Moonlight,
/// NICE DCV, Teradici, Citrix, VMware Blast) or a remote-desktop session --
/// that preference stops being harmless and becomes actively destructive, in
/// two independent ways:
///
///   1. THE ANNOTATIONS BECOME INVISIBLE TO THE ONLY PERSON WHO CAN SEE THEM.
///      If the streaming host honours the exclusion the way the API documents,
///      the overlay is composited out of the exact frame the human is watching.
///      Chalkboard's entire purpose -- drawing on the user's screen -- silently
///      stops working, with every diagnostic still reporting success because
///      the window really was created, really was shown, and really did have
///      the affinity applied.
///
///   2. THE WHOLE SESSION CAN GO DARK. Some capture stacks do not merely honour
///      a display-affinity request, they treat its mere presence as "protected
///      content is on screen" and refuse to stream at all. This is documented
///      behaviour in the wild, not a hypothetical: NVIDIA's ShadowPlay walks
///      visible top-level windows calling `GetWindowDisplayAffinity` and
///      disables Instant Replay for ANY non-`WDA_NONE` window -- password
///      managers and Zoom's own "you are sharing your screen" banner trip it,
///      with no DRM anywhere in sight. Shadow's cloud PC reports the same class
///      of false positive to the user as error S-102, "Shadow has detected a
///      protected video that we cannot display", which blanks the session.
///
///      Note that a host doing this window-affinity walk cannot distinguish
///      `WDA_EXCLUDEFROMCAPTURE` from the older `WDA_MONITOR` -- it only checks
///      "is the affinity non-zero". So there is no gentler affinity value to
///      retreat to; the only safe answer on such a host is to apply none.
///
/// Both failures are silent from inside this process: nothing the app can query
/// afterwards distinguishes "excluded, and the user is happily looking at the
/// annotations on a local monitor" from "excluded, and the user is staring at a
/// blank stream". So the decision has to be made up front, from what the
/// environment looks like, and it has to be reported honestly in diagnostics
/// rather than assumed.
///
/// THE ASYMMETRY THAT SETS THE DEFAULT: failing to detect a streamed session
/// costs the user their whole screen. Detecting one that was not really
/// streaming costs them only that Chalkboard's annotations show up in a
/// screen recording they take -- the same thing that happens on every capture
/// path that ignores the hint today, and explicitly not a privacy boundary
/// this app claims to enforce. This policy therefore leans toward suppressing
/// the exclusion, and offers `always` for anyone who wants the old behaviour
/// back unconditionally.
///
/// This type is deliberately PURE and platform-neutral: it takes the facts as
/// parameters and returns a decision, so the whole matrix is unit-testable on
/// both platforms. Gathering the facts is `RemoteSessionProbe`'s job, and
/// applying the decision belongs to each platform's presentation backend.
public enum CaptureExclusionPolicy {

    // MARK: - Environment override

    /// Opt-out/opt-in override, read from the process environment.
    ///
    /// Named to match the existing `AI_CHALKBOARD_*` family
    /// (`AI_CHALKBOARD_LOG_DIR`, `AI_CHALKBOARD_SUSPENSION_ROOT`, ...). Unlike
    /// those, this one is not path-shaped, so it deliberately does NOT go
    /// through `AbsolutePath.isAbsolute` -- that gate exists for paths and
    /// would be meaningless here.
    public static let environmentVariableName = "AI_CHALKBOARD_CAPTURE_EXCLUSION"

    public enum Override: Equatable {
        /// Suppress the exclusion when a remote/streamed session is detected,
        /// apply it otherwise. The default, and the only value that consults
        /// `remoteSessionSignals` at all.
        case auto
        /// Never apply the exclusion, detection or not.
        case never
        /// Always apply the exclusion, even on a session detected as streamed.
        /// This is the "I know what I'm doing, give me the old behaviour"
        /// escape hatch; it can blank a cloud-PC session, which is precisely
        /// why it has to be asked for explicitly.
        case always
    }

    /// Distinguishes "unset" from "set to something we do not recognise" so the
    /// caller can log a warning for the latter instead of silently treating a
    /// typo as the default. Both still resolve to `.auto` -- a malformed
    /// override must never be a startup failure.
    public enum OverrideParse: Equatable {
        case unset
        case recognized(Override)
        case unrecognized(String)

        public var resolved: Override {
            switch self {
            case .recognized(let value): return value
            case .unset, .unrecognized: return .auto
            }
        }
    }

    /// Accepted spellings. Generous on purpose: this is a knob a user reaches
    /// for while their screen is black, and rejecting `AI_CHALKBOARD_CAPTURE_EXCLUSION=0`
    /// because the table only listed `never` would be a hostile way to fail.
    /// There is no established Swift-side boolean-env-var idiom in this repo to
    /// copy (only the Python test harnesses parse `== "1"`), so this establishes
    /// one: case-insensitive, whitespace-trimmed, with an explicit table.
    public static func parseOverride(fromEnvironmentValue raw: String?) -> OverrideParse {
        guard let raw else { return .unset }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .unset }
        switch normalized {
        case "auto", "default":
            return .recognized(.auto)
        case "never", "no", "off", "false", "0", "include", "disabled":
            return .recognized(.never)
        case "always", "yes", "on", "true", "1", "exclude", "force", "forced":
            return .recognized(.always)
        default:
            return .unrecognized(raw)
        }
    }

    // MARK: - Known streaming / remote-desktop hosts

    /// One process whose presence means this desktop is (or can at any moment
    /// be) captured and streamed to a human somewhere else.
    public struct StreamingHost: Equatable {
        /// Lowercased executable name with no directory and no extension --
        /// the shape `normalizedProcessName(_:)` produces.
        public let executable: String
        /// Human-readable vendor/product, used verbatim in the signal strings
        /// that reach diagnostics and the log.
        public let vendor: String

        public init(executable: String, vendor: String) {
            self.executable = executable
            self.vendor = vendor
        }
    }

    /// The match table.
    ///
    /// Entries fall into two groups, deliberately treated IDENTICALLY (see the
    /// asymmetry argument in this type's doc comment):
    ///
    ///   * Streaming hosts whose entire reason for existing is that this
    ///     machine is being watched remotely -- Shadow, Parsec, Sunshine,
    ///     NICE DCV, Teradici, Citrix, VMware Blast, NVIDIA GameStream. On
    ///     these, a false positive is nearly impossible.
    ///
    ///   * Remote-access tools that commonly idle as a background service with
    ///     nobody connected -- AnyDesk, TeamViewer, RustDesk, VNC, Chrome
    ///     Remote Desktop. These CAN produce a false positive, and the cost of
    ///     one is only that annotations become capturable. Set the override to
    ///     `always` to opt back in.
    ///
    /// Names that would be dangerously generic are deliberately absent. Two
    /// worth calling out because they look tempting:
    ///   * `nvcontainer` -- NVIDIA ShadowPlay's host. It runs on EVERY machine
    ///     with an NVIDIA driver, streamed or not, so matching it would disable
    ///     the exclusion for a large share of ordinary desktops.
    ///   * `steam` -- Steam Remote Play streams from `steam.exe` itself, which
    ///     is running on plenty of machines that are not streaming anything.
    ///     (`streaming_client.exe` is the CLIENT side, so its presence means
    ///     this machine is watching another one -- the opposite of what we care
    ///     about -- and matching it would be a false positive with backwards
    ///     reasoning.)
    ///
    /// MACOS NAMING. Most entries here are Windows service/binary names, and
    /// several name software with no macOS build at all (Shadow's cloud PC,
    /// PCoIP and Blast host agents, Citrix VDA, the WinVNC/TightVNC/UltraVNC
    /// servers). On macOS an app is seen through `NSWorkspace` as its
    /// CFBundleExecutable or its bundle name, which is normally the PRODUCT
    /// name -- `TeamViewer.app` yields `teamviewer`, not `teamviewer_desktop`.
    /// Entries written only in the Windows shape therefore never matched
    /// there, silently, on exactly the vendors this table claimed to cover.
    /// `anydesk` and `rustdesk` were unaffected only by luck: those products
    /// use the same lowercase name on both platforms. Bare product-name
    /// aliases are listed alongside the Windows names for the vendors that
    /// actually ship a macOS host, and the real limits of macOS detection are
    /// stated in README's "Remote and streamed sessions" section rather than
    /// implied to be narrower than they are.
    public static let knownStreamingHosts: [StreamingHost] = [
        // Shadow (shadow.tech) cloud PC. All three names are unmistakably
        // theirs; the generic-sounding `ShadowLogger`/`ShadowManager` siblings
        // are left out because those words are common enough to collide.
        StreamingHost(executable: "shadowstreamer", vendor: "Shadow cloud PC"),
        StreamingHost(executable: "shadowsvsmanager", vendor: "Shadow cloud PC"),
        StreamingHost(executable: "shadowprocessator", vendor: "Shadow cloud PC"),
        // Parsec. Both the Windows service binary and the bare product name:
        // see the macOS-naming note at the end of this table.
        StreamingHost(executable: "parsecd", vendor: "Parsec"),
        StreamingHost(executable: "parsec", vendor: "Parsec"),
        // Sunshine, the self-hosted Moonlight server. (`moonlight` itself is
        // the client and is intentionally not matched.)
        StreamingHost(executable: "sunshine", vendor: "Sunshine/Moonlight"),
        // NVIDIA GameStream host (superseded by Sunshine, still in the wild).
        StreamingHost(executable: "nvstreamer", vendor: "NVIDIA GameStream"),
        StreamingHost(executable: "nvstreamsvc", vendor: "NVIDIA GameStream"),
        // NICE DCV.
        StreamingHost(executable: "dcvserver", vendor: "NICE DCV"),
        StreamingHost(executable: "dcvagent", vendor: "NICE DCV"),
        // Teradici PCoIP agent.
        StreamingHost(executable: "pcoip_server_win32", vendor: "Teradici PCoIP"),
        StreamingHost(executable: "pcoip_agent", vendor: "Teradici PCoIP"),
        // VMware Horizon / Blast agent.
        StreamingHost(executable: "blastworker", vendor: "VMware Blast"),
        StreamingHost(executable: "vmware-remotemks", vendor: "VMware Blast"),
        // Citrix HDX / Virtual Delivery Agent.
        StreamingHost(executable: "ctxgfx", vendor: "Citrix HDX"),
        StreamingHost(executable: "picaservice", vendor: "Citrix HDX"),
        // Chrome Remote Desktop.
        StreamingHost(executable: "remoting_host", vendor: "Chrome Remote Desktop"),
        StreamingHost(executable: "remoting_me2me_host", vendor: "Chrome Remote Desktop"),
        // Always-on remote-access tools (see the false-positive note above).
        StreamingHost(executable: "anydesk", vendor: "AnyDesk"),
        StreamingHost(executable: "teamviewer_desktop", vendor: "TeamViewer"),
        StreamingHost(executable: "tv_w32", vendor: "TeamViewer"),
        StreamingHost(executable: "tv_x64", vendor: "TeamViewer"),
        StreamingHost(executable: "teamviewer", vendor: "TeamViewer"),
        StreamingHost(executable: "rustdesk", vendor: "RustDesk"),
        StreamingHost(executable: "winvnc", vendor: "VNC server"),
        StreamingHost(executable: "tvnserver", vendor: "VNC server"),
        StreamingHost(executable: "vncserver", vendor: "VNC server"),
        StreamingHost(executable: "uvnc_service", vendor: "VNC server")
    ]

    /// Reduces a raw process name to the table's key shape: no directory, no
    /// extension, lowercased.
    ///
    /// Splits on BOTH separators rather than using `URL(fileURLWithPath:)`,
    /// for the same reason `AbsolutePath` exists in this repo: a Windows path
    /// handed to a POSIX-flavoured path API is silently mis-parsed, and this
    /// function has to give identical answers on both platforms because its
    /// tests run on both.
    public static func normalizedProcessName(_ raw: String) -> String {
        let lastComponent = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? raw
        // Trimmed BEFORE the extension check, not after. Trimming afterwards
        // looks equivalent and is not: `"AnyDesk.exe "` ends in `"exe "`, so
        // `hasSuffix(".exe")` is false, nothing is stripped, and the trailing
        // trim then yields `"anydesk.exe"` -- which matches no table entry, so
        // a running remote-access host goes undetected and the exclusion is
        // applied on a streamed session. That is precisely the false negative
        // this whole type exists to prevent, so the order is load-bearing.
        var name = lastComponent.trimmingCharacters(in: .whitespaces).lowercased()
        // Only strip a trailing extension, and only a known one. Truncating at
        // the last "." unconditionally would mangle names that legitimately
        // contain dots.
        for suffix in [".exe", ".app"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        // Trailing trim again: a name like `"anydesk .exe"` leaves whitespace
        // behind once the extension is gone.
        return name.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Signal detection

    /// Turns raw environment facts into human-readable reasons this session
    /// looks streamed. An empty result means "looks like an ordinary local
    /// desktop".
    ///
    /// The strings are the ones that reach the log and `get_overlay_state`, so
    /// they name the concrete evidence rather than just asserting a conclusion:
    /// a user told "remote session detected" cannot check the claim, whereas one
    /// told "Shadow cloud PC (ShadowStreamer.exe)" can.
    ///
    /// Deduplicated by vendor and sorted, so a machine running three Shadow
    /// services reports one signal, and the output is stable enough to assert
    /// on in tests and to compare across calls without spurious churn.
    public static func remoteSessionSignals(runningProcessNames: [String],
                                            isTerminalServicesSession: Bool) -> [String] {
        var signals: [String] = []

        if isTerminalServicesSession {
            // Covers RDP and anything else layered on Terminal Services. Note
            // it does NOT cover cloud PCs like Shadow, which run in the console
            // session with a virtual display adapter and report 0 here -- which
            // is exactly why the process table below is not optional.
            signals.append("Windows Terminal Services / Remote Desktop session (SM_REMOTESESSION)")
        }

        let normalized = Set(runningProcessNames.map(normalizedProcessName))
        var seenVendors = Set<String>()
        var vendorSignals: [String] = []
        for host in knownStreamingHosts where normalized.contains(host.executable) {
            guard seenVendors.insert(host.vendor).inserted else { continue }
            vendorSignals.append("\(host.vendor) (\(host.executable))")
        }
        signals.append(contentsOf: vendorSignals.sorted())

        return signals
    }

    // MARK: - The decision

    public enum Decision: Equatable {
        /// Ordinary local desktop: apply the platform's capture-exclusion
        /// primitive, exactly as this app always has.
        case exclude
        /// A streamed session was detected, but the environment override says
        /// to exclude anyway.
        case excludeForcedByEnvironment
        /// `set_capture_visible(true)` is in effect -- an explicit, live,
        /// self-expiring request from the operator that outranks everything
        /// else here.
        case includeForCaptureDebug
        /// The environment override switched the exclusion off outright.
        case includeSuppressedByEnvironment
        /// This looks like a streamed/remote session, so the exclusion is
        /// suppressed to keep the annotations visible -- and to keep hosts that
        /// equate display affinity with protected content from blanking the
        /// session.
        case includeSuppressedForRemoteSession(signals: [String])

        /// The single bit every caller ultimately wants.
        public var excludesFromCapture: Bool {
            switch self {
            case .exclude, .excludeForcedByEnvironment:
                return true
            case .includeForCaptureDebug, .includeSuppressedByEnvironment, .includeSuppressedForRemoteSession:
                return false
            }
        }

        /// Stable, machine-readable reason, emitted in `get_overlay_state` so an
        /// agent can branch on it without parsing prose.
        public var reasonCode: String {
            switch self {
            case .exclude: return "excluded"
            case .excludeForcedByEnvironment: return "excluded-forced-by-environment"
            case .includeForCaptureDebug: return "included-capture-debug"
            case .includeSuppressedByEnvironment: return "included-suppressed-by-environment"
            case .includeSuppressedForRemoteSession: return "included-suppressed-remote-session"
            }
        }

        /// Whether capture-debug mode (`set_capture_visible(true)`) was in
        /// effect when this decision was made.
        ///
        /// WHY CALLERS SHOULD PREFER THIS over reading `isCaptureVisible`
        /// again: `decide` returns `.includeForCaptureDebug` if and only if
        /// `captureDebugVisible` was true, so this is exactly that input --
        /// but recovered from the SAME snapshot the rest of the decision was
        /// built from. A diagnostic that reads the live flag separately can
        /// straddle a concurrent change (the five-minute auto-revert timer, a
        /// sibling instance's broadcast, or the menu toggle) and emit one
        /// payload saying capture-debug is both on and off.
        public var isCaptureDebugVisible: Bool {
            self == .includeForCaptureDebug
        }

        /// The evidence behind `.includeSuppressedForRemoteSession`; empty for
        /// every other case.
        public var signals: [String] {
            if case .includeSuppressedForRemoteSession(let signals) = self { return signals }
            return []
        }

        /// Platform-NEUTRAL prose. Callers that report to an agent compose this
        /// with the platform's own mechanism name (`NSWindow.sharingType`
        /// vs `SetWindowDisplayAffinity`), because this repo treats a
        /// platform-inaccurate diagnostic string as a correctness bug rather
        /// than a wording nit -- see `MCPToolHandlers.swift`'s note on that.
        public var explanation: String {
            switch self {
            case .exclude:
                return "This session looks like an ordinary local desktop, so overlay windows ask to be excluded from other applications' screen captures. That request is a preference, not a security boundary: any capture path is free to ignore it."
            case .excludeForcedByEnvironment:
                return "\(CaptureExclusionPolicy.environmentVariableName)=always forces capture exclusion on even though this session was detected as remote/streamed. On a cloud PC or remote desktop this can hide annotations from the person watching, or make the streaming host blank the session as suspected protected content."
            case .includeForCaptureDebug:
                return "Capture-debug mode is on (set_capture_visible(true)), so overlay windows do not ask to be excluded from capture and every annotation is rendered. This state auto-reverts after five minutes without renewal."
            case .includeSuppressedByEnvironment:
                return "\(CaptureExclusionPolicy.environmentVariableName)=never suppresses capture exclusion, so overlay windows never ask to be hidden from other applications' captures."
            case .includeSuppressedForRemoteSession(let signals):
                return "Capture exclusion is suppressed because this session looks remote or streamed (\(signals.joined(separator: "; "))). On such a session the display the user is watching IS a capture: excluding the overlay from captures would hide the annotations from the only person who can see them, and some streaming hosts treat any capture-excluded window as protected content and blank the whole session. Set \(CaptureExclusionPolicy.environmentVariableName)=always to override."
            }
        }
    }

    /// The whole matrix, in precedence order.
    ///
    /// `captureDebugVisible` wins outright. It is a live, explicit, five-minute
    /// request from whoever is driving the session, and it only ever moves in
    /// the safe direction (toward being capturable), so nothing below it needs
    /// a say. Checking it first also preserves the pre-existing behaviour of
    /// `set_capture_visible` exactly, on every machine.
    public static func decide(captureDebugVisible: Bool,
                              override: Override,
                              remoteSessionSignals: [String]) -> Decision {
        if captureDebugVisible {
            return .includeForCaptureDebug
        }
        switch override {
        case .never:
            return .includeSuppressedByEnvironment
        case .always:
            // `always` only counts as an OVERRIDE when there was something to
            // override. On an ordinary desktop it asks for the behaviour that
            // was already going to happen, and reporting it as a forced
            // override there would put a claim about a detected remote session
            // into the explanation of a machine where none was detected.
            return remoteSessionSignals.isEmpty ? .exclude : .excludeForcedByEnvironment
        case .auto:
            return remoteSessionSignals.isEmpty
                ? .exclude
                : .includeSuppressedForRemoteSession(signals: remoteSessionSignals)
        }
    }
}
