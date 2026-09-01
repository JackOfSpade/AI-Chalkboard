// chalk_internal.h
//
// Shared, NON-public type definitions used across this target's .cpp shim
// files (chalk_render.cpp today; the future images/UIA/capture .cpp files
// implementing chalkboard_win.h's sections 2-4 tomorrow). This header is
// NOT under include/, so it never crosses the module boundary to Swift --
// Package.swift's publicHeadersPath is "include", meaning only
// chalkboard_win.h is part of this target's public interface. Everything
// declared here is free to use full C++ (classes, STL containers, GDI+
// types) since none of it has to satisfy the extern-"C"-only rule that
// governs chalkboard_win.h itself.
//
// It exists to give the opaque handles chalkboard_win.h declares --
// ChalkRenderTarget (== struct ChalkRenderTargetOpaque*) and ChalkImage
// (== struct ChalkImageOpaque*) -- one authoritative internal layout that
// every .cpp file including this header can construct, read, and destroy
// consistently. In particular, chalk_render.cpp's chalk_rt_draw_image needs
// to read a decoded ChalkImage's pixel data, and whichever .cpp file later
// implements section 2 (chalk_image_decode_file et al.) needs to CREATE a
// ChalkImageOpaque with this exact shape for that to work without a
// conversion step.
//
// Defining the struct bodies here (rather than in chalkboard_win.h) is safe
// and intentional: `extern "C"` only affects the linkage of functions and
// variables, never type declarations, so a plain C++ struct definition is
// legal to attach to a tag that chalkboard_win.h's `typedef struct
// FooOpaque* Foo;` only forward-declared inside its extern "C" block (the
// same reasoning chalkboard_win.h documents for its `enum ... : int32_t`
// declarations).

#pragma once

#include "include/chalkboard_win.h"

#ifdef _WIN32

#ifndef NOMINMAX
#define NOMINMAX
#endif
// Deliberately NOT defining WIN32_LEAN_AND_MEAN: it strips OLE/COM
// declarations (IStream, IUnknown, ...) that the GDI+ headers below need
// (e.g. Image::Save(IStream*, ...)) -- without them GdiplusBitmap.h and
// friends fail to parse.
#include <windows.h>
#include <objidl.h>  // IStream -- required by the GDI+ headers below.

// Some Windows SDK versions of the GDI+ headers reference std::min/std::max
// without including <algorithm> themselves; include it first defensively so
// this header builds regardless of SDK version, alongside NOMINMAX above so
// windows.h's own min/max macros never shadow the std:: versions.
#include <algorithm>
#include <gdiplus.h>

#include <vector>

// Backs a ChalkRenderTarget (chalkboard_win.h section 1). Owns the pixel
// buffer, the GDI+ Bitmap/Graphics pair over it, and the save/restore +
// global-alpha state chalk_rt_save/chalk_rt_restore/chalk_rt_set_global_alpha
// manage. See chalk_render.cpp for the functions that operate on this.
struct ChalkRenderTargetOpaque {
    int32_t width = 0;
    int32_t height = 0;
    int32_t stride = 0;
    // Top-down, premultiplied BGRA (PixelFormat32bppPARGB), `stride` bytes
    // per row. `bitmap` is constructed directly over this vector's storage
    // (Gdiplus::Bitmap's caller-owned-buffer constructor), so this vector
    // must never be resized/reallocated after chalk_rt_create populates it
    // -- doing so would leave `bitmap` pointing at freed memory.
    std::vector<uint8_t> pixels;
    Gdiplus::Bitmap* bitmap = nullptr;
    Gdiplus::Graphics* graphics = nullptr;
    // chalk_rt_save/chalk_rt_restore stack. GDI+'s Graphics::Save returns an
    // opaque GraphicsState token rather than maintaining its own visible
    // stack, so the render target keeps one here itself, alongside the
    // global alpha value in effect at each save point (global alpha is NOT
    // part of GDI+'s own graphics state, so it has to be captured/restored
    // by hand in parallel -- see the section-1 NOTE in chalkboard_win.h).
    std::vector<Gdiplus::GraphicsState> stateStack;
    std::vector<double> alphaStack;
    double globalAlpha = 1.0;
};

// Backs a ChalkImage (chalkboard_win.h section 2). Populated by whichever
// .cpp implements chalk_image_decode_file (WIC decode -> premultiplied
// BGRA), and read by chalk_rt_draw_image in chalk_render.cpp to composite
// the decoded bitmap onto a render target. `bitmap` must be constructed
// with pixel format PixelFormat32bppPARGB directly over `pixels`' storage,
// exactly like ChalkRenderTargetOpaque::bitmap above, so the two share
// identical premultiplication semantics and chalk_rt_draw_image never needs
// a conversion step.
// NOTE: `pixels` is a plain malloc'd buffer (not std::vector<uint8_t>) --
// chalk_image.cpp (the .cpp that actually populates/destroys this struct)
// allocates and frees it with malloc/free throughout, consistent with the
// C-style allocation chalk_image_decode_file/chalk_image_destroy already
// use for the ChalkImageOpaque struct itself. `bitmap` is constructed
// directly over `pixels`' storage (Gdiplus::Bitmap's caller-owned-buffer
// constructor, exactly like ChalkRenderTargetOpaque::bitmap above), so
// `pixels` must never move/be reallocated for as long as `bitmap` is alive.
struct ChalkImageOpaque {
    int32_t width = 0;
    int32_t height = 0;
    int32_t stride = 0;
    uint8_t* pixels = nullptr;
    Gdiplus::Bitmap* bitmap = nullptr;
};

#endif // _WIN32
