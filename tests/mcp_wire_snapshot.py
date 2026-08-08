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
  * "Cleared N annotation(s)", the eviction count, and an AMBIGUOUS app
    query's candidate list are count/environment-dependent (which apps
    happen to be running, in what order) even between two captures moments
    apart on the same machine, so those are normalised structurally too.
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
import os
import re
import subprocess
import sys
import threading
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
    # Unknown tool name -> the `default:` branch of the tools/call switch.
    ("call_unknown_tool", "nope", {}),

    # --- draw_circle: success, every failure mode, every app-resolution path.
    ("call_circle_missing_args", "draw_circle", {"x": 10}),
    ("call_circle_ok", "draw_circle", {
        "x": 100, "y": 120, "radius": 40, "color": "blue", "label": "C",
        "app": "", "duration_seconds": 0,
    }),
    ("call_circle_normalized", "draw_circle", {
        "x": 0.5, "y": 0.5, "radius": 30, "is_normalized": True, "app": "",
    }),
    # radius <= 0 (negative, not merely zero, to exercise the same branch a
    # sign-flipped caller would hit).
    ("call_circle_radius_nonpositive", "draw_circle", {"x": 1, "y": 1, "radius": -5, "app": ""}),
    # A JSON boolean where MCPArgument.double requires a number. `True` here
    # serialises as the JSON literal `true`, which used to coerce to 1.0
    # through NSNumber before MCPArgument.double's CFBooleanGetTypeID guard.
    ("call_circle_radius_boolean", "draw_circle", {"x": 1, "y": 1, "radius": True, "app": ""}),
    # "NaN" as a coordinate: Double("NaN") parses to a non-finite value that
    # MCPArgument.double must reject rather than store.
    ("call_circle_nan_coordinate", "draw_circle", {"x": "NaN", "y": 1, "radius": 5, "app": ""}),
    # Ambiguous app: "com.apple" is a bundle-id PREFIX (not a complete id --
    # BundleIdentifierSyntax.looksComplete requires >= 3 dot-separated
    # components) that matches many non-prohibited "com.apple.*" processes
    # (Finder, Dock, Control Center, ...) on essentially any real macOS
    # session, regardless of which third-party apps the developer happens to
    # have open. The exact candidate LIST is still machine/moment-dependent
    # (which system agents are running right now), which is why it is
    # normalised structurally by _AMBIGUOUS_LIST_RE rather than relied upon
    # to match byte-for-byte.
    ("call_circle_ambiguous_app", "draw_circle", {"x": 1, "y": 1, "radius": 5, "app": "com.apple"}),
    # Unresolvable: not bundle-id shaped, matches no running app -> .notFound
    # with the "could not resolve" message (raw query only, fully static).
    ("call_circle_unresolvable_app", "draw_circle", {
        "x": 1, "y": 1, "radius": 5, "app": "zzz-definitely-not-a-real-app-xyz",
    }),
    # Bundle-id shaped but not running -> accepted verbatim. The id here is
    # ours, not live data, so it needs no masking to be reproducible.
    ("call_circle_bundleid_not_running", "draw_circle", {
        "x": 1, "y": 1, "radius": 5, "app": "com.example.NotRunning-Circle",
    }),

    # --- draw_arrow: success, missing args, and the OMITTED-app default path
    # (links to ActiveAppTracker.fallbackAppId, i.e. genuinely live data).
    # This is the one call in this fixture that deliberately exercises that
    # path end to end, to prove the harvest-based masking actually handles it
    # rather than merely being unit-tested in isolation.
    ("call_arrow_missing_args", "draw_arrow", {"x1": 1, "y1": 2}),
    ("call_arrow_ok", "draw_arrow", {"x1": 1, "y1": 2, "x2": 3, "y2": 4, "app": ""}),
    ("call_arrow_default_app", "draw_arrow", {"x1": 5, "y1": 6, "x2": 7, "y2": 8}),

    # --- draw_box: success, missing args, non-positive dimensions.
    ("call_box_missing_args", "draw_box", {"x": 1, "y": 2, "width": 3}),
    ("call_box_ok", "draw_box", {"x": 1, "y": 2, "width": 3, "height": 4, "app": ""}),
    ("call_box_negative_dimensions", "draw_box", {"x": 1, "y": 2, "width": -5, "height": 4, "app": ""}),

    # --- draw_label: success, missing args.
    ("call_label_missing_args", "draw_label", {"x": 1, "y": 2}),
    ("call_label_ok", "draw_label", {"x": 1, "y": 2, "text": "hi", "app": ""}),

    # --- draw_path: too few points, unparseable points, success, over-cap.
    ("call_path_too_few_points", "draw_path", {"points": [[1, 2]]}),
    ("call_path_unparseable_points", "draw_path", {"points": ["a", "b"]}),
    ("call_path_ok", "draw_path", {
        "points": [[1, 2], {"x": 3, "y": 4}], "is_closed": True, "app": "",
    }),
    # One point past Sources/Support/DrawingDefaults.swift's maxPathPoints
    # (10,000), each individually well-formed so all 10,001 parse
    # successfully and DrawValidation.pathPointCount is what actually rejects
    # the call -- not the separate "too few / unparseable" guards above.
    ("call_path_over_cap", "draw_path", {"points": [[i, i] for i in range(10_001)], "app": ""}),

    # --- draw_grid: success, app-scoped, step_px below the minimum.
    ("call_grid_ok", "draw_grid", {"step_px": 150, "label": "G", "duration_seconds": 0}),
    ("call_grid_scoped", "draw_grid", {"app": "com.example.NotRunning-Grid"}),
    # Below DrawingDefaults.minGridStepPx (1 physical pixel) -> the hang-guard
    # rejection in DrawValidation.gridStep.
    ("call_grid_step_too_small", "draw_grid", {"step_px": 0.25}),

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

    ("call_get_screens", "get_screens", {}),
    ("call_get_active_app", "get_active_app", {}),
    # Sent after the draw_* calls above so the response reflects a populated
    # store: real annotation ids/timestamps/app-links to canonicalise, not an
    # empty list that would leave that code path untested.
    ("call_list_annotations", "list_annotations", {}),

    # --- clear: annotation_id miss, typo'd scope, scope=all.
    ("call_clear_by_id_missing", "clear", {"annotation_id": "does-not-exist"}),
    ("call_clear_typo_scope", "clear", {"scope": "TYPO"}),
    ("call_clear_scope_all", "clear", {"scope": "all"}),
]

EXPECTED_KEYS: frozenset[str] = frozenset(
    key for key, _, _ in _TOP_LEVEL_REQUESTS
) | frozenset(key for key, _, _ in _TOOL_CALLS)


def _looks_like_complete_bundle_id(value: str) -> bool:
    """Mirrors Sources/Overlay/ActiveAppTracker.swift's
    `BundleIdentifierSyntax.looksComplete`: at least 3 non-empty,
    dot-separated components and no whitespace."""
    parts = value.split(".")
    return len(parts) >= 3 and all(parts) and not any(ch.isspace() for ch in value)


# The `app` values this fixture supplies that are themselves complete,
# never-running bundle ids (accepted verbatim by resolveTargetApp -- see the
# "call_circle_bundleid_not_running" / "call_grid_scoped" entries above) are
# deterministic literals WE chose, not live environment data. If they were
# masked like a genuinely live app identity, a future regression that
# corrupted the verbatim-acceptance path (e.g. stored the wrong id, or
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


# Bounded tail kept from the child's stderr for failure diagnostics. Bounded
# deliberately -- see `_StderrDrain`'s doc comment for why an UNBOUNDED read
# is exactly the bug this class exists to avoid.
_STDERR_TAIL_BYTES = 16_000


class _StderrDrain:
    """Continuously drains a child process's stderr on a background thread.

    WHY THIS EXISTS: `MCPServer.handleToolsCall` logs one line per call,
    including a Swift debug description of the entire `arguments` value --
    and `call_path_over_cap` below deliberately sends 10,001 points, which
    turns that single log line into several hundred KB. `test_mcp_stdio.py`'s
    own harness (`stderr_diagnostics`) only reads the child's stderr once, at
    the very end, after the process has already exited -- which is fine for
    its own fixtures (none of them log anywhere near this much), but is
    exactly wrong here: nobody draining stderr while the process is still
    running means the child's write(2) into a full pipe (64 KB on macOS)
    blocks indefinitely, and since that logging call happens synchronously
    BEFORE the tool body runs, it wedges the JSON-RPC response too --
    indistinguishable, from this script's side, from the server simply
    hanging. Continuously draining stderr throughout the run, as any
    reasonable MCP host's stdio transport would, is the actual fix; keeping
    only a bounded tail (not reusing `stderr_diagnostics`'s unbounded read)
    keeps the fix itself from becoming an unbounded-memory version of the
    same problem.
    """

    def __init__(self, proc: subprocess.Popen):
        self._buffer = bytearray()
        self._lock = threading.Lock()
        self._thread = threading.Thread(target=self._run, args=(proc,), daemon=True)
        self._thread.start()

    def _run(self, proc: subprocess.Popen) -> None:
        stream = proc.stderr
        if stream is None:
            return
        fd = stream.fileno()
        while True:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            with self._lock:
                self._buffer.extend(chunk)
                overflow = len(self._buffer) - _STDERR_TAIL_BYTES
                if overflow > 0:
                    del self._buffer[:overflow]

    def join_and_get_tail(self, timeout: float) -> str:
        """Waits (briefly) for the drain thread to observe EOF -- which
        `terminate_child` causes by the time this is called -- then returns
        whatever tail it collected."""
        self._thread.join(timeout)
        with self._lock:
            return bytes(self._buffer).decode("utf-8", errors="replace")


def run_capture(binary_path: str, out_path: Path, timeout: float = DEFAULT_TIMEOUT_SECONDS) -> None:
    """Launches `binary_path --mcp`, sends every request in
    `_TOP_LEVEL_REQUESTS` + `_TOOL_CALLS` in order, and writes the
    canonicalised result to `out_path`."""
    proc = subprocess.Popen(
        [binary_path, "--mcp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    reader = stdio_harness.MCPLineReader(proc)
    stderr_drain = _StderrDrain(proc)
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
        if failed:
            diagnostics = stderr_drain.join_and_get_tail(timeout=2.0).strip()
            if diagnostics:
                print(f"\nChild stderr (last {_STDERR_TAIL_BYTES} bytes):\n{diagnostics}", file=sys.stderr, flush=True)

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
_EVICTED_COUNT_RE = re.compile(r"\d+ older annotation\(s\) were dropped")
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
    masked = _EVICTED_COUNT_RE.sub("<N> older annotation(s) were dropped", masked)
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
