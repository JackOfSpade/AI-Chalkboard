"""Check that BOTH platform conformances satisfy each platform protocol.

WHY THIS EXISTS. This app is one codebase targeting macOS and Windows, and its
platform split is a set of small protocols with one conformance per platform
(`FileLockPrimitive`, `LeaseStorageBackend`, `OverlayPresentationBackend`,
`AppHostUI`, `DrawingContext`). Whoever is editing it can usually only COMPILE
ONE OF THE TWO PLATFORMS: adding a protocol requirement, or renaming one, breaks
the other platform's conformance silently until someone builds there. That is
the single most likely way this architecture regresses.

This script is a cheap standing guard against exactly that. It is pure Python
with no Swift toolchain and no platform SDK, so it runs anywhere -- including on
a Linux CI runner that can build neither platform.

WHAT IT PROVES: every requirement declared by each protocol has a member of the
same name and argument-label count in BOTH platforms' conformance regions.

WHAT IT DOES NOT PROVE: it is a STRUCTURAL check, not a type check. It cannot
see a wrong parameter type, a wrong return type, or a semantic mistake. It is a
supplement to compiling both platforms, never a replacement.

Associatedtypes are reported informationally rather than as failures, because
Swift infers them from the implementing members -- a conformance with no
explicit `typealias` is still valid.

Run: python3 tests/check_platform_conformance.py     (exit 0 = clean)
"""
import re
import sys
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

# protocol name -> (file declaring it, files that may hold conformances)
PROTOCOLS = {
    "FileLockPrimitive": ("Sources/Support/FileLockPrimitive.swift", ["Sources/InstanceLock.swift"]),
    "LeaseStorageBackend": ("Sources/Overlay/SuspensionLeaseStorage.swift", ["Sources/Overlay/SuspensionLeaseStorage.swift"]),
    "OverlayPresentationBackend": ("Sources/Overlay/OverlayWindowController+Presentation.swift",
                                   ["Sources/Overlay/OverlayWindowController+Presentation.swift",
                                    "Sources/Overlay/OverlayWindowController.swift",
                                    "Sources/Overlay/WindowsOverlayWindow.swift"]),
    "AppHostUI": ("Sources/AppLifecycleCoordinator.swift", ["Sources/AppDelegate.swift"]),
    "DrawingContext": ("Sources/Overlay/DrawingContext.swift",
                       ["Sources/Overlay/CoreGraphicsDrawingContext.swift",
                        "Sources/Overlay/GDIPlusDrawingContext.swift"]),
    "TargetWindowSampling": ("Sources/Overlay/TargetWindowProbe.swift",
                             ["Sources/Overlay/TargetWindowProbe.swift"]),
}

FUNC_RE = re.compile(r"^\s*(?:@\w+\s+)*(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+)?(?:static\s+|class\s+|mutating\s+)*func\s+(\w+)\s*\((.*)\)", re.S)
VAR_RE = re.compile(r"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?(?:static\s+)?var\s+(\w+)\s*:")
ASSOC_RE = re.compile(r"^\s*associatedtype\s+(\w+)")


def logical_lines(raw_lines):
    """Join continuation lines so a signature split across lines is matched.

    Swift wraps long signatures freely, and the first version of this checker
    only matched `func f(...)` when the parens closed on the same line. That
    produced false 'missing' reports for members that plainly exist -- it
    flagged the SAME members missing on Windows, which demonstrably compiles,
    which is how the bug was caught. Yields (text, original_line_index).
    """
    out = []
    buf = ""
    start = 0
    depth = 0
    for i, line in enumerate(raw_lines):
        stripped = line.strip()
        # Preprocessor directives are never continuations - emit as-is so the
        # platform-region tracker still sees them on their own line.
        if stripped.startswith("#if") or stripped.startswith("#elseif") or stripped.startswith("#endif") or stripped.startswith("#else"):
            if buf:
                out.append((buf, start))
                buf = ""
                depth = 0
            out.append((line, i))
            continue
        if not buf:
            start = i
            buf = line
        else:
            buf += " " + stripped
        depth += line.count("(") - line.count(")")
        if depth <= 0:
            out.append((buf, start))
            buf = ""
            depth = 0
    if buf:
        out.append((buf, start))
    return out


def labels(paramstr):
    """Argument labels only - the part that must match at a call site."""
    out = []
    depth = 0
    cur = ""
    for ch in paramstr:
        if ch in "<([":
            depth += 1
        elif ch in ">)]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    res = []
    for p in out:
        p = p.strip()
        if not p:
            continue
        res.append(p.split(":")[0].strip().split()[0] if ":" in p else p)
    return tuple(res)


def protocol_requirements(path, name):
    """Requirements declared in `protocol name { ... }`.

    Returns `(reqs, (start, end))`, where `start`/`end` are an INCLUSIVE
    index range into this file's own `logical_lines()` sequence spanning the
    protocol declaration block (the `protocol Name {` line through its
    closing `}`). `members_in_region()` uses that range as `exclude_range`
    to skip the requirement declarations themselves when the same file is
    also scanned as a conformance path -- see that function's doc comment
    for why this matters. Returns `None` (both here and for the range) when
    the protocol cannot be found, exactly as before.
    """
    raw = (ROOT / path).read_text(encoding="utf-8", errors="replace").splitlines()
    text = [t for (t, _) in logical_lines(raw)]
    start = None
    for i, line in enumerate(text):
        if re.search(rf"protocol\s+{name}\b", line):
            start = i
            break
    if start is None:
        return None
    depth = 0
    end = start
    reqs = {"funcs": set(), "vars": set(), "assoc": set()}
    for i in range(start, len(text)):
        line = text[i]
        depth += line.count("{") - line.count("}")
        if depth > 0:
            m = FUNC_RE.match(line)
            if m:
                reqs["funcs"].add((m.group(1), labels(m.group(2))))
            m = VAR_RE.match(line)
            if m:
                reqs["vars"].add(m.group(1))
            m = ASSOC_RE.match(line)
            if m:
                reqs["assoc"].add(m.group(1))
        if depth <= 0 and line.count("}"):
            end = i
            break
    return reqs, (start, end)


def members_in_region(paths, want_platform, protocol_file=None, exclude_range=None):
    """Every func/var/typealias declared in the given platform's regions.

    `protocol_file` / `exclude_range` (an inclusive (start, end) index pair
    into that file's OWN `logical_lines()` sequence, from
    `protocol_requirements()`) let the caller skip a protocol's own
    declaration block when scanning the file that declares it.

    WHY THIS PARAMETER EXISTS -- do not remove it or "simplify" it away.
    Several protocols here (`OverlayPresentationBackend`,
    `LeaseStorageBackend`) are declared in the SAME file as one or both
    platforms' real conformances -- the 6a98779 hoist colocated them on
    purpose, and their protocol block sits in the file's SHARED region
    (before any `#if os(...)`). Before this parameter existed, this
    function's `plat is None` branch counted every line in that shared
    region toward BOTH platforms unconditionally, which includes the
    protocol's OWN requirement declarations -- `func orderOnScreen()` inside
    `protocol OverlayPresentationBackend { ... }` matches `FUNC_RE` exactly
    like a real implementation would. That made the whole check pass
    VACUOUSLY for exactly these two protocols: a real platform conformance
    could be renamed, deleted, or simply never written, and the protocol's
    own declaration would silently supply the "satisfying member" this
    checker was looking for, on every run, forever. Confirmed by
    reproduction: renaming `WindowsOverlayWindow`'s real `orderOnScreen()`
    conformance in a scratch copy of the tree still printed a clean
    0-missing result for `OverlayPresentationBackend win` before this fix,
    because the protocol's own declaration in
    `OverlayWindowController+Presentation.swift` (one of that protocol's own
    `conf_paths`) was still there to match against. `exclude_range` closes
    that hole by skipping the requirement-declaration lines themselves,
    ONLY within the file that declares them -- every other file, and every
    real conformance extension in the SAME file (which sits below the first
    `#if`, outside this range), is scanned exactly as before.
    """
    funcs, varnames, types = set(), set(), set()
    for path in paths:
        f = ROOT / path
        if not f.exists():
            continue
        plat = None  # None = shared
        skip_this_file = path == protocol_file
        raw = f.read_text(encoding="utf-8", errors="replace").splitlines()
        for idx, (line, _) in enumerate(logical_lines(raw)):
            s = line.strip()
            if s.startswith("#if os(macOS)"):
                plat = "mac"
                continue
            if s.startswith("#elseif os(Windows)") or s.startswith("#if os(Windows)"):
                plat = "win"
                continue
            if s.startswith("#endif"):
                plat = None
                continue
            # Skip the protocol's own requirement-declaration lines when
            # scanning the file that declares it -- see this function's doc
            # comment. Checked AFTER the #if/#endif tracking above (so
            # `plat` stays correct even if a future protocol block somehow
            # straddled one, which none does today) but BEFORE the
            # shared-code fallthrough below, which is exactly the branch
            # that used to swallow these lines as false matches.
            if skip_this_file and exclude_range is not None and exclude_range[0] <= idx <= exclude_range[1]:
                continue
            # shared code counts for both platforms
            if plat is not None and plat != want_platform:
                continue
            m = FUNC_RE.match(line)
            if m:
                funcs.add((m.group(1), labels(m.group(2))))
            m = VAR_RE.match(line)
            if m:
                varnames.add(m.group(1))
            m = re.match(r"^\s*(?:public\s+)?(?:typealias|struct|enum|final class|class)\s+(\w+)", line)
            if m:
                types.add(m.group(1))
    return funcs, varnames, types


failures = []
print(f"{'protocol':<28} {'platform':<8} {'reqs':>5} {'missing':>8}")
print("-" * 56)
for pname, (decl, conf_paths) in PROTOCOLS.items():
    result = protocol_requirements(decl, pname)
    if result is None:
        print(f"{pname:<28} COULD NOT PARSE")
        failures.append((pname, "unparsed", "protocol not found"))
        continue
    reqs, protocol_range = result
    total = len(reqs["funcs"]) + len(reqs["vars"]) + len(reqs["assoc"])
    for plat in ("mac", "win"):
        funcs, varnames, types = members_in_region(conf_paths, plat, protocol_file=decl, exclude_range=protocol_range)
        missing = []
        inferred = []
        for fname, labs in reqs["funcs"]:
            # match on name + arity of labels; a same-named func with the same
            # label count is treated as satisfying it
            if not any(g == fname and len(l) == len(labs) for (g, l) in funcs):
                missing.append(f"func {fname}({','.join(labs)})")
        for v in reqs["vars"]:
            if v not in varnames and not any(g == v for (g, _) in funcs):
                missing.append(f"var {v}")
        # Associatedtypes are deliberately NOT treated as missing when no
        # explicit `typealias` is present: Swift INFERS them from the
        # signatures of the implementing members, so a conformance that never
        # writes `typealias Handle = Int32` is still perfectly valid. Reporting
        # those was the checker's second false-positive class. They are listed
        # informationally only.
        for a in sorted(reqs["assoc"]):
            if a not in types:
                inferred.append(f"{a} (inferred, no explicit typealias)")
        print(f"{pname:<28} {plat:<8} {total:>5} {len(missing):>8}"
              + (("  <-- " + "; ".join(missing)) if missing else ""))
        if missing:
            failures.append((pname, plat, "; ".join(missing)))

print()
if failures:
    print(f"RESULT: {len(failures)} conformance gap(s) found")
    for p, plat, d in failures:
        print(f"  {p} [{plat}]: {d}")
    sys.exit(1)
print("RESULT: every protocol requirement has a matching member in BOTH platform conformances")
