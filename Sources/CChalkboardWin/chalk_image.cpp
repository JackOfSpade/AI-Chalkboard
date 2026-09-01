// chalk_image.cpp
//
// Implementation for Section 2 (Images / WIC) and Section 4 (Capture) of
// the C shim declared in include/chalkboard_win.h:
//   chalk_image_decode_file, chalk_image_destroy, chalk_image_encode_png,
//   chalk_image_free_bytes, chalk_capture_monitor, chalk_capture_free,
//   chalk_window_set_excluded_from_capture.
//
// Per the rule in chalkboard_win.cpp, the ENTIRE Windows-specific body of
// every function here lives inside `#ifdef _WIN32`, with a portable stub in
// `#else`, so this translation unit stays valid (if inert) C++ on macOS.

#include "include/chalkboard_win.h"
#include "chalk_internal.h"

#ifdef _WIN32

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <wincodec.h>
#include <algorithm>
#include <gdiplus.h>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>

// Not guaranteed to be defined by every Windows SDK version this shim might
// be built against (WDA_EXCLUDEFROMCAPTURE needs a Windows 10-era SDK,
// CAPTUREBLT is old but some minimal headers omit it) -- fall back to the
// documented raw values so this file compiles regardless of exactly which
// SDK headers are on the include path.
#ifndef CAPTUREBLT
#define CAPTUREBLT 0x40000000
#endif
#ifndef WDA_NONE
#define WDA_NONE 0x00000000
#endif
#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

namespace {

// GDI+ process-wide lifetime, mirroring chalk_render.cpp's own
// EnsureGdiplusStarted (duplicated rather than shared across translation
// units since chalk_internal.h is a plain data-layout header, not a place
// for cross-.cpp singletons). GdiplusStartup is idempotent-safe to call
// from more than one .cpp as long as each call is paired with its own
// token and none of them call GdiplusShutdown -- which, as in
// chalk_render.cpp, this file deliberately never does for a long-lived
// process.
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

// RAII COM initialization for one call. See the doc comment on
// chalk_uia_find_element's UIA_UNAVAILABLE code and the task brief this file
// was written against: a thread may already have CoInitializeEx'd itself
// (e.g. Swift-side host code, or an earlier call on this same thread) in a
// DIFFERENT concurrency model than the COINIT_APARTMENTTHREADED this shim
// asks for. That comes back as RPC_E_CHANGED_MODE, which is benign -- COM is
// already usable on this thread -- but since our call did NOT bump the
// per-thread init refcount in that case, we must NOT call CoUninitialize;
// doing so would unbalance whatever DID initialize it. We only balance the
// call when WE actually incremented the refcount (S_OK or S_FALSE).
class ComInitGuard {
public:
    ComInitGuard() {
        HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        if (hr == S_OK || hr == S_FALSE) {
            usable_ = true;
            shouldUninit_ = true;
        } else if (hr == RPC_E_CHANGED_MODE) {
            usable_ = true;
            shouldUninit_ = false;
        } else {
            usable_ = false;
            shouldUninit_ = false;
        }
    }
    ~ComInitGuard() {
        if (shouldUninit_) {
            CoUninitialize();
        }
    }
    ComInitGuard(const ComInitGuard&) = delete;
    ComInitGuard& operator=(const ComInitGuard&) = delete;

    bool usable() const { return usable_; }

private:
    bool usable_;
    bool shouldUninit_;
};

// Creates the process-wide WIC imaging factory for one call. Returns
// nullptr on failure; caller must Release() a non-null result.
IWICImagingFactory* CreateWicFactory() {
    IWICImagingFactory* factory = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                   CLSCTX_INPROC_SERVER,
                                   IID_PPV_ARGS(&factory));
    if (FAILED(hr)) {
        return nullptr;
    }
    return factory;
}

inline uint8_t ClampToByte(int v) {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return static_cast<uint8_t>(v);
}

// Un-premultiplies a premultiplied-BGRA buffer into a tightly packed
// (`width * 4`-strided) straight-alpha BGRA buffer, for handing to WIC's PNG
// encoder, which -- unlike this shim's render target / decoded-image
// convention -- expects straight alpha.
void UnpremultiplyBgraToStraight(const uint8_t* src, int32_t width, int32_t height,
                                  int32_t srcStride, uint8_t* dst) {
    const int32_t dstStride = width * 4;
    for (int32_t y = 0; y < height; ++y) {
        const uint8_t* srow = src + static_cast<size_t>(y) * srcStride;
        uint8_t* drow = dst + static_cast<size_t>(y) * dstStride;
        for (int32_t x = 0; x < width; ++x) {
            const uint8_t b = srow[x * 4 + 0];
            const uint8_t g = srow[x * 4 + 1];
            const uint8_t r = srow[x * 4 + 2];
            const uint8_t a = srow[x * 4 + 3];
            if (a == 0) {
                drow[x * 4 + 0] = 0;
                drow[x * 4 + 1] = 0;
                drow[x * 4 + 2] = 0;
                drow[x * 4 + 3] = 0;
            } else if (a == 255) {
                drow[x * 4 + 0] = b;
                drow[x * 4 + 1] = g;
                drow[x * 4 + 2] = r;
                drow[x * 4 + 3] = 255;
            } else {
                // Round-to-nearest un-premultiply: straight = premult *
                // 255 / a. Clamped defensively in case source data violates
                // the premultiplied invariant (premult_channel <= alpha).
                drow[x * 4 + 0] = ClampToByte((b * 255 + a / 2) / a);
                drow[x * 4 + 1] = ClampToByte((g * 255 + a / 2) / a);
                drow[x * 4 + 2] = ClampToByte((r * 255 + a / 2) / a);
                drow[x * 4 + 3] = a;
            }
        }
    }
}

} // namespace

// =============================================================================
// Section 2 -- Images (WIC)
// =============================================================================

int32_t chalk_image_decode_file(const uint16_t* path, ChalkImage* out_image,
                                 int32_t* out_width, int32_t* out_height) {
    if (!path || !out_image || !out_width || !out_height) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }

    // uint16_t* and wchar_t* are both the native 16-bit UTF-16 code unit on
    // Windows -- no conversion needed, just a reinterpretation of the same
    // bytes (see the header's boundary-string note).
    const wchar_t* wpath = reinterpret_cast<const wchar_t*>(path);

    // Distinguish "does not exist" from "WIC could not decode it" up front,
    // rather than trying to infer it from whatever HRESULT
    // CreateDecoderFromFilename happens to return.
    const DWORD attrs = GetFileAttributesW(wpath);
    if (attrs == INVALID_FILE_ATTRIBUTES || (attrs & FILE_ATTRIBUTE_DIRECTORY)) {
        return CHALK_ERR_FILE_NOT_FOUND;
    }

    ComInitGuard com;
    if (!com.usable()) {
        return CHALK_ERR_WIC_INIT_FAILED;
    }

    IWICImagingFactory* factory = CreateWicFactory();
    if (!factory) {
        return CHALK_ERR_WIC_INIT_FAILED;
    }

    IWICBitmapDecoder* decoder = nullptr;
    HRESULT hr = factory->CreateDecoderFromFilename(
        wpath, nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &decoder);
    if (FAILED(hr)) {
        factory->Release();
        if (hr == WINCODEC_ERR_COMPONENTNOTFOUND) {
            // No decoder installed for this container on this machine --
            // the HEIC-without-Store-extension case. Must stay distinct
            // from "file is corrupt" so the caller can tell the user to
            // install a codec instead of reporting a broken file.
            return CHALK_ERR_UNSUPPORTED_FORMAT;
        }
        if (hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) ||
            hr == HRESULT_FROM_WIN32(ERROR_PATH_NOT_FOUND)) {
            return CHALK_ERR_FILE_NOT_FOUND;
        }
        return CHALK_ERR_DECODE_FAILED;
    }

    IWICBitmapFrameDecode* frame = nullptr;
    hr = decoder->GetFrame(0, &frame);
    if (FAILED(hr)) {
        decoder->Release();
        factory->Release();
        return CHALK_ERR_DECODE_FAILED;
    }

    IWICFormatConverter* converter = nullptr;
    hr = factory->CreateFormatConverter(&converter);
    if (FAILED(hr)) {
        frame->Release();
        decoder->Release();
        factory->Release();
        return CHALK_ERR_OUT_OF_MEMORY;
    }

    hr = converter->Initialize(frame, GUID_WICPixelFormat32bppPBGRA,
                                WICBitmapDitherTypeNone, nullptr, 0.0,
                                WICBitmapPaletteTypeCustom);
    if (FAILED(hr)) {
        converter->Release();
        frame->Release();
        decoder->Release();
        factory->Release();
        return CHALK_ERR_DECODE_FAILED;
    }

    UINT width = 0, height = 0;
    hr = converter->GetSize(&width, &height);
    if (FAILED(hr) || width == 0 || height == 0) {
        converter->Release();
        frame->Release();
        decoder->Release();
        factory->Release();
        return CHALK_ERR_DECODE_FAILED;
    }

    // Bound the decoded dimensions BEFORE any stride/buffer arithmetic below
    // narrows them to UINT/size_t. This is NOT a fix for a known-exploitable
    // hole: WIC's own validation is believed to already reject a file that
    // declares dimensions large enough to make `width * 4` wrap (an outside
    // report to this effect was checked with a standalone harness feeding
    // WIC crafted PNG/BMP headers declaring width 1,073,741,825 -- chosen so
    // width*4 wraps to 4 in 32-bit arithmetic -- and WIC rejected both at
    // CreateDecoderFromFilename, with CopyPixels independently validating
    // the caller's stride/buffer against the real dimensions on top of
    // that). But WIC's internal validation is not part of any contract this
    // project controls, and could differ across Windows versions or with
    // third-party codecs installed (HEIF Image Extensions, camera-RAW
    // codecs). This check makes the C++ layer self-consistent with the
    // limits chalkboard_win.h already documents for decoded raster input --
    // 16,384 px per axis, 20,000,000 px total -- which today are ALSO
    // enforced on the Swift side, in RasterAssetStore.validate(width:height:),
    // AFTER this function has already fully decoded the image. The bound
    // (and the stride/bufSize it gates) is computed in uint64_t so the
    // check itself cannot wrap the way the plain 32-bit arithmetic below
    // could.
    //
    // Returns CHALK_ERR_IMAGE_TOO_LARGE here, NOT CHALK_ERR_INVALID_ARGUMENT:
    // the path and every argument to this call are perfectly valid, it is
    // the file's own decoded pixel dimensions that exceed the bound. Using
    // CHALK_ERR_INVALID_ARGUMENT would make WindowsRasterImage map this to
    // `.invalidArgument`, and RasterAssetStore in turn map THAT to
    // `.invalidPath` -- telling a caller with a perfectly good absolute path
    // to a too-large image that their *path* is malformed. See
    // CHALK_ERR_IMAGE_TOO_LARGE's doc comment in chalkboard_win.h.
    constexpr uint64_t kMaxDecodedDimension = 16384;
    constexpr uint64_t kMaxDecodedPixels = 20000000;
    const uint64_t width64 = width;
    const uint64_t height64 = height;
    if (width64 > kMaxDecodedDimension || height64 > kMaxDecodedDimension ||
        width64 * height64 > kMaxDecodedPixels) {
        converter->Release();
        frame->Release();
        decoder->Release();
        factory->Release();
        return CHALK_ERR_IMAGE_TOO_LARGE;
    }

    // Safe to narrow now: width/height are each bounded by kMaxDecodedDimension
    // above, so stride (width * 4) fits UINT and bufSize (stride * height)
    // fits size_t on both 32- and 64-bit builds.
    const uint64_t stride64 = width64 * 4;
    const uint64_t bufSize64 = stride64 * height64;
    const UINT stride = static_cast<UINT>(stride64);
    const size_t bufSize = static_cast<size_t>(bufSize64);
    uint8_t* pixels = static_cast<uint8_t*>(malloc(bufSize));
    if (!pixels) {
        converter->Release();
        frame->Release();
        decoder->Release();
        factory->Release();
        return CHALK_ERR_OUT_OF_MEMORY;
    }

    hr = converter->CopyPixels(nullptr, stride, static_cast<UINT>(bufSize), pixels);
    converter->Release();
    frame->Release();
    decoder->Release();
    factory->Release();
    if (FAILED(hr)) {
        free(pixels);
        return CHALK_ERR_DECODE_FAILED;
    }

    if (!EnsureGdiplusStarted()) {
        free(pixels);
        return CHALK_ERR_WIC_INIT_FAILED;
    }

    // new (not malloc): ChalkImageOpaque has non-trivial default member
    // initializers (see chalk_internal.h) that must actually run so
    // `bitmap` starts life as nullptr on every path below, including the
    // early-return ones. Matched by `delete img` in chalk_image_destroy.
    ChalkImageOpaque* img = new (std::nothrow) ChalkImageOpaque();
    if (!img) {
        free(pixels);
        return CHALK_ERR_OUT_OF_MEMORY;
    }
    img->pixels = pixels;
    img->width = static_cast<int32_t>(width);
    img->height = static_cast<int32_t>(height);
    img->stride = static_cast<int32_t>(stride);

    // Construct the GDI+ Bitmap directly over `pixels`' storage, exactly
    // like ChalkRenderTargetOpaque::bitmap in chalk_render.cpp, so
    // chalk_rt_draw_image can composite this image with no conversion step.
    // The converter above produced GUID_WICPixelFormat32bppPBGRA (premultiplied
    // B,G,R,A byte order in memory), which is the same in-memory layout as
    // GDI+'s PixelFormat32bppPARGB.
    try {
        img->bitmap = new Gdiplus::Bitmap(static_cast<INT>(width), static_cast<INT>(height),
                                           static_cast<INT>(stride), PixelFormat32bppPARGB,
                                           static_cast<BYTE*>(img->pixels));
    } catch (const std::bad_alloc&) {
        free(img->pixels);
        delete img;
        return CHALK_ERR_OUT_OF_MEMORY;
    }
    if (img->bitmap->GetLastStatus() != Gdiplus::Ok) {
        delete img->bitmap;
        free(img->pixels);
        delete img;
        return CHALK_ERR_DECODE_FAILED;
    }

    *out_image = reinterpret_cast<ChalkImage>(img);
    *out_width = static_cast<int32_t>(width);
    *out_height = static_cast<int32_t>(height);
    return CHALK_OK;
}

void chalk_image_destroy(ChalkImage image) {
    if (!image) {
        return;
    }
    ChalkImageOpaque* img = reinterpret_cast<ChalkImageOpaque*>(image);
    delete img->bitmap;   // must be destroyed before freeing the pixel storage it wraps.
    free(img->pixels);
    delete img;
}

int32_t chalk_image_encode_png(const uint8_t* bgra, int32_t width, int32_t height,
                                int32_t stride, uint8_t** out_bytes, int32_t* out_len) {
    if (!bgra || !out_bytes || !out_len || width <= 0 || height <= 0 ||
        stride <= 0 || stride < width * 4) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }

    ComInitGuard com;
    if (!com.usable()) {
        return CHALK_ERR_WIC_INIT_FAILED;
    }

    IWICImagingFactory* factory = CreateWicFactory();
    if (!factory) {
        return CHALK_ERR_WIC_INIT_FAILED;
    }

    // PNG wants straight alpha; everything crossing this shim's boundary
    // otherwise (render target buffer, decoded ChalkImage) is premultiplied.
    const int32_t dstStride = width * 4;
    const size_t dstSize = static_cast<size_t>(dstStride) * static_cast<size_t>(height);
    uint8_t* straight = static_cast<uint8_t*>(malloc(dstSize));
    if (!straight) {
        factory->Release();
        return CHALK_ERR_OUT_OF_MEMORY;
    }
    UnpremultiplyBgraToStraight(bgra, width, height, stride, straight);

    // CreateStreamOnHGlobal(NULL, TRUE, ...) allocates its own HGLOBAL and
    // frees it automatically when the stream is Release()'d (fDeleteOnRelease
    // = TRUE) -- we copy the encoded bytes out into our own malloc'd buffer
    // before that release, so no separate GlobalFree is needed here.
    IStream* stream = nullptr;
    HRESULT hr = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
    if (FAILED(hr)) {
        free(straight);
        factory->Release();
        return CHALK_ERR_ENCODE_FAILED;
    }

    IWICBitmapEncoder* encoder = nullptr;
    hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
    if (SUCCEEDED(hr)) {
        hr = encoder->Initialize(stream, WICBitmapEncoderNoCache);
    }

    IWICBitmapFrameEncode* frame = nullptr;
    if (SUCCEEDED(hr)) {
        // Passing NULL for the encoder-options out-param is documented as
        // valid when the caller does not need to set any PNG-specific
        // options (we don't).
        hr = encoder->CreateNewFrame(&frame, nullptr);
    }
    if (SUCCEEDED(hr)) {
        hr = frame->Initialize(nullptr);
    }
    if (SUCCEEDED(hr)) {
        hr = frame->SetSize(static_cast<UINT>(width), static_cast<UINT>(height));
    }
    WICPixelFormatGUID pixelFormat = GUID_WICPixelFormat32bppBGRA;
    if (SUCCEEDED(hr)) {
        hr = frame->SetPixelFormat(&pixelFormat);
    }
    if (SUCCEEDED(hr) && !IsEqualGUID(pixelFormat, GUID_WICPixelFormat32bppBGRA)) {
        // The encoder negotiated a different pixel format than the straight
        // BGRA bytes we can supply -- treat as a failure rather than write
        // mismatched pixels silently.
        hr = E_FAIL;
    }
    if (SUCCEEDED(hr)) {
        hr = frame->WritePixels(static_cast<UINT>(height), static_cast<UINT>(dstStride),
                                 static_cast<UINT>(dstSize), straight);
    }
    if (SUCCEEDED(hr)) {
        hr = frame->Commit();
    }
    if (SUCCEEDED(hr)) {
        hr = encoder->Commit();
    }

    if (frame) frame->Release();
    if (encoder) encoder->Release();
    free(straight);

    if (FAILED(hr)) {
        stream->Release();
        factory->Release();
        return CHALK_ERR_ENCODE_FAILED;
    }

    HGLOBAL hGlobal = nullptr;
    hr = GetHGlobalFromStream(stream, &hGlobal);
    if (FAILED(hr) || !hGlobal) {
        stream->Release();
        factory->Release();
        return CHALK_ERR_ENCODE_FAILED;
    }

    const SIZE_T size = GlobalSize(hGlobal);
    void* locked = GlobalLock(hGlobal);
    if (!locked || size == 0) {
        if (locked) GlobalUnlock(hGlobal);
        stream->Release();
        factory->Release();
        return CHALK_ERR_ENCODE_FAILED;
    }

    uint8_t* out = static_cast<uint8_t*>(malloc(size));
    if (!out) {
        GlobalUnlock(hGlobal);
        stream->Release();
        factory->Release();
        return CHALK_ERR_OUT_OF_MEMORY;
    }
    memcpy(out, locked, size);
    GlobalUnlock(hGlobal);

    stream->Release(); // frees hGlobal (fDeleteOnRelease = TRUE above)
    factory->Release();

    *out_bytes = out;
    *out_len = static_cast<int32_t>(size);
    return CHALK_OK;
}

void chalk_image_free_bytes(uint8_t* bytes) {
    free(bytes);
}

// =============================================================================
// Section 4 -- Capture
// =============================================================================

int32_t chalk_capture_monitor(double x, double y, double w, double h,
                               uint8_t** out_bgra, int32_t* out_w,
                               int32_t* out_h, int32_t* out_stride) {
    if (!out_bgra || !out_w || !out_h || !out_stride) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(w) || !std::isfinite(h) ||
        w <= 0 || h <= 0) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }

    const int32_t left = static_cast<int32_t>(std::lround(x));
    const int32_t top = static_cast<int32_t>(std::lround(y));
    const int32_t width = static_cast<int32_t>(std::lround(w));
    const int32_t height = static_cast<int32_t>(std::lround(h));
    if (width <= 0 || height <= 0) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }

    // GetDC(NULL) is a DC over the whole virtual desktop; its coordinate
    // space already matches the virtual-desktop coordinates this header
    // documents for every ChalkRect, including negative x/y on a monitor
    // left of/above the primary one, so `left`/`top` are used as BitBlt
    // source coordinates directly with no further translation.
    HDC screenDC = GetDC(nullptr);
    if (!screenDC) {
        return CHALK_ERR_CAPTURE_FAILED;
    }

    HDC memDC = CreateCompatibleDC(screenDC);
    if (!memDC) {
        ReleaseDC(nullptr, screenDC);
        return CHALK_ERR_CAPTURE_FAILED;
    }

    BITMAPINFO bmi;
    ZeroMemory(&bmi, sizeof(bmi));
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = width;
    bmi.bmiHeader.biHeight = -height; // negative => top-down DIB
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    void* bits = nullptr;
    HBITMAP dib = CreateDIBSection(screenDC, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!dib || !bits) {
        if (dib) DeleteObject(dib);
        DeleteDC(memDC);
        ReleaseDC(nullptr, screenDC);
        return CHALK_ERR_CAPTURE_FAILED;
    }

    HGDIOBJ oldBitmap = SelectObject(memDC, dib);
    // CAPTUREBLT so layered/WS_EX_LAYERED windows (e.g. this app's own
    // overlay) are captured exactly as composited on screen, per the
    // header's doc comment on this function.
    const BOOL blitOk = BitBlt(memDC, 0, 0, width, height, screenDC, left, top,
                                SRCCOPY | CAPTUREBLT);
    SelectObject(memDC, oldBitmap);

    if (!blitOk) {
        DeleteObject(dib);
        DeleteDC(memDC);
        ReleaseDC(nullptr, screenDC);
        return CHALK_ERR_CAPTURE_FAILED;
    }

    const int32_t stride = width * 4;
    const size_t bufSize = static_cast<size_t>(stride) * static_cast<size_t>(height);
    uint8_t* out = static_cast<uint8_t*>(malloc(bufSize));
    if (!out) {
        DeleteObject(dib);
        DeleteDC(memDC);
        ReleaseDC(nullptr, screenDC);
        return CHALK_ERR_OUT_OF_MEMORY;
    }
    memcpy(out, bits, bufSize);

    DeleteObject(dib);
    DeleteDC(memDC);
    ReleaseDC(nullptr, screenDC);

    // BitBlt/GDI copies RGB only -- it does NOT composite or otherwise set
    // an alpha channel, so the 4th byte of every captured pixel is left
    // undefined (historically just whatever garbage was in the DIB's
    // memory). If this buffer were returned as-is and a caller treated it
    // as straight BGRA (e.g. compositing it back through
    // chalk_rt_draw_image, or piping it into chalk_image_encode_png), the
    // undefined/zero alpha would make the whole capture render fully
    // transparent -- a classic, silent BitBlt bug. A screen capture is
    // always fully opaque, so force alpha to 255 across the buffer before
    // returning it.
    for (size_t i = 3; i < bufSize; i += 4) {
        out[i] = 255;
    }

    *out_bgra = out;
    *out_w = width;
    *out_h = height;
    *out_stride = stride;
    return CHALK_OK;
}

void chalk_capture_free(uint8_t* bgra) {
    free(bgra);
}

int32_t chalk_window_set_excluded_from_capture(void* hwnd, int32_t excluded) {
    if (!hwnd) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    const HWND h = static_cast<HWND>(hwnd);
    const DWORD affinity = excluded ? static_cast<DWORD>(WDA_EXCLUDEFROMCAPTURE)
                                     : static_cast<DWORD>(WDA_NONE);
    // SetWindowDisplayAffinity returning FALSE covers both an invalid hwnd
    // and this Windows build predating WDA_EXCLUDEFROMCAPTURE support
    // (introduced in Windows 10 2004) -- the header's doc comment on
    // CHALK_ERR_DISPLAY_AFFINITY_FAILED explicitly folds both cases into
    // this one code, so the caller sees an honest failure (never a false
    // "exclusion applied") either way; it has no separate code to
    // distinguish "too old" from "invalid handle".
    const BOOL ok = SetWindowDisplayAffinity(h, affinity);
    if (!ok) {
        return CHALK_ERR_DISPLAY_AFFINITY_FAILED;
    }
    return CHALK_OK;
}

#else // _WIN32

// Portable stubs so this translation unit compiles on non-Windows platforms
// (macOS). Every function returns the most fitting "unavailable" error code
// (or is a harmless no-op for void-returning functions) -- WIC and GDI
// simply do not exist there, and AIChalkboardCore does not link this target
// on macOS in the first place (see Package.swift).

int32_t chalk_image_decode_file(const uint16_t* path, ChalkImage* out_image,
                                 int32_t* out_width, int32_t* out_height) {
    (void)path;
    (void)out_image;
    (void)out_width;
    (void)out_height;
    return CHALK_ERR_WIC_INIT_FAILED;
}

void chalk_image_destroy(ChalkImage image) {
    (void)image;
}

int32_t chalk_image_encode_png(const uint8_t* bgra, int32_t width, int32_t height,
                                int32_t stride, uint8_t** out_bytes, int32_t* out_len) {
    (void)bgra;
    (void)width;
    (void)height;
    (void)stride;
    (void)out_bytes;
    (void)out_len;
    return CHALK_ERR_WIC_INIT_FAILED;
}

void chalk_image_free_bytes(uint8_t* bytes) {
    (void)bytes;
}

int32_t chalk_capture_monitor(double x, double y, double w, double h,
                               uint8_t** out_bgra, int32_t* out_w,
                               int32_t* out_h, int32_t* out_stride) {
    (void)x;
    (void)y;
    (void)w;
    (void)h;
    (void)out_bgra;
    (void)out_w;
    (void)out_h;
    (void)out_stride;
    return CHALK_ERR_CAPTURE_FAILED;
}

void chalk_capture_free(uint8_t* bgra) {
    (void)bgra;
}

int32_t chalk_window_set_excluded_from_capture(void* hwnd, int32_t excluded) {
    (void)hwnd;
    (void)excluded;
    return CHALK_ERR_DISPLAY_AFFINITY_FAILED;
}

#endif // _WIN32
