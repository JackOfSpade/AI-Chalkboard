// chalk_render.cpp
//
// Implements chalkboard_win.h Section 1 -- Render target (GDI+): every
// chalk_rt_* function. See chalk_internal.h for the ChalkRenderTargetOpaque
// / ChalkImageOpaque layouts this file constructs and reads.
//
// The ENTIRE Windows-specific body of every function in this file stays
// inside `#ifdef _WIN32`, with a portable stub in `#else`, so this
// translation unit compiles cleanly (to effectively nothing) on macOS.

#include "include/chalkboard_win.h"
#include "chalk_internal.h"

#ifdef _WIN32

#include <algorithm>
#include <cmath>
#include <cwchar>
#include <mutex>
#include <new>
#include <vector>

namespace {

// ---------------------------------------------------------------------------
// GDI+ process-wide lifetime
// ---------------------------------------------------------------------------
//
// GdiplusStartup is called lazily, exactly once, behind a mutex, the first
// time any render-target or text-measuring call needs GDI+. It is
// deliberately NEVER paired with GdiplusShutdown: this shim backs a
// long-lived MCP server process, and GdiplusShutdown racing an in-flight
// frame on another thread during process teardown is a real crash risk for
// no benefit (the OS reclaims everything on process exit anyway).
std::mutex g_gdiplusMutex;
bool g_gdiplusStarted = false;
ULONG_PTR g_gdiplusToken = 0;

bool EnsureGdiplusStarted() {
    std::lock_guard<std::mutex> lock(g_gdiplusMutex);
    if (g_gdiplusStarted) {
        return true;
    }
    Gdiplus::GdiplusStartupInput input;
    Gdiplus::Status status = Gdiplus::GdiplusStartup(&g_gdiplusToken, &input, nullptr);
    if (status != Gdiplus::Ok) {
        return false;
    }
    g_gdiplusStarted = true;
    return true;
}

// ---------------------------------------------------------------------------
// Small shared helpers
// ---------------------------------------------------------------------------

bool IsValidTarget(ChalkRenderTarget target) {
    return target != nullptr && target->bitmap != nullptr && target->graphics != nullptr;
}

bool IsFiniteUnit(double v) {
    // A color channel or alpha value: finite and within [0, 1].
    return std::isfinite(v) && v >= 0.0 && v <= 1.0;
}

uint8_t ToByte(double unitValue) {
    const double clamped = unitValue < 0.0 ? 0.0 : (unitValue > 1.0 ? 1.0 : unitValue);
    return static_cast<uint8_t>(std::lround(clamped * 255.0));
}

// Builds a Gdiplus::Color for a brush/pen from 0..1 channel doubles and an
// already-combined (call alpha * target global alpha) effective alpha.
//
// IMPORTANT: Gdiplus::Color values handed to brushes/pens are STRAIGHT
// (non-premultiplied) ARGB, even though the render target's own backing
// buffer is stored premultiplied (PixelFormat32bppPARGB) -- GDI+
// premultiplies internally when it composites a brush/pen color onto a
// PARGB surface. Do NOT premultiply r,g,b by effectiveAlpha here: doing so
// would double-premultiply and produce a darker-than-intended result
// everywhere alpha < 1.
Gdiplus::Color MakeColor(double r, double g, double b, double effectiveAlpha) {
    return Gdiplus::Color(ToByte(effectiveAlpha), ToByte(r), ToByte(g), ToByte(b));
}

int32_t MapStatus(Gdiplus::Status status) {
    switch (status) {
        case Gdiplus::Ok:
            return CHALK_OK;
        case Gdiplus::OutOfMemory:
            return CHALK_ERR_OUT_OF_MEMORY;
        default:
            return CHALK_ERR_GDIPLUS_GENERIC;
    }
}

// Builds a Gdiplus::GraphicsPath from a ChalkPathElement array, validating
// the sequence per CHALK_ERR_INVALID_PATH's contract as it goes. Returns
// CHALK_OK (with `path` populated) or CHALK_ERR_INVALID_PATH /
// CHALK_ERR_GDIPLUS_GENERIC.
int32_t BuildGraphicsPath(const ChalkPathElement* elements, int32_t count,
                           Gdiplus::GraphicsPath& path) {
    if (count <= 0) {
        // "the array was empty where at least one element is required"
        // also covers a negative count, which chalk_rt_fill_path/
        // chalk_rt_stroke_path's own doc comments route to this same code
        // (distinct from the generic CHALK_ERR_INVALID_ARGUMENT).
        return CHALK_ERR_INVALID_PATH;
    }
    if (elements == nullptr) {
        return CHALK_ERR_INVALID_PATH;
    }
    if (elements[0].op != CHALK_PATH_MOVE) {
        return CHALK_ERR_INVALID_PATH;
    }

    double curX = 0.0, curY = 0.0;
    double startX = 0.0, startY = 0.0;
    bool prevWasClose = false;

    for (int32_t i = 0; i < count; ++i) {
        const ChalkPathElement& e = elements[i];

        // A figure that was just closed must be followed by a MOVE (or be
        // the end of the array) before any more geometry is added.
        if (prevWasClose && e.op != CHALK_PATH_MOVE) {
            return CHALK_ERR_INVALID_PATH;
        }
        prevWasClose = false;

        switch (e.op) {
            case CHALK_PATH_MOVE:
                path.StartFigure();
                curX = e.x0;
                curY = e.y0;
                startX = e.x0;
                startY = e.y0;
                break;

            case CHALK_PATH_LINE:
                path.AddLine(static_cast<Gdiplus::REAL>(curX), static_cast<Gdiplus::REAL>(curY),
                             static_cast<Gdiplus::REAL>(e.x0), static_cast<Gdiplus::REAL>(e.y0));
                curX = e.x0;
                curY = e.y0;
                break;

            case CHALK_PATH_QUAD: {
                // GDI+ has no quadratic Bezier primitive -- elevate to a
                // cubic by placing the two cubic control points 2/3 of the
                // way from each endpoint toward the single quadratic
                // control point (the standard quadratic-to-cubic identity).
                const double c1x = curX + (2.0 / 3.0) * (e.x0 - curX);
                const double c1y = curY + (2.0 / 3.0) * (e.y0 - curY);
                const double c2x = e.x1 + (2.0 / 3.0) * (e.x0 - e.x1);
                const double c2y = e.y1 + (2.0 / 3.0) * (e.y0 - e.y1);
                path.AddBezier(static_cast<Gdiplus::REAL>(curX), static_cast<Gdiplus::REAL>(curY),
                                static_cast<Gdiplus::REAL>(c1x), static_cast<Gdiplus::REAL>(c1y),
                                static_cast<Gdiplus::REAL>(c2x), static_cast<Gdiplus::REAL>(c2y),
                                static_cast<Gdiplus::REAL>(e.x1), static_cast<Gdiplus::REAL>(e.y1));
                curX = e.x1;
                curY = e.y1;
                break;
            }

            case CHALK_PATH_CUBIC:
                path.AddBezier(static_cast<Gdiplus::REAL>(curX), static_cast<Gdiplus::REAL>(curY),
                                static_cast<Gdiplus::REAL>(e.x0), static_cast<Gdiplus::REAL>(e.y0),
                                static_cast<Gdiplus::REAL>(e.x1), static_cast<Gdiplus::REAL>(e.y1),
                                static_cast<Gdiplus::REAL>(e.x2), static_cast<Gdiplus::REAL>(e.y2));
                curX = e.x2;
                curY = e.y2;
                break;

            case CHALK_PATH_CLOSE:
                path.CloseFigure();
                curX = startX;
                curY = startY;
                prevWasClose = true;
                break;

            default:
                return CHALK_ERR_INVALID_PATH;
        }
    }

    if (path.GetLastStatus() != Gdiplus::Ok) {
        return CHALK_ERR_GDIPLUS_GENERIC;
    }
    return CHALK_OK;
}

// Resolves the font family chalk_rt_measure_text / chalk_rt_draw_text paint
// with: "Segoe UI", falling back to the generic sans-serif family if Segoe
// UI is unavailable on this system. Returns nullptr (and leaves *outStatus
// set) only if even the fallback is unusable.
const Gdiplus::FontFamily* ResolveTextFamily(Gdiplus::FontFamily& segoeStorage) {
    // Placement: caller supplies storage for the primary attempt so its
    // lifetime covers the whole call; the fallback is GDI+'s own static
    // singleton and needs no storage here.
    if (segoeStorage.GetLastStatus() == Gdiplus::Ok && segoeStorage.IsAvailable()) {
        return &segoeStorage;
    }
    const Gdiplus::FontFamily* fallback = Gdiplus::FontFamily::GenericSansSerif();
    if (fallback != nullptr && fallback->GetLastStatus() == Gdiplus::Ok) {
        return fallback;
    }
    return nullptr;
}

// Applies the StringFormat settings shared by chalk_rt_measure_text and
// chalk_rt_draw_text -- typographic metrics, no wrapping, no trimming -- so
// the box each one computes/paints agrees. Takes `format` by reference
// rather than building-and-returning one: Gdiplus::StringFormat's copy
// constructor is protected (GDI+ classes generally disable copying, since a
// naive copy would double-free the underlying GDI+ handle), so a
// StringFormat can never be returned by value.
void ApplyTextFormat(Gdiplus::StringFormat& format) {
    format.SetFormatFlags(format.GetFormatFlags() | Gdiplus::StringFormatFlagsNoWrap);
    format.SetTrimming(Gdiplus::StringTrimmingNone);
}

}  // namespace

// =============================================================================
// Create / destroy / raw buffer access
// =============================================================================

ChalkRenderTarget chalk_rt_create(int32_t width, int32_t height) {
    if (width <= 0 || height <= 0) {
        return nullptr;
    }
    if (!EnsureGdiplusStarted()) {
        return nullptr;
    }

    const int32_t stride = width * 4;  // 4 bytes/pixel; positive since width > 0.
    const size_t bufferSize = static_cast<size_t>(stride) * static_cast<size_t>(height);

    ChalkRenderTargetOpaque* target = new (std::nothrow) ChalkRenderTargetOpaque();
    if (target == nullptr) {
        return nullptr;
    }

    try {
        target->pixels.assign(bufferSize, 0);  // fully transparent premultiplied BGRA.
    } catch (const std::bad_alloc&) {
        delete target;
        return nullptr;
    }
    target->width = width;
    target->height = height;
    target->stride = stride;

    // NOTE: plain `new`, not `new (std::nothrow)` -- Gdiplus::GdiplusBase
    // (the common base every GDI+ class shares) overloads member
    // operator new itself, and does not provide the 3-argument
    // (size, align_val_t, nothrow_t) overload MSVC's C++17 aligned-new
    // lookup wants for a nothrow placement new of a GDI+ type; the plain,
    // throwing form resolves to GdiplusBase's ordinary operator new(size_t)
    // and is caught below like any other allocation failure.
    try {
        target->bitmap = new Gdiplus::Bitmap(width, height, stride, PixelFormat32bppPARGB,
                                              reinterpret_cast<BYTE*>(target->pixels.data()));
    } catch (const std::bad_alloc&) {
        delete target;
        return nullptr;
    }
    if (target->bitmap->GetLastStatus() != Gdiplus::Ok) {
        delete target->bitmap;
        delete target;
        return nullptr;
    }

    try {
        target->graphics = new Gdiplus::Graphics(target->bitmap);
    } catch (const std::bad_alloc&) {
        delete target->bitmap;
        delete target;
        return nullptr;
    }
    if (target->graphics->GetLastStatus() != Gdiplus::Ok) {
        delete target->graphics;
        delete target->bitmap;
        delete target;
        return nullptr;
    }

    target->graphics->SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    target->graphics->SetCompositingMode(Gdiplus::CompositingModeSourceOver);
    target->graphics->SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
    target->globalAlpha = 1.0;

    return target;
}

void chalk_rt_destroy(ChalkRenderTarget target) {
    if (target == nullptr) {
        return;
    }
    delete target->graphics;
    delete target->bitmap;
    delete target;  // ~ChalkRenderTargetOpaque frees `pixels` and the stacks.
}

uint8_t* chalk_rt_pixels(ChalkRenderTarget target) {
    if (!IsValidTarget(target)) {
        return nullptr;
    }
    return target->pixels.data();
}

int32_t chalk_rt_stride(ChalkRenderTarget target) {
    if (!IsValidTarget(target)) {
        return 0;
    }
    return target->stride;
}

int32_t chalk_rt_clear(ChalkRenderTarget target) {
    if (!IsValidTarget(target)) {
        return CHALK_ERR_INVALID_RENDER_TARGET;
    }
    // The Bitmap was constructed directly over this buffer, so writing zero
    // bytes into it IS clearing the bitmap -- no separate GDI+ call needed,
    // and this unconditionally clears the whole surface regardless of any
    // clip/transform currently in effect on `graphics`, matching the "clears
    // the entire backing buffer" contract.
    std::fill(target->pixels.begin(), target->pixels.end(), static_cast<uint8_t>(0));
    return CHALK_OK;
}

// =============================================================================
// Save / restore / transform / global alpha
// =============================================================================

int32_t chalk_rt_save(ChalkRenderTarget target) {
    if (!IsValidTarget(target)) {
        return CHALK_ERR_INVALID_RENDER_TARGET;
    }
    const Gdiplus::GraphicsState state = target->graphics->Save();
    const Gdiplus::Status status = target->graphics->GetLastStatus();
    if (status != Gdiplus::Ok) {
        return MapStatus(status);
    }
    try {
        target->stateStack.push_back(state);
        target->alphaStack.push_back(target->globalAlpha);
    } catch (const std::bad_alloc&) {
        // The GDI+-side save already happened; it stays alive (harmlessly)
        // inside the Graphics object's own state list until the Graphics is
        // destroyed. We only failed to track it on our side, so surface
        // that as out-of-memory rather than leaving a corrupt stack.
        return CHALK_ERR_OUT_OF_MEMORY;
    }
    return CHALK_OK;
}

int32_t chalk_rt_restore(ChalkRenderTarget target) {
    if (!IsValidTarget(target)) {
        return CHALK_ERR_INVALID_RENDER_TARGET;
    }
    if (target->stateStack.empty()) {
        return CHALK_ERR_INVALID_ARGUMENT;  // unbalanced restore.
    }
    const Gdiplus::GraphicsState state = target->stateStack.back();
    const double alpha = target->alphaStack.back();

    const Gdiplus::Status status = target->graphics->Restore(state);
    if (status != Gdiplus::Ok) {
        return MapStatus(status);
    }
    target->stateStack.pop_back();
    target->alphaStack.pop_back();
    target->globalAlpha = alpha;
    return CHALK_OK;
}

int32_t chalk_rt_concat_transform(ChalkRenderTarget target, double a, double b, double c,
                                   double d, double tx, double ty) {
    if (!IsValidTarget(target)) {
        return CHALK_ERR_INVALID_RENDER_TARGET;
    }
    Gdiplus::Matrix matrix(static_cast<Gdiplus::REAL>(a), static_cast<Gdiplus::REAL>(b),
                            static_cast<Gdiplus::REAL>(c), static_cast<Gdiplus::REAL>(d),
                            static_cast<Gdiplus::REAL>(tx), static_cast<Gdiplus::REAL>(ty));
    if (matrix.GetLastStatus() != Gdiplus::Ok) {
        return MapStatus(matrix.GetLastStatus());
    }
    const Gdiplus::Status status =
        target->graphics->MultiplyTransform(&matrix, Gdiplus::MatrixOrderPrepend);
    return MapStatus(status);
}

int32_t chalk_rt_set_global_alpha(ChalkRenderTarget target, double alpha) {
    if (!IsValidTarget(target)) {
        return CHALK_ERR_INVALID_RENDER_TARGET;
    }
    if (!std::isfinite(alpha)) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    target->globalAlpha = alpha < 0.0 ? 0.0 : (alpha > 1.0 ? 1.0 : alpha);
    return CHALK_OK;
}

// =============================================================================
// Fill / stroke
// =============================================================================

int32_t chalk_rt_fill_path(ChalkRenderTarget target, const ChalkPathElement* elements,
                            int32_t count, double r, double g, double b, double a,
                            int32_t even_odd) {
    if (!IsValidTarget(target)) {
        return CHALK_ERR_INVALID_RENDER_TARGET;
    }

    Gdiplus::GraphicsPath path;
    const int32_t pathStatus = BuildGraphicsPath(elements, count, path);
    if (pathStatus != CHALK_OK) {
        return pathStatus;
    }

    if (!IsFiniteUnit(r) || !IsFiniteUnit(g) || !IsFiniteUnit(b) || !IsFiniteUnit(a)) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }

    path.SetFillMode(even_odd != 0 ? Gdiplus::FillModeAlternate : Gdiplus::FillModeWinding);

    const double effectiveAlpha = a * target->globalAlpha;
    Gdiplus::SolidBrush brush(MakeColor(r, g, b, effectiveAlpha));

    const Gdiplus::Status status = target->graphics->FillPath(&brush, &path);
    return MapStatus(status);
}

int32_t chalk_rt_stroke_path(ChalkRenderTarget target, const ChalkPathElement* elements,
                              int32_t count, double r, double g, double b, double a,
                              double line_width, const double* dash, int32_t dash_count) {
    if (!IsValidTarget(target)) {
        return CHALK_ERR_INVALID_RENDER_TARGET;
    }

    Gdiplus::GraphicsPath path;
    const int32_t pathStatus = BuildGraphicsPath(elements, count, path);
    if (pathStatus != CHALK_OK) {
        return pathStatus;
    }

    if (!IsFiniteUnit(r) || !IsFiniteUnit(g) || !IsFiniteUnit(b) || !IsFiniteUnit(a)) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    if (!std::isfinite(line_width) || line_width <= 0.0) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    if (dash_count < 0) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    if ((dash != nullptr) != (dash_count > 0)) {
        // dash non-NULL with dash_count == 0, or dash NULL with
        // dash_count > 0 -- the two must agree.
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    for (int32_t i = 0; i < dash_count; ++i) {
        if (!std::isfinite(dash[i]) || dash[i] <= 0.0) {
            return CHALK_ERR_INVALID_ARGUMENT;
        }
    }

    const double effectiveAlpha = a * target->globalAlpha;
    Gdiplus::Pen pen(MakeColor(r, g, b, effectiveAlpha), static_cast<Gdiplus::REAL>(line_width));
    pen.SetLineJoin(Gdiplus::LineJoinRound);
    pen.SetStartCap(Gdiplus::LineCapRound);
    pen.SetEndCap(Gdiplus::LineCapRound);

    if (dash_count > 0) {
        // TRAP: Pen::SetDashPattern expresses each dash/gap length as a
        // MULTIPLE OF THE PEN WIDTH, not an absolute length in the same
        // units as `line_width` (which is what `dash`'s own units are, per
        // the header doc comment) -- divide every entry by line_width
        // before handing it to GDI+, or the whole pattern comes out
        // line_width times too long.
        std::vector<Gdiplus::REAL> dashPattern;
        dashPattern.reserve(static_cast<size_t>(dash_count));
        for (int32_t i = 0; i < dash_count; ++i) {
            dashPattern.push_back(static_cast<Gdiplus::REAL>(dash[i] / line_width));
        }
        pen.SetDashStyle(Gdiplus::DashStyleCustom);
        const Gdiplus::Status dashStatus = pen.SetDashPattern(dashPattern.data(), dash_count);
        if (dashStatus != Gdiplus::Ok) {
            return MapStatus(dashStatus);
        }
    }

    const Gdiplus::Status status = target->graphics->DrawPath(&pen, &path);
    return MapStatus(status);
}

int32_t chalk_rt_fill_rect(ChalkRenderTarget target, double x, double y, double w, double h,
                            double r, double g, double b, double a) {
    if (!IsValidTarget(target)) {
        return CHALK_ERR_INVALID_RENDER_TARGET;
    }
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(w) || !std::isfinite(h) ||
        w <= 0.0 || h <= 0.0) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    if (!IsFiniteUnit(r) || !IsFiniteUnit(g) || !IsFiniteUnit(b) || !IsFiniteUnit(a)) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }

    const double effectiveAlpha = a * target->globalAlpha;
    Gdiplus::SolidBrush brush(MakeColor(r, g, b, effectiveAlpha));
    const Gdiplus::RectF rect(static_cast<Gdiplus::REAL>(x), static_cast<Gdiplus::REAL>(y),
                               static_cast<Gdiplus::REAL>(w), static_cast<Gdiplus::REAL>(h));

    const Gdiplus::Status status = target->graphics->FillRectangle(&brush, rect);
    return MapStatus(status);
}

// =============================================================================
// Text
// =============================================================================

int32_t chalk_rt_measure_text(const uint16_t* text, double font_pixel_size, double* out_w,
                               double* out_h) {
    if (text == nullptr || out_w == nullptr || out_h == nullptr) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    if (!std::isfinite(font_pixel_size) || font_pixel_size <= 0.0) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    if (!EnsureGdiplusStarted()) {
        return CHALK_ERR_GDIPLUS_INIT_FAILED;
    }

    // No render target is available (or required) for measurement -- use a
    // throwaway 1x1 scratch Bitmap+Graphics, exactly for sizing/positioning
    // decisions that may need to happen before any target exists.
    Gdiplus::Bitmap scratchBitmap(1, 1, PixelFormat32bppARGB);
    if (scratchBitmap.GetLastStatus() != Gdiplus::Ok) {
        return CHALK_ERR_GDIPLUS_GENERIC;
    }
    Gdiplus::Graphics scratchGraphics(&scratchBitmap);
    if (scratchGraphics.GetLastStatus() != Gdiplus::Ok) {
        return CHALK_ERR_GDIPLUS_GENERIC;
    }
    scratchGraphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);

    Gdiplus::FontFamily segoe(L"Segoe UI");
    const Gdiplus::FontFamily* family = ResolveTextFamily(segoe);
    if (family == nullptr) {
        return CHALK_ERR_GDIPLUS_GENERIC;
    }

    Gdiplus::Font font(family, static_cast<Gdiplus::REAL>(font_pixel_size),
                        Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    if (font.GetLastStatus() != Gdiplus::Ok) {
        return CHALK_ERR_GDIPLUS_GENERIC;
    }

    Gdiplus::StringFormat format(Gdiplus::StringFormat::GenericTypographic());
    ApplyTextFormat(format);

    const wchar_t* wtext = reinterpret_cast<const wchar_t*>(text);
    const INT length = static_cast<INT>(wcslen(wtext));

    // A large, effectively-unbounded layout rect anchored at the origin:
    // with NoWrap set this never actually wraps, it just gives
    // MeasureString room to report the string's true, unclipped extent.
    const Gdiplus::RectF layoutRect(0.0f, 0.0f, 1000000.0f, 1000000.0f);
    Gdiplus::RectF boundingBox;
    const Gdiplus::Status status =
        scratchGraphics.MeasureString(wtext, length, &font, layoutRect, &format, &boundingBox);
    if (status != Gdiplus::Ok) {
        return CHALK_ERR_GDIPLUS_GENERIC;
    }

    *out_w = boundingBox.Width;
    *out_h = boundingBox.Height;
    return CHALK_OK;
}

int32_t chalk_rt_draw_text(ChalkRenderTarget target, const uint16_t* text, double x, double y,
                            double font_pixel_size, double r, double g, double b, double a) {
    if (!IsValidTarget(target)) {
        return CHALK_ERR_INVALID_RENDER_TARGET;
    }
    if (text == nullptr) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    if (!std::isfinite(font_pixel_size) || font_pixel_size <= 0.0) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    if (!std::isfinite(x) || !std::isfinite(y)) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    if (!IsFiniteUnit(r) || !IsFiniteUnit(g) || !IsFiniteUnit(b) || !IsFiniteUnit(a)) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }

    Gdiplus::FontFamily segoe(L"Segoe UI");
    const Gdiplus::FontFamily* family = ResolveTextFamily(segoe);
    if (family == nullptr) {
        return CHALK_ERR_GDIPLUS_GENERIC;
    }

    Gdiplus::Font font(family, static_cast<Gdiplus::REAL>(font_pixel_size),
                        Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    if (font.GetLastStatus() != Gdiplus::Ok) {
        return CHALK_ERR_GDIPLUS_GENERIC;
    }

    Gdiplus::StringFormat format(Gdiplus::StringFormat::GenericTypographic());
    ApplyTextFormat(format);

    const wchar_t* wtext = reinterpret_cast<const wchar_t*>(text);
    const INT length = static_cast<INT>(wcslen(wtext));

    const double effectiveAlpha = a * target->globalAlpha;
    Gdiplus::SolidBrush brush(MakeColor(r, g, b, effectiveAlpha));

    // Same (x, y, huge, huge) origin-anchored layout rect chalk_rt_measure_text
    // measures against, so the box actually painted here agrees with what a
    // caller sized against via that call. (x, y) is therefore the TOP-LEFT
    // corner of the text box, not a baseline origin.
    const Gdiplus::RectF destRect(static_cast<Gdiplus::REAL>(x), static_cast<Gdiplus::REAL>(y),
                                   1000000.0f, 1000000.0f);

    const Gdiplus::Status status =
        target->graphics->DrawString(wtext, length, &font, destRect, &format, &brush);
    return MapStatus(status);
}

// =============================================================================
// Image compositing
// =============================================================================

int32_t chalk_rt_draw_image(ChalkRenderTarget target, ChalkImage image, double x, double y,
                             double w, double h, double alpha) {
    if (!IsValidTarget(target)) {
        return CHALK_ERR_INVALID_RENDER_TARGET;
    }
    if (image == nullptr || image->bitmap == nullptr) {
        return CHALK_ERR_INVALID_IMAGE;
    }
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(w) || !std::isfinite(h) ||
        w <= 0.0 || h <= 0.0) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    if (!IsFiniteUnit(alpha)) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }

    const double effectiveAlpha = alpha * target->globalAlpha;

    // The source bitmap is premultiplied BGRA (PixelFormat32bppPARGB, the
    // same format chalk_image_decode_file produces and the render target's
    // own buffer uses). Scaling ALL FOUR channels (R,G,B,A) by the same
    // factor is the correct way to scale overall opacity on premultiplied
    // pixel data: a premultiplied pixel (R*s, G*s, B*s, s) with every
    // channel scaled by k is exactly the premultiplied representation of
    // the same underlying color at alpha s*k. Scaling only the alpha
    // column -- the common recipe for *non*-premultiplied/straight-alpha
    // bitmaps -- would leave the color channels too saturated for the new,
    // lower alpha and produce a subtly-wrong translucent fade.
    const Gdiplus::REAL k = static_cast<Gdiplus::REAL>(effectiveAlpha);
    Gdiplus::ColorMatrix matrix = {{
        {k, 0.0f, 0.0f, 0.0f, 0.0f},
        {0.0f, k, 0.0f, 0.0f, 0.0f},
        {0.0f, 0.0f, k, 0.0f, 0.0f},
        {0.0f, 0.0f, 0.0f, k, 0.0f},
        {0.0f, 0.0f, 0.0f, 0.0f, 1.0f},
    }};

    Gdiplus::ImageAttributes attributes;
    const Gdiplus::Status attrStatus = attributes.SetColorMatrix(
        &matrix, Gdiplus::ColorMatrixFlagsDefault, Gdiplus::ColorAdjustTypeBitmap);
    if (attrStatus != Gdiplus::Ok) {
        return MapStatus(attrStatus);
    }

    const Gdiplus::RectF destRect(static_cast<Gdiplus::REAL>(x), static_cast<Gdiplus::REAL>(y),
                                   static_cast<Gdiplus::REAL>(w), static_cast<Gdiplus::REAL>(h));
    const Gdiplus::Status status = target->graphics->DrawImage(
        image->bitmap, destRect, 0.0f, 0.0f, static_cast<Gdiplus::REAL>(image->width),
        static_cast<Gdiplus::REAL>(image->height), Gdiplus::UnitPixel, &attributes);
    return MapStatus(status);
}

#else  // !_WIN32

// -----------------------------------------------------------------------------
// Portable stubs. Not expected to actually run on macOS -- AIChalkboardCore
// does not link this target there -- but this translation unit must still be
// valid, warning-clean C++ wherever SwiftPM evaluates it.
// -----------------------------------------------------------------------------

ChalkRenderTarget chalk_rt_create(int32_t, int32_t) {
    return nullptr;
}

void chalk_rt_destroy(ChalkRenderTarget) {
    // No-op: chalk_rt_create never hands back a live handle on this
    // platform, so there is nothing to free.
}

uint8_t* chalk_rt_pixels(ChalkRenderTarget) {
    return nullptr;
}

int32_t chalk_rt_stride(ChalkRenderTarget) {
    return 0;
}

int32_t chalk_rt_clear(ChalkRenderTarget) {
    return CHALK_ERR_INVALID_RENDER_TARGET;
}

int32_t chalk_rt_save(ChalkRenderTarget) {
    return CHALK_ERR_INVALID_RENDER_TARGET;
}

int32_t chalk_rt_restore(ChalkRenderTarget) {
    return CHALK_ERR_INVALID_RENDER_TARGET;
}

int32_t chalk_rt_concat_transform(ChalkRenderTarget, double, double, double, double, double,
                                   double) {
    return CHALK_ERR_INVALID_RENDER_TARGET;
}

int32_t chalk_rt_set_global_alpha(ChalkRenderTarget, double) {
    return CHALK_ERR_INVALID_RENDER_TARGET;
}

int32_t chalk_rt_fill_path(ChalkRenderTarget, const ChalkPathElement*, int32_t, double, double,
                            double, double, int32_t) {
    return CHALK_ERR_INVALID_RENDER_TARGET;
}

int32_t chalk_rt_stroke_path(ChalkRenderTarget, const ChalkPathElement*, int32_t, double, double,
                              double, double, double, const double*, int32_t) {
    return CHALK_ERR_INVALID_RENDER_TARGET;
}

int32_t chalk_rt_fill_rect(ChalkRenderTarget, double, double, double, double, double, double,
                            double, double) {
    return CHALK_ERR_INVALID_RENDER_TARGET;
}

int32_t chalk_rt_measure_text(const uint16_t* text, double font_pixel_size, double* out_w,
                               double* out_h) {
    // Argument validation still runs on every platform so callers see a
    // consistent contract; only the GDI+-specific failure differs.
    if (text == nullptr || out_w == nullptr || out_h == nullptr) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    if (font_pixel_size <= 0.0) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    return CHALK_ERR_GDIPLUS_INIT_FAILED;
}

int32_t chalk_rt_draw_text(ChalkRenderTarget, const uint16_t*, double, double, double, double,
                            double, double, double) {
    return CHALK_ERR_INVALID_RENDER_TARGET;
}

int32_t chalk_rt_draw_image(ChalkRenderTarget, ChalkImage, double, double, double, double,
                             double) {
    return CHALK_ERR_INVALID_RENDER_TARGET;
}

#endif  // _WIN32
