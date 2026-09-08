#!/usr/bin/env python3
"""Golden-snapshot diffing for the AI Chalkboard MCP wire protocol.

WHY THIS EXISTS: during a refactor of the MCP dispatch/validation layer, the
thing that made the refactor safe was capturing every JSON-RPC response the
real binary produces for a fixed, wide set of requests -- before the change
and after -- and diffing them. It caught nothing (the refactor was clean),
but it twice settled real disputes about whether an observed difference was
a genuine regression or environment noise (a different frontmost app, a
different set of running processes). That is exactly the situation a manual
"looks fine to me" review cannot resolve, which is why this is a repo tool
and not a one-off script.

USAGE:

    python3 tests/mcp_wire_snapshot.py capture <binary> before.json
    # ... make your change, rebuild ...
    python3 tests/mcp_wire_snapshot.py capture <binary> after.json
    python3 tests/mcp_wire_snapshot.py compare before.json after.json

`compare` exits 0 and prints "EQUIVALENT" if the two captures are the same
after canonicalisation, or exits non-zero with a unified diff otherwise.

NO COMMITTED BASELINE, ON PURPOSE: screen count, resolution, and backing
scale factor all vary by machine, and `get_screens` output is deliberately
NOT masked (see CANONICALISATION below) -- masking it would hide the exact
class of regression a display-handling refactor is most likely to introduce.
That means a baseline captured on one laptop would show a spurious diff on
every other machine. This tool's contract is therefore strictly BEFORE vs.
AFTER on ONE machine, across ONE change -- never a cross-machine or
long-term-stored comparison. Capture twice, compare, then discard both
files; do not check either one into the repo.

CANONICALISATION -- the part that matters most:

  * UUIDs (annotation ids) and `createdAt` timestamps are always fresh, so
    they are normalised unconditionally.
  * `windowNumber` (emitted by verify_presentation and get_overlay_state) is
    a WindowServer-assigned id that is different on every app launch, so two
    captures taken either side of a rebuild -- the only comparison this tool
    supports -- spuriously differ on it. A null windowNumber is NOT masked:
    "no window exists" is a reproducible finding worth diffing. Note that
    `_TOOL_CALLS` reaches verify_presentation only through its missing-args
    ERROR fixture (`call_verify_presentation_missing_args`), which carries no
    windowNumber, so `call_get_overlay_state`'s `overlays[].windowNumber` is
    the only thing this mask actually normalises in a real run today.
  * Live application identity (the frontmost/fallback app `get_active_app`
    and `list_annotations` report, and therefore whatever an untagged
    `draw_*` call links its annotation to) is NOT masked using a hardcoded
    list of app names -- an earlier version of this tool did that, and on a
    machine whose frontmost app was not on the list, the name leaked into
    the "canonicalised" output and produced a spurious diff. The same
    weakness could just as easily have hidden a REAL regression behind a
    name that *was* on the list. Instead, the live identity is HARVESTED
    FROM THE CAPTURE ITSELF (see `_harvest_identities`) and every occurrence
    of each harvested string is masked, longest-first so a short name never
    partially eats a longer one that contains it (see `_mask_string`).
  * "Cleared N annotation(s)" and an AMBIGUOUS app query's candidate list
    are count/environment-dependent (which apps happen to be running, in
    what order) even between two captures moments apart on the same machine,
    so those are normalised structurally too. Annotation expiry and eviction
    are deliberately NOT normalised: drawings persist until an explicit
    clear, so either field or message returning is a real regression.
  * A tool result whose `text` is itself a JSON document (get_screens,
    list_annotations, get_active_app) is PARSED and re-emitted as structured
    data rather than compared as an opaque string. Swift's
    `JSONSerialization` does not sort dictionary keys, so two runs of the
    identical, unchanged server can legitimately produce byte-different
    `text` strings that decode to the exact same data. `compare`'s
    `json.dumps(..., sort_keys=True)` then normalises that nondeterminism
    away, for the embedded document just as it does for the outer capture.
  * Screen geometry (`get_screens`' resolutions, ids, backing scale factors)
    is deliberately left UNMASKED. It is machine-specific, which is exactly
    why this tool is never used for a cross-machine comparison in the first
    place -- see NO COMMITTED BASELINE above.

SAFETY: `capture` never calls `set_capture_visible` with a real boolean.
That tool posts a session-global DistributedNotification that reconfigures
EVERY AI Chalkboard instance currently running on the machine, including
ones this test harness does not own (e.g. a live Claude Desktop session).
Only its missing-argument error path is exercised; see the comment at that
call site below.
"""

from __future__ import annotations

import argparse
import difflib
import json
import math
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

# `test_mcp_stdio.py` lives at the repo root (one level above this file) and
# guards its own CLI behind `if __name__ == "__main__"`, so importing it here
# never launches anything. The repo root is inserted explicitly, rather than
# relying on whatever ambient sys.path[0] happens to be, because
# `python3 tests/mcp_wire_snapshot.py ...` (a plain script invocation, as
# opposed to `python3 -m unittest tests/...`) sets sys.path[0] to this file's
# OWN directory (tests/), not the repo root -- and test_mcp_stdio.py is not
# there.
_REPO_ROOT = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

import test_mcp_stdio as stdio_harness  # noqa: E402 (see sys.path shim above)

DEFAULT_TIMEOUT_SECONDS = 15.0

# ---------------------------------------------------------------------------
# Coverage: the fixed sequence of JSON-RPC requests `capture` sends.
#
# Each tuple is (result_key, method, params-or-None). Order matches the
# order requests are sent, which matters for a few of the later entries
# (list_annotations is deliberately sent after the draw_* calls that create
# annotations, and the clear_* calls are deliberately last).
# ---------------------------------------------------------------------------

_TOP_LEVEL_REQUESTS: list[tuple[str, str, dict[str, Any] | None]] = [
    ("initialize", "initialize", {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "mcp-wire-snapshot", "version": "1"},
    }),
    ("ping", "ping", None),
    ("tools_list", "tools/list", None),
    # Exercises the JSON-RPC -32601 dispatch path in MCPServer.handleMessage.
    ("unknown_method", "no/such/method", None),
]

# Each tuple is (result_key, tool_name, arguments). Every entry becomes one
# `tools/call` request. `app: ""` is passed explicitly wherever the specific
# behaviour under test does not care about app-linking, precisely so the
# response does not depend on whichever app happens to be frontmost on the
# machine running `capture` -- keeping the fixture itself as deterministic as
# possible going in, on top of (not instead of) the canonicalisation below.
_TOOL_CALLS: list[tuple[str, str, dict[str, Any]]] = [
    ("call_unknown_tool", "nope", {}),
    # Free-draw vector coverage: missing, malformed, stroke/fill/dash, and app linking.
    ("call_path_missing_data", "draw_path", {}),
    ("call_path_malformed", "draw_path", {"path_data": "M 0"}),
    ("call_path_ok", "draw_path", {
        "path_data": "M 10 10 C 20 0 30 20 40 10 Z", "stroke_color": "blue",
        "stroke_width": 4, "stroke_opacity": 0.6, "fill_color": "cyan",
        "fill_opacity": 0.2, "dash": [8, 4], "z_index": 3,
        "app": "",
    }),
    ("call_path_normalized_ok", "draw_path", {
        "path_data": "M 0.1 0.2 L 0.8 0.7", "coordinate_space": "normalized",
        "stroke_width": 4, "app": "",
    }),
    # `duration_seconds` is a retired parameter that is REJECTED rather than
    # ignored, so the refusal text is part of the wire contract an agent sees.
    # It is captured here because several entries in this list silently carried
    # the parameter after it was retired: what were meant to be the successful
    # draw_path/draw_text captures were really capturing this error, so the
    # snapshot compared two error responses and the success coverage they exist
    # to provide was gone without any test turning red.
    ("call_path_duration_seconds_rejected", "draw_path", {
        "path_data": "M 1 1 L 2 2", "app": "", "duration_seconds": 60,
    }),
    # First-class geometry succeeds without a TCC prompt and is deliberately
    # followed by list_annotations below, which pins that it is stored as a
    # normal durable vector path. Supplying the retired lifetime parameter
    # must reject the call rather than quietly create an expiring shape.
    ("call_shape_circle_ok", "draw_shape", {
        "shape": "circle", "center_x": 240, "center_y": 160, "radius": 36,
        "stroke_color": "magenta", "stroke_width": 3, "fill_color": "cyan",
        "fill_opacity": 0.25, "dash": [6, 3], "app": "",
    }),
    ("call_shape_duration_seconds_rejected", "draw_shape", {
        "shape": "circle", "center_x": 240, "center_y": 160, "radius": 36,
        "app": "", "duration_seconds": 60,
    }),
    ("call_path_screenshot_missing_dimensions", "draw_path", {
        "path_data": "M 10 20 L 40 80", "coordinate_space": "screenshot_pixels", "app": "",
    }),
    ("call_path_default_app", "draw_path", {"path_data": "M 1 1 L 2 2"}),
    ("call_path_bundleid_not_running", "draw_path", {
        "path_data": "M 1 1 L 2 2", "app": "com.example.NotRunning-FreeDraw",
    }),
    ("call_path_ambiguous_app", "draw_path", {"path_data": "M 1 1 L 2 2", "app": "com.apple"}),
    ("call_path_bad_opacity", "draw_path", {"path_data": "M 1 1 L 2 2", "fill_opacity": 2}),
    ("call_path_move_only", "draw_path", {"path_data": "M 1 1", "app": ""}),
    ("call_path_invisible", "draw_path", {"path_data": "M 1 1 L 2 2", "stroke_width": 0, "fill_color": "blue", "fill_opacity": 0, "app": ""}),
    ("call_path_invalid_optional", "draw_path", {"path_data": "M 1 1 L 2 2", "stroke_width": True, "app": ""}),
    ("call_path_overflow", "draw_path", {"path_data": "M 1e308 0 l 1e308 0", "app": ""}),
    ("call_path_bad_dash", "draw_path", {"path_data": "M 1 1 L 2 2", "dash": [4, 0]}),

    # Stable image/batch validation paths avoid machine-specific local files.
    ("call_image_missing_args", "draw_image", {}),
    ("call_image_missing_file", "draw_image", {"image_path": "/definitely/missing.png", "x": 1, "y": 2}),
    ("call_image_invalid_optional", "draw_image", {"image_path": "/definitely/missing.png", "x": 1, "y": 2, "opacity": "not-a-number"}),
    # Text succeeds without a TCC grant, unlike element lookup and screen
    # capture. It also protects the first-class primitive's normal lifecycle
    # and schema from silently regressing back into a caller-rendered image.
    ("call_text_missing_args", "draw_text", {"x": 10, "y": 20}),
    ("call_text_ok", "draw_text", {
        "text": "Fusion", "x": 120, "y": 80, "font_size": 22,
        "color": "white", "background_color": "#202020", "background_opacity": 0.8,
        "opacity": 0.9, "z_index": 4, "app": "",
    }),
    # A positive avoid call needs the freshly-created shape's UUID, so its
    # draw -> bounds -> disjointness workflow belongs in test_mcp_stdio.py.
    # Keep this deterministic missing-ID rejection here too: it proves the
    # new public parameter reaches draw_text's handler and fails before any
    # annotation can be created, without needing to chain a runtime ID
    # through this static wire-fixture table.
    ("call_text_avoid_missing_annotation", "draw_text", {
        "text": "Avoid", "x": 120, "y": 80, "font_size": 18,
        "background_color": "#000000", "padding_px": 4,
        "avoid": ["does-not-exist"], "app": "",
    }),
    ("call_batch_empty", "draw_batch", {"items": []}),
    ("call_batch_unknown_type", "draw_batch", {"items": [{"type": "circle"}], "app": ""}),
    ("call_batch_path_ok", "draw_batch", {"items": [
        {"type": "path", "path_data": "M 0 0 L 10 10", "stroke_color": "red"},
        {"type": "path", "path_data": "M 20 20 Q 30 0 40 20", "fill_color": "yellow", "stroke_width": 0},
    ], "app": ""}),

    # --- set_capture_visible: ONLY the missing-argument error path.
    #
    # DO NOT add a call here with a real `visible` boolean. Unlike every
    # other tool, set_capture_visible's effect is NOT scoped to the child
    # process this script launched: MCPToolHandlers routes it through
    # InstanceBroadcast.postSetCaptureVisible, which posts a session-global
    # DistributedNotification that every AI Chalkboard instance on the
    # machine observes and applies immediately -- including, for example, a
    # live Claude Desktop session the person running `capture` may have open
    # right now. Calling it with true/false here would silently toggle that
    # other instance's capture-debug rendering mode. The missing-argument
    # error path below never reaches InstanceBroadcast, so it is the only
    # safe way to exercise this tool's dispatch at all.
    ("call_capture_visible_missing_args", "set_capture_visible", {}),

    # Real lease calls alter shared presentation state, so do not invoke their
    # valid path from this fixture. Each malformed request below is rejected
    # before a lease, coordinator write, or transport broadcast can occur.
    ("call_suspend_unexpected_args", "suspend_annotations", {"unexpected": True}),
    ("call_suspend_bad_duration", "suspend_annotations", {"lease_seconds": 0}),
    ("call_suspend_boolean_duration", "suspend_annotations", {"lease_seconds": True}),
    ("call_suspend_numeric_string_duration", "suspend_annotations", {"lease_seconds": "15"}),
    ("call_suspend_fractional_duration", "suspend_annotations", {"lease_seconds": 1.5}),
    ("call_suspend_null_duration", "suspend_annotations", {"lease_seconds": None}),
    ("call_suspend_extreme_duration", "suspend_annotations", {"lease_seconds": 10 ** 100}),
    ("call_suspend_bad_idempotency_key", "suspend_annotations", {"idempotency_key": "not-a-uuid"}),
    ("call_suspend_uppercase_idempotency_key", "suspend_annotations", {"idempotency_key": "A0B1C2D3-E4F5-4A6B-8C9D-0E1F2A3B4C5D"}),
    ("call_suspend_braced_idempotency_key", "suspend_annotations", {"idempotency_key": "{a0b1c2d3-e4f5-4a6b-8c9d-0e1f2a3b4c5d}"}),
    ("call_suspend_non_string_idempotency_key", "suspend_annotations", {"idempotency_key": 4}),
    ("call_suspend_null_idempotency_key", "suspend_annotations", {"idempotency_key": None}),
    ("call_resume_missing_token", "resume_annotations", {}),
    ("call_resume_bad_token", "resume_annotations", {"lease_token": "not-a-token"}),
    ("call_resume_unicode_token", "resume_annotations", {"lease_token": "é" * 22}),
    ("call_resume_null_token", "resume_annotations", {"lease_token": None}),
    ("call_resume_numeric_token", "resume_annotations", {"lease_token": 1}),
    ("call_resume_unexpected_args", "resume_annotations", {"lease_token": "A" * 43, "unexpected": True}),
    # The disposable-process valid lifecycle is exercised by test_mcp_stdio.py,
    # which always resumes in a finally block.

    ("call_get_screens", "get_screens", {}),
    ("call_get_overlay_state", "get_overlay_state", {}),
    ("call_get_active_app", "get_active_app", {}),
    # Status is intentionally safe without Accessibility permission. The
    # lookup call below fails before it can require TCC, giving this snapshot
    # deterministic coverage of dispatch and required-argument validation.
    ("call_get_accessibility_status", "get_accessibility_status", {}),
    ("call_highlight_element_missing_label", "highlight_element", {}),
    # Sent after the draw_* calls above so the response reflects a populated
    # store: real annotation ids/timestamps/app-links to canonicalise, not an
    # empty list that would leave that code path untested.
    ("call_list_annotations", "list_annotations", {}),

    # verify_annotation success returns a nondeterministic image and requires a
    # real screenshot file, so the golden wire fixture exercises its stable
    # validation path. End-to-end image content is covered by test_mcp_stdio.py.
    ("call_verify_annotation_missing_args", "verify_annotation", {}),
    ("call_verify_annotation_bad_padding", "verify_annotation", {
        "annotation_id": "does-not-exist", "capture_source": "chalkboard", "padding_px": "not-a-number",
    }),
    # A missing annotation is checked before capture, so this exercises the
    # Chalkboard-source request shape without triggering Screen Recording TCC.
    ("call_verify_annotation_chalkboard_missing_annotation", "verify_annotation", {
        "annotation_id": "does-not-exist", "capture_source": "chalkboard", "request_permission": False,
    }),
    ("call_verify_presentation_missing_args", "verify_presentation", {}),

    # Stable-ID adjustment: the not-found branch is deterministic and proves
    # dispatch/validation without needing to parse a freshly generated ID.
    ("call_update_annotation_missing", "update_annotation", {
        "annotation_id": "does-not-exist", "offset_x": 10, "offset_y": -5, "opacity": 0.8, "z_index": 6,
    }),

    # --- clear: annotation_id miss, explicit app, invalid combination,
    # typo'd scope, and scope=all.
    ("call_clear_by_id_missing", "clear", {"annotation_id": "does-not-exist"}),
    ("call_clear_explicit_app", "clear", {"app": "com.example.NotRunning-FreeDraw"}),
    ("call_clear_all_with_app", "clear", {"scope": "all", "app": "com.example.NotRunning-FreeDraw"}),
    ("call_clear_typo_scope", "clear", {"scope": "TYPO"}),
    ("call_clear_scope_all", "clear", {"scope": "all"}),
]

# `run_capture` stores every response into one dict keyed by result_key, so a
# key duplicated between (or within) the two tables above would silently drop
# a fixture: the second response overwrites the first, and the capture still
# validates because EXPECTED_KEYS -- being a set built from the very same
# tables -- collapses the duplicate too. Nothing downstream could ever notice
# the missing coverage. An EXPLICIT raise, not an `assert`: assertions are
# stripped entirely under `python3 -O`, which would turn this guard into a
# no-op in exactly the environment least likely to be watched closely. A
# built-in RuntimeError rather than this module's own CaptureValidationError:
# that type means "a capture FILE cannot be trusted" and is caught-and-reported
# as a user error by `main`, whereas this is a defect in this file's own
# fixture tables and must fail at import, loudly and uncatchably.
_ALL_KEYS: list[str] = [key for key, _, _ in _TOP_LEVEL_REQUESTS] + [key for key, _, _ in _TOOL_CALLS]
_DUPLICATE_KEYS = sorted({key for key in _ALL_KEYS if _ALL_KEYS.count(key) > 1})
if _DUPLICATE_KEYS:
    raise RuntimeError(
        f"duplicate result_key(s) in _TOP_LEVEL_REQUESTS/_TOOL_CALLS: {_DUPLICATE_KEYS} -- "
        "each key must be unique or its fixture's response is silently discarded."
    )

EXPECTED_KEYS: frozenset[str] = frozenset(_ALL_KEYS)


def _looks_like_complete_bundle_id(value: str) -> bool:
    """Mirrors Sources/Overlay/ActiveAppTracker.swift's
    `BundleIdentifierSyntax.looksComplete`: at least 3 non-empty,
    dot-separated components and no whitespace."""
    parts = value.split(".")
    return len(parts) >= 3 and all(parts) and not any(ch.isspace() for ch in value)


# The `app` values this fixture supplies that are themselves complete,
# never-running bundle ids (accepted verbatim by resolveTargetApp) are
# deterministic literals WE chose, not live environment data. Today that is
# "com.example.NotRunning-FreeDraw", supplied by the
# "call_path_bundleid_not_running", "call_clear_explicit_app", and
# "call_clear_all_with_app" entries above. If they were masked like a
# genuinely live app identity, a future regression that corrupted the
# verbatim-acceptance path (e.g. stored the wrong id, or
# truncated it) would still get harvested-and-masked from THIS SAME
# capture's list_annotations entry and disappear behind the same "<APPID>"
# token in both the before and after capture -- exactly the kind of
# self-cancelling mask this tool must not produce. Excluding them from
# masking keeps their exact round-trip visible to a diff, unlike a truly
# volatile identity (the live frontmost/fallback app), which cannot be
# known ahead of time and therefore has no such exclusion available.
_STATIC_APP_LITERALS: frozenset[str] = frozenset(
    args["app"]
    for _, _, args in _TOOL_CALLS
    if isinstance(args.get("app"), str) and _looks_like_complete_bundle_id(args["app"])
)


# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

class CaptureValidationError(Exception):
    """Raised when a capture cannot be trusted: missing, empty, truncated,
    or produced by an incompatible version of this tool. Never caught
    silently -- see `validate_capture_shape`."""


def run_capture(binary_path: str, out_path: Path, timeout: float = DEFAULT_TIMEOUT_SECONDS) -> None:
    """Launches `binary_path --mcp`, sends every request in
    `_TOP_LEVEL_REQUESTS` + `_TOOL_CALLS` in order, and writes the
    canonicalised result to `out_path`."""
    if not math.isfinite(timeout) or timeout <= 0:
        raise CaptureValidationError("--timeout must be a finite number greater than zero")
    # `spawn_mcp_child` starts the shared bounded `StderrDrain` immediately.
    # It provides ordinary-host behavior and a useful failure tail while this
    # one child receives every fixture. The server does not rely on it for
    # progress: Logger bounds complete stderr records to 512 bytes and either
    # writes non-blockingly (macOS) or submits to a bounded background worker
    # (Windows), dropping under sustained backpressure rather than wedging a
    # JSON-RPC response.
    #
    # The child is also put in a private, disposable suspension domain (see
    # `isolated_suspension_env`'s doc comment for what each key does). That is
    # not merely hygiene here, it is a correctness requirement for THIS tool:
    # a production-domain child's `call_get_overlay_state` response reports the
    # machine's LIVE suspension state (`annotationsSuspended`,
    # `activeLeaseCount`, `suspensionRegistryBootstrapped`), none of which is
    # masked by `canonicalize_capture`. A live Claude session that happens to
    # hold a lease during one of the two captures and not the other would
    # therefore produce exactly the spurious, "is this a real regression?"
    # diff this tool exists to eliminate -- on top of the child otherwise
    # writing that session's real lease registry and sharing its DNC
    # invalidation channel and instance lock.
    suspension_root = tempfile.mkdtemp(prefix="ai-chalkboard-wiresnap-")
    proc, reader, stderr_drain = stdio_harness.spawn_mcp_child(
        binary_path,
        extra_env=stdio_harness.isolated_suspension_env(suspension_root, "wiresnap"),
    )
    results: dict[str, Any] = {}
    next_id = 1
    failed = False

    def send(method: str, params: dict[str, Any] | None) -> Any:
        nonlocal next_id
        request: dict[str, Any] = {"jsonrpc": "2.0", "id": next_id, "method": method}
        if params is not None:
            request["params"] = params
        next_id += 1
        return stdio_harness.send_request(proc, reader, request, timeout)

    try:
        for key, method, params in _TOP_LEVEL_REQUESTS:
            results[key] = send(method, params)
        for key, tool_name, arguments in _TOOL_CALLS:
            results[key] = send("tools/call", {"name": tool_name, "arguments": arguments})
    except Exception:
        failed = True
        raise
    finally:
        stdio_harness.terminate_child(proc)
        # Always join the drain once its child has been reaped. Captures can
        # be invoked repeatedly by test code or a long-lived automation
        # process; leaving successful captures' daemon threads to wind down
        # on their own unnecessarily retains process/pipe objects between
        # runs. Keep the diagnostic tail only when it is useful.
        diagnostics = stderr_drain.join_and_get_tail(
            timeout=stdio_harness.SHUTDOWN_TIMEOUT_SECONDS
        ).strip()
        if failed:
            if diagnostics:
                print(f"\nChild stderr (last {stdio_harness.STDERR_TAIL_BYTES} bytes):\n{diagnostics}", file=sys.stderr, flush=True)
        shutil.rmtree(suspension_root, ignore_errors=True)

    missing = EXPECTED_KEYS - results.keys()
    if missing:
        raise CaptureValidationError(
            f"capture ended without responses for {sorted(missing)} -- the child likely "
            "exited early. Refusing to write a partial capture."
        )

    canonical = canonicalize_capture(results)
    out_path.write_text(json.dumps(canonical, indent=2, sort_keys=True) + "\n")
    print(f"wrote {out_path} ({len(canonical)} entries)", flush=True)


# ---------------------------------------------------------------------------
# Canonicalisation
# ---------------------------------------------------------------------------

_UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
_CLEARED_COUNT_RE = re.compile(r"Cleared \d+ annotation\(s\)")
# Matches the volatile candidate list inside the AMBIGUOUS app-resolution
# error text (see DrawRequest.resolveTargetApp's `.ambiguous` branch), up to
# (but not including) the literal ". Nothing was drawn" that always follows
# it, so wording changes on either side of the candidate list still produce
# a real, visible diff.
_AMBIGUOUS_LIST_RE = re.compile(r"matches \d+ running applications: .*?(?=\. Nothing was drawn)", re.DOTALL)

# Dicts carrying one of these (id-key, name-key) pairs are how this server
# reports a LIVE application's identity: get_active_app's frontmost/
# fallback/rawFrontmost objects use bundleId/name, and each list_annotations
# entry uses appId/appName for the app it is linked to. Harvesting is scoped
# to exactly these two known pairs -- NOT any dict with a "name" key -- on
# purpose: a generic "name" harvest would also sweep up tools/list's tool
# names ("clear", "get_screens", ...) and initialize's serverInfo.name, and
# masking those as if they were live app identities would both corrupt
# unrelated text (short, common substrings like "clear" appear inside
# perfectly ordinary words) and hide a real regression in exactly the
# strings a wire-protocol snapshot exists to protect.
_ID_NAME_KEY_PAIRS = (("bundleId", "name"), ("appId", "appName"))


def _try_parse_json(text: str) -> Any | None:
    stripped = text.strip()
    if not stripped or stripped[0] not in "{[":
        return None
    try:
        return json.loads(stripped)
    except (json.JSONDecodeError, ValueError):
        return None


def _harvest_identities(node: Any, names: set[str], ids: set[str]) -> None:
    """Recursively collects the live application identities THIS capture
    itself reported, by walking every dict and descending into any string
    that turns out to be an embedded JSON document (a tool result's `text`
    field). See the module docstring's CANONICALISATION section for why this
    replaces a hardcoded app-name list."""
    if isinstance(node, dict):
        for id_key, name_key in _ID_NAME_KEY_PAIRS:
            # Gate on the ID key's PRESENCE (not the name key's): "bundleId"
            # and "appId" are specific to an app-identity object, whereas a
            # bare "name" key alone appears all over the protocol (every
            # tools/list entry, initialize's serverInfo) and harvesting on
            # that alone would sweep in exactly the strings this scoping is
            # meant to leave alone. See this function's own doc comment.
            if id_key not in node:
                continue
            id_value = node.get(id_key)
            if isinstance(id_value, str) and id_value:
                ids.add(id_value)
            name_value = node.get(name_key)
            if isinstance(name_value, str) and name_value:
                names.add(name_value)
        for value in node.values():
            _harvest_identities(value, names, ids)
    elif isinstance(node, list):
        for item in node:
            _harvest_identities(item, names, ids)
    elif isinstance(node, str):
        parsed = _try_parse_json(node)
        if parsed is not None:
            _harvest_identities(parsed, names, ids)


def _mask_plain_text(text: str, ids_longest_first: list[str], names_longest_first: list[str]) -> str:
    masked = _UUID_RE.sub("<UUID>", text)
    # Longest-first: an app named "Code" and one named "Visual Studio Code"
    # running at once must not corrupt each other. Masking "Code" first would
    # also eat the "Code" inside "Visual Studio Code", leaving a mangled
    # "Visual Studio <APP>" instead of a clean "<APP>" for the longer name's
    # own occurrences.
    for value in ids_longest_first:
        masked = masked.replace(value, "<APPID>")
    for value in names_longest_first:
        masked = masked.replace(value, "<APP>")
    masked = _CLEARED_COUNT_RE.sub("Cleared <N> annotation(s)", masked)
    masked = _AMBIGUOUS_LIST_RE.sub("matches <N> running applications: <CANDIDATES>", masked)
    return masked


def _mask_string(text: str, ids_longest_first: list[str], names_longest_first: list[str]) -> Any:
    parsed = _try_parse_json(text)
    if parsed is not None:
        # Tool results whose text IS a JSON document (get_screens,
        # list_annotations, get_active_app) are parsed and re-emitted as
        # structured data, not compared as an opaque string: Swift's
        # JSONSerialization does not sort dictionary keys, so two captures of
        # the identical, unchanged server can produce byte-different `text`
        # strings that decode to identical data. Wrapping the parsed value
        # marks it as "this was a JSON string" so `compare`'s
        # json.dumps(sort_keys=True) can normalise its key order downstream,
        # the same way it normalises the outer capture's.
        return {"__embedded_json__": _mask_value(parsed, ids_longest_first, names_longest_first)}
    return _mask_plain_text(text, ids_longest_first, names_longest_first)


def _mask_value(node: Any, ids_longest_first: list[str], names_longest_first: list[str]) -> Any:
    if isinstance(node, str):
        return _mask_string(node, ids_longest_first, names_longest_first)
    if isinstance(node, list):
        return [_mask_value(v, ids_longest_first, names_longest_first) for v in node]
    if isinstance(node, dict):
        out: dict[str, Any] = {}
        for key, value in node.items():
            if key == "createdAt":
                # Annotation.createdAt encodes as a raw Double (seconds since
                # the Foundation reference date) via JSONEncoder's default
                # .deferredToDate strategy -- there is no string marker a
                # regex could key off, so this has to be a key-based
                # replacement rather than a pattern in _mask_plain_text.
                out[key] = "<TIME>"
            elif key == "windowNumber" and value is not None:
                # A WindowServer-assigned window id, emitted by
                # verify_presentation and by get_overlay_state (via
                # `overlayInputPolicySnapshot`). It is a fresh integer on every
                # app launch, so two captures taken either side of a rebuild --
                # the exact thing this tool is for -- always disagree on it.
                # Like createdAt it is a bare number with no string marker for a
                # regex to key off, so it has to be masked by key here.
                # `None` is left alone: "there is no window" is a real,
                # reproducible finding this tool must still be able to diff.
                # Of those two emitters only get_overlay_state is reached with
                # a live window by `_TOOL_CALLS` (verify_presentation appears
                # there solely as `call_verify_presentation_missing_args`, an
                # error fixture), so in practice this masks exactly
                # `call_get_overlay_state`'s `overlays[].windowNumber`.
                out[key] = "<WINDOWNUM>"
            else:
                out[key] = _mask_value(value, ids_longest_first, names_longest_first)
        return out
    return node


def canonicalize_capture(raw: dict[str, Any]) -> dict[str, Any]:
    """Returns a canonicalised copy of a raw `{result_key: json_rpc_response}`
    capture: volatile identities masked, embedded JSON parsed, everything
    else -- including screen geometry -- left exactly as the server sent it."""
    names: set[str] = set()
    ids: set[str] = set()
    _harvest_identities(raw, names, ids)
    # See _STATIC_APP_LITERALS's doc comment: these are our own deterministic
    # fixture inputs, not live data, and must stay visible for a diff to
    # catch a regression in how they round-trip.
    names -= _STATIC_APP_LITERALS
    ids -= _STATIC_APP_LITERALS
    names_longest_first = sorted(names, key=len, reverse=True)
    ids_longest_first = sorted(ids, key=len, reverse=True)
    return _mask_value(raw, ids_longest_first, names_longest_first)


# ---------------------------------------------------------------------------
# Compare
# ---------------------------------------------------------------------------

def diff_captures(before: dict[str, Any], after: dict[str, Any]) -> list[str]:
    """Returns a unified diff (as lines) between two already-canonicalised
    captures; an empty list means they are equivalent. Both are re-serialised
    with sort_keys=True immediately before diffing so that dict key order --
    which `canonicalize_capture` does not itself normalise -- can never be
    the source of a reported difference."""
    before_text = json.dumps(before, indent=2, sort_keys=True).splitlines()
    after_text = json.dumps(after, indent=2, sort_keys=True).splitlines()
    if before_text == after_text:
        return []
    return list(difflib.unified_diff(before_text, after_text, fromfile="before", tofile="after", lineterm=""))


def validate_capture_shape(data: Any, source: str) -> None:
    """Refuses to let `compare` treat a capture as usable if it is empty,
    truncated, or missing expected keys.

    This is the check requirement 4 exists for: a `compare` that reports
    "equivalent" purely because both inputs are empty (or both were cut off
    mid-write) would silently defeat the entire point of this tool -- it
    exists specifically to catch the difference a distracted reviewer might
    miss, and a vacuous pass is the most distracted possible reviewer.
    """
    if not isinstance(data, dict) or not data:
        raise CaptureValidationError(f"{source}: capture is empty or not a JSON object; refusing to compare.")
    missing = sorted(EXPECTED_KEYS - data.keys())
    if missing:
        raise CaptureValidationError(
            f"{source}: capture is missing {len(missing)} expected entr{'y' if len(missing) == 1 else 'ies'} "
            f"(e.g. {missing[:5]}) -- it looks truncated, hand-edited, or from an incompatible version of "
            "this tool. Refusing to report 'equivalent'."
        )
    for key in EXPECTED_KEYS:
        entry = data.get(key)
        if not isinstance(entry, dict) or not entry:
            raise CaptureValidationError(f"{source}: entry '{key}' is empty or malformed; refusing to compare.")


def _load_capture(path: Path) -> Any:
    try:
        text = path.read_text()
    except OSError as exc:
        raise CaptureValidationError(f"{path}: cannot read capture file: {exc}") from exc
    if not text.strip():
        raise CaptureValidationError(f"{path}: capture file is empty.")
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise CaptureValidationError(f"{path}: capture file is not valid JSON ({exc}); it looks truncated.") from exc


def run_compare(before_path: Path, after_path: Path) -> int:
    before = _load_capture(before_path)
    after = _load_capture(after_path)
    validate_capture_shape(before, str(before_path))
    validate_capture_shape(after, str(after_path))

    diff_lines = diff_captures(before, after)
    if not diff_lines:
        print(f"EQUIVALENT: {before_path} and {after_path} match after canonicalisation.")
        return 0

    print(
        f"DIFFERENT: {before_path} vs {after_path} ({len(diff_lines)} diff line(s)). "
        "If this is expected environment noise (not a real regression), the fix belongs in "
        "canonicalize_capture(), not in loosening this comparison:",
        file=sys.stderr,
    )
    for line in diff_lines:
        print(line, file=sys.stderr)
    return 1


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Capture or compare a golden snapshot of the AI Chalkboard MCP wire protocol."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    capture_parser = subparsers.add_parser(
        "capture",
        help="Launch <binary> --mcp, drive every MCP request/response pair, and write the canonicalised result.",
    )
    capture_parser.add_argument("binary", help="Path to the AIChalkboard executable, e.g. .build/debug/AIChalkboard.")
    capture_parser.add_argument("out_path", metavar="out.json", help="Where to write the canonicalised capture.")
    capture_parser.add_argument(
        "--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS, metavar="SECONDS",
        help="maximum time to wait for each MCP response (default: %(default)s)",
    )

    compare_parser = subparsers.add_parser(
        "compare", help="Diff two captures; exit 0 if equivalent, non-zero with a diff otherwise.",
    )
    compare_parser.add_argument("before", metavar="before.json")
    compare_parser.add_argument("after", metavar="after.json")

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    try:
        if args.command == "capture":
            run_capture(args.binary, Path(args.out_path), timeout=args.timeout)
            return 0
        if args.command == "compare":
            return run_compare(Path(args.before), Path(args.after))
    except CaptureValidationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 2  # unreachable: argparse's `required=True` rejects any other command.


if __name__ == "__main__":
    sys.exit(main())
