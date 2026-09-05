#if os(Windows)
import WinSDK
import CChalkboardWin
import Foundation

/// One physical monitor's overlay: its `WS_POPUP` Win32 window, the GDI+
/// render target `AnnotationRenderer` paints into, and the separate
/// `UpdateLayeredWindow` presentation surface that puts those pixels on
/// screen. The Windows analogue of the (NSWindow, OverlayView) pair
/// `OverlayWindowController`'s index-aligned `overlayWindows`/`overlayViews`
/// arrays keep on macOS -- kept as ONE object per monitor here rather than
/// two parallel arrays: there is no AppKit-style separate "view" object on
/// this platform (`GDIPlusDrawingContext` -- wrapped by `renderTarget` below
/// -- IS the drawing surface), so the pairing invariant those two mac arrays
/// exist to document is structurally impossible to violate here: there is
/// only one thing to create, store, and destroy per screen, not two.
///
/// ===========================================================================
/// WHY A SEPARATE PRESENTATION SURFACE, NOT `renderTarget.pixelBuffer` DIRECTLY
/// ===========================================================================
/// `UpdateLayeredWindow` does not accept a raw pixel buffer; it blends from
/// whatever GDI bitmap is currently selected into a device context. This
/// class therefore owns a second, presentation-only 32bpp top-down DIB
/// section (`presentationBitmap`/`presentationBits`, selected into
/// `presentationDC`) and copies `renderTarget`'s freshly painted BGRA bytes
/// into it on every `repaint(annotations:imageForAssetId:)` before calling
/// `UpdateLayeredWindow`. `GDIPlusDrawingContext` (the `DrawingContext`
/// implementation `AnnotationRenderer` actually paints through) owns its own
/// GDI+-managed buffer for a reason -- see that file's doc comment -- so
/// this copy is the seam between "a buffer GDI+ is willing to paint into"
/// and "a buffer `UpdateLayeredWindow` is willing to present from", not
/// redundant duplication.
final class WindowsOverlayWindow {
    let hwnd: HWND
    let screenId: String

    /// Physical-pixel virtual-desktop rect this window currently covers.
    /// `x`/`y` can be negative on a multi-monitor desktop whose primary
    /// display is not the leftmost/topmost one -- see `chalkboard_win.h`'s
    /// `ChalkRect` doc comment, which this reuses rather than inventing a
    /// second plain rect type only for this file.
    let frame: ChalkRect

    /// `AnnotationRenderer`'s drawing surface, sized to exactly `frame`'s
    /// physical pixel dimensions. See
    /// `OverlayWindowController+Presentation.swift`'s Windows paint path for
    /// why this is fed `scaleFactor: 1.0` (physical pixels standing in for
    /// "points") rather than a real DPI conversion.
    let renderTarget: GDIPlusDrawingContext

    private let presentationDC: HDC
    private let presentationBitmap: HBITMAP
    private let presentationBits: UnsafeMutableRawPointer
    private let presentationStride: Int
    private let previousBitmap: HGDIOBJ?
    private var closed = false

    private var pixelWidth: Int { Int(frame.w) }
    private var pixelHeight: Int { Int(frame.h) }

    // MARK: - Window class registration

    /// Kept alive for the process's lifetime (a `static let`, never
    /// deallocated): `RegisterClassExW`/`CreateWindowExW` only read this
    /// during the synchronous call each is used in, but there is no reason
    /// to re-allocate it per window when every overlay window shares one
    /// class.
    private static let windowClassNameWide: [UInt16] = Array("AIChalkboardOverlayWindow".utf16) + [0]
    private static var classRegistered = false

    private static func registerClassIfNeeded() {
        guard !classRegistered else { return }
        classRegistered = true
        windowClassNameWide.withUnsafeBufferPointer { namePtr in
            var wc = WNDCLASSEXW()
            wc.cbSize = UInt32(MemoryLayout<WNDCLASSEXW>.size)
            wc.style = 0
            wc.lpfnWndProc = chalkboardOverlayWndProc
            wc.cbClsExtra = 0
            wc.cbWndExtra = 0
            wc.hInstance = GetModuleHandleW(nil)
            wc.hIcon = nil
            // No cursor is registered on purpose: this window is
            // `WS_EX_TRANSPARENT` and never receives mouse messages (they
            // pass straight through to whatever is underneath -- see the
            // extended-style comment on `init` below), so there is no
            // situation in which this class's cursor would ever be shown.
            wc.hCursor = nil
            wc.hbrBackground = nil
            wc.lpszMenuName = nil
            wc.lpszClassName = namePtr.baseAddress
            wc.hIconSm = nil
            if RegisterClassExW(&wc) == 0 {
                Logger.shared.log("WindowsOverlayWindow: RegisterClassExW failed (GetLastError=\(GetLastError())).", level: "ERROR")
            }
        }
    }

    // MARK: - Style flags
    //
    // Written as explicit hex literals typed directly as `DWORD` rather than
    // referencing the WinSDK-imported macro names: several of these
    // (`WS_POPUP` chief among them, whose value is `0x80000000`) are wide
    // enough that whether ClangImporter happens to have typed the imported
    // constant as `Int32` or `UInt32` changes whether a later `DWORD(...)`
    // conversion is a safe no-op or a runtime-trapping negative-to-unsigned
    // conversion. A `DWORD`-typed hex literal has no such ambiguity -- Swift
    // infers the unsigned type directly from context, so there is nothing
    // to get wrong here regardless of how the SDK header's macro imports.
    private static let wsPopup: DWORD = 0x8000_0000
    /// Makes the window a layered window at all -- required for
    /// `UpdateLayeredWindow` to work, and the ONLY thing this app ever uses
    /// to control that window's transparency. `SetLayeredWindowAttributes`
    /// must never be called on a window created with this style: Microsoft
    /// documents that doing so makes subsequent `UpdateLayeredWindow` calls
    /// on the SAME window fail until the layered bit is cleared and reset --
    /// this codebase never calls `SetLayeredWindowAttributes` at all, and
    /// this comment is here so a future edit does not "helpfully" add one.
    private static let wsExLayered: DWORD = 0x0008_0000
    /// Makes every mouse message pass straight through to whatever window is
    /// underneath -- verified on this machine: `WindowFromPoint` over a
    /// window created with this style returns the window UNDERNEATH it, not
    /// this overlay. This is the Windows equivalent of the macOS branch's
    /// `NSWindow.ignoresMouseEvents = true`.
    private static let wsExTransparent: DWORD = 0x0000_0020
    /// Keeps this window out of the taskbar and out of Alt+Tab -- the
    /// Windows equivalent of the macOS branch not appearing in the Dock or
    /// the Cmd+Tab switcher.
    private static let wsExToolWindow: DWORD = 0x0000_0080
    /// Prevents this window from ever becoming the foreground/active window
    /// (e.g. via `SetWindowPos`'s `SWP_SHOWWINDOW`), which would otherwise
    /// steal input focus from whatever the user is actually working in --
    /// the click-through overlay must never do that just by being shown.
    private static let wsExNoActivate: DWORD = 0x0800_0000
    /// Keeps the overlay above ordinary application windows, including a
    /// fullscreen app's own window -- annotating over anything on screen,
    /// the same requirement the macOS branch's extensive `.statusBar`
    /// window-level investigation documents.
    private static let wsExTopMost: DWORD = 0x0000_0008

    private static let swpNoSize: UINT = 0x0001
    private static let swpNoMove: UINT = 0x0002
    private static let swpNoZOrder: UINT = 0x0004
    private static let swpNoActivate: UINT = 0x0010
    private static let swpShowWindow: UINT = 0x0040
    private static let swpHideWindow: UINT = 0x0080

    // MARK: - Init / teardown

    /// Creates the popup window and its two backing surfaces for one
    /// monitor. Returns `nil` on any failure along the way -- window
    /// creation, GDI+ render-target creation, or DIB-section/compatible-DC
    /// creation -- logging exactly which step failed rather than handing the
    /// caller a partially-usable object. UI-THREAD-ONLY: `CreateWindowExW`
    /// ties window ownership to the calling thread (see `WindowsUIThread`'s
    /// doc comment), so every caller must already be inside a
    /// `WindowsUIThread.sync`/`.async` block.
    init?(screenId: String, frame: ChalkRect) {
        let width = Int(frame.w.rounded())
        let height = Int(frame.h.rounded())
        guard width > 0, height > 0 else {
            Logger.shared.log("WindowsOverlayWindow: refusing to create a window for screenId=\(screenId) with non-positive size \(width)x\(height).", level: "ERROR")
            return nil
        }

        guard let target = GDIPlusDrawingContext(width: width, height: height) else {
            // GDIPlusDrawingContext already logs the specific shim failure.
            return nil
        }

        Self.registerClassIfNeeded()
        let exStyle = Self.wsExLayered | Self.wsExTransparent | Self.wsExToolWindow | Self.wsExNoActivate | Self.wsExTopMost
        let createdWindow: HWND? = Self.windowClassNameWide.withUnsafeBufferPointer { namePtr in
            CreateWindowExW(
                exStyle,
                namePtr.baseAddress,
                nil,
                Self.wsPopup,
                Int32(frame.x.rounded()), Int32(frame.y.rounded()),
                Int32(width), Int32(height),
                nil, nil, GetModuleHandleW(nil), nil
            )
        }
        guard let window = createdWindow else {
            Logger.shared.log("WindowsOverlayWindow: CreateWindowExW failed for screenId=\(screenId) (GetLastError=\(GetLastError())).", level: "ERROR")
            return nil
        }

        var bitmapInfo = BITMAPINFO()
        bitmapInfo.bmiHeader.biSize = UInt32(MemoryLayout<BITMAPINFOHEADER>.size)
        bitmapInfo.bmiHeader.biWidth = Int32(width)
        // NEGATIVE height selects a top-down DIB (row 0 = top row), matching
        // `chalk_rt_pixels`' own top-down convention exactly -- see
        // `GDIPlusDrawingContext`'s doc comment -- so `present()` below can
        // copy row-for-row with no vertical flip.
        bitmapInfo.bmiHeader.biHeight = -Int32(height)
        bitmapInfo.bmiHeader.biPlanes = 1
        bitmapInfo.bmiHeader.biBitCount = 32
        // BI_RGB = 0 (wingdi.h) -- no compression, which is what a
        // premultiplied-BGRA `UpdateLayeredWindow` source needs.
        bitmapInfo.bmiHeader.biCompression = 0

        var bits: UnsafeMutableRawPointer?
        // DIB_RGB_COLORS = 0 (wingdi.h): bmiColors holds literal RGB values,
        // irrelevant here since biBitCount is 32 (no color table is used),
        // but this is the value every CreateDIBSection caller passes for a
        // true-color bitmap.
        guard let bitmap = CreateDIBSection(nil, &bitmapInfo, 0, &bits, nil, 0), let bitsPointer = bits else {
            Logger.shared.log("WindowsOverlayWindow: CreateDIBSection failed for screenId=\(screenId) (GetLastError=\(GetLastError())).", level: "ERROR")
            DestroyWindow(window)
            return nil
        }
        guard let dc = CreateCompatibleDC(nil) else {
            Logger.shared.log("WindowsOverlayWindow: CreateCompatibleDC failed for screenId=\(screenId) (GetLastError=\(GetLastError())).", level: "ERROR")
            DeleteObject(bitmap)
            DestroyWindow(window)
            return nil
        }
        let previous = SelectObject(dc, bitmap)

        self.hwnd = window
        self.screenId = screenId
        self.frame = frame
        self.renderTarget = target
        self.presentationDC = dc
        self.presentationBitmap = bitmap
        self.presentationBits = bitsPointer
        self.presentationStride = width * 4
        self.previousBitmap = previous
    }

    deinit {
        // A backstop, not the normal teardown path: `OverlayWindowController`
        // always calls `close()` explicitly (from the UI thread) during a
        // rebuild, exactly like the macOS branch's `rebuildOverlayWindows()`
        // explicitly closes every old `NSWindow` before dropping the array
        // reference. `deinit` order/thread is not guaranteed to be the UI
        // thread, so this only guards against a future call site that drops
        // the last reference without going through `close()` first.
        if !closed {
            // Do NOT call `close()` (or otherwise touch `self`) here: Win32
            // ties window ownership to the thread that created it, so
            // `DestroyWindow` must run on `WindowsUIThread` (see that type's
            // doc comment) -- calling `close()` inline, as this used to,
            // silently LEAKED the HWND (`_ = DestroyWindow(hwnd)` discards
            // its failure) on any thread other than WindowsUIThread, even
            // though `DeleteObject`/`DeleteDC` are more thread-tolerant and
            // likely still succeeded. That made this "backstop" not actually
            // work for the exact scenario its own doc comment above says it
            // exists to guard against. Copy the native handles out (never
            // capture `self` -- it is mid-deallocation, and a strong capture
            // in an escaping closure would resurrect a partially-torn-down
            // instance across the thread hop) and finish teardown on the UI
            // thread instead.
            let hwndToDestroy = hwnd
            let dcToDelete = presentationDC
            let bitmapToDelete = presentationBitmap
            let previousToRestore = previousBitmap
            WindowsUIThread.shared.async {
                if let previousToRestore {
                    _ = SelectObject(dcToDelete, previousToRestore)
                }
                _ = DeleteObject(bitmapToDelete)
                _ = DeleteDC(dcToDelete)
                _ = DestroyWindow(hwndToDestroy)
            }
        }
    }

    /// Releases every native resource this object owns: the presentation DC
    /// and its DIB section, and the Win32 window itself. `renderTarget`
    /// (a `GDIPlusDrawingContext`) frees its own shim-owned render target in
    /// its own `deinit` once this object is released, so it needs no
    /// explicit teardown call here. Safe to call more than once.
    func close() {
        guard !closed else { return }
        closed = true
        if let previousBitmap {
            _ = SelectObject(presentationDC, previousBitmap)
        }
        _ = DeleteObject(presentationBitmap)
        _ = DeleteDC(presentationDC)
        _ = DestroyWindow(hwnd)
    }

    /// "Hidden but retained": `SetWindowPos` with `SWP_HIDEWINDOW`/
    /// `SWP_SHOWWINDOW` plus `SWP_NOACTIVATE`, never `ShowWindow`. Per
    /// Microsoft's own documentation `ShowWindow(SW_HIDE)` activates a
    /// DIFFERENT window when hiding the currently-active one -- which would
    /// steal focus from whatever the user is drawing over, even though this
    /// window itself never accepts activation (`WS_EX_NOACTIVATE`). Moving
    /// the window off-screen instead of hiding it was also rejected: it
    /// would stay `IsWindowVisible` (still on-screen window enumerations,
    /// still composited), and a later hot-plugged monitor could land
    /// exactly on those now-repurposed coordinates. `SWP_HIDEWINDOW`
    /// actually removes the window from on-screen enumeration, matching the
    /// contract `refreshViewsNow(under:)`'s macOS doc comment describes.
    func setVisible(_ visible: Bool) {
        let flags = Self.swpNoMove | Self.swpNoSize | Self.swpNoZOrder | Self.swpNoActivate
            | (visible ? Self.swpShowWindow : Self.swpHideWindow)
        _ = SetWindowPos(hwnd, nil, 0, 0, 0, 0, flags)
    }

    /// Applies (or clears) `WDA_EXCLUDEFROMCAPTURE` via the shim's
    /// `chalk_window_set_excluded_from_capture`. This affects captures taken
    /// by OTHER processes; `set_capture_visible(true)`'s own placement
    /// screenshots go through `chalk_capture_monitor`, which reads the
    /// composited desktop directly and always sees this window regardless of
    /// this setting -- see that shim function's doc comment.
    func setExcludedFromCapture(_ excluded: Bool) {
        guard let hwndPointer = UnsafeMutableRawPointer(hwnd) else { return }
        let status = chalk_window_set_excluded_from_capture(hwndPointer, excluded ? 1 : 0)
        if status != 0 {
            Logger.shared.log("WindowsOverlayWindow: chalk_window_set_excluded_from_capture(excluded: \(excluded)) failed with shim status \(status) for screenId=\(screenId).", level: "ERROR")
        }
    }

    /// Repaints `renderTarget` from `annotations` and presents the result.
    /// UI-THREAD-ONLY, like every other method here.
    func repaint(annotations: [Annotation], imageForAssetId: (String) -> RasterImageHandle?) {
        renderTarget.clear()
        AnnotationRenderer.drawAnnotations(
            annotations,
            into: renderTarget,
            // scaleFactor 1.0 against a physical-pixel-sized canvas -- see
            // this type's class-level doc comment and
            // `ScreenSnapshot.swift`'s Windows `buildScreenInfos()` comment
            // for the full reasoning.
            //
            // Routed through `OverlayDrawingMetrics.rendererScaleFactor`
            // rather than written as a bare `1.0`: that function is the ONE
            // definition of this divisor, and `AnnotationVerificationCompositor`
            // reads the same one, which is what stops a verification image
            // from being rendered at a scale this live overlay never used --
            // the verifier used to pass the monitor's `backingScaleFactor`
            // against a physical-pixel canvas exactly like this one, so on a
            // 150%-DPI display it showed the circle this line paints at
            // (1920, 1080) r=200 sitting at (1280, 720) r=133 instead.
            //
            // The argument is IGNORED on this platform, by that function's
            // documented contract: this window holds no `ScreenInfo` at paint
            // time (`init` takes only a screenId and a physical-pixel rect),
            // and the literal below is therefore NOT a claim about this
            // monitor's DPI -- the canvas is physical pixels, so the divisor
            // is 1 whatever that DPI is.
            canvasSize: CGSize(width: pixelWidth, height: pixelHeight),
            scaleFactor: OverlayDrawingMetrics.rendererScaleFactor(displayBackingScaleFactor: 1),
            imageForAssetId: imageForAssetId
        )
        present()
    }

    /// Copies `renderTarget`'s freshly painted premultiplied-BGRA bytes into
    /// the presentation DIB section row-by-row (each side's own stride may
    /// differ, though in practice both are `width * 4` for a 32bpp buffer
    /// with no padding) and hands that surface to `UpdateLayeredWindow`.
    private func present() {
        guard let source = renderTarget.pixelBuffer else {
            Logger.shared.log("WindowsOverlayWindow: renderTarget.pixelBuffer was nil for screenId=\(screenId); skipping present.", level: "ERROR")
            return
        }
        let sourceStride = renderTarget.bytesPerRow
        let rowBytes = min(sourceStride, presentationStride)
        if rowBytes > 0 {
            for row in 0..<pixelHeight {
                let sourceRow = UnsafeRawBufferPointer(start: source + row * sourceStride, count: rowBytes)
                let destinationRow = UnsafeMutableRawBufferPointer(start: presentationBits + row * presentationStride, count: rowBytes)
                destinationRow.copyMemory(from: sourceRow)
            }
        }

        var pointDestination = POINT(x: Int32(frame.x.rounded()), y: Int32(frame.y.rounded()))
        var size = SIZE(cx: Int32(pixelWidth), cy: Int32(pixelHeight))
        var pointSource = POINT(x: 0, y: 0)
        // AC_SRC_OVER = 0, AC_SRC_ALPHA = 1 (wingdi.h): standard
        // per-pixel-alpha blend, constant alpha left at 255 (full) since
        // every annotation's own opacity is already baked into the pixels
        // `AnnotationRenderer` just painted via `setGlobalAlpha`/color alpha
        // -- there is no separate window-level alpha to apply on top.
        var blend = BLENDFUNCTION(BlendOp: 0, BlendFlags: 0, SourceConstantAlpha: 255, AlphaFormat: 1)
        // ULW_ALPHA = 0x00000002 (wingdi.h): use `blend`'s per-pixel alpha
        // channel rather than a color key.
        let updated = UpdateLayeredWindow(hwnd, nil, &pointDestination, &size, presentationDC, &pointSource, 0, &blend, 2)
        if !updated {
            Logger.shared.log("WindowsOverlayWindow: UpdateLayeredWindow failed (GetLastError=\(GetLastError())) for screenId=\(screenId).", level: "ERROR")
        }
    }

    // MARK: - Diagnostics
    //
    // See `OverlayWindowController+Diagnostics.swift`'s Windows
    // `presentationStatus(for:)` for why these are the BEST AVAILABLE checks
    // on this platform, not an independent second witness the way
    // `CGWindowListCopyWindowInfo` is on macOS.

    /// `IsWindow` + `IsWindowVisible`: this process's own user32 window
    /// state, read back rather than assumed from what we last requested.
    var isWindowVisible: Bool {
        guard IsWindow(hwnd) else { return false }
        return IsWindowVisible(hwnd)
    }

    /// The window's current screen rect, per `GetWindowRect` -- the ONLY
    /// geometry source available here (there is no second, independently
    /// maintained compositor-side rect to cross-check it against the way
    /// `kCGWindowBounds` is on macOS).
    var windowRect: ChalkRect? {
        var rect = RECT()
        guard GetWindowRect(hwnd, &rect) else { return nil }
        return ChalkRect(x: Double(rect.left), y: Double(rect.top),
                          w: Double(rect.right - rect.left), h: Double(rect.bottom - rect.top))
    }

    /// Whether the live extended window style still has every bit this
    /// class created the window with (layered/transparent/topmost/etc.).
    /// `GWL_EXSTYLE` is `-20` (winuser.h).
    var extendedStyleMatchesExpected: Bool {
        let expected = Self.wsExLayered | Self.wsExTransparent | Self.wsExToolWindow | Self.wsExNoActivate | Self.wsExTopMost
        let current = DWORD(bitPattern: Int32(truncatingIfNeeded: GetWindowLongPtrW(hwnd, -20)))
        return (current & expected) == expected
    }

    /// Reads back this window's CURRENT display-affinity setting via
    /// `GetWindowDisplayAffinity` rather than trusting this object's own
    /// most recent `setExcludedFromCapture(_:)` call -- an honest query,
    /// like every other property in this section, not a cached assumption.
    /// `nil` means the query itself failed; otherwise `true` means
    /// `WDA_EXCLUDEFROMCAPTURE` is currently applied.
    var isExcludedFromCapture: Bool? {
        var affinity: DWORD = 0
        guard GetWindowDisplayAffinity(hwnd, &affinity) else { return nil }
        // WDA_EXCLUDEFROMCAPTURE = 0x00000011 (winuser.h).
        return affinity == 0x0000_0011
    }

    /// DWM's own "is this window cloaked" bit (`DWMWA_CLOAKED` = 14,
    /// dwmapi.h), read via a DIFFERENT subsystem (the Desktop Window
    /// Manager compositor) than `IsWindowVisible` above (user32's window
    /// manager state) -- the closest thing to a second, independently
    /// maintained witness this platform offers. `nil` means the query
    /// itself failed (e.g. DWM composition unavailable), which is reported
    /// distinctly from "queried successfully and found not cloaked".
    var isCloakedByDWM: Bool? {
        var cloaked: DWORD = 0
        // DWMWA_CLOAKED = 14 (dwmapi.h).
        let hr = DwmGetWindowAttribute(hwnd, 14, &cloaked, DWORD(MemoryLayout<DWORD>.size))
        guard hr == S_OK else { return nil }
        return cloaked != 0
    }
}

/// Free function, not a method: `WNDCLASSEXW.lpfnWndProc` requires a plain
/// `@convention(c)` function pointer with no captured context, which only a
/// top-level (or capture-free static) Swift function can provide.
///
/// Handles exactly the two messages `OverlayWindowController` needs to react
/// to -- `WM_DISPLAYCHANGE` (broadcast to every top-level window when the
/// display configuration changes) and `WM_DPICHANGED` (sent to the specific
/// window whose DPI changed) -- and hands both to
/// `OverlayWindowController.shared`'s single coalesced-rebuild entry point.
/// `WM_DISPLAYCHANGE` in particular arrives at EVERY overlay window
/// separately (one per monitor), so the controller-side handler is
/// responsible for coalescing that into exactly one rebuild rather than one
/// per window -- see `handleDisplayOrDpiChange()`'s doc comment.
private func chalkboardOverlayWndProc(_ hwnd: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch message {
    case UINT(WM_DISPLAYCHANGE), UINT(WM_DPICHANGED):
        OverlayWindowController.shared.handleDisplayOrDpiChange()
        return 0
    default:
        return DefWindowProcW(hwnd, message, wParam, lParam)
    }
}
#endif
