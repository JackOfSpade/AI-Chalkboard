// chalkboard_win.cpp
//
// Implementation for the C shim declared in include/chalkboard_win.h. This
// target exists because GDI+, WIC, and UI Automation are C++/COM APIs that
// Swift cannot import directly -- everything reachable from Swift has to be
// plain C (`extern "C"`), so the real Windows-specific bodies live in here,
// in C++, behind that C surface.
//
// The ENTIRE Windows-specific body of every function in this file must
// stay inside `#ifdef _WIN32`, with a portable stub in `#else`, so that this
// translation unit compiles cleanly (to effectively nothing) on macOS. In
// practice AIChalkboardCore does not even depend on this target on macOS
// (see Package.swift), but keeping the file itself portable means it is
// never a Windows-only compile hazard even if that dependency graph
// changes.

#include "include/chalkboard_win.h"

#ifdef _WIN32

// NOTE: no Windows/COM headers are pulled in yet -- this is a skeleton.
// Later work in this target will #include <windows.h>, <gdiplus.h>,
// <wincodec.h>, and the UI Automation headers as real functionality is
// added here.

int32_t chalkboard_win_abi_version(void) {
    return 1;
}

#else

// Portable stub so this translation unit compiles on non-Windows platforms
// (macOS). Not expected to actually run there -- AIChalkboardCore does not
// link this target on macOS -- but the file must still be valid C++
// wherever SwiftPM evaluates it.
int32_t chalkboard_win_abi_version(void) {
    return 0;
}

#endif // _WIN32
