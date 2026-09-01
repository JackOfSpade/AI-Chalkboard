// chalk_uia.cpp
//
// Implementation of Section 3 (UI Automation) of the C shim declared in
// include/chalkboard_win.h: chalk_uia_find_element and
// chalk_uia_sample_names. Mirrors the contract AccessibilityElementResolver
// documents on macOS (Sources/Overlay/AccessibilityElementResolver.swift) --
// every distinction that resolver's error taxonomy makes is preserved here
// as its own ChalkErrorCode.
//
// As with every other .cpp in this target, the ENTIRE Windows-specific body
// lives inside `#ifdef _WIN32` with a portable `#else` stub, so this
// translation unit still compiles (to effectively nothing useful) when
// SwiftPM evaluates the target on macOS.
//
// -----------------------------------------------------------------------
// THREADING MODEL -- READ THIS BEFORE TOUCHING THE TIMEOUT/CLEANUP CODE
// -----------------------------------------------------------------------
// Every UIA call in this file runs on a DEDICATED worker thread that this
// file creates per call (via _beginthreadex, so the CRT's per-thread state
// is initialized/torn down correctly for the STL containers used below --
// prefer this over raw CreateThread whenever the thread body uses the CRT).
// That worker calls CoInitializeEx(NULL, COINIT_MULTITHREADED) once, does
// all of its COM/UIA work, and calls CoUninitialize before it exits.
//
// The calling thread never talks to UIA directly. Instead it hands the
// request to the worker and calls WaitForSingleObject(hThread, timeoutMs).
// This exists because a UIA call into a hung/frozen provider (a target
// application that stopped pumping messages, or whose UI Automation
// provider deadlocked) blocks the calling thread INDEFINITELY -- there is
// no per-call cancellation in classic (non-IUIAutomation2) UI Automation.
// This shim's caller is an MCP request handler that must never wedge, so
// bounding the WAIT is non-negotiable even when the call itself cannot be
// bounded.
//
// BE HONEST ABOUT WHAT THIS DOES AND DOES NOT BUY US:
//   - WaitForSingleObject only stops US from waiting. It does not, and
//     cannot, reach into a stuck COM call and cancel it. If the provider is
//     truly hung, the worker thread keeps blocking inside UIA forever (or
//     until the target process dies/recovers), and we deliberately LEAK
//     that thread rather than terminate it: TerminateThread on a thread
//     stopped mid-COM-call would corrupt the process's COM/CRT state far
//     worse than a leaked thread does. See the request/disposition
//     handshake below for how we avoid a use-after-free of the *request*
//     object in this situation even though the thread itself outlives the
//     call.
//   - This is a REAL, KNOWN regression versus macOS, where
//     AXUIElementSetMessagingTimeout gives the OS itself a per-call bound
//     enforced by the Accessibility server -- a hung AX provider still
//     returns (with an error) within that bound, and no thread is ever
//     leaked. Windows classic UI Automation has no equivalent knob.
//   - IUIAutomation2::ConnectionTimeout / TransactionTimeout (used below
//     whenever QueryInterface for IUIAutomation2 succeeds) DOES give a real
//     OS/RPC-enforced per-call bound, which materially narrows the gap: on
//     a system where the target's provider is reachable via IUIAutomation2,
//     the underlying COM calls themselves time out close to
//     `timeout_seconds`, and the worker thread returns normally instead of
//     hanging. The leak above is the residual risk on the IUIAutomation1
//     fallback path (no IUIAutomation2 available) or if a provider ignores
//     the RPC timeout outright.
//
// REQUEST OWNERSHIP HANDOFF (avoids use-after-free / double-free):
// The request struct is heap-allocated and crosses threads. Exactly one
// side must free it. We arbitrate this with a single atomic<int>
// `disposition` on the request, using atomic exchange as a hand off baton:
//   - The calling thread, on a clean WaitForSingleObject(WAIT_OBJECT_0),
//     knows the worker has fully returned (thread termination is a proper
//     synchronization point), so it reads the results and deletes the
//     request directly -- no atomics needed on that path.
//   - On WAIT_TIMEOUT, the calling thread must not touch *req again (the
//     worker may still be writing to it). It calls
//     `req->disposition.exchange(kCallerAbandoned)`. If that returns
//     kWorkerFinished (the rare race where the worker finished in the
//     instant between the timeout firing and this exchange), the calling
//     thread now owns req and deletes it. Otherwise the worker, whenever it
//     eventually finishes, will see kCallerAbandoned via its own exchange
//     and delete req itself.
//   - The worker, at the very end of its run, calls
//     `req->disposition.exchange(kWorkerFinished)`. If that returns
//     kCallerAbandoned, the worker deletes req. Otherwise it leaves req
//     alone for the calling thread to collect via the happy path above.
// Exactly one of the two `exchange` calls observes the other side's
// stamped value first, and that side is unambiguously the one responsible
// for deleting -- there is no window where both or neither delete it.

#include "include/chalkboard_win.h"

#ifdef _WIN32

#ifndef NOMINMAX
#define NOMINMAX // keep <windows.h> from defining min/max macros that would
                  // shadow <algorithm>'s std::min/std::max and friends.
#endif

#include <windows.h>
#include <process.h>   // _beginthreadex
#include <oleauto.h>   // BSTR / SysFreeString / SysStringLen
#include <uiautomation.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cwctype>
#include <deque>
#include <string>
#include <unordered_set>
#include <vector>

#ifndef UIA_E_ELEMENTNOTAVAILABLE
#define UIA_E_ELEMENTNOTAVAILABLE _HRESULT_TYPEDEF_(0x80040201L)
#endif

namespace {

// ---------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------

// Minimal move-only RAII wrapper for a raw COM pointer. We hand-roll this
// instead of pulling in ATL's CComPtr because this target does not link
// atls.lib (see Package.swift's Windows link list), and WRL::ComPtr would
// pull in another header dependency for no real benefit here.
template <typename T>
class ComPtr {
public:
    ComPtr() = default;
    explicit ComPtr(T* ptr) : ptr_(ptr) {}
    ComPtr(const ComPtr&) = delete;
    ComPtr& operator=(const ComPtr&) = delete;
    ComPtr(ComPtr&& other) noexcept : ptr_(other.ptr_) { other.ptr_ = nullptr; }
    ComPtr& operator=(ComPtr&& other) noexcept {
        if (this != &other) {
            Reset();
            ptr_ = other.ptr_;
            other.ptr_ = nullptr;
        }
        return *this;
    }
    ~ComPtr() { Reset(); }

    void Reset(T* np = nullptr) {
        if (ptr_) ptr_->Release();
        ptr_ = np;
    }
    // For use as an out-parameter target: releases any prior value and
    // returns the address to receive the new one.
    T** ReceiveAddress() {
        Reset();
        return &ptr_;
    }
    T* Get() const { return ptr_; }
    T* operator->() const { return ptr_; }
    explicit operator bool() const { return ptr_ != nullptr; }

private:
    T* ptr_ = nullptr;
};

// RAII around CoInitializeEx/CoUninitialize so every early-return path in
// the worker functions below tears COM down correctly without needing
// manual bookkeeping.
class ComApartment {
public:
    explicit ComApartment(DWORD coinit) { hr_ = CoInitializeEx(nullptr, coinit); }
    ~ComApartment() {
        if (SUCCEEDED(hr_)) CoUninitialize();
    }
    bool Ok() const { return SUCCEEDED(hr_); }

private:
    HRESULT hr_ = E_FAIL;
};

// Disposition values for the request/worker cleanup handshake documented at
// the top of this file.
enum : int {
    kPending = 0,
    kWorkerFinished = 1,
    kCallerAbandoned = 2,
};

// NOTE: IUIAutomationElement::get_CurrentBoundingRectangle (used below)
// fills in a plain Win32 RECT (left/top/right/bottom, LONG), NOT the
// UiaRect (left/top/width/height, double) struct that name might suggest --
// UiaRect is used elsewhere in the UIA client API (e.g. some pattern
// properties/events), but not on IUIAutomationElement itself. RECT's LONG
// fields are always "finite" by construction (no NaN/infinity in an
// integer), so the finiteness check that mattered for a double-based rect
// collapses to just checking a positive width/height here.
bool IsUsableUiaRect(const RECT& r) {
    return (r.right - r.left) > 0 && (r.bottom - r.top) > 0;
}

ChalkRect ToChalkRect(const RECT& r) {
    ChalkRect out;
    out.x = r.left;
    out.y = r.top;
    out.w = r.right - r.left;
    out.h = r.bottom - r.top;
    return out;
}

// A COM call HRESULT that indicates the provider (or the RPC channel to it)
// timed out or died mid-call rather than answering. See
// CHALK_ERR_UIA_RETRYABLE_TIMEOUT's doc comment in the header for the
// intended scope of this mapping.
bool IsRetryableTimeoutHResult(HRESULT hr) {
    return hr == RPC_E_TIMEOUT ||
           hr == static_cast<HRESULT>(HRESULT_FROM_WIN32(ERROR_TIMEOUT)) ||
           hr == CO_E_SERVER_EXEC_FAILURE;
}

// A COM call HRESULT that indicates a UIPI privilege boundary blocked us
// (elevated target, this process not elevated). See
// CHALK_ERR_UIA_ACCESS_DENIED's doc comment in the header.
bool IsAccessDeniedHResult(HRESULT hr) {
    return hr == E_ACCESSDENIED || hr == UIA_E_ELEMENTNOTAVAILABLE;
}

// `s` is a caller-owned, NUL-terminated UTF-16 buffer (see the header's
// string-crossing-the-boundary note). wchar_t is 16 bits on every Windows
// target this shim builds for, so treating a `const uint16_t*` as UTF-16
// text via wchar_t is the standard, expected interop pattern here (the
// header explicitly chose uint16_t over wchar_t only so it stays parseable
// as plain C on the macOS side, not because the underlying encoding is
// different).
static_assert(sizeof(wchar_t) == 2, "This file assumes 16-bit wchar_t (Windows).");

std::wstring Utf16ToWString(const uint16_t* s) {
    if (!s) return std::wstring();
    size_t len = 0;
    while (s[len] != 0) ++len;
    return std::wstring(reinterpret_cast<const wchar_t*>(s), len);
}

std::wstring BstrToWString(BSTR b) {
    if (!b) return std::wstring();
    return std::wstring(reinterpret_cast<const wchar_t*>(b), SysStringLen(b));
}

bool ContainsCaseInsensitive(const std::wstring& haystack, const std::wstring& needle) {
    if (needle.empty()) return true;
    if (needle.size() > haystack.size()) return false;
    auto it = std::search(
        haystack.begin(), haystack.end(), needle.begin(), needle.end(),
        [](wchar_t a, wchar_t b) { return std::towlower(a) == std::towlower(b); });
    return it != haystack.end();
}

// Clamp a caller-supplied timeout (seconds) to a DWORD millisecond value
// safe to pass to WaitForSingleObject / IUIAutomation2's timeout setters.
// Never returns 0 (which would make WaitForSingleObject poll instead of
// wait) and never returns INFINITE.
DWORD TimeoutSecondsToMs(double seconds) {
    const double kMaxMs = 3600.0 * 1000.0 * 24.0; // 24h ceiling, comfortably below INFINITE
    double ms = seconds * 1000.0;
    if (!(ms > 1.0)) ms = 1.0;
    if (ms > kMaxMs) ms = kMaxMs;
    return static_cast<DWORD>(ms);
}

// Finds the visible top-level windows owned by `pid`. UI Automation has no
// pid -> root-element API, so this is the standard way in: enumerate
// top-level windows, filter by owning process and visibility, and resolve
// each surviving HWND to an element with ElementFromHandle.
struct EnumWindowsContext {
    DWORD pid;
    std::vector<HWND>* windows;
};

BOOL CALLBACK EnumWindowsForProcessProc(HWND hwnd, LPARAM lparam) {
    auto* ctx = reinterpret_cast<EnumWindowsContext*>(lparam);
    if (!IsWindowVisible(hwnd)) return TRUE;
    DWORD windowPid = 0;
    GetWindowThreadProcessId(hwnd, &windowPid);
    if (windowPid == ctx->pid) {
        ctx->windows->push_back(hwnd);
    }
    return TRUE;
}

std::vector<HWND> FindTopLevelWindowsForProcess(DWORD pid) {
    std::vector<HWND> result;
    EnumWindowsContext ctx{pid, &result};
    EnumWindows(EnumWindowsForProcessProc, reinterpret_cast<LPARAM>(&ctx));
    return result;
}

// Creates the IUIAutomation client, and applies the caller's timeout as a
// real OS-enforced per-call bound via IUIAutomation2 when that interface is
// available (see the threading-model comment at the top of the file for
// why this matters). Returns CHALK_OK on success.
//
// Uses the __uuidof(...)-based CoCreateInstance/QueryInterface shape (GUID
// looked up from the interface/coclass type itself) rather than the
// separately-named CLSID_CUIAutomation/IID_IUIAutomation* constants,
// because that is the exact call shape this project already proved
// compiles and runs correctly on this toolchain (see the "PROVEN ALREADY"
// UI Automation smoke test this port is built from).
int32_t CreateAutomationClient(DWORD timeoutMs, ComPtr<IUIAutomation>* outAutomation) {
    ComPtr<IUIAutomation> automation;
    HRESULT hr = CoCreateInstance(__uuidof(CUIAutomation), nullptr, CLSCTX_INPROC_SERVER,
                                   __uuidof(IUIAutomation),
                                   reinterpret_cast<void**>(automation.ReceiveAddress()));
    if (FAILED(hr) || !automation) {
        return CHALK_ERR_UIA_UNAVAILABLE;
    }

    // IUIAutomation2 is a strict superset (inherits IUIAutomation), so on
    // success we can keep using `automation` (still a valid IUIAutomation*)
    // for everything else and only needed the -2 pointer transiently to set
    // the timeouts.
    ComPtr<IUIAutomation2> automation2;
    if (SUCCEEDED(automation.Get()->QueryInterface(
            __uuidof(IUIAutomation2), reinterpret_cast<void**>(automation2.ReceiveAddress())))) {
        automation2->put_ConnectionTimeout(timeoutMs);
        automation2->put_TransactionTimeout(timeoutMs);
    }
    // If IUIAutomation2 is unavailable we silently fall back to plain
    // IUIAutomation with no OS-enforced per-call bound -- this is exactly
    // the residual-risk path the threading-model comment above documents.

    *outAutomation = std::move(automation);
    return CHALK_OK;
}

// ---------------------------------------------------------------------
// Outstanding-worker cap
// ---------------------------------------------------------------------
//
// The threading-model comment at the top of this file explains why a
// worker stuck inside a truly hung UIA provider call is deliberately
// LEAKED rather than terminated -- TerminateThread mid-COM-call would
// corrupt the process's COM/CRT state worse than a leaked thread does.
// That design choice means a single local process that owns a top-level
// window and simply never pumps its message queue again (no special
// coding required -- Sleep() in the message loop is enough) turns every
// call this file makes against that pid into one more permanently-blocked
// worker thread. Verified empirically: IUIAutomation2's ConnectionTimeout/
// TransactionTimeout (set in CreateAutomationClient) does NOT reliably
// bound this -- against a plain non-pumping window the underlying COM call
// can still hang past the RPC timeout, so the "residual risk" the
// threading-model comment calls an edge case is in practice the common
// case for this trivial attack. Worse, CHALK_ERR_UIA_RETRYABLE_TIMEOUT's
// own contract tells callers a timeout is "usually worth a retry", so the
// natural response to the failure is the one that multiplies it: repeated
// calls (whether an MCP agent following that advice, or a hostile caller
// doing it deliberately) leak one more thread each time, with nothing in
// this file previously capping how many could accumulate.
//
// We cannot stop an individual leak once a worker is committed to a hung
// COM call -- that is the whole point of the leak-don't-terminate design.
// What we CAN do is bound how many such leaks are allowed to accumulate
// before we refuse to create more. Every worker this file spawns (both
// FindElementThreadProc and SampleNamesThreadProc share one cap, since
// both are exposed to the identical hung-provider scenario) reserves a
// slot here before the OS thread is created and releases it right before
// the worker function returns -- so a slot stays held for exactly as long
// as that thread is alive, including for however long it stays genuinely
// stuck. Once kMaxOutstandingUiaWorkers slots are held, new calls fail
// immediately with the dedicated, explicitly non-retryable
// CHALK_ERR_UIA_TOO_MANY_PENDING instead of spawning yet another thread --
// this is what actually bounds worst-case leaked threads, independent of
// retry count or how many distinct targets a caller tries.
constexpr int kMaxOutstandingUiaWorkers = 24;
std::atomic<int> g_outstandingUiaWorkers{0};

// Reserves one of the kMaxOutstandingUiaWorkers slots above (a try-acquire,
// not a blocking wait -- callers that fail to acquire must fail fast, not
// queue, or a burst of calls against a hung target would just serialize
// into the same unbounded pending pile this cap exists to prevent). Must
// be paired with exactly one ReleaseUiaWorkerSlot() call: either here
// inline (if the thread never actually starts) or at the top of the
// worker's own thread proc once its Run*Worker call returns.
bool TryAcquireUiaWorkerSlot() {
    int prev = g_outstandingUiaWorkers.fetch_add(1, std::memory_order_acq_rel);
    if (prev >= kMaxOutstandingUiaWorkers) {
        g_outstandingUiaWorkers.fetch_sub(1, std::memory_order_acq_rel);
        return false;
    }
    return true;
}

void ReleaseUiaWorkerSlot() {
    g_outstandingUiaWorkers.fetch_sub(1, std::memory_order_acq_rel);
}

// ---------------------------------------------------------------------
// chalk_uia_find_element
// ---------------------------------------------------------------------

struct FindElementRequest {
    // Inputs, copied/owned here so the worker never touches caller memory
    // (the caller's `name` pointer is only valid for the duration of the
    // synchronous call, which may end -- from the caller's point of view --
    // before this worker is done, per the leaked-thread scenario above).
    DWORD process_id = 0;
    std::wstring name;
    int32_t match_mode = CHALK_UIA_MATCH_EXACT;
    int32_t occurrence = 0;
    int32_t max_nodes = 0;
    double timeout_seconds = 0.0;

    // Ownership handshake -- see the file-level comment.
    std::atomic<int> disposition{kPending};

    // Outputs.
    int32_t result = CHALK_ERR_INTERNAL;
    ChalkRect bounds{};
    int32_t match_count = 0;
    int32_t frameless_count = 0;
    bool write_bounds = false;
    bool write_match_count = false;
    bool write_frameless_count = false;
};

void RunFindElementWorker(FindElementRequest* req) {
    ComApartment com(COINIT_MULTITHREADED);
    if (!com.Ok()) {
        req->result = CHALK_ERR_UIA_UNAVAILABLE;
        return;
    }

    const DWORD timeoutMs = TimeoutSecondsToMs(req->timeout_seconds);

    ComPtr<IUIAutomation> automation;
    int32_t createStatus = CreateAutomationClient(timeoutMs, &automation);
    if (createStatus != CHALK_OK) {
        req->result = createStatus;
        return;
    }

    ComPtr<IUIAutomationTreeWalker> walker;
    // We deliberately use the ControlView walker (not RawView, which is
    // enormous and would make "the tree" mean something very different
    // from the macOS AX tree this mirrors) -- matches the header's own
    // rationale for this choice.
    if (FAILED(automation->get_ControlViewWalker(walker.ReceiveAddress())) || !walker) {
        req->result = CHALK_ERR_UIA_UNAVAILABLE;
        return;
    }

    std::vector<HWND> rootWindows = FindTopLevelWindowsForProcess(req->process_id);
    if (rootWindows.empty()) {
        req->result = CHALK_ERR_UIA_INVALID_PROCESS;
        return;
    }

    // NOTE ON IMPLEMENTATION STRATEGY vs. a single CreatePropertyCondition +
    // FindAll(TreeScope_Subtree, ...) call: we do a manual, budgeted
    // breadth-first walk instead, for three reasons that all trace back to
    // header-documented behavior FindAll cannot give us:
    //   1. `max_nodes` must bound elements VISITED. FindAll's internal
    //      traversal cost is not observable through its API -- a provider
    //      could walk an arbitrarily large subtree before returning, with
    //      no budget we can enforce.
    //   2. CHALK_UIA_MATCH_CONTAINS is a case-insensitive substring test.
    //      UIA property conditions only express equality (optionally
    //      case-insensitive via PropertyConditionFlags_IgnoreCase), not
    //      "contains" -- there is no condition we could hand FindAll that
    //      expresses it.
    //   3. `occurrence` names a match by BREADTH-FIRST TRAVERSAL ORDER and
    //      must be able to short-circuit the walk the instant that match is
    //      found. That requires driving traversal ourselves; FindAll only
    //      hands back a finished collection.
    // We still honor the header's ProcessId filter (via
    // get_CurrentProcessId per candidate, below) and its ControlView
    // choice -- just via manual walk rather than a condition tree.
    std::deque<ComPtr<IUIAutomationElement>> queue;
    bool anyAccessDenied = false;
    for (HWND hwnd : rootWindows) {
        IUIAutomationElement* raw = nullptr;
        HRESULT hr = automation->ElementFromHandle(hwnd, &raw);
        if (FAILED(hr) || !raw) {
            if (IsAccessDeniedHResult(hr)) anyAccessDenied = true;
            continue;
        }
        queue.emplace_back(ComPtr<IUIAutomationElement>(raw));
    }

    if (queue.empty()) {
        req->result = anyAccessDenied ? CHALK_ERR_UIA_ACCESS_DENIED
                                       : CHALK_ERR_UIA_INVALID_PROCESS;
        return;
    }

    int32_t visited = 0;
    int32_t usableCount = 0;
    int32_t framelessCount = 0;
    ChalkRect selectedRect{};
    bool foundOccurrence = false;   // occurrence > 0 path: target reached
    bool budgetExhausted = false;

    while (!queue.empty()) {
        if (req->disposition.load(std::memory_order_relaxed) == kCallerAbandoned) {
            // The calling thread already gave up and is no longer waiting
            // on us (see the file-level comment). Stop doing pointless work
            // as soon as we notice -- we still cannot abort a COM call
            // already in flight, but we can avoid burning more CPU on a
            // result nobody will read.
            return;
        }

        ++visited;
        if (visited > req->max_nodes) {
            budgetExhausted = true;
            break;
        }

        ComPtr<IUIAutomationElement> element = std::move(queue.front());
        queue.pop_front();

        BSTR nameBstr = nullptr;
        HRESULT nameHr = element->get_CurrentName(&nameBstr);
        if (IsRetryableTimeoutHResult(nameHr)) {
            req->result = CHALK_ERR_UIA_RETRYABLE_TIMEOUT;
            if (nameBstr) SysFreeString(nameBstr);
            return;
        }
        std::wstring elementName = SUCCEEDED(nameHr) ? BstrToWString(nameBstr) : std::wstring();
        if (nameBstr) SysFreeString(nameBstr);

        bool nameMatches = false;
        if (!elementName.empty()) {
            if (req->match_mode == CHALK_UIA_MATCH_CONTAINS) {
                nameMatches = ContainsCaseInsensitive(elementName, req->name);
            } else {
                nameMatches = (elementName == req->name);
            }
        }

        if (nameMatches) {
            int elementPid = 0;
            HRESULT pidHr = element->get_CurrentProcessId(&elementPid);
            bool pidMatches = SUCCEEDED(pidHr) && static_cast<DWORD>(elementPid) == req->process_id;
            if (pidMatches) {
                RECT rect{};
                HRESULT rectHr = element->get_CurrentBoundingRectangle(&rect);
                if (IsRetryableTimeoutHResult(rectHr)) {
                    req->result = CHALK_ERR_UIA_RETRYABLE_TIMEOUT;
                    return;
                }
                bool usable = SUCCEEDED(rectHr) && IsUsableUiaRect(rect);
                if (usable) {
                    ++usableCount;
                    ChalkRect cr = ToChalkRect(rect);
                    if (req->occurrence > 0) {
                        if (usableCount == req->occurrence) {
                            selectedRect = cr;
                            foundOccurrence = true;
                            break;
                        }
                    } else if (usableCount == 1) {
                        selectedRect = cr;
                    }
                } else {
                    ++framelessCount;
                }
            }
        }

        IUIAutomationElement* childRaw = nullptr;
        HRESULT childHr = walker->GetFirstChildElement(element.Get(), &childRaw);
        while (SUCCEEDED(childHr) && childRaw) {
            queue.emplace_back(ComPtr<IUIAutomationElement>(childRaw));
            IUIAutomationElement* nextRaw = nullptr;
            HRESULT siblingHr = walker->GetNextSiblingElement(childRaw, &nextRaw);
            if (FAILED(siblingHr)) break;
            childRaw = nextRaw;
        }
    }

    if (budgetExhausted) {
        req->result = CHALK_ERR_UIA_NODE_BUDGET_EXHAUSTED;
        return;
    }

    if (req->occurrence > 0) {
        if (foundOccurrence) {
            req->result = CHALK_OK;
            req->bounds = selectedRect;
            req->match_count = 1;
            req->frameless_count = framelessCount;
            req->write_bounds = req->write_match_count = req->write_frameless_count = true;
            return;
        }
        if (usableCount == 0 && framelessCount > 0) {
            req->result = CHALK_ERR_UIA_NO_USABLE_BOUNDS;
            req->frameless_count = framelessCount;
            req->write_frameless_count = true;
            return;
        }
        if (usableCount == 0) {
            req->result = CHALK_ERR_UIA_NO_MATCH;
            return;
        }
        req->result = CHALK_ERR_UIA_OCCURRENCE_OUT_OF_RANGE;
        req->match_count = usableCount;
        req->write_match_count = true;
        return;
    }

    // occurrence == 0: require exactly one usable match across the whole
    // (budget-bounded) tree.
    if (usableCount == 0) {
        if (framelessCount > 0) {
            req->result = CHALK_ERR_UIA_NO_USABLE_BOUNDS;
            req->frameless_count = framelessCount;
            req->write_frameless_count = true;
        } else {
            req->result = CHALK_ERR_UIA_NO_MATCH;
        }
        return;
    }
    if (usableCount == 1) {
        req->result = CHALK_OK;
        req->bounds = selectedRect;
        req->match_count = 1;
        req->frameless_count = framelessCount;
        req->write_bounds = req->write_match_count = req->write_frameless_count = true;
        return;
    }
    req->result = CHALK_ERR_UIA_AMBIGUOUS;
    req->match_count = usableCount;
    req->write_match_count = true;
}

unsigned __stdcall FindElementThreadProc(void* argRaw) {
    auto* req = static_cast<FindElementRequest*>(argRaw);
    RunFindElementWorker(req);
    // The worker's UIA call has returned (this line is never reached at all
    // for a worker genuinely stuck in a hung COM call -- see the
    // outstanding-worker-cap comment above), so release its slot before the
    // ownership handshake below. This keeps the cap counting threads that
    // are still actually alive/stuck, not bookkeeping in the handshake.
    ReleaseUiaWorkerSlot();
    // See the ownership-handshake comment at the top of the file.
    if (req->disposition.exchange(kWorkerFinished, std::memory_order_acq_rel) == kCallerAbandoned) {
        delete req;
    }
    return 0;
}

int32_t ValidateFindElementArgs(const uint16_t* name, int32_t match_mode, int32_t occurrence,
                                 int32_t max_nodes, double timeout_seconds,
                                 const ChalkRect* out_bounds, const int32_t* out_match_count,
                                 const int32_t* out_frameless_count) {
    if (!name || !out_bounds || !out_match_count || !out_frameless_count) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    if (name[0] == 0) return CHALK_ERR_INVALID_ARGUMENT; // empty name can never usefully match
    if (match_mode != CHALK_UIA_MATCH_EXACT && match_mode != CHALK_UIA_MATCH_CONTAINS) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    if (occurrence < 0) return CHALK_ERR_INVALID_ARGUMENT;
    if (max_nodes <= 0) return CHALK_ERR_INVALID_ARGUMENT;
    if (!(timeout_seconds > 0.0) || !std::isfinite(timeout_seconds)) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    return CHALK_OK;
}

// ---------------------------------------------------------------------
// chalk_uia_sample_names
// ---------------------------------------------------------------------

// chalk_uia_sample_names takes no caller timeout (see the header), so it
// uses its own generous, fixed internal budget -- both as the node/time
// cutoff for the walk itself and (when IUIAutomation2 is available) as the
// per-call OS-enforced bound, same technique as chalk_uia_find_element.
constexpr int32_t kSampleNamesNodeBudget = 20000;
constexpr double kSampleNamesTimeBudgetSeconds = 5.0;
// Extra slack the CALLING thread gives the worker beyond the internal
// budget above before treating it as hung and giving up on the wait. This
// is not a hard guarantee the worker actually stops by then (see the
// threading-model comment) -- it is slack for normal per-call overhead
// (COM marshaling, provider latency) on top of the walk's own budget.
constexpr double kSampleNamesOuterWaitSlackSeconds = 3.0;

struct SampleNamesRequest {
    DWORD process_id = 0;
    int32_t max_names = 0;

    std::atomic<int> disposition{kPending};

    // Result: CHALK_OK with whatever was collected (possibly empty) is the
    // only "the walk didn't fully finish" outcome this function is allowed
    // to report -- see its header doc comment ("never fails merely because
    // the tree is large"). Only argument/process/availability/access errors
    // are real failures here.
    int32_t result = CHALK_OK;
    std::vector<std::wstring> names;
};

void RunSampleNamesWorker(SampleNamesRequest* req) {
    ComApartment com(COINIT_MULTITHREADED);
    if (!com.Ok()) {
        req->result = CHALK_ERR_UIA_UNAVAILABLE;
        return;
    }

    const DWORD timeoutMs = TimeoutSecondsToMs(kSampleNamesTimeBudgetSeconds);

    ComPtr<IUIAutomation> automation;
    int32_t createStatus = CreateAutomationClient(timeoutMs, &automation);
    if (createStatus != CHALK_OK) {
        req->result = createStatus;
        return;
    }

    ComPtr<IUIAutomationTreeWalker> walker;
    if (FAILED(automation->get_ControlViewWalker(walker.ReceiveAddress())) || !walker) {
        req->result = CHALK_ERR_UIA_UNAVAILABLE;
        return;
    }

    std::vector<HWND> rootWindows = FindTopLevelWindowsForProcess(req->process_id);
    if (rootWindows.empty()) {
        req->result = CHALK_ERR_UIA_INVALID_PROCESS;
        return;
    }

    std::deque<ComPtr<IUIAutomationElement>> queue;
    bool anyAccessDenied = false;
    for (HWND hwnd : rootWindows) {
        IUIAutomationElement* raw = nullptr;
        HRESULT hr = automation->ElementFromHandle(hwnd, &raw);
        if (FAILED(hr) || !raw) {
            if (IsAccessDeniedHResult(hr)) anyAccessDenied = true;
            continue;
        }
        queue.emplace_back(ComPtr<IUIAutomationElement>(raw));
    }

    if (queue.empty()) {
        // This is a best-effort diagnostic scan; per its contract it only
        // reports the hard failures (no windows at all / access denied),
        // never a budget/size failure.
        req->result = anyAccessDenied ? CHALK_ERR_UIA_ACCESS_DENIED
                                       : CHALK_ERR_UIA_INVALID_PROCESS;
        return;
    }

    const ULONGLONG deadlineTick =
        GetTickCount64() + static_cast<ULONGLONG>(kSampleNamesTimeBudgetSeconds * 1000.0);

    std::unordered_set<std::wstring> seen;
    int32_t visited = 0;

    while (!queue.empty()) {
        if (req->disposition.load(std::memory_order_relaxed) == kCallerAbandoned) return;
        if (static_cast<int32_t>(req->names.size()) >= req->max_names) break;
        if (visited >= kSampleNamesNodeBudget) break;
        if (GetTickCount64() >= deadlineTick) break;

        ++visited;
        ComPtr<IUIAutomationElement> element = std::move(queue.front());
        queue.pop_front();

        BSTR nameBstr = nullptr;
        HRESULT nameHr = element->get_CurrentName(&nameBstr);
        // Unlike chalk_uia_find_element, a per-call timeout here does not
        // fail the whole scan -- it is a best-effort diagnostic (see the
        // function's header doc comment): just stop collecting and return
        // whatever we already have.
        if (IsRetryableTimeoutHResult(nameHr)) {
            if (nameBstr) SysFreeString(nameBstr);
            break;
        }
        if (SUCCEEDED(nameHr) && nameBstr && SysStringLen(nameBstr) > 0) {
            std::wstring name = BstrToWString(nameBstr);
            if (seen.insert(name).second) {
                req->names.push_back(std::move(name));
            }
        }
        if (nameBstr) SysFreeString(nameBstr);

        IUIAutomationElement* childRaw = nullptr;
        HRESULT childHr = walker->GetFirstChildElement(element.Get(), &childRaw);
        while (SUCCEEDED(childHr) && childRaw) {
            queue.emplace_back(ComPtr<IUIAutomationElement>(childRaw));
            IUIAutomationElement* nextRaw = nullptr;
            HRESULT siblingHr = walker->GetNextSiblingElement(childRaw, &nextRaw);
            if (FAILED(siblingHr)) break;
            childRaw = nextRaw;
        }
    }

    req->result = CHALK_OK;
}

unsigned __stdcall SampleNamesThreadProc(void* argRaw) {
    auto* req = static_cast<SampleNamesRequest*>(argRaw);
    RunSampleNamesWorker(req);
    // See the matching comment in FindElementThreadProc: this shares the
    // same outstanding-worker cap because it is exposed to the identical
    // hung-provider scenario (ElementFromHandle/get_CurrentName/
    // GetFirstChildElement calls that can block forever).
    ReleaseUiaWorkerSlot();
    if (req->disposition.exchange(kWorkerFinished, std::memory_order_acq_rel) == kCallerAbandoned) {
        delete req;
    }
    return 0;
}

} // namespace

extern "C" {

int32_t chalk_uia_find_element(uint32_t process_id, const uint16_t* name, int32_t match_mode,
                                int32_t occurrence, int32_t max_nodes, double timeout_seconds,
                                ChalkRect* out_bounds, int32_t* out_match_count,
                                int32_t* out_frameless_count) {
    int32_t validation = ValidateFindElementArgs(name, match_mode, occurrence, max_nodes,
                                                  timeout_seconds, out_bounds, out_match_count,
                                                  out_frameless_count);
    if (validation != CHALK_OK) return validation;

    // See the outstanding-worker-cap comment above FindElementRequest: fail
    // fast, before even allocating a request, once too many prior workers
    // are still outstanding (most likely stuck in a hung provider we have
    // no way to cancel) -- this is what actually bounds worst-case leaked
    // threads.
    if (!TryAcquireUiaWorkerSlot()) {
        return CHALK_ERR_UIA_TOO_MANY_PENDING;
    }

    auto* req = new (std::nothrow) FindElementRequest();
    if (!req) {
        ReleaseUiaWorkerSlot();
        return CHALK_ERR_OUT_OF_MEMORY;
    }
    req->process_id = static_cast<DWORD>(process_id);
    req->name = Utf16ToWString(name);
    req->match_mode = match_mode;
    req->occurrence = occurrence;
    req->max_nodes = max_nodes;
    req->timeout_seconds = timeout_seconds;

    HANDLE hThread = reinterpret_cast<HANDLE>(
        _beginthreadex(nullptr, 0, FindElementThreadProc, req, 0, nullptr));
    if (!hThread) {
        ReleaseUiaWorkerSlot(); // thread never started; it will never reach
                                 // ReleaseUiaWorkerSlot() itself.
        delete req; // thread never started; ownership never left this thread.
        return CHALK_ERR_INTERNAL;
    }

    const DWORD waitMs = TimeoutSecondsToMs(timeout_seconds);
    DWORD waitResult = WaitForSingleObject(hThread, waitMs);
    CloseHandle(hThread); // releases OUR reference to the thread object only;
                           // does not stop a still-running thread.

    if (waitResult == WAIT_OBJECT_0) {
        // Thread has fully terminated; safe to read *req directly and free
        // it -- no concurrent writer remains.
        int32_t result = req->result;
        if (req->write_bounds) *out_bounds = req->bounds;
        if (req->write_match_count) *out_match_count = req->match_count;
        if (req->write_frameless_count) *out_frameless_count = req->frameless_count;
        delete req;
        return result;
    }

    // Timed out (or WaitForSingleObject itself failed -- treat identically
    // and defensively: we must not touch *req again either way). Hand off
    // cleanup ownership per the file-level comment.
    if (req->disposition.exchange(kCallerAbandoned, std::memory_order_acq_rel) ==
        kWorkerFinished) {
        delete req;
    }
    return CHALK_ERR_UIA_RETRYABLE_TIMEOUT;
}

int32_t chalk_uia_sample_names(uint32_t process_id, int32_t max_names, uint16_t* out_buffer,
                                int32_t buffer_len, int32_t* out_count) {
    if (max_names <= 0 || buffer_len < 0 || (!out_buffer && buffer_len > 0) || !out_count) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }

    // Shares chalk_uia_find_element's outstanding-worker cap -- see that
    // comment above FindElementRequest. This is the one case where this
    // "never fails merely because the tree is large" diagnostic scan can
    // report a hard failure: the problem here is never the tree, it is a
    // saturated worker pool.
    if (!TryAcquireUiaWorkerSlot()) {
        return CHALK_ERR_UIA_TOO_MANY_PENDING;
    }

    auto* req = new (std::nothrow) SampleNamesRequest();
    if (!req) {
        ReleaseUiaWorkerSlot();
        return CHALK_ERR_OUT_OF_MEMORY;
    }
    req->process_id = static_cast<DWORD>(process_id);
    req->max_names = max_names;

    HANDLE hThread = reinterpret_cast<HANDLE>(
        _beginthreadex(nullptr, 0, SampleNamesThreadProc, req, 0, nullptr));
    if (!hThread) {
        ReleaseUiaWorkerSlot();
        delete req;
        return CHALK_ERR_INTERNAL;
    }

    const DWORD waitMs = TimeoutSecondsToMs(kSampleNamesTimeBudgetSeconds +
                                             kSampleNamesOuterWaitSlackSeconds);
    DWORD waitResult = WaitForSingleObject(hThread, waitMs);
    CloseHandle(hThread);

    if (waitResult == WAIT_OBJECT_0) {
        int32_t result = req->result;
        if (result == CHALK_OK) {
            int32_t written = 0;
            int64_t cursor = 0; // widened so a pathological name length can never overflow
                                 // the fits-in-buffer check below.
            for (const std::wstring& n : req->names) {
                int64_t needed = static_cast<int64_t>(n.size()) + 1; // + NUL
                if (cursor + needed > static_cast<int64_t>(buffer_len)) break;
                std::memcpy(out_buffer + cursor, n.data(), n.size() * sizeof(uint16_t));
                out_buffer[cursor + static_cast<int64_t>(n.size())] = 0;
                cursor += needed;
                ++written;
            }
            *out_count = written;
        }
        delete req;
        return result;
    }

    // Per this function's contract it never reports a timeout error (see
    // its header doc comment: "never fails merely because the tree is
    // large"). If even our generous internal budget plus slack wasn't
    // honored, treat it the same as "collected nothing before giving up":
    // succeed with an empty sample rather than inventing an error code
    // this function's contract does not list. As with
    // chalk_uia_find_element, we hand cleanup off to the worker rather than
    // touch *req again.
    if (req->disposition.exchange(kCallerAbandoned, std::memory_order_acq_rel) ==
        kWorkerFinished) {
        delete req;
    }
    *out_count = 0;
    return CHALK_OK;
}

} // extern "C"

#else // !_WIN32

// Portable stubs. UI Automation does not exist off Windows, so once the
// (fully portable, Windows-API-free) argument validation passes, the only
// honest answer is CHALK_ERR_UIA_UNAVAILABLE -- the same code
// chalk_uia_find_element uses on Windows when the UIA COM service itself
// could not be reached. Out-parameters are left untouched, matching the
// header's "on any other error, outputs are left unchanged" contract.

namespace {

int32_t ValidateFindElementArgsPortable(const uint16_t* name, int32_t match_mode,
                                         int32_t occurrence, int32_t max_nodes,
                                         double timeout_seconds, const ChalkRect* out_bounds,
                                         const int32_t* out_match_count,
                                         const int32_t* out_frameless_count) {
    if (!name || !out_bounds || !out_match_count || !out_frameless_count) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    if (name[0] == 0) return CHALK_ERR_INVALID_ARGUMENT; // empty name can never usefully match
    if (match_mode != CHALK_UIA_MATCH_EXACT && match_mode != CHALK_UIA_MATCH_CONTAINS) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    if (occurrence < 0) return CHALK_ERR_INVALID_ARGUMENT;
    if (max_nodes <= 0) return CHALK_ERR_INVALID_ARGUMENT;
    if (!(timeout_seconds > 0.0)) return CHALK_ERR_INVALID_ARGUMENT;
    return CHALK_OK;
}

} // namespace

extern "C" {

int32_t chalk_uia_find_element(uint32_t /*process_id*/, const uint16_t* name, int32_t match_mode,
                                int32_t occurrence, int32_t max_nodes, double timeout_seconds,
                                ChalkRect* out_bounds, int32_t* out_match_count,
                                int32_t* out_frameless_count) {
    int32_t validation = ValidateFindElementArgsPortable(
        name, match_mode, occurrence, max_nodes, timeout_seconds, out_bounds, out_match_count,
        out_frameless_count);
    if (validation != CHALK_OK) return validation;
    return CHALK_ERR_UIA_UNAVAILABLE;
}

int32_t chalk_uia_sample_names(uint32_t /*process_id*/, int32_t max_names, uint16_t* out_buffer,
                                int32_t buffer_len, int32_t* out_count) {
    if (max_names <= 0 || buffer_len < 0 || (!out_buffer && buffer_len > 0) || !out_count) {
        return CHALK_ERR_INVALID_ARGUMENT;
    }
    return CHALK_ERR_UIA_UNAVAILABLE;
}

} // extern "C"

#endif // _WIN32
