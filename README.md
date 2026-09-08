# AI Chalkboard 🎨

A lightweight, click-through, AI-only drawing overlay for macOS and Windows 10/11 controlled via an in-process **Model Context Protocol (MCP)** server over `stdio`.

Designed specifically for AI agents (**Claude Cowork**, **Claude Desktop**, **Claude Code**) to draw unrestricted vector or raster artwork directly over UI elements during visual computer-use tasks, while **all human mouse and keyboard input passes straight through** to underlying apps.

---

## Key Features

- **Click-Through Input Transparency**: Built with `window.ignoresMouseEvents = true`. The overlay window never consumes mouse clicks, drags, or keystrokes. It is also ordered fully off screen (not just left transparent) on any screen with nothing currently visible to paint, so a tool that determines click ownership by walking the on-screen window list — rather than by routing a real click and letting the window server honor `ignoresMouseEvents` — never finds AI Chalkboard occupying a screen it isn't actively annotating. For dispatchers that still reject any visible overlay, `suspend_annotations` temporarily orders the overlay out without clearing its annotations; call `resume_annotations` after the click.
- **Multi-Monitor Aware**: Automatically spawns transparent overlay windows across all connected displays and adjusts when display configurations change.
- **First-Class Text and Free Drawing**: `draw_text` renders normal UI labels directly. `draw_path` accepts arbitrary SVG geometry, `draw_image` places caller-rendered raster art, and `draw_batch` combines primitives atomically. This keeps shapes unrestricted without making ordinary text a PNG-generation chore.
- **Centre-and-Radius Shapes**: `draw_shape` (and `draw_batch`'s `type: "shape"` items) draw a circle, ellipse, or rectangle from a centre and radius (or a rect's corner), instead of the caller hand-writing `draw_path`'s raw SVG arc commands. The app computes the closed path itself — including the two-arc construction a full ellipse needs, since a single SVG arc command cannot close on itself — because every hand-written arc was a chance to mis-center it, which is how measured placement error was actually entering. `draw_path` remains the tool for anything the centre/radius model doesn't cover: arrows, callouts, handwriting, and other freeform geometry.
- **Opt-In Collision Avoidance**: `draw_text`, `draw_shape`, and top-level `draw_batch` accept `avoid: ["annotation-id", ...]`. Chalkboard measures the prospective drawing and every referenced annotation through the same exact off-screen renderer as `get_annotation_bounds`; if their painted rectangles overlap, it runs a bounded nearby search and moves the whole new annotation to a clear on-screen position when one is found (preferring below, then above, right, and left on equal-distance ties) with an 8-backing-pixel gap. If none of the bounded candidates clears every requested annotation, nothing is drawn. The structured success response reports the requested and final painted bounds plus the annotation-wide offset actually stored. Omit `avoid` to retain unrestricted deliberate stacking and the legacy plain-text response. Avoidance is evaluated once, at draw time: later `update_annotation` calls or independently moving/resizing anchors can introduce overlap again.
- **Coordinate-Space Inputs**: `draw_path`, `draw_shape`, `draw_image`, `draw_text`, and `draw_batch` accept top-left-origin `backing_pixels` (the default), `normalized` 0…1, or `screenshot_pixels` coordinates. When geometry is measured from an image, use `screenshot_pixels` with the exact dimensions of that same uncropped full-display image version after any client/model resize. Detectable cropped/window aspect mismatches are rejected instead of being silently stretched across a display. Supplying `screenshot_width`/`screenshot_height` under any other `coordinate_space` is likewise rejected rather than silently ignored: passing the dimensions is unambiguous evidence of the space the caller meant, so contradicting it must fail loudly instead of reinterpreting the coordinates. A crop with the display's exact aspect ratio is mathematically indistinguishable from a downsampled full-display image, so callers must preserve full-display provenance. SVG paths retain source coordinates plus their backing-pixel scale; text/image positions are stored in backing pixels. Stroke, font, padding, and other style dimensions always remain backing pixels. `draw_shape` is the one exception to "coordinates and lengths transform the same way": its centres (`center_x`/`center_y`, or a rect's `x`/`y` corner) go through the same position transform as every other tool, but its lengths (`radius`, `radius_x`, `radius_y`, `width`, `height`) are scaled per axis instead — so a `circle` requested under `normalized` on a non-square display resolves to an ellipse in backing pixels, by design, because one radius fraction is not the same physical distance on both axes. `backingScaleFactor` reflects the active macOS display mode, not the panel's marketing label, on macOS; on Windows it is derived from `GetDpiForMonitor`'s effective DPI divided by 96.
- **Element-Anchored Highlighting**: `highlight_element` can locate a named accessible UI element (for example, a button titled “Fusion”) and highlight its resolved bounds as a rectangle (default), ellipse, or circle via `shape` — round and pill-shaped controls (radio buttons, circular icon buttons) get a ring around their actual silhouette instead of just their bounding box, and the `circle` variant fully encloses the element (radius = half the element's diagonal plus `padding_px`), so no corner of what it rings ever sticks out. When a label is ambiguous, the rejection lists every candidate with its occurrence number, role, and resolved on-screen bounds, so the right one can be chosen by geometry rather than guessed. Element lookup goes through macOS's Accessibility (AX) API on macOS and Windows UI Automation (UIA) on Windows — see "Platform differences" below for how the two diverge. `get_accessibility_status` reports whether macOS Accessibility access is available before a call depends on it; on Windows there is no persistent, checkable grant to report ahead of time, so the same tool always reports optimistic availability and says so, and the true per-lookup signal is `highlight_element`'s own error (see "Platform differences"). By default (`anchor="element"`) the highlight is not resolved once and abandoned: it follows the element's window as that window moves or resizes, and re-runs this same lookup once the window settles so the ring stays on the control through a reflow instead of merely translating with the window frame — see "Window-Anchored Drawings" below for the tracking mechanism and its limits, `anchor="window"` for cheaper frame-only tracking with no re-resolve, or `anchor="none"` for the original resolve-once-and-never-move behavior.
- **Window-Anchored Drawings**: Every drawing tool (`draw_path`, `draw_shape`, `draw_image`, `draw_text`, `draw_batch`) accepts `anchor="window"`, which attaches the annotation to one window of a named `app` — whichever of that app's windows overlaps the drawing's own painted bounds the most, front-most breaking ties — so the drawing follows that window as the user moves or resizes it, instead of staying at fixed display coordinates forever. `anchor_resize` picks the resize policy: `pin` (default) follows only the window's top-left corner and keeps the drawing's own size, right for anything anchored to window chrome — a toolbar button, a tab, a sidebar item; `scale` scales the drawing's positions and geometry lengths per axis by the window's current-size/reference-size ratio, right only when the drawing's own geometry was measured against content that itself scales with the window, such as a canvas or a video frame. Under both policies, stroke width, font size, and padding stay fixed backing pixels — the same rule `normalized` coordinates already follow. `highlight_element` defaults to `anchor="element"` instead of `"window"`; see "Element-Anchored Highlighting" above for what the extra element re-resolve buys it. None of this is free of limits:
  - Tracking is **sampled, not event-driven**: a background timer samples each distinct anchor target's window geometry at 30 Hz while something is actively changing, backing off to once per 0.25 s after 1 second with no change and to once per second after 10 seconds, and it runs no timer at all while nothing is anchored. A drawing therefore trails its window by up to one sample interval during an active drag or resize, landing once the window stops. There is no way to composite this overlay atomically with another application's own redraw.
  - `pin`/`scale` are geometric policies, not layout understanding: they move or scale a rectangle, and have no idea what a real UI's reflow did to the control inside it. `anchor="element"` is the only mode that tracks a specific control through a reflow, and it is only as accurate as repeating the same Accessibility lookup that found the control the first time.
  - A minimized window, a hidden app, or a window on another Space reports the anchor as `hidden`; a window absent for three consecutive samples reports `lost`. Neither state is painted, and **neither deletes the annotation** — `clear` remains the only way a drawing goes away, exactly as the persistence guarantee below promises.
  - An anchored drawing that follows its window onto another display repaints there, but it is still clipped to one display like every other annotation, and backing scale is not compensated across displays with different scale factors.
  - On macOS this needs **no new permission**: `CGWindowListCopyWindowInfo` reports window bounds, number, owning process, and layer without the Screen Recording grant — only the window's NAME is gated behind it, and the window prober never reads it. `anchor="element"` needs the same Accessibility grant `highlight_element` already needs to find the element in the first place; it is not an additional grant.
- **Stable In-Place Adjustment**: `update_annotation` moves or restyles an existing annotation without minting a new ID, preserving the ID used by verification and clear operations. It can also change an annotation's anchor after the fact — detach it in place, (re-)anchor it to whichever window it currently sits over, or just change an anchored annotation's resize policy — without needing to redraw. Explicit `z_index` controls ordering between annotations; later batch items remain on top of earlier items within that batch.
- **Leased Suspension for Click Workflows**: `suspend_annotations` acquires a 1–60-second (15-second default) lease and orders overlay windows out while retaining annotations and IDs. Keep its `leaseToken` secret and release exactly that token with `resume_annotations`; overlapping callers cannot accidentally resume one another’s overlays. An optional canonical UUID idempotency key makes safe retries return the same active lease only from its creator MCP server process instance. Generate a fresh random UUID and treat it as secret too; reuse from another instance is rejected and never reveals the other lease token. The result only says `clickSafeAtObservation: true` after bounded observation and a final durable read confirm that exact live generation and its peer presentation are settled — on macOS that observation reads WindowServer, the compositor's own registration; on Windows there is no equivalent single ground-truth read, so it is instead two Win32/DWM window-state samples (`IsWindowVisible` plus the DWM cloak flag) corroborated by a `DwmFlush()`-observed compositor frame boundary, a meaningfully weaker guarantee than a compositor registration read (see "Platform differences" below). This is point-in-time evidence on both platforms, not raw-framebuffer/occlusion proof and not true simultaneous highlight-and-click support.
- **Persists Until Explicitly Cleared**: A drawing has no lifetime and no timeout. It stays on screen until something explicitly clears it — the AI calling `clear` (by `annotation_id`, by `app`, or `scope="all"`), or the user clicking the menu-bar "Clear Annotations for Current App + Global" (⌘K) or "Clear Everything (All Apps)". `duration_seconds` is not a tool parameter any more: supplying it on any drawing tool is REJECTED outright rather than silently ignored, so a caller cannot come away believing a drawing will clean itself up. This guarantee holds only for the life of the MCP server process — annotations are held in server memory, not written to disk, so they do not survive that process restarting or quitting.
- **Closed-Loop Verification**: `verify_annotation` proves free-draw placement against a clean UI screenshot using the exact live renderer and reports the painted bounds in the screenshot's own pixels. On a desktop where the screenshot could plausibly be a full-display capture (native or downsampled — never upscaled) of more than one connected display, a caller-supplied screenshot is refused unless `screenshot_screen_id` names the display it was captured from (which must be the annotation's own display) — dimensions alone cannot identify which monitor an image shows, and compositing over the wrong monitor's UI would report a placement error that does not exist — the same `AnnotationRenderer` Swift source on both platforms, though the rasterizer underneath differs (Core Graphics on macOS, GDI+ on Windows), so output is not bit-identical across platforms. `verify_presentation` separately checks the retained window state and bounded alignment with the annotation's target display so agents can detect most presentation failures without asking a human to eyeball the display. On macOS this is a dual-witness check — AppKit's own window state cross-checked against `CGWindowListCopyWindowInfo`, WindowServer's independently maintained ledger. Windows has no equivalent second source for an ordinary window: `verify_presentation` there reads only this process's own Win32 state (`IsWindowVisible`/`GetWindowRect`/extended style) plus DWM's independently maintained cloak flag, which is real but much narrower evidence — see "Platform differences" below.
- **Bounded Diagnostics**: Coordinate/verification rejections and lifecycle/presentation events are timestamped in UTC and attempted as complete records on stderr plus a rotating log file — `~/Library/Logs/AIChalkboard/ai_chalkboard.log` on macOS, `%LOCALAPPDATA%\AIChalkboard\Logs\ai_chalkboard.log` on Windows. macOS makes stderr nonblocking and drops a whole record under backpressure; Windows hands bounded records to a bounded serial writer because an arbitrary inherited standard-error handle cannot safely be converted to overlapped I/O. A full pipe can therefore occupy only that Windows worker, never the MCP loop or unbounded memory. On both platforms the asynchronous file handoff is likewise bounded and may drop records when saturated. Message payloads are capped at 16 KiB; the retained file log rotates at 5 MiB and keeps one backup (each file can exceed the threshold only by a bounded final record). Cross-process rotation is coordinated with `flock` on macOS and `LockFileEx` on Windows, and each platform detects another process having rotated the file out from under it by comparing file identity — POSIX inode on macOS, `GetFileInformationByHandle`'s volume-serial/file-index pair on Windows, which Microsoft documents as not guaranteed stable across a close/reopen on every filesystem the way a POSIX inode is (the only consequence of that instability here is a harmless extra close-and-reopen, never a misdirected write). If size measurement or rotation cannot complete, file writes pause, so a persistent filesystem error cannot create an infinitely growing log. Rejection records use fixed reason codes and numeric geometry rather than persisting caller text, UI labels, or local asset paths.
- **Capture Debug Request**: `set_capture_visible(true)` asks compatible capture paths to include the overlay and renders all annotations for placement checks. Capture programs retain their own app/window filters, so inclusion is not guaranteed; on macOS `NSWindow.SharingType.none` is also not a privacy boundary on modern releases. On Windows the same toggle instead governs `SetWindowDisplayAffinity`'s `WDA_EXCLUDEFROMCAPTURE`, which only ever affects captures taken by *other* applications of *this* window — it has no bearing on Chalkboard's own `chalk_capture_monitor` (BitBlt) capture route, which always includes every composited window (see "Platform differences" below). Two safety nets guard against forgetting to turn it back off: it auto-reverts to `false` after 5 minutes with no renewal, and the menu-bar icon tints orange for as long as it's on. Capture exclusion is *also* suppressed automatically whenever this session looks remote or streamed — see "Remote and streamed sessions" below — so `set_capture_visible(false)` no longer implies the exclusion is in force. `get_screens` and `get_overlay_state` both report the actual decision, and the evidence behind it, in a `captureExclusion` object.
- **Launch-Mode-Dependent Lifecycle UI** (macOS specifics; Windows has a parallel status-icon control surface described below but no bundle/`Info.plist`/Dock concept to branch on): The activation policy is chosen at runtime from `argv`, not from the bundle. A direct GUI launch (Finder/Dock) uses `.regular`, so the app appears in the Dock and Cmd-Tab and can be quit by right-clicking its Dock icon. An MCP launch (`--mcp`, how Claude Desktop/Cowork start it) uses `.accessory` instead — no Dock icon, no Cmd-Tab entry, since one config entry spawns several processes and each would otherwise add its own Dock icon. `LSUIElement` is deliberately left `false` in `Info.plist`: a static plist cannot branch on `argv`, so the runtime `setActivationPolicy` call is the only thing that can tell the two modes apart. In MCP mode the menu-bar status item — "Clear Annotations for Current App + Global" (⌘K), "Clear Everything (All Apps)", "Capture Debug Mode", "Quit AI Chalkboard" (⌘Q) — is the **only** user-facing control surface, and only the primary instance owns one. On Windows the equivalent is a system-tray icon owned by whichever process wins the same primary-election lock (see "Single-instance lock" below); Windows has no bundle/Dock/Cmd-Tab concept for a launch-mode-dependent policy to select between.

---

## Platform differences

AI Chalkboard is one Swift package built for both macOS and Windows, with
platform code split by `#if os(macOS)` / `#if os(Windows)`. The Windows port
is functional — verified end to end as an MCP stdio server, with the tray
icon, single-instance election, monitor enumeration, and frontmost-app
tracking all working — but several guarantees the macOS build makes are
provably weaker on Windows, because the two OSes simply do not expose
equivalent primitives. This section states each difference plainly rather
than letting parity be assumed.

**Screen-capture permission.** macOS gates screen capture behind TCC's Screen
Recording permission: an ungranted app's capture calls fail, and
`get_accessibility_status`/verification capture report that honestly.
Windows has no capture-permission model for a desktop application at all —
any process able to run code in the session can already read the composited
screen. `get_accessibility_status`-style permission reporting on Windows
therefore always reports capture as granted, with an explicit note that there
is no permission system to check. This is a real reduction in what the OS
enforces on Windows, not a convenience: there is no equivalent of revoking
Screen Recording access for this app.

**Remote and streamed sessions.** Capture exclusion — `NSWindow.SharingType
.none` on macOS, `SetWindowDisplayAffinity`'s `WDA_EXCLUDEFROMCAPTURE` on
Windows — has always been a preference ("don't let annotations leak into the
user's OBS recording"), never a boundary. On a machine whose own display *is* a
capture, that preference turns destructive, so Chalkboard now detects such
sessions and does not apply the exclusion there at all. Two independent
failures motivate this. First, if the streaming host honours the exclusion the
way the API documents, the overlay is composited out of the exact frame the
human is watching: the annotations become invisible to the only person who
could see them, while every diagnostic still reports success. Second, some
capture stacks treat the mere presence of a display-affinity request as
"protected content is on screen" and refuse to stream at all — NVIDIA's
ShadowPlay walks visible windows with `GetWindowDisplayAffinity` and disables
Instant Replay for *any* non-`WDA_NONE` window (password managers and Zoom's
own screen-share banner trip it, with no DRM involved), and Shadow's cloud PC
reports the same class of false positive to the user as error S-102, "Shadow
has detected a protected video that we cannot display". A host doing that walk
cannot distinguish `WDA_EXCLUDEFROMCAPTURE` from the older `WDA_MONITOR`, so
there is no gentler affinity value to retreat to — the only safe answer is to
apply none.

Detection is by known streaming/remote-desktop host process (Shadow, Parsec,
Sunshine/Moonlight, NICE DCV, Teradici, Citrix, VMware Blast, Chrome Remote
Desktop, AnyDesk, TeamViewer, RustDesk, VNC), plus
`GetSystemMetrics(SM_REMOTESESSION)` on Windows. That metric is necessary but
nowhere near sufficient and is deliberately not relied on alone: a cloud PC
such as Shadow runs in the *console* session against a virtual display adapter
and reports 0. The bias is deliberate and asymmetric — failing to detect a
streamed session costs the user their whole screen, while a false positive
costs only that annotations become capturable, which is exactly what already
happens on every capture path that ignores the hint. Set
`AI_CHALKBOARD_CAPTURE_EXCLUSION=always` to force the exclusion on anyway, or
`=never` to suppress it unconditionally; the default is `auto`. The decision,
its stable `reasonCode`, and the concrete signals behind it are reported by
`get_screens` and `get_overlay_state` so the behaviour is checkable rather than
merely asserted.

The two platforms detect unequally, and **Windows detection is much the
stronger of the two**. Windows walks the full process table
(`CreateToolhelp32Snapshot`), so it sees background services. macOS is thinner
for two separate reasons, both worth stating plainly:

1. `NSWorkspace.runningApplications` lists launched applications but *not*
   daemons, so macOS's own Screen Sharing (`screensharingd`) and other
   launchd-only remote-access services are invisible. Closing this needs a
   `sysctl(KERN_PROC_ALL)` walk that does not exist yet.
2. Even among applications it does see, a match depends on the name lining up
   with the host table — and most of that table is Windows service binaries,
   several of them naming software with no macOS build at all (Shadow's cloud
   PC, PCoIP and Blast host agents, Citrix VDA, the Windows VNC servers). On
   macOS an app appears under its *product* name, so `TeamViewer.app` reads as
   `teamviewer`, not `teamviewer_desktop`. Product-name aliases are listed for
   the vendors that ship a macOS host, but the practical macOS coverage is
   essentially Parsec, AnyDesk, TeamViewer, RustDesk and Sunshine — not the
   full list above.

An earlier version of this section named only the first reason and asserted
that the four cross-platform apps "are covered", which was not true of
TeamViewer. On macOS, treat `AI_CHALKBOARD_CAPTURE_EXCLUSION=never` as the
reliable control rather than relying on detection.

**Sibling-instance capture exclusion.** On macOS, Chalkboard's verification
capture goes through ScreenCaptureKit, which can be configured to exclude a
list of *other* applications — Chalkboard uses this to exclude every running
instance of itself (by process ID, bundle identifier, and executable path),
so a sibling MCP process's overlay never contaminates a capture. Windows'
only related primitive, `SetWindowDisplayAffinity`'s
`WDA_EXCLUDEFROMCAPTURE`, lets a window exclude only *itself*, and even that
is documented to affect only captures taken by *other* applications (Zoom,
OBS, the Windows built-in recorder) — not Chalkboard's own capture route.
Chalkboard's Windows verification capture (`chalk_capture_monitor`, BitBlt
with `CAPTUREBLT`) has no exclusion mechanism whatsoever: it includes every
window composited on screen, including this process's own overlay and any
sibling AI Chalkboard instance's overlay. `ScreenCaptureExclusionScope`
reports every dimension `false` on Windows for exactly this reason — it is
never non-trivial there the way it can be on macOS.

**`verify_presentation`.** On macOS this is a dual-witness proof: AppKit's
own window state cross-checked against `CGWindowListCopyWindowInfo`,
WindowServer's independently maintained record of what it is actually
compositing — two genuinely separate witnesses, one of which this process
does not control. Windows has no equivalent second source for an ordinary
application window: `EnumWindows`/`IsWindowVisible`/`GetWindowRect` all read
the same user32 window-manager state this process itself just set, which can
confirm a request was applied but proves nothing an adversarial or merely
buggy caller couldn't fake by reading its own state back. The one exception
is `DwmGetWindowAttribute(DWMWA_CLOAKED)`: DWM is a genuinely separate
subsystem from user32, so its cloak bit is real independent evidence — just
much narrower than `CGWindowList` (cloaked-or-not only, no
bounds/alpha/z-order cross-check). The Windows result never claims the
confidence the macOS one does; its independent-registration fields are
always `nil` there, and every response's `note` says so explicitly rather
than reusing macOS's wording.

**`verify_annotation`.** The renderer itself is literally the same shared
Swift source on both platforms (`AnnotationRenderer`, drawing through a
platform-neutral `DrawingContext`) — the "same renderer, cross-checked
against the platform's own screenshot" guarantee holds on both. What differs
is the rasterizer underneath: Core Graphics/Quartz on macOS, GDI+ on
Windows. Different rasterizers legitimately produce different antialiasing,
hinting, and rounding, so a Windows verification PNG is not bit-identical to
a macOS verification PNG of the same annotation at the same geometry — the
honest claim is "the same renderer, verified by cross-check", never "the
same pixels".

**`suspend_annotations` / `clickSafeAtObservation`.** The observational basis
is weaker on Windows for the same underlying reason as `verify_presentation`.
On macOS, post-suspension quiescence is checked by reading WindowServer's own
registration twice, ~50ms apart. Windows has no equivalent single
ground-truth read, so it instead takes two Win32/DWM window-state samples
(`IsWindowVisible` plus the DWM cloak flag) and corroborates them with a
`DwmFlush()` call that proves a real compositor frame boundary was crossed
during the observation — but does not prove which windows were included in
that frame, only that the compositor is alive and did real work. It is the
closest honest equivalent available, not the same claim: `clickSafeAtObservation:
true` derived from the Windows path means "no evidence of an on-screen
Chalkboard window survived two Win32/DWM state samples plus a real compositor
frame boundary", not "the compositor has confirmed nothing is on screen",
which is what the same field means on macOS.

**Window anchoring.** macOS samples a target window's live geometry with
`CGWindowListCopyWindowInfo` (see "Window-Anchored Drawings" above for why
that needs no Screen Recording grant). Windows samples the equivalent with
`EnumWindows`/`GetWindowRect`, re-verified on every sample with `IsWindow`
plus an owning-process re-check: Win32 recycles `HWND` values, so once a
window is destroyed, a later, completely unrelated window — possibly owned by
a different process — can be assigned that exact same handle value within
this process's lifetime, and a recycled handle must report the original
window as `lost` rather than silently start anchoring to whatever new window
now holds that number. Both platforms re-verify the sampled window's owning
process id against the target before trusting it at all; the extra `IsWindow`
liveness check is specifically a Windows concern, because a macOS window
number is not reused for the same window the way a Win32 `HWND` can be.
Separately, macOS filters candidate windows to "normal" ones with
`kCGWindowLayer == 0`, excluding menus, tooltips, and panels; Windows has no
equivalent z-order-plane concept to filter on at all, so the Windows
conformance instead approximates it with a visible / non-iconic /
non-zero-area / top-level (`GetAncestor(hwnd, GA_ROOT) == hwnd`) check. This
is an approximation of "normal window," not a translation of macOS's explicit
layer check — say so rather than implying parity.

**Element highlighting.** macOS uses the Accessibility (AX) API; Windows uses
UI Automation (UIA), read through its `ControlView` — a tree-view choice that
changes what "the tree" contains relative to AX's own hierarchy. Per-call
messaging timeouts differ in kind, not just in number: macOS's
`AXUIElementSetMessagingTimeout` is an OS-enforced bound on a single AX call.
Windows uses `IUIAutomation2`'s `ConnectionTimeout`/`TransactionTimeout` where
that interface is available, which gives a comparable real timeout; when it
is not available (or a provider ignores it), the shim instead runs the UIA
call on a dedicated worker thread and simply stops *waiting* on it after the
timeout — the call itself is not cancelled, so a truly hung provider leaves
that worker thread blocked indefinitely rather than being interrupted the way
an OS-enforced bound interrupts it on macOS. The permission model also
differs in kind, not just presence/absence: UI Automation has no persistent,
revocable grant to check ahead of a lookup the way macOS AX/TCC trust does,
so `get_accessibility_status` on Windows always reports optimistic
availability and says so; the true per-lookup signal (including an elevation
boundary AX has no equivalent of) is `highlight_element`'s own error.
Separately: every measured number in the "Permissions, capture, and proof
limits" section above (~5,200 elements/second, the 60,000-element DaVinci
Resolve tree, the occurrence-shortcut timings) is a macOS AX measurement,
taken against macOS's traversal. No comparable measurement has been taken
against Windows UIA, and those numbers are not assumed to transfer — UIA's
per-call shape, `ControlView` scoping, and COM marshaling overhead are all
different enough that they could differ substantially in either direction.

**App identity.** macOS identifies a running application by its bundle
identifier (`"com.apple.Safari"`), a stable, OS-assigned string. Windows has
no such concept; `ActiveAppTracker` on Windows instead uses the process's
executable file name (e.g. `"chrome.exe"`), compared case-insensitively,
resolved via `QueryFullProcessImageNameW`. This is now part of the `app` MCP
parameter's contract on Windows, and it is a coarser identity than a bundle
id in one specific way: several distinct running processes can legitimately
share one identity string. Every Chromium-based app spawns many
`chrome.exe`/`msedge.exe` helper processes, and DaVinci Resolve spawns
render/worker helpers under related executable names, so app targeting and
the `app` parameter can be more ambiguous on Windows for multi-process apps
than the equivalent macOS bundle-id lookup.

**Image formats.** `draw_image`/`verify_annotation` accept PNG/JPEG/HEIC/TIFF
on both platforms, but HEIC/HEIF decoding on Windows depends on the user
having installed Microsoft's "HEIF Image Extensions" from the Microsoft
Store — it is not bundled with Windows or with this app. A missing codec is
reported as its own distinct "unsupported format on this system" error
(`unsupportedFormatOnSystem`), not folded into a generic decode failure, so a
caller can tell "install the codec or re-export as PNG/JPEG/TIFF/BMP" apart
from "this file is corrupt".

**Log path.** `~/Library/Logs/AIChalkboard/ai_chalkboard.log` on macOS;
`%LOCALAPPDATA%\AIChalkboard\Logs\ai_chalkboard.log` on Windows. Both rotate
at 5 MiB with one backup and use a platform-appropriate advisory lock
(`flock` / `LockFileEx`) to coordinate rotation across the multiple processes
Claude Desktop routinely spawns for one config entry — see "Single-instance
lock" below for why file-identity checks (used to detect another process
having rotated the file) are correspondingly best-effort on Windows.

**Termination.** macOS delivers SIGTERM/SIGINT/SIGHUP, which this app
catches to shut down gracefully — closing overlay windows, flushing logs, and
fanning a quit out to sibling instances before exiting. Windows has a
comparable console-control shutdown path this app also handles gracefully.
But Windows additionally exposes `TerminateProcess`, a hard-kill primitive
with no equivalent signal-handler opportunity at all — unlike SIGKILL, which
is at least the deliberately-last-resort case on POSIX, `TerminateProcess` is
commonly the default "stop this process" call in Windows process-management
tooling. A host that reaches for it gives this app no chance to close
windows, flush the log, or notify sibling instances — a genuine
termination-safety difference worth knowing about when choosing how a host
manages this process's lifecycle.

**Window layering.** macOS places the overlay at `NSWindow.Level.statusBar`
after an empirical probe (a borderless probe window at each candidate level,
screenshotted, and pixel-checked against the Dock's icon pixels and the menu
bar's glyph pixels) confirmed it draws above both the Dock (level 20) and the
real menu bar content (levels 24–25), not just their background bands.
Windows uses the `WS_EX_TOPMOST` extended window style, which keeps the
overlay above ordinary application windows including a fullscreen app's own
window. Whether it also draws above the Windows taskbar and system tray —
the Windows analogues of the Dock and menu bar — is not covered by the macOS
measurement above and has not been separately measured on Windows; this
README does not claim that parity, only the `WS_EX_TOPMOST` mechanism.

**Single-instance lock.** Both platforms elect one process as primary (owner
of the tray icon / menu-bar item) using a filesystem lock, with an identical
fail-open-at-startup / fail-closed-on-retry design. The underlying lock
differs in strength: POSIX `flock()` (macOS) is *advisory* — a
non-participating process can read, write, or delete the lock file freely,
and only a fellow participant in the election ever observes contention.
Win32's `LockFileEx` (Windows) is *mandatory* — the OS enforces the locked
byte range against any process attempting a conflicting access, participant
or not, which is strictly more restrictive than the POSIX contract, never
less. Working the other direction, Windows is weaker on file-identity
checks: several places in this election need to prove "the handle/descriptor
I hold is still the file this path names". POSIX does this with
`st_dev`/`st_ino`, a hard kernel guarantee for a live file. The closest
Windows analogue, `GetFileInformationByHandle`'s
(`dwVolumeSerialNumber`, `nFileIndexHigh`, `nFileIndexLow`), is documented by
Microsoft as *not* guaranteed stable across a close-and-reopen on every
filesystem (some remote and FAT-family volumes can hand back a different
file index for what is, on disk, the same file). Every identity check in
this codebase is deliberately shaped so the only possible consequence is an
unnecessary "looks replaced" verdict — a harmless extra close-and-reopen, or
an extra declined promotion followed by a retry — never the unsafe direction
of two different files being mistaken for one. In short: identity checks on
Windows are best-effort and fail toward re-election, not toward silently
trusting a stale handle.

---

## MCP Tools Reference

| Tool | Parameters | Description |
| --- | --- | --- |
| `get_screens` | `none` | Returns display IDs, physical pixel resolutions, backing scale factors, point dimensions, coordinate-space guidance, and the top-level `annotationsSuspended` presentation state. |
| `get_overlay_state` | `none` | Reports overlay visibility, click-through state, top-level `annotationsSuspended` for click dispatchers that can honor it, and an `anchorTracking` object — whether the sampling timer is currently running, counts of anchored/tracking/hidden/lost annotations, and the current sample interval plus time since the last sample (both `null` while nothing is anchored). |
| `draw_path` | `path_data`, `stroke_color?`, `stroke_width?`, `stroke_opacity?`, `fill_color?`, `fill_opacity?`, `fill_rule?`, `dash?`, `coordinate_space?`, `screenshot_width?`, `screenshot_height?`, `z_index?`, `screen_id?`, `app?`, `anchor?`, `anchor_resize?` | Draws arbitrary SVG path data. Supports absolute/relative `M L H V C S Q T A Z`, curves, arcs, fills, dashes, and independent stroke/fill opacity. |
| `draw_shape` | `shape`, `center_x?`, `center_y?`, `radius?`, `radius_x?`, `radius_y?`, `width?`, `height?`, `x?`, `y?`, `stroke_color?`, `stroke_width?`, `stroke_opacity?`, `fill_color?`, `fill_opacity?`, `fill_rule?`, `dash?`, `coordinate_space?`, `screenshot_width?`, `screenshot_height?`, `z_index?`, `screen_id?`, `app?`, `anchor?`, `anchor_resize?`, `avoid?` | Draws a circle, ellipse, or rectangle from a centre and radius (or a rect's corner), instead of hand-written `draw_path` arc commands; emits the same closed-path vector geometry `draw_path` would, with the same styling. `shape=circle` requires `center_x`/`center_y`/`radius`; `ellipse` requires `center_x`/`center_y`/`radius_x`/`radius_y`; `rect` requires `width`/`height` plus exactly one of `x`/`y` (corner) or `center_x`/`center_y` (centre) — both or neither is rejected. `avoid` accepts 1–32 existing annotation IDs and applies one exact-renderer, draw-time collision-free placement. |
| `draw_image` | `image_path`, `x`, `y`, `width?`, `height?`, `rotation_degrees?`, `opacity?`, `coordinate_space?`, `screenshot_width?`, `screenshot_height?`, `z_index?`, `screen_id?`, `app?`, `anchor?`, `anchor_resize?` | Decodes arbitrary PNG/JPEG/HEIC/TIFF art into memory once and places it with alpha, scaling, rotation, and a selected coordinate space. |
| `draw_text` | `text`, `x`, `y`, `font_size`, `color?`, `background_color?`, `background_opacity?`, `padding_px?`, `opacity?`, `coordinate_space?`, `screenshot_width?`, `screenshot_height?`, `z_index?`, `screen_id?`, `app?`, `anchor?`, `anchor_resize?`, `avoid?` | Renders a text label at a top-left position without requiring an intermediate raster image. `font_size` is required. `avoid` accepts 1–32 existing annotation IDs and reports the final exact painted bounds/offset used. |
| `draw_batch` | `items`, `coordinate_space?`, `screenshot_width?`, `screenshot_height?`, `screen_id?`, `app?`, `z_index?`, `anchor?`, `anchor_resize?`, `avoid?` | Atomically adds up to 100 mixed path/image/text/shape primitives under one annotation ID, with a 16-image / 128 MiB decoded-raster sublimit. Each item's `type` is `path`, `image`, `text`, or `shape`; `shape` items take the same fields as `draw_shape`. `anchor`/`anchor_resize` and `avoid` apply to the whole batch at once; collision avoidance translates every item by the same annotation-wide offset. |
| `highlight_element` | `label`, `app?`, `role?`, `match?`, `occurrence?`, `max_nodes?`, `timeout_seconds?`, `shape?`, `padding_px?`, `anchor?`, `anchor_resize?`, `stroke_color?`/`color?`, `stroke_width?`, `stroke_opacity?`, `fill_color?`, `fill_opacity?`, `z?`/`z_index?` | Resolves one element in a running app's Accessibility hierarchy and draws a vector highlight around its bounds — rectangle (default), ellipse, or circle via `shape`. Exact matching is the default; ambiguous results require a one-based occurrence. `max_nodes` (default 3,000, ceiling 10,000) and `timeout_seconds` (default 2.0, ceiling 10.0) bound the traversal that finds it. Defaults to `anchor="element"` — see "Element-Anchored Highlighting" above. |
| `get_accessibility_status` | `request_permission?` | macOS: reports real Accessibility (TCC) authorization; `request_permission` defaults to false, set it true only to explicitly ask macOS to show its permission prompt. Windows: always reports optimistic availability, since UI Automation has no persistent grant to check ahead of a lookup — `request_permission` has no effect there; the true per-lookup signal is `highlight_element`'s own error. |
| `update_annotation` | `annotation_id`, `offset_x?`, `offset_y?`, `opacity?`, `z_index?`, `anchor?`, `anchor_resize?`, kind-specific style fields | Moves or restyles an annotation in place. Its ID and creation identity remain stable. `anchor="none"` detaches it and freezes it exactly where it currently sits (it does not snap back to its original position); `anchor="window"` (re-)anchors it to whichever window of its linked app it currently sits over, baselining from its present position so it does not jump; `anchor_resize` alone changes an already-anchored annotation's resize policy in place, re-baselining the same way. Rejected on a global annotation (no linked app) or on one with no existing anchor to touch, as appropriate. |
| `suspend_annotations` | `lease_seconds?`, `idempotency_key?` | Acquires a short-lived suspension lease and returns secret `leaseToken`. `lease_seconds` is integer 1–60 (default 15); `idempotency_key` is an optional secret lowercase canonical UUID for retries from the same MCP server process instance. Reuse elsewhere errors without revealing a token. Only act on `clickSafeAtObservation: true`. |
| `resume_annotations` | `lease_token` | Releases exactly one returned secret `leaseToken`. If another lease remains, the result succeeds only when `peerPresentationSettled=true`; otherwise the token is released but the result is an error. With no remaining lease, the result records a linearized snapshot/restoration request, not global convergence proof. Tombstone cleanup lasts 120 seconds. |
| `clear` | `annotation_id?`, `scope?`, `app?` | Clears one exact ID when supplied. Otherwise pass `app` to target that app plus globals; omission preserves fallback-app behavior. Use `scope="all"` (without `app`) to clear every app. |
| `list_annotations` | `offset?`, `limit?` | Returns a bounded page of active annotations, which persist until explicitly cleared (there is no TTL to report), plus top-level `annotationsSuspended`. Follow `nextOffset` to page; huge geometry is explicitly summarized instead of producing an oversized MCP response. Each anchored annotation's entry carries an `anchor` object (mode, resize policy, tracking state, reference/current window frames, and the live adjustment) in the same shape `draw_*`/`highlight_element` return; an unanchored entry omits the key entirely. |
| `verify_annotation` | `annotation_id`, `screenshot_path?` or `capture_source="chalkboard"`, `request_permission?`, `padding_px?` | Returns a PNG crop composited with the exact live renderer. Exactly one screenshot source is required; `request_permission` is valid only for Chalkboard capture and defaults to false. An anchored annotation's response also carries its `anchor` object plus `anchorMovedDuringVerification`, `true` when the tracker's live projection changed between the start of this render and the moment compositing finished — evidence the window was still moving, not a failure to retry against. |
| `verify_presentation` | `annotation_id` | macOS: checks AppKit drawable state cross-checked against WindowServer's independently maintained all/on-screen registration, plus target-display bounds — a dual-witness check. Windows: checks this process's own Win32 window state (visibility/frame/extended style) plus DWM's independently maintained cloak flag — a single-source check with one narrow independent corroboration, materially weaker evidence than the macOS dual-witness form (see "Platform differences"). Neither platform claims raw-framebuffer proof. For an anchored annotation, the display checked is the window's current (effective) display, not necessarily where it was originally drawn, and a target window that is minimized/hidden or gone is reported as its own `anchor_window_hidden`/`anchor_window_lost` failure code rather than the generic absence code. |
| `get_annotation_bounds` | `annotation_id`, `screenshot_width?`, `screenshot_height?`, `target_bounds_screenshot_px?` | Reports where an annotation is actually painted, in the display's backing pixels and — when `screenshot_width`/`screenshot_height` are supplied — in that screenshot's own pixel space, using the exact live renderer and no screen capture at all. With `target_bounds_screenshot_px` it also returns the centre-to-centre delta and the absolute `offset_x`/`offset_y` to pass to `update_annotation` to close the gap. See "Verifying placement when the overlay is not in your screenshot" below. |
| `get_active_app` | `none` | Returns raw/current frontmost app state, the fallback app targeted by untagged drawing calls, and local `annotationsSuspended` presentation state. |
| `set_capture_visible` | `visible` | Applies capture-debug state locally before responding, then broadcasts it to sibling instances; external capture filters still decide inclusion. `false` restores per-app filtering but does not re-apply capture exclusion on a session detected as remote/streamed. |

---

## Input Validation & Limits

Drawing tools reject input that could not produce a visible, correct annotation, rather than
reporting success and drawing nothing useful:

| Rule | Why |
| --- | --- |
| SVG path data ≤ 200,000 characters | Path data is parsed once per distinct path string (see `SVGPathCache`) and repainted every frame; the bound permits detailed art without allowing one persistent path to monopolize the overlay thread, and it bounds the parse cache's budget. |
| Full SVG command validation | Malformed/non-finite path geometry, invalid arc flags, opacity outside 0…1, and non-positive dash lengths are rejected before anything is stored. |
| Text ≤ 20,000 characters; conservative 2M-px extent / 64M-pixel estimated area | Text, font size, and padding are checked before native text layout (AppKit on macOS, GDI+ on Windows), so creation, batch items, and updates cannot request an impractically large text surface. |
| Raster input ≤ 50 MB / 20 MP / 16,384 px per axis | Files are opened once, validated from that descriptor, read into a bounded immutable snapshot, and decoded into memory; paths are never retained or returned. Unsupported/vector/multi-frame files are rejected. |
| At most 256 raster assets / 512 MiB decoded raster memory per process | Per-image limits alone do not prevent an aggregate image bomb. Clearing, update replacement, and batch-validation rollback release the store's ownership; active render leases keep in-flight frames deterministic. |
| Batch size 1…100, with at most 16 rasters / 128 MiB decoded raster data | A batch validates and loads completely before storage; any invalid component releases temporary raster assets and adds nothing. Vector-only batches retain the broader 100-item freedom. |
| `avoid` contains 1…32 unique, current annotation IDs | Each referenced annotation and the prospective drawing are rendered off screen for exact painted bounds, so the cap bounds per-call renderer work. Missing IDs, cross-display bounds, non-painted hidden/lost anchors, or a screen with no clear placement reject atomically. Updates, clears, or anchor motion racing layout are detected at insertion and retried once. |
| At most 2,000 stored annotations per process | Drawings persist until cleared, so a session that never calls `clear` grows the store without bound. Once full, an insertion that would exceed the cap is REJECTED outright rather than silently evicting the oldest annotation to make room — silent eviction was a second way (alongside the timeout this store no longer has) for a drawing to vanish without the AI or the user asking for it. Call `clear` to make room. |
| 16 MiB retained vector/text payload and 10,000 retained primitives | Aggregate limits prevent many individually-valid paths/text/batches from exhausting memory or repaint time. A rejected draw/update leaves existing annotations intact. |
| 8 MiB serialized MCP response | Verification reserves JSON/base64 overhead, `list_annotations` is paged, and every final response is capped. Oversized geometry is summarized rather than emitting an unbounded line. |
| A draw call with no displays available is an error | Previously the annotation was stored against a synthetic screen id that no overlay window ever matches — permanently invisible, reported as success. |

Malformed JSON and non-object JSON-RPC payloads (including batch arrays) now receive a proper
`-32700` / `-32600` error response instead of silence.

## Permissions, capture, and proof limits

This section documents macOS specifics — including every measured number in it
(element/second rates, the DaVinci Resolve tree size, the occurrence-shortcut
timings) — which are macOS Accessibility (AX) measurements and are not assumed
to transfer to Windows UI Automation (UIA); no comparable measurement has been
taken there. See "Platform differences" below for what is known, and not yet
measured, about the Windows path.

`highlight_element` uses the macOS Accessibility API. It cannot inspect another
application until macOS grants AI Chalkboard Accessibility permission; callers
should check `get_accessibility_status` (using `request_permission=true` only
when an explicit system prompt is wanted) and handle denied, unavailable, missing,
or ambiguous elements as normal tool errors. Accessibility geometry is converted
to the selected display's backing-pixel coordinate space before it is drawn. The
default `anchor="element"` tracking mode repeats this same lookup in the
background every time the element's window settles after moving (see
"Window-Anchored Drawings" above), so a highlight created while permission was
granted can still start failing that background re-resolve if permission is
revoked afterward — the failure surfaces as `anchor.elementResolutionIssue`
("permission", among other fixed codes), not as a rejected tool call, since the
original draw already succeeded.

`highlight_element` lookup failures split into two measured, differently-actionable
cases rather than one blanket "not found." First, a control can simply not be
exposed to Accessibility at all — against a live DaVinci Resolve, `highlight_element`
against Resolve's Fusion Inspector tab strip returned "no accessibility element
matched" on 12 of 12 attempts — meaning element anchoring is not possible for that
control, and the caller should fall back to screenshot-measured coordinates plus
`verify_annotation` rather than retrying the same lookup. Second, a busy application
can fail to answer an Accessibility attribute request within the messaging timeout
even though the element genuinely IS exposed — the same measurement against Resolve
saw this on 1 of 12 attempts, on a label ("Tracking") that otherwise resolved cleanly
every other time — and that case is now reported as its own distinct, retryable
error instead of being folded into "this app has no Accessibility metadata"; retry
the lookup rather than concluding the UI is unreachable. When a lookup finds no
match at all, its error also names a bounded, de-duplicated sample of the labels
the app's Accessibility tree DOES expose (up to 64 collected, ranked toward labels
related to the failed query, up to 8 previewed), so a caller can re-target with a
corrected label or role instead of guessing screen coordinates. None of this changes
what is and is not proven elsewhere in this section: a successful match still only
proves that Accessibility reported a frame, not that the frame is unoccluded or
pixel-accurate.

An element that matches the label but publishes no usable screen frame (no
AXPosition/AXSize — typically an off-screen, menu, or otherwise non-drawable
element) is no longer treated as a match at all: `highlight_element` exists to
draw a shape around an element's bounds, and an element with no bounds has nothing
to draw around, so it can never be selected, pad an ambiguity list, or consume an
`occurrence` slot. `occurrence` therefore numbers only the highlightable matches —
the Nth element that matches the label AND has a usable frame — not the Nth element
that merely matches the label. When some matches are skipped this way,
`occurrenceOutOfRange` reports how many highlightable matches were actually
available and separately notes the frameless count, so a caller who can see more
matching labels on screen than the error's count understands why the rest were
unusable rather than assuming a miscount. A label that matches only frameless
elements is reported distinctly from a plain "no match" — the error names how many
elements matched but had nothing to draw around — since the label genuinely was
found on the element; retry with a different label or role, or fall back to
screenshot-measured coordinates confirmed with `verify_annotation`.

`highlight_element`'s traversal is also bounded by the sheer size of the hierarchy
it walks, and for some applications that size is the whole story regardless of how
precisely the query is written. Against a live DaVinci Resolve, the published
Accessibility tree exceeds 60,000 elements and took over 11 seconds to walk without
completing, at a measured rate of roughly 5,200 elements/second — well past the
3,000-element / 2.0-second default budget, and past even the 10,000-element /
10.0-second ceiling. Three consequences follow from that, stated plainly rather
than implied. First, the search is breadth-first and visits every element
regardless of its label or role, so a narrower query does NOT make a large tree
reachable — only `max_nodes`, `timeout_seconds`, and `occurrence` change how much
of the tree the walk actually needs to cover. Second, without `occurrence` the walk
deliberately continues past a match to prove the label is unambiguous, so a match
found early in the walk is still lost if the walk later exhausts its budget;
supplying `occurrence` (e.g. `occurrence: 1`) returns the first highlightable match
immediately once it is found, and is the practical approach for a large
application — measured at 0.01–1.3s against Resolve's tree, versus a 4.2s
budget failure with no `occurrence` supplied against that same tree. Third, for an
application whose tree exceeds every allowed budget, element anchoring is simply
not available — the supported path is screenshot-measured coordinates confirmed
with `verify_annotation`, the same fallback named throughout this section.

Chalkboard-side capture avoids depending on another computer-use tool's
per-application screenshot grant. On macOS it still needs Screen Recording
permission: `request_permission` may ask macOS for that grant; it never bypasses
TCC, and a failed or denied request returns an error instead of pretending that
the annotation was verified. On Windows there is no such grant to request or be
denied at all — see "Platform differences" below — so `request_permission` is a
no-op there and capture cannot fail for permission reasons. One verification
capture may run at a time and waits up to 30 seconds on macOS; if a framework
capture is still winding down after a timeout, the next request returns a
retryable error rather than accumulating background captures.

`verify_annotation` is a synthetic composite: it proves the stored annotation's
geometry against the supplied or captured UI image, using the same renderer
source on both platforms (see "Element-Anchored Highlighting" and "Platform
differences" above/below for the rasterizer caveat). `verify_presentation`
proves that the live overlay window is registered and drawable at the expected
display — on macOS this is a dual-witness proof (AppKit cross-checked against
WindowServer's independent ledger); on Windows it is single-source evidence
from this process's own Win32 state plus DWM's cloak flag, a materially weaker
guarantee (see "Platform differences"). Neither platform's operation is
raw-framebuffer evidence, and neither can prove that every pixel was unoccluded
by another process, system surface, or capture filter. Raw-framebuffer and
occlusion proof are permanently unsupported by this architecture on either
platform.

`window.ignoresMouseEvents` (macOS) / `WS_EX_TRANSPARENT` (Windows) means real
pointer events pass through the overlay on both platforms. While an annotation
is visible, though, the full-screen overlay still
appears in ordinary topmost-window listings. A computer-use click ownership
heuristic must consult the reported click-through state (or dispatch a real
click), rather than treating the presence of any non-allowlisted overlay window
as ownership. Chalkboard can report that state; it cannot change another
tool's click-dispatch policy. When that dispatcher cannot honor the state, use
this ordered workaround: draw/highlight → `suspend_annotations` with a short
lease → retain its secret `leaseToken` → wait for `clickSafeAtObservation: true` →
perform the computer-use click → `resume_annotations` with that exact token.
The lease expires automatically (default 15 seconds, maximum 60) if cleanup
is lost; release it promptly anyway. A retry using the same fresh, lowercase
canonical UUID `idempotency_key` returns the same active lease instead of
creating an overlapping one. Both the key and returned token are capabilities:
do not put either in logs, issue trackers, or shared prompts. The idempotency
key is scoped to its creator MCP server process instance while that lease
remains active; another instance reusing it gets an error and never receives
the token. Never
reuse a key between independent callers. Releasing an already-released
or expired token is deliberately successful cleanup only during the bounded
120-second tombstone window; afterwards it is unknown and returns an error.
The result names the bounded
cooperating-process/window-observation scope and is deliberately honest: it is
not raw-framebuffer or occlusion proof, and a process/window created after the
observation can change the state. Suspension keeps every annotation and its ID
exactly as they were; since annotations have no lifetime to pause or extend,
hiding them for the lease's duration cannot make one vanish out from under it.
It is a compatibility
workaround, not true concurrent highlight-and-click support: keeping a
highlight visible during the click still requires the computer-use dispatcher
to honor `ignoresMouseEvents`.

`resume_annotations` also distinguishes durable state from presentation
settlement. When another lease remains, a successful response requires
`peerPresentationSettled=true` for the current generation; a failed settle
returns an MCP error even though that caller's token has already been released.
When the released token was the final lease, the response reports only the
linearized no-lease snapshot and that restoration was requested. It does not
claim every peer/window has already converged on screen.

---

## Verifying placement when the overlay is not in your screenshot

A real, reported failure: an agent's own screenshot tool did not contain the
overlay at all, even though `verify_presentation` reported the annotation's
window on screen. What follows is what was actually measured, kept separate
from the topology reasoning after it, which was not.

**The measurement.** With `set_capture_visible(true)` set and a 300×300 solid
box drawn, all four mainstream macOS capture paths — `CGDisplayCreateImage`,
`CGWindowListCreateImage`, the `screencapture` CLI, and ScreenCaptureKit —
captured 90,000 of 90,000 expected pixels; with `set_capture_visible(false)`,
all four captured 0 of 90,000. `kCGWindowSharingState` flips from 0 to 1 with
the toggle, and the pixels follow. The overlay's window level (25,
`NSWindow.Level.statusBar`) was not a filter for any of the four paths.

**The conclusion.** Chalkboard's capture-affinity mechanism works as
documented, and `set_capture_visible(true)` is the supported way to make
annotations visible to another tool's capture. If annotations are still absent
from a screenshot after that, the cause is on the capturing side, not
Chalkboard's: a content filter the other tool built once and never rebuilt
after the sharing type changed underneath it; a filter that skips
`.accessory`-activation-policy background-agent windows entirely (see
"Launch-Mode-Dependent Lifecycle UI" above); or a capture of a different
surface altogether. That last case is worth spelling out even though it was
not measured here: a screenshot taken THROUGH a remote-desktop or
screen-sharing session captures the REMOTE machine's framebuffer, which a
locally drawn overlay was never composited into and cannot be. This is
inference from the session's topology, not a measurement — say so plainly
rather than presenting it with the same confidence as the numbers above.

**The remedy that does not depend on any of it.** `get_annotation_bounds`
answers "where is this drawing, in my screenshot's pixels" without any of the
above needing to be true: no capture, no permission, and no requirement that
the overlay ever reach any capture pipeline's output. A short worked loop:

1. Take your own screenshot (whatever tool you already use for computer use).
2. Measure the UI element you meant to annotate in that same screenshot's pixels.
3. Call `get_annotation_bounds` with that screenshot's `screenshot_width`/`screenshot_height` and the measured rect as `target_bounds_screenshot_px`.
4. Apply the returned `offset_x`/`offset_y` (from `correctionBackingPx`) with `update_annotation`.

**What this is NOT.** `get_annotation_bounds` is renderer geometry — the exact
live `AnnotationRenderer` painted the annotation alone into an offscreen
transparent bitmap and reported its non-transparent pixel bounds — not proof
that any pixel reached a real framebuffer. `verify_presentation` remains the
window-registration check and `verify_annotation` the composited-image check
against an actual screenshot; this tool replaces neither and proves neither of
the things they prove.

---

## Verifying an MCP refactor: wire-output snapshots

[`tests/mcp_wire_snapshot.py`](tests/mcp_wire_snapshot.py) captures JSON-RPC responses from the real
`AIChalkboard --mcp` binary for a fixed, wide set of stable requests (the full tool catalog plus
non-session-global dispatch paths and representative success/failure modes, `initialize`, `ping`, an unknown method, an unknown tool,
…), canonicalises away
volatile fields (UUIDs, timestamps, whichever app happens to be frontmost), and diffs two such
captures. Use it before/after a change to the MCP dispatch, validation, or tool-catalog layer:

```bash
swift build
python3 tests/mcp_wire_snapshot.py capture .build/debug/AIChalkboard before.json
# ... make your change, rebuild ...
python3 tests/mcp_wire_snapshot.py capture .build/debug/AIChalkboard after.json
python3 tests/mcp_wire_snapshot.py compare before.json after.json
```

`compare` exits `0` and prints `EQUIVALENT` if nothing meaningful changed, or exits non-zero with a
readable diff otherwise. **Same-machine only**: screen geometry (resolution, backing scale factor) is
deliberately left unmasked, since a refactor touching display handling should surface exactly there —
so a capture is only ever compared against another capture from the same machine, never checked into
the repo as a baseline, and never compared across machines.

---

## Build & Run Instructions

### macOS

```bash
./build_app.sh
```
Executes release compilation and packages `dist/AIChalkboard.app`. The
deployable bundle deliberately lives outside SwiftPM's `.build` directory, so
a later `swift build -c release` cannot remove the executable configured for
your MCP host.
`CFBundleShortVersionString` comes from `BuildMetadata.productVersion`.
`CFBundleVersion` comes from the separate `BuildMetadata.bundleVersion`, which
must be incremented before every distributed build; it uses Apple's one-to-three
numeric-component build format (so `0` is valid). The separate
`AIChalkboardBuildIdentifier` records the Git revision (or the safe `source`
fallback for source archives and build hosts without Git).
Local release builds are pinned to the persistent `AI Chalkboard Local Code
Signing` identity in the login keychain (SHA-1
`65B98DF43D4BF99750538424213806A962381046`). This keeps the app's designated
requirement stable across rebuilds so macOS Screen Recording and Accessibility
grants survive ordinary local updates. The build fails instead of falling back
to ad-hoc signing if that exact identity or its private key is unavailable.

For a clean-Mac packaging check that does not have this private identity, run
`bash tests/test_deployment_layout.sh --assemble-test-bundle`. It explicitly
uses an ad-hoc signature solely to test bundle assembly in `.test-dist/`, never
touching the deployable `dist/` bundle. Do not distribute that bundle or use it
for a normal local release, because it cannot retain existing macOS privacy
grants across rebuilds.

### Windows

Prerequisites:
- Swift 6.3+ for Windows (the toolchain, runtime, and platform SDK components from swift.org/install, installed under `%LOCALAPPDATA%\Programs\Swift`)
- Visual Studio 2022 Build Tools with the "Desktop development with C++" (VC++) workload and a Windows 10/11 SDK component

```powershell
.\build_app.ps1
```
Locates the Swift toolchain/runtime/SDK, imports the MSVC build environment
from `vcvars64.bat` (via `vswhere`), runs `swift build -c release`, and
assembles a deployable layout at `dist\AIChalkboard\` containing
`AIChalkboard.exe` plus every Swift runtime DLL it imports (determined by
walking the executable's PE import table and closing over what the Swift
toolchain's own runtime directory provides), so the result runs without the
Swift toolchain on `PATH`. Unlike macOS there is no bundle format, code
signing identity, or TCC grant tied to a signature — the script's job is
narrower than `build_app.sh`'s: assemble the exe and its DLL closure, nothing
more.

---

## Claude Desktop / Cowork Integration

### macOS

From the repository root, print the absolute executable path for *your* checkout:

```bash
binary_path="$(pwd -P)/dist/AIChalkboard.app/Contents/MacOS/AIChalkboard"
printf '%s\n' "$binary_path"
```

Then add AI Chalkboard to `~/Library/Application Support/Claude/claude_desktop_config.json`, replacing the placeholder below with that printed path:

```json
{
  "mcpServers": {
    "ai-chalkboard": {
      "command": "/replace/this/with/the/path/printed/above/AIChalkboard",
      "args": ["--mcp"]
    }
  }
}
```

### Windows

From the repository root, print the absolute executable path for *your* checkout:

```powershell
$binaryPath = (Resolve-Path '.\dist\AIChalkboard\AIChalkboard.exe').Path
$binaryPath
```

Then add AI Chalkboard to `%APPDATA%\Claude\claude_desktop_config.json`,
replacing the placeholder below with that printed path and doubling each
backslash for JSON:

```json
{
  "mcpServers": {
    "ai-chalkboard": {
      "command": "C:\\replace\\this\\with\\the\\path\\printed\\above\\AIChalkboard.exe",
      "args": ["--mcp"]
    }
  }
}
```

Point `command` at the `AIChalkboard.exe` under `dist\AIChalkboard\` that
`build_app.ps1` produces — the one bundled with the Swift runtime DLLs it
needs — not the raw `.build\x86_64-unknown-windows-msvc\release\AIChalkboard.exe`
output. Claude Desktop launches the MCP server with its own environment, not
your shell's `PATH`, so a copy that depends on the Swift toolchain being on
`PATH` will fail to start (missing-DLL exit) under Claude Desktop even though
it runs fine from a developer shell. JSON requires every backslash in a
Windows path to be doubled, as shown above.

---

## Why This Setup is Ideal for Claude Cowork

1. **Physical-Pixel Coordinates**: When a screenshot represents the full display pixel grid, SVG and raster coordinates correspond directly to backing pixels. App/window-filtered computer-use captures may omit the overlay even when capture debug mode is enabled.
2. **No Cleanup Guesswork**: Claude never has to pick a duration hoping it outlasts (or doesn't outlive) the explanation it's giving. It draws, explains at whatever pace the user needs, and calls `clear` when the annotation has served its purpose — nothing times out from under it, and nothing lingers because Claude forgot a duration was still counting down.
3. **Zero Input Disruption**: User can continue typing or clicking underneath while Claude draws highlights.

---

## Automated branch → main merging

Every branch pushed to `origin` is merged into `main` automatically — once, and only
once, the CI run for that branch's exact tip commit is green. The branch is then
deleted. The gate is **fail-closed**: a red, in-progress, missing, or API-error CI
result all skip the branch for that drain; nothing merges on ambiguity. The branch is
picked up automatically on the next CI completion for its tip SHA (e.g. a retry, or a
new push) — but because the gate is fail-closed, a tip SHA whose only CI run was
**cancelled** (e.g. a manually cancelled run) is never retried automatically, and a
branch stuck this way is not flagged by anything — resolving it (re-run CI or push a
new commit) is a manual, human-noticed step.

| File | Role |
| --- | --- |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | The merge gate. Its run conclusion for a branch's tip SHA is what auto-merge reads. |
| [`.github/workflows/auto-merge-claude.yml`](.github/workflows/auto-merge-claude.yml) | Drains every un-merged branch on each CI completion and re-verifies main's tip post-merge. |
| [`scripts/auto_merge_decision.sh`](scripts/auto_merge_decision.sh) | The fail-closed decision predicates (CI-green check, ancestry check, etc.). |
| [`tests/test_auto_merge_logic.sh`](tests/test_auto_merge_logic.sh) | Unit tests for those predicates. |
| [`.claude/session-start.sh`](.claude/session-start.sh) | SessionStart hook: resets a remote Claude session's assigned branch to `origin/main`. |

**Operating notes**

- There is no PR review step by design — a green CI run on a branch is sufficient to merge it.
- If git cannot resolve a merge cleanly, the bot opens an `Auto-merge conflict: <branch>` PR instead of merging, so a human resolves it by hand.
- The bot pushes the merge commit using `GITHUB_TOKEN`, so GitHub does **not** re-run CI on that commit. To cover this blind spot, the workflow's `postmerge` job re-verifies main's actual merged tip and opens a deduped issue if it's red.
- `workflow_dispatch` on `auto-merge-claude.yml` is the manual drain escape hatch (e.g. after a transient API failure).
- `ci.yml` is deliberately scoped to `branches: ['**']` (every branch, no tags), and its concurrency group is keyed on the commit SHA — so a re-run of an older commit can never cancel the current tip's run and strand the branch.

**Requirements**

- Repo Settings → Actions → General → Workflow permissions may be left at the read-only default — each workflow above requests the write scopes it needs via its own `permissions:` block.
- Issues must stay enabled — the `postmerge` job alerts by opening an issue if main's actual merged tip is red.
- No branch protection is configured on this repo, so the bash gate in `scripts/auto_merge_decision.sh` is the only merge gate that exists.
- There is no automated alert for a branch stuck on red/cancelled/missing CI or an open `Auto-merge conflict:` PR — these are resolved manually as noticed.
