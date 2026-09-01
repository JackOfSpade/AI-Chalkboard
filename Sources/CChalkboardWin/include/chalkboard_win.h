// chalkboard_win.h
//
// This target exists because the Windows-native APIs AI Chalkboard needs for
// the overlay renderer and UI automation -- GDI+, the Windows Imaging
// Component (WIC), and UI Automation -- are C++/COM surfaces. Swift cannot
// import C++ classes, vtables, or COM interfaces directly (no bridging
// header story exists for that on Windows the way Objective-C bridging works
// on macOS). So this SwiftPM C++ target sits between them: it links against
// GDI+/WIC/UIA in .cpp translation units, and exposes ONLY a plain C surface
// through this header for AIChalkboardCore to call into.
//
// Rule for everything in this header: it must be `extern "C"` -- no C++
// classes, no references, no default arguments, no overloads, no templates.
// Anything Swift needs to reach has to be expressible in plain C. Opaque
// state (a render target, a decoded image) is always an opaque pointer
// typedef -- `typedef struct ChalkFooOpaque* ChalkFoo;` -- never a struct
// whose layout Swift would have to mirror. The one exception is a genuinely
// plain-old-data struct declared right here (ChalkRect, ChalkPathElement):
// those are safe to cross the boundary by value because their layout is
// fixed and fully described in this file.
//
// Every fallible function returns an `int32_t` status: 0 (CHALK_OK) for
// success, or one of the negative `ChalkErrorCode` values below. Results are
// written through out-parameters, never through the return value, so Swift
// can check the status first and only then read the outputs. None of these
// functions return a raw HRESULT/AXError/HRESULT-shaped COM code -- COM and
// UIA failures are translated to one of the named codes below inside the
// .cpp shim, precisely so the Swift side has a stable, meaningful contract
// to switch on instead of a leaky Windows implementation detail.
//
// Strings crossing this boundary are UTF-16, NUL-terminated
// (`const uint16_t*` in, `uint16_t*` out) -- the native width of both
// Windows text APIs and Swift's `String.utf16`, so callers on both sides can
// convert without a UTF-8 round trip. A `const uint16_t*` argument is always
// owned by the caller and only read for the duration of the call.
//
// This header itself is NOT guarded by #ifdef _WIN32/os checks: it must
// stay parseable when SwiftPM evaluates the target on macOS too (the
// *implementation* in chalkboard_win.cpp is what's conditionally compiled).

#ifndef CHALKBOARD_WIN_H
#define CHALKBOARD_WIN_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Version probe. Returns a monotonically increasing ABI version number for
// this shim so Swift-side code can sanity-check it is linked against the
// C++ shim it expects. Returns 0 on non-Windows builds (see the portable
// stub in chalkboard_win.cpp).
//
// Version history (bump this whenever the flat C surface below changes in a
// way Swift-side callers need to know about):
//   1 -- probe only, no functional surface.
//   2 -- adds the render target / GDI+ drawing surface (section 1), image
//        decode/encode via WIC (section 2), UI Automation element lookup
//        (section 3), and screen capture / capture-exclusion (section 4)
//        declared below.
int32_t chalkboard_win_abi_version(void);

// =============================================================================
// Common types
// =============================================================================

// Status codes returned by every fallible function in this header. CHALK_OK
// (0) means success; every other value is negative and distinct so Swift can
// switch over the full set meaningfully instead of only testing "is it
// zero". Grouped by area below; a group's numeric values are stable once
// Swift code depends on them, so add new codes at the end of a group rather
// than renumbering.
//
// This is a plain enum with a fixed underlying type (not `enum class`) so it
// stays trivially usable as a plain `int32_t` from C call sites and from the
// .cpp shim, while still giving Swift named cases to switch on.
enum ChalkErrorCode : int32_t {
    CHALK_OK = 0,

    // --- generic (can be returned from any area) ---
    // A required argument was null, empty, out of range, or otherwise
    // malformed (e.g. width/height <= 0, a null render target/image handle,
    // a negative element count).
    CHALK_ERR_INVALID_ARGUMENT = -1,
    // A heap or GDI+/COM allocation failed.
    CHALK_ERR_OUT_OF_MEMORY = -2,
    // An unexpected failure the shim could not attribute to a more specific
    // code below (an unrecognized COM/GDI+ status, a should-never-happen
    // internal invariant). Treat as non-retryable.
    CHALK_ERR_INTERNAL = -3,

    // --- render target / GDI+ (section 1) ---
    // GDI+ (GdiplusStartup) or its Graphics/Bitmap objects could not be
    // brought up at all -- distinct from CHALK_ERR_GDIPLUS_GENERIC because
    // it means NO drawing on ANY render target can succeed right now.
    CHALK_ERR_GDIPLUS_INIT_FAILED = -100,
    // A GDI+ call reported a non-Ok Status this shim does not have a more
    // specific code for (see the function's doc comment for what GDI+
    // operation was involved).
    CHALK_ERR_GDIPLUS_GENERIC = -101,
    // The ChalkRenderTarget handle passed in is null or does not refer to a
    // live target (already destroyed, or never created).
    CHALK_ERR_INVALID_RENDER_TARGET = -102,
    // The ChalkPathElement array is malformed: a MOVE was not the first
    // element, an element's `op` is not one of the CHALK_PATH_* constants,
    // or the array was empty where at least one element is required.
    CHALK_ERR_INVALID_PATH = -103,

    // --- images / WIC (section 2) ---
    // The WIC imaging factory (CoCreateInstance of CLSID_WICImagingFactory)
    // could not be created.
    CHALK_ERR_WIC_INIT_FAILED = -200,
    // chalk_image_decode_file's path does not exist or is not readable.
    CHALK_ERR_FILE_NOT_FOUND = -201,
    // WIC opened the file but could not decode pixel data from it (corrupt
    // or truncated file, or a container WIC recognizes but cannot fully
    // parse). Distinct from CHALK_ERR_UNSUPPORTED_FORMAT below.
    CHALK_ERR_DECODE_FAILED = -202,
    // WIC has no decoder installed for this file's format on this machine.
    // This is the code a caller sees for HEIC/HEIF specifically when the
    // user has not installed Microsoft's "HEIF Image Extensions" -- report
    // it as "unsupported format on this system", never collapse it into
    // CHALK_ERR_DECODE_FAILED, since the fix (install a codec) is entirely
    // different from "this file is broken".
    CHALK_ERR_UNSUPPORTED_FORMAT = -203,
    // chalk_image_encode_png could not produce PNG bytes from the given
    // buffer (WIC PNG encoder creation or write failure).
    CHALK_ERR_ENCODE_FAILED = -204,
    // The ChalkImage handle passed in is null or does not refer to a live
    // decoded image.
    CHALK_ERR_INVALID_IMAGE = -205,
    // chalk_image_decode_file successfully decoded pixel dimensions from the
    // file, but they exceed the safety bound this shim enforces (16,384px on
    // either axis, or 20,000,000px total -- see the check's own comment in
    // chalk_image.cpp) before that decode's stride/buffer arithmetic runs.
    // Distinct from CHALK_ERR_INVALID_ARGUMENT on purpose: the file and its
    // path are both entirely valid, the caller-supplied *arguments* to this
    // call are fine -- it is the image's own decoded content that is too
    // large, exactly the same condition RasterAssetStore.validate(width:
    // height:) rejects on the Swift side for a macOS-decoded image. Folding
    // this back into CHALK_ERR_INVALID_ARGUMENT would make a perfectly good
    // absolute path get reported to the caller as malformed, which is wrong.
    CHALK_ERR_IMAGE_TOO_LARGE = -206,

    // --- UI Automation (section 3) ---
    // The UI Automation COM service could not be reached at all (CoCreate of
    // CUIAutomation failed, or CoInitializeEx failed on this thread). This
    // is the Windows analogue of macOS's "Accessibility not trusted": no
    // element lookup can succeed until this clears.
    CHALK_ERR_UIA_UNAVAILABLE = -300,
    // The traversal completed within its node/time budget and found no
    // element whose name matched. Not an error condition to retry.
    CHALK_ERR_UIA_NO_MATCH = -301,
    // At least one element matched the name, but none of the matches
    // published a usable (non-empty, finite) BoundingRectangle, so there is
    // nothing to anchor a highlight to. `out_frameless_count` on
    // chalk_uia_find_element carries how many such matches were seen.
    CHALK_ERR_UIA_NO_USABLE_BOUNDS = -302,
    // More than one element matched the name and no `occurrence` (or
    // occurrence == 0) was supplied to disambiguate.
    // `out_match_count` carries how many matches were found.
    CHALK_ERR_UIA_AMBIGUOUS = -303,
    // `occurrence` was supplied but is out of range for the number of
    // matches actually found. `out_match_count` carries the number that
    // WAS available so the caller can report a correct range.
    CHALK_ERR_UIA_OCCURRENCE_OUT_OF_RANGE = -304,
    // A UIA provider call did not answer within `timeout_seconds` (COM
    // RPC_E_* timeout, or CO_E_SERVER_EXEC_FAILURE-style busy target).
    // RETRYABLE: this reflects a target application that was momentarily
    // unresponsive, not a permanent absence of automation support -- callers
    // should treat this the same way the macOS resolver treats
    // `applicationBusy`, i.e. it is usually worth a retry rather than
    // immediately falling back to screen coordinates.
    CHALK_ERR_UIA_RETRYABLE_TIMEOUT = -305,
    // The traversal visited `max_nodes` elements without finishing the
    // tree. Like the macOS resolver's `traversalLimitReached`, this counts
    // elements VISITED, not candidates matched -- narrowing `name` does not
    // lower it; raising `max_nodes` (and `timeout_seconds` alongside it)
    // does. NOT retryable with the same arguments.
    CHALK_ERR_UIA_NODE_BUDGET_EXHAUSTED = -306,
    // The target process is elevated (running as administrator) and this
    // process is not, so UIA cannot cross the privilege boundary to read
    // its UI tree (UIPI restriction). No retry or budget change fixes this;
    // the caller must run AI Chalkboard elevated, or fall back to
    // screenshot-measured coordinates.
    CHALK_ERR_UIA_ACCESS_DENIED = -307,
    // `process_id` does not name a currently-running process, or the
    // process has no root automation element (e.g. it has no windows yet).
    CHALK_ERR_UIA_INVALID_PROCESS = -308,
    // This shim already has its cap's worth of UIA worker threads
    // outstanding (see kMaxOutstandingUiaWorkers in chalk_uia.cpp) -- most
    // of them likely permanently stuck inside a hung UI Automation provider
    // call that classic UI Automation gives this shim no way to cancel (see
    // the threading-model comment at the top of chalk_uia.cpp). NOT
    // RETRYABLE, unlike CHALK_ERR_UIA_RETRYABLE_TIMEOUT: retrying -- with
    // the same or a different process_id -- only adds another stuck thread
    // on top of an already-saturated pool. Callers should treat this as a
    // hard failure (fall back to screen coordinates, or surface that UI
    // Automation is currently wedged) rather than something worth retrying.
    CHALK_ERR_UIA_TOO_MANY_PENDING = -309,

    // --- capture (section 4) ---
    // BitBlt (or the GDI calls around it: CreateCompatibleDC/Bitmap,
    // GetDC) failed while capturing the requested rectangle.
    CHALK_ERR_CAPTURE_FAILED = -400,
    // SetWindowDisplayAffinity failed (invalid HWND, or the OS rejected the
    // affinity value on this window).
    CHALK_ERR_DISPLAY_AFFINITY_FAILED = -401,
};

// A rectangle in virtual-desktop coordinates (the same origin/units as
// Win32 screen coordinates, which is what every ChalkRect in this header
// uses: x/y can be negative on a multi-monitor desktop whose primary
// monitor is not the leftmost/topmost one).
typedef struct {
    double x;
    double y;
    double w;
    double h;
} ChalkRect;

// =============================================================================
// Section 1 -- Render target (GDI+)
// =============================================================================
//
// A ChalkRenderTarget owns a caller-sized, top-down, premultiplied-BGRA
// pixel buffer (PixelFormat32bppPARGB) plus one GDI+ Graphics over it, ready
// to hand to UpdateLayeredWindow after each draw. All coordinates passed to
// drawing calls are in that buffer's own pixel space; callers apply any
// screen/backing-scale mapping themselves before calling in, the same way
// the macOS CoreGraphics renderer does.
//
// GLOBAL ALPHA -- READ THIS BEFORE PORTING ANY DRAWING CODE FROM macOS:
// GDI+ has no equivalent of CGContext's context-wide constant alpha
// (`CGContextSetAlpha`). Rather than approximate one with a layer (which
// would change compositing semantics), each ChalkRenderTarget stores its
// OWN current global alpha (set via chalk_rt_set_global_alpha, 1.0 by
// default), and every fill/stroke/text/image call below multiplies that
// stored alpha into the `a` (or `alpha`) it was given before it paints --
// i.e. the effective alpha used is `a * current_global_alpha`, not `a`
// alone. This is the single most likely place a Windows draw can visibly
// diverge from its macOS counterpart if global alpha is set and then a
// caller forgets it is still in effect (chalk_rt_restore undoes it exactly
// like any other saved graphics state, since it is captured by
// chalk_rt_save/chalk_rt_restore -- see below).

typedef struct ChalkRenderTargetOpaque* ChalkRenderTarget;

// Forward declaration of the opaque image handle (fully documented in
// Section 2 below, where it belongs conceptually). It has to be declared
// this early because chalk_rt_draw_image, below in this same section,
// takes a ChalkImage parameter -- and C/C++ require the typedef to be
// visible at the point of use, not merely somewhere later in the file.
typedef struct ChalkImageOpaque* ChalkImage;

// Creates a `width` x `height` render target with a fully transparent
// premultiplied-BGRA backing buffer and a GDI+ Graphics over it
// (SmoothingMode set to AntiAlias). Returns NULL on failure (invalid
// width/height <= 0, or GDI+/GDI allocation failure). Deliberately no
// out-parameter error code here, unlike every fallible function below --
// a constructor that can only fail before there is any handle to report
// through stays a simple pointer-or-NULL call; a NULL result always means
// "could not create", full stop.
ChalkRenderTarget chalk_rt_create(int32_t width, int32_t height);

// Destroys a render target created by chalk_rt_create and frees its pixel
// buffer and GDI+ Graphics. Safe to call with NULL (no-op).
void chalk_rt_destroy(ChalkRenderTarget target);

// Returns a pointer to the target's premultiplied-BGRA pixel buffer
// (top-down: row 0 is the top row), suitable for passing directly as the
// bitmap bits to UpdateLayeredWindow. Returns NULL if `target` is NULL or
// invalid. The pointer is owned by `target` and is valid until
// chalk_rt_destroy is called; it does not need to be freed separately.
uint8_t* chalk_rt_pixels(ChalkRenderTarget target);

// Returns the byte stride (row pitch) of chalk_rt_pixels' buffer, i.e. the
// number of bytes to advance to move down one row. Returns 0 if `target` is
// NULL or invalid -- 0 is never a valid stride for a real target, so
// treating a 0 return as "invalid target" is safe.
int32_t chalk_rt_stride(ChalkRenderTarget target);

// Clears the entire backing buffer to fully transparent (0,0,0,0) pixels.
// Errors: CHALK_ERR_INVALID_RENDER_TARGET, CHALK_ERR_GDIPLUS_GENERIC.
int32_t chalk_rt_clear(ChalkRenderTarget target);

// Pushes the current GDI+ graphics state (transform, clip, and -- per the
// NOTE above -- the target's own current global alpha) onto an internal
// stack, mirroring CoreGraphics' CGContextSaveGState. Implemented with
// GDI+'s Graphics::Save, which hands back an opaque GraphicsState token
// rather than maintaining a stack itself, so the render target keeps its
// own stack of those tokens (and of the alpha value in effect at each save
// point) internally.
// Errors: CHALK_ERR_INVALID_RENDER_TARGET, CHALK_ERR_GDIPLUS_GENERIC,
// CHALK_ERR_OUT_OF_MEMORY (growing the internal save stack).
int32_t chalk_rt_save(ChalkRenderTarget target);

// Pops and restores the most recent state pushed by chalk_rt_save,
// including the global alpha in effect at that save point.
// Errors: CHALK_ERR_INVALID_RENDER_TARGET, CHALK_ERR_GDIPLUS_GENERIC,
// CHALK_ERR_INVALID_ARGUMENT if the save stack is empty (unbalanced
// restore).
int32_t chalk_rt_restore(ChalkRenderTarget target);

// Left-multiplies the current transform by the affine matrix
// [ a  b  0 ]
// [ c  d  0 ]
// [ tx ty 1 ]
// (GDI+/CoreGraphics row-vector convention: a point is transformed as
// x' = a*x + c*y + tx, y' = b*x + d*y + ty). Equivalent to
// Graphics::MultiplyTransform with MatrixOrderPrepend.
// Errors: CHALK_ERR_INVALID_RENDER_TARGET, CHALK_ERR_GDIPLUS_GENERIC.
int32_t chalk_rt_concat_transform(ChalkRenderTarget target,
                                   double a, double b, double c, double d,
                                   double tx, double ty);

// Sets the render target's current global alpha multiplier (see the NOTE
// above the section banner) -- every subsequent fill/stroke/text/image call
// on this target multiplies its own alpha by this value until it is changed
// again or restored by chalk_rt_restore. `alpha` is clamped to [0, 1] by the
// shim rather than rejected out of range.
// Errors: CHALK_ERR_INVALID_RENDER_TARGET, CHALK_ERR_INVALID_ARGUMENT if
// `alpha` is NaN or infinite.
int32_t chalk_rt_set_global_alpha(ChalkRenderTarget target, double alpha);

// One element of a flattened path. Which of x0,y0 / x1,y1 / x2,y2 are used
// depends on `op`:
//   CHALK_PATH_MOVE  -- starts a new figure at (x0,y0). Must be the first
//                        element, or the first element after a CLOSE.
//   CHALK_PATH_LINE  -- straight line from the current point to (x0,y0).
//   CHALK_PATH_QUAD  -- quadratic curve from the current point through
//                        control point (x0,y0) to end point (x1,y1). The
//                        shim elevates this to GDI+'s cubic AddBezier
//                        internally (GDI+ has no native quadratic op), so
//                        the visual result matches a standard quadratic
//                        Bezier; unused x2,y2 are ignored.
//   CHALK_PATH_CUBIC  -- cubic Bezier from the current point through
//                        control points (x0,y0) and (x1,y1) to end point
//                        (x2,y2). Maps directly to GraphicsPath::AddBezier.
//   CHALK_PATH_CLOSE  -- closes the current figure back to its MOVE point
//                        (GraphicsPath::CloseFigure). Uses no coordinates;
//                        x0,y0,x1,y1,x2,y2 are ignored and should be left 0.
typedef struct {
    int32_t op;
    double x0, y0;
    double x1, y1;
    double x2, y2;
} ChalkPathElement;

enum ChalkPathOp : int32_t {
    CHALK_PATH_MOVE  = 0,
    CHALK_PATH_LINE  = 1,
    CHALK_PATH_QUAD  = 2,
    CHALK_PATH_CUBIC = 3,
    CHALK_PATH_CLOSE = 4,
};

// Fills the path described by `elements` (an array of `count`
// ChalkPathElement, built into one GraphicsPath) with the solid color
// (r,g,b,a), each channel in [0, 1], using GDI+'s SolidBrush and
// Graphics::FillPath. `even_odd` selects the path's fill rule: nonzero
// selects FillModeAlternate (even-odd), zero selects FillModeWinding
// (nonzero winding) -- matching CoreGraphics' EOFill vs. Fill distinction.
// The color's alpha is multiplied by the target's current global alpha (see
// the section NOTE) before painting.
// Errors: CHALK_ERR_INVALID_RENDER_TARGET, CHALK_ERR_INVALID_PATH (null
// `elements` with count > 0, count < 0, or a malformed element sequence --
// see CHALK_ERR_INVALID_PATH above), CHALK_ERR_INVALID_ARGUMENT (any of
// r,g,b,a is not finite or outside [0,1]), CHALK_ERR_GDIPLUS_GENERIC.
int32_t chalk_rt_fill_path(ChalkRenderTarget target,
                            const ChalkPathElement* elements, int32_t count,
                            double r, double g, double b, double a,
                            int32_t even_odd);

// Strokes the path described by `elements`/`count` (see chalk_rt_fill_path)
// with the solid color (r,g,b,a) and `line_width`, using a GDI+ Pen.
// Line join and both line caps are FIXED, not configurable: this mirrors
// the macOS CoreGraphics renderer, which always draws with a round join and
// round caps (Pen::SetLineJoin(LineJoinRound),
// Pen::SetStartCap/SetEndCap(LineCapRound)) -- there is deliberately no
// parameter for this because the macOS side never varies it either.
// `dash`, if non-NULL, is an array of `dash_count` values (alternating
// on/off lengths, in the same units as `line_width`) applied via
// Pen::SetDashPattern; pass NULL and 0 for a solid line. The color's alpha
// is multiplied by the target's current global alpha (see the section
// NOTE) before painting.
// Errors: CHALK_ERR_INVALID_RENDER_TARGET, CHALK_ERR_INVALID_PATH,
// CHALK_ERR_INVALID_ARGUMENT (r,g,b,a out of [0,1] or non-finite;
// line_width <= 0 or non-finite; dash_count < 0; dash non-NULL with
// dash_count == 0 or vice versa; any dash value <= 0), CHALK_ERR_GDIPLUS_GENERIC.
int32_t chalk_rt_stroke_path(ChalkRenderTarget target,
                              const ChalkPathElement* elements, int32_t count,
                              double r, double g, double b, double a,
                              double line_width,
                              const double* dash, int32_t dash_count);

// Fills the axis-aligned rectangle (x, y, w, h) with the solid color
// (r,g,b,a). Equivalent to (and may be implemented as) a one-rectangle
// GraphicsPath through chalk_rt_fill_path, provided as its own entry point
// because it is the single most common fill AI Chalkboard performs
// (highlight boxes) and does not need a caller-built path array. The
// color's alpha is multiplied by the target's current global alpha (see
// the section NOTE) before painting.
// Errors: CHALK_ERR_INVALID_RENDER_TARGET, CHALK_ERR_INVALID_ARGUMENT (w or
// h <= 0 or non-finite; r,g,b,a out of [0,1] or non-finite), CHALK_ERR_GDIPLUS_GENERIC.
int32_t chalk_rt_fill_rect(ChalkRenderTarget target,
                            double x, double y, double w, double h,
                            double r, double g, double b, double a);

// Measures the pixel size `text` would occupy if drawn with
// chalk_rt_draw_text at `font_pixel_size`, using GDI+'s
// Graphics::MeasureString against the "Segoe UI" FontFamily (matching the
// font chalk_rt_draw_text actually paints with). Takes NO render target
// deliberately: text layout is wanted for sizing/positioning decisions
// before a target may even exist yet (e.g. to size a callout box), so this
// call stands alone and uses its own throwaway measuring Graphics
// internally.
// Errors: CHALK_ERR_INVALID_ARGUMENT (null `text`, or font_pixel_size <= 0
// or non-finite, or null out_w/out_h), CHALK_ERR_GDIPLUS_INIT_FAILED,
// CHALK_ERR_GDIPLUS_GENERIC.
int32_t chalk_rt_measure_text(const uint16_t* text, double font_pixel_size,
                               double* out_w, double* out_h);

// Draws `text` in the solid color (r,g,b,a) at `font_pixel_size`, using the
// "Segoe UI" FontFamily, with (x, y) as the TOP-LEFT corner of the text box
// (not a baseline origin -- callers porting from a baseline-based macOS
// call site must adjust). The color's alpha is multiplied by the target's
// current global alpha (see the section NOTE) before painting.
// Errors: CHALK_ERR_INVALID_RENDER_TARGET, CHALK_ERR_INVALID_ARGUMENT (null
// `text`; font_pixel_size <= 0 or non-finite; r,g,b,a out of [0,1] or
// non-finite), CHALK_ERR_GDIPLUS_GENERIC.
int32_t chalk_rt_draw_text(ChalkRenderTarget target, const uint16_t* text,
                            double x, double y, double font_pixel_size,
                            double r, double g, double b, double a);

// Draws `image` (a ChalkImage decoded by chalk_image_decode_file) into the
// destination rectangle (x, y, w, h) on `target`, scaling as needed.
// `alpha` in [0, 1] is an additional per-call multiplier on top of the
// image's own pixel alpha; like every other paint call it is further
// multiplied by the target's current global alpha (see the section NOTE),
// so the effective opacity is `alpha * current_global_alpha` applied to
// each already-premultiplied source pixel.
// Errors: CHALK_ERR_INVALID_RENDER_TARGET, CHALK_ERR_INVALID_IMAGE,
// CHALK_ERR_INVALID_ARGUMENT (w or h <= 0 or non-finite; alpha out of
// [0,1] or non-finite), CHALK_ERR_GDIPLUS_GENERIC.
int32_t chalk_rt_draw_image(ChalkRenderTarget target, ChalkImage image,
                             double x, double y, double w, double h,
                             double alpha);

// =============================================================================
// Section 2 -- Images (WIC)
// =============================================================================
//
// A ChalkImage is an opaque handle to a bitmap WIC decoded into memory as
// premultiplied BGRA (matching the render target's own pixel format, so
// chalk_rt_draw_image never needs an extra conversion step).
//
// (ChalkImage itself is typedef'd earlier, in Section 1, since
// chalk_rt_draw_image there needs the name before this section begins.)

// Decodes the image file at UTF-16 `path` via WIC (IWICImagingFactory ->
// IWICBitmapDecoder -> IWICFormatConverter to
// GUID_WICPixelFormat32bppPBGRA) into a new ChalkImage, and writes its
// pixel dimensions to *out_width/*out_height. WIC's installed codec set
// covers PNG, JPEG, TIFF, BMP, and GIF (first frame) out of the box; HEIC/
// HEIF decodes only if the user has installed Microsoft's "HEIF Image
// Extensions" from the Microsoft Store, and its absence is reported as
// CHALK_ERR_UNSUPPORTED_FORMAT specifically (see that code's doc comment
// above), not folded into CHALK_ERR_DECODE_FAILED.
// On success, `*out_image` is a newly allocated handle the caller must
// release with chalk_image_destroy. On failure, `*out_image` is left
// unchanged (do not assume it is set to NULL).
// Errors: CHALK_ERR_INVALID_ARGUMENT (null path/out_image/out_width/
// out_height), CHALK_ERR_IMAGE_TOO_LARGE (the decoded image exceeds
// 16,384px on either axis or 20,000,000px total -- the same bound
// RasterAssetStore enforces on the Swift side, applied here too as defense
// in depth before this function's own stride/buffer arithmetic runs -- see
// the comment at that check in chalk_image.cpp), CHALK_ERR_FILE_NOT_FOUND,
// CHALK_ERR_UNSUPPORTED_FORMAT, CHALK_ERR_DECODE_FAILED,
// CHALK_ERR_WIC_INIT_FAILED, CHALK_ERR_OUT_OF_MEMORY.
int32_t chalk_image_decode_file(const uint16_t* path, ChalkImage* out_image,
                                 int32_t* out_width, int32_t* out_height);

// Destroys an image decoded by chalk_image_decode_file. Safe to call with
// NULL (no-op).
void chalk_image_destroy(ChalkImage image);

// Encodes a premultiplied-BGRA buffer (`width` x `height`, row pitch
// `stride` bytes) to PNG bytes in memory via WIC's PNG encoder
// (IWICBitmapEncoder over an in-memory IStream), for AI Chalkboard's
// verify_annotation flow. On success, `*out_bytes` points to a newly
// malloc'd buffer of `*out_len` bytes that the caller must free with
// chalk_image_free_bytes; PNG requires straight (non-premultiplied) alpha,
// so the shim un-premultiplies each pixel before encoding. On failure,
// `*out_bytes`/`*out_len` are left unchanged.
// Errors: CHALK_ERR_INVALID_ARGUMENT (null bgra/out_bytes/out_len; width,
// height, or stride <= 0; stride < width*4), CHALK_ERR_ENCODE_FAILED,
// CHALK_ERR_WIC_INIT_FAILED, CHALK_ERR_OUT_OF_MEMORY.
int32_t chalk_image_encode_png(const uint8_t* bgra, int32_t width, int32_t height,
                                int32_t stride, uint8_t** out_bytes, int32_t* out_len);

// Frees a buffer returned via *out_bytes by chalk_image_encode_png. Safe to
// call with NULL (no-op). Do not call free()/delete on that pointer
// directly -- it was allocated by the shim's own allocator, which may not
// be the same heap Swift's runtime would free from.
void chalk_image_free_bytes(uint8_t* bytes);

// =============================================================================
// Section 3 -- UI Automation
// =============================================================================
//
// Read-only element lookup, mirroring the contract
// AccessibilityElementResolver documents on macOS (see
// Sources/Overlay/AccessibilityElementResolver.swift): given a running
// process and a name to match, find exactly one usable element and return
// its screen bounds, or a specific, actionable error when that is not
// possible. Every distinction that resolver's error taxonomy makes
// (no-match vs. ambiguous vs. matched-but-unbounded vs. busy-and-retryable
// vs. budget-exhausted) is preserved here as its own ChalkErrorCode rather
// than collapsed, because AIChalkboardCore's calling code branches on it.

enum ChalkUiaMatchMode : int32_t {
    // Element Name must equal `name` exactly (case-sensitive ordinal
    // comparison), matching AccessibilityLabelMatchMode.exact on macOS.
    CHALK_UIA_MATCH_EXACT = 0,
    // Element Name must contain `name` (case-insensitive), matching
    // AccessibilityLabelMatchMode.contains on macOS.
    CHALK_UIA_MATCH_CONTAINS = 1,
};

// Finds a UI Automation element inside the process `process_id` whose Name
// property matches `name` under `match_mode` (a CHALK_UIA_MATCH_* value),
// walking the automation tree breadth-first exactly like the macOS
// resolver, bounded by both `max_nodes` (elements VISITED, not matched --
// narrowing `name` does not raise this budget) and `timeout_seconds`
// (wall-clock budget for the whole walk).
//
// `occurrence` selects which match to return when more than one element
// matches: pass 0 to require exactly one match (CHALK_ERR_UIA_AMBIGUOUS if
// more than one is found), or a 1-based index to select the Nth match found
// in traversal order without requiring the whole tree to be walked (an
// explicit occurrence lets the walk stop as soon as that match is found,
// the same short-circuit AccessibilityElementResolver documents for
// `traversalLimitReached`).
//
// Only elements that publish a usable (non-empty, finite)
// BoundingRectangle count as matches for occurrence-counting and can be
// returned; elements that match `name` but have no usable bounds are
// counted separately in `*out_frameless_count` and never occupy an
// occurrence slot (mirroring `matchesHaveNoUsableFrame`/
// `occurrenceOutOfRange`'s frameless-count note on macOS).
//
// On CHALK_OK, `*out_bounds` is the matched element's BoundingRectangle in
// virtual-desktop coordinates, `*out_match_count` is exactly 1 (the
// selected match), and `*out_frameless_count` is how many additional
// elements matched `name` but were skipped for lacking usable bounds.
// On CHALK_ERR_UIA_AMBIGUOUS or CHALK_ERR_UIA_OCCURRENCE_OUT_OF_RANGE,
// `*out_match_count` is the number of usable matches actually found (so the
// caller can report a correct range), and `*out_bounds` is left unchanged.
// On any other error, `*out_bounds`, `*out_match_count`, and
// `*out_frameless_count` are left unchanged.
//
// Errors: CHALK_ERR_INVALID_ARGUMENT (null name/out_bounds/out_match_count/
// out_frameless_count; max_nodes <= 0; timeout_seconds <= 0 or non-finite;
// occurrence < 0), CHALK_ERR_UIA_INVALID_PROCESS, CHALK_ERR_UIA_UNAVAILABLE,
// CHALK_ERR_UIA_ACCESS_DENIED, CHALK_ERR_UIA_NO_MATCH,
// CHALK_ERR_UIA_NO_USABLE_BOUNDS, CHALK_ERR_UIA_AMBIGUOUS,
// CHALK_ERR_UIA_OCCURRENCE_OUT_OF_RANGE, CHALK_ERR_UIA_RETRYABLE_TIMEOUT,
// CHALK_ERR_UIA_NODE_BUDGET_EXHAUSTED, CHALK_ERR_UIA_TOO_MANY_PENDING.
int32_t chalk_uia_find_element(uint32_t process_id, const uint16_t* name,
                                int32_t match_mode, int32_t occurrence,
                                int32_t max_nodes, double timeout_seconds,
                                ChalkRect* out_bounds,
                                int32_t* out_match_count,
                                int32_t* out_frameless_count);

// Collects a bounded, de-duplicated sample of the element Names actually
// published by process `process_id` (up to `max_names` of them), for the
// "no match" diagnostic AIChalkboardCore surfaces to an MCP caller --
// mirroring `AccessibilityElementResolver.noMatches`'s `exposedSample` on
// macOS, which lets a caller correct a typo'd label instead of giving up on
// element anchoring entirely. Names are packed into `out_buffer`
// (capacity `buffer_len` UTF-16 code units) as consecutive NUL-terminated
// UTF-16 strings back-to-back (i.e. NUL-separated, with a NUL after the
// last name too); `*out_count` is set to how many names were written. This
// call has its own independent, generous internal node/time budget (it is
// a diagnostic best-effort scan, not a precise lookup) and never fails
// merely because the tree is large -- it stops early and returns whatever
// it collected.
// If `out_buffer` is too small to hold even one NUL-terminated name, the
// call still succeeds with `*out_count == 0` and writes nothing (never
// partially writes a name past `buffer_len`).
// Errors: CHALK_ERR_INVALID_ARGUMENT (max_names <= 0; buffer_len < 0; null
// out_buffer when buffer_len > 0; null out_count), CHALK_ERR_UIA_INVALID_PROCESS,
// CHALK_ERR_UIA_UNAVAILABLE, CHALK_ERR_UIA_ACCESS_DENIED,
// CHALK_ERR_UIA_TOO_MANY_PENDING (this call shares chalk_uia_find_element's
// outstanding-worker-thread cap -- see that code's doc comment; this is the
// one case where this "never fails merely because the tree is large"
// diagnostic scan CAN report a hard failure, because it is not the tree
// that is the problem).
int32_t chalk_uia_sample_names(uint32_t process_id, int32_t max_names,
                                uint16_t* out_buffer, int32_t buffer_len,
                                int32_t* out_count);

// =============================================================================
// Section 4 -- Capture
// =============================================================================

// Captures the virtual-desktop rectangle (x, y, w, h) from the screen via
// BitBlt with the CAPTUREBLT flag (so layered/WS_EX_LAYERED windows, e.g.
// AI Chalkboard's own overlay, are included exactly as composited on
// screen -- callers that need a capture EXCLUDING the overlay should first
// call chalk_window_set_excluded_from_capture on the overlay's HWND). On
// success, `*out_bgra` is a newly malloc'd top-down BGRA (non-premultiplied,
// straight alpha as returned by BitBlt/GDI -- alpha is typically 255
// throughout for an opaque screen capture) buffer of `*out_h * *out_stride`
// bytes that the caller must free with chalk_capture_free; `*out_w`/`*out_h`
// echo the requested pixel dimensions (rounded the same way GDI rounds a
// device rectangle) and `*out_stride` is the buffer's row pitch in bytes.
// On failure, `*out_bgra`/`*out_w`/`*out_h`/`*out_stride` are left unchanged.
// Errors: CHALK_ERR_INVALID_ARGUMENT (w or h <= 0 or non-finite; null
// out_bgra/out_w/out_h/out_stride), CHALK_ERR_CAPTURE_FAILED, CHALK_ERR_OUT_OF_MEMORY.
int32_t chalk_capture_monitor(double x, double y, double w, double h,
                               uint8_t** out_bgra, int32_t* out_w,
                               int32_t* out_h, int32_t* out_stride);

// Frees a buffer returned via *out_bgra by chalk_capture_monitor. Safe to
// call with NULL (no-op). As with chalk_image_free_bytes, do not free this
// pointer any other way -- it was allocated by the shim's own allocator.
void chalk_capture_free(uint8_t* bgra);

// Sets or clears display-affinity exclusion on the window `hwnd` (an HWND,
// passed as `void*` since HWND is itself an opaque pointer type and this
// header must not pull in <windows.h> to name it) via
// SetWindowDisplayAffinity: `excluded` nonzero applies WDA_EXCLUDEFROMCAPTURE
// (the window renders normally on screen but is omitted from screen
// captures and recordings taken by other applications -- used to keep AI
// Chalkboard's own overlay out of the user's screen shares/recordings);
// `excluded` zero restores WDA_NONE. This affects captures taken by OTHER
// processes; it has no effect on chalk_capture_monitor above, which reads
// the composited desktop directly via BitBlt/CAPTUREBLT.
// Errors: CHALK_ERR_INVALID_ARGUMENT (null hwnd), CHALK_ERR_DISPLAY_AFFINITY_FAILED
// (SetWindowDisplayAffinity returned FALSE -- e.g. hwnd is invalid, or this
// Windows version does not support WDA_EXCLUDEFROMCAPTURE).
int32_t chalk_window_set_excluded_from_capture(void* hwnd, int32_t excluded);

#ifdef __cplusplus
}
#endif

#endif // CHALKBOARD_WIN_H
