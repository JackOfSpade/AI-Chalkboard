# AI Chalkboard 🎨

A lightweight, click-through, AI-only drawing overlay for macOS controlled via an in-process **Model Context Protocol (MCP)** server over `stdio`.

Designed specifically for AI agents (**Claude Cowork**, **Claude Desktop**, **Claude Code**) to draw unrestricted vector or raster artwork directly over UI elements during visual computer-use tasks, while **all human mouse and keyboard input passes straight through** to underlying apps.

---

## Key Features

- **Click-Through Input Transparency**: Built with `window.ignoresMouseEvents = true`. The overlay window never consumes mouse clicks, drags, or keystrokes. It is also ordered fully off screen (not just left transparent) on any screen with nothing currently visible to paint, so a tool that determines click ownership by walking the on-screen window list — rather than by routing a real click and letting the window server honor `ignoresMouseEvents` — never finds AI Chalkboard occupying a screen it isn't actively annotating. For dispatchers that still reject any visible overlay, `suspend_annotations` temporarily orders the overlay out without clearing its annotations; call `resume_annotations` after the click.
- **Multi-Monitor Aware**: Automatically spawns transparent overlay windows across all connected displays and adjusts when display configurations change.
- **First-Class Text and Free Drawing**: `draw_text` renders normal UI labels directly. `draw_path` accepts arbitrary SVG geometry, `draw_image` places caller-rendered raster art, and `draw_batch` combines primitives atomically. This keeps shapes unrestricted without making ordinary text a PNG-generation chore.
- **Coordinate-Space Inputs**: `draw_path`, `draw_image`, `draw_text`, and `draw_batch` accept top-left-origin `backing_pixels` (the default), `normalized` 0…1, or `screenshot_pixels` coordinates. When geometry is measured from an image, use `screenshot_pixels` with the exact dimensions of that same uncropped full-display image version after any client/model resize. Detectable cropped/window aspect mismatches are rejected instead of being silently stretched across a display. A crop with the display's exact aspect ratio is mathematically indistinguishable from a downsampled full-display image, so callers must preserve full-display provenance. SVG paths retain source coordinates plus their backing-pixel scale; text/image positions are stored in backing pixels. Stroke, font, padding, and other style dimensions always remain backing pixels. `backingScaleFactor` reflects the active macOS display mode, not the panel's marketing label.
- **Element-Anchored Highlighting**: `highlight_element` can locate a named accessible UI element (for example, a button titled “Fusion”) and highlight its resolved bounds. `get_accessibility_status` reports whether macOS Accessibility access is available before a call depends on it.
- **Stable In-Place Adjustment**: `update_annotation` moves or restyles an existing annotation without minting a new ID, preserving the ID used by verification and clear operations. Explicit `z_index` controls ordering between annotations; later batch items remain on top of earlier items within that batch.
- **Leased Suspension for Click Workflows**: `suspend_annotations` acquires a 1–60-second (15-second default) lease and orders overlay windows out while retaining annotations, IDs, and running TTLs. Keep its `leaseToken` secret and release exactly that token with `resume_annotations`; overlapping callers cannot accidentally resume one another’s overlays. An optional canonical UUID idempotency key makes safe retries return the same active lease only from its creator MCP server process instance. Generate a fresh random UUID and treat it as secret too; reuse from another instance is rejected and never reveals the other lease token. The result only says `clickSafeAtObservation: true` after bounded WindowServer observation and a final durable read confirm that exact live generation and its peer presentation are settled. This is point-in-time evidence, not raw-framebuffer/occlusion proof and not true simultaneous highlight-and-click support.
- **Auto-Clear Duration**: Optional `duration_seconds` parameter on all drawing tools (e.g. `duration_seconds: 3.0`) causes drawing annotations to automatically disappear after N seconds to keep the screen uncluttered. Durations are bounded to seven days; omit the field for persistence.
- **Closed-Loop Verification**: `verify_annotation` proves free-draw placement against a clean UI screenshot using the exact live renderer. `verify_presentation` separately checks the retained AppKit window/view, WindowServer on-screen registration, and bounded alignment with the annotation's target display so agents can detect most presentation failures without asking a human to eyeball the display.
- **Bounded Diagnostics**: Coordinate/verification rejections and lifecycle/presentation events are timestamped in UTC and written to stderr plus `~/Library/Logs/AIChalkboard/ai_chalkboard.log`. Message payloads are capped at 16 KiB; the log rotates at 5 MiB and keeps one backup (each file can exceed the threshold only by a bounded final record). If size measurement or rotation cannot complete, file writes pause while stderr continues, so a persistent filesystem error cannot create an infinitely growing log. Rejection records use fixed reason codes and numeric geometry rather than persisting caller text, UI labels, or local asset paths.
- **Capture Debug Request**: `set_capture_visible(true)` asks compatible capture paths to include the overlay and renders all annotations for placement checks. Capture programs retain their own app/window filters, so inclusion is not guaranteed; `.none` is also not a privacy boundary on modern macOS. Two safety nets guard against forgetting to turn it back off: it auto-reverts to `false` after 5 minutes with no renewal, and the menu-bar icon tints orange for as long as it's on.
- **Launch-Mode-Dependent Lifecycle UI**: The activation policy is chosen at runtime from `argv`, not from the bundle. A direct GUI launch (Finder/Dock) uses `.regular`, so the app appears in the Dock and Cmd-Tab and can be quit by right-clicking its Dock icon. An MCP launch (`--mcp`, how Claude Desktop/Cowork start it) uses `.accessory` instead — no Dock icon, no Cmd-Tab entry, since one config entry spawns several processes and each would otherwise add its own Dock icon. `LSUIElement` is deliberately left `false` in `Info.plist`: a static plist cannot branch on `argv`, so the runtime `setActivationPolicy` call is the only thing that can tell the two modes apart. In MCP mode the menu-bar status item — "Clear Annotations for Current App + Global" (⌘K), "Clear Everything (All Apps)", "Capture Debug Mode", "Quit AI Chalkboard" (⌘Q) — is the **only** user-facing control surface, and only the primary instance owns one.

---

## MCP Tools Reference

| Tool | Parameters | Description |
| --- | --- | --- |
| `get_screens` | `none` | Returns display IDs, physical pixel resolutions, backing scale factors, point dimensions, coordinate-space guidance, and the top-level `annotationsSuspended` presentation state. |
| `get_overlay_state` | `none` | Reports overlay visibility, click-through state, and top-level `annotationsSuspended` for click dispatchers that can honor it. |
| `draw_path` | `path_data`, `stroke_color?`, `stroke_width?`, `stroke_opacity?`, `fill_color?`, `fill_opacity?`, `fill_rule?`, `dash?`, `coordinate_space?`, `screenshot_width?`, `screenshot_height?`, `z_index?`, `screen_id?`, `app?`, `duration_seconds?` | Draws arbitrary SVG path data. Supports absolute/relative `M L H V C S Q T A Z`, curves, arcs, fills, dashes, and independent stroke/fill opacity. |
| `draw_image` | `image_path`, `x`, `y`, `width?`, `height?`, `rotation_degrees?`, `opacity?`, `coordinate_space?`, `screenshot_width?`, `screenshot_height?`, `z_index?`, `screen_id?`, `app?`, `duration_seconds?` | Decodes arbitrary PNG/JPEG/HEIC/TIFF art into memory once and places it with alpha, scaling, rotation, and a selected coordinate space. |
| `draw_text` | `text`, `x`, `y`, `font_size`, `color?`, `background_color?`, `background_opacity?`, `padding_px?`, `opacity?`, `coordinate_space?`, `screenshot_width?`, `screenshot_height?`, `z_index?`, `screen_id?`, `app?`, `duration_seconds?` | Renders a text label at a top-left position without requiring an intermediate raster image. `font_size` is required. |
| `draw_batch` | `items`, `coordinate_space?`, `screenshot_width?`, `screenshot_height?`, `screen_id?`, `app?`, `duration_seconds?`, `z_index?` | Atomically adds up to 100 mixed path/image/text primitives under one annotation ID, with a 16-image / 128 MiB decoded-raster sublimit. |
| `highlight_element` | `label`, `app?`, `role?`, `match?`, `occurrence?`, `padding_px?`, `stroke_color?`/`color?`, `stroke_width?`, `stroke_opacity?`, `fill_color?`, `fill_opacity?`, `duration_seconds?`, `z?`/`z_index?` | Resolves one element in a running app's Accessibility hierarchy and draws a normal vector rectangle around its bounds. Exact matching is the default; ambiguous results require a one-based occurrence. |
| `get_accessibility_status` | `request_permission?` | Reports macOS Accessibility authorization. `request_permission` defaults to false; set it true only to explicitly ask macOS to show its permission prompt. |
| `update_annotation` | `annotation_id`, `offset_x?`, `offset_y?`, `opacity?`, `z_index?`, kind-specific style fields | Moves or restyles an annotation in place. Its ID and creation identity remain stable. |
| `suspend_annotations` | `lease_seconds?`, `idempotency_key?` | Acquires a short-lived suspension lease and returns secret `leaseToken`. `lease_seconds` is integer 1–60 (default 15); `idempotency_key` is an optional secret lowercase canonical UUID for retries from the same MCP server process instance. Reuse elsewhere errors without revealing a token. Only act on `clickSafeAtObservation: true`. |
| `resume_annotations` | `lease_token` | Releases exactly one returned secret `leaseToken`. If another lease remains, the result succeeds only when `peerPresentationSettled=true`; otherwise the token is released but the result is an error. With no remaining lease, the result records a linearized snapshot/restoration request, not global convergence proof. Tombstone cleanup lasts 120 seconds. |
| `clear` | `annotation_id?`, `scope?`, `app?` | Clears one exact ID when supplied. Otherwise pass `app` to target that app plus globals; omission preserves fallback-app behavior. Use `scope="all"` (without `app`) to clear every app. |
| `list_annotations` | `offset?`, `limit?` | Returns a bounded page of active annotations, including RFC 3339 `expiresAt`, live `remainingSeconds` TTL metadata, and top-level `annotationsSuspended`. Follow `nextOffset` to page; huge geometry is explicitly summarized instead of producing an oversized MCP response. |
| `verify_annotation` | `annotation_id`, `screenshot_path?` or `capture_source="chalkboard"`, `request_permission?`, `padding_px?` | Returns a PNG crop composited with the exact live renderer. Exactly one screenshot source is required; `request_permission` is valid only for Chalkboard capture and defaults to false. |
| `verify_presentation` | `annotation_id` | Checks AppKit drawable state plus WindowServer all/on-screen registration and target-display bounds. Catches missing/hidden/detached/transparent/wrong-level/frame/display windows; does not claim raw-framebuffer proof. |
| `get_active_app` | `none` | Returns raw/current frontmost app state, the fallback app targeted by untagged drawing calls, and local `annotationsSuspended` presentation state. |
| `set_capture_visible` | `visible` | Applies capture-debug state locally before responding, then broadcasts it to sibling instances; external capture filters still decide inclusion. |

---

## Input Validation & Limits

Drawing tools reject input that could not produce a visible, correct annotation, rather than
reporting success and drawing nothing useful:

| Rule | Why |
| --- | --- |
| SVG path data ≤ 200,000 characters | Path data is parsed once per distinct path string (see `SVGPathCache`) and repainted every frame; the bound permits detailed art without allowing one persistent path to monopolize the overlay thread, and it bounds the parse cache's budget. |
| Full SVG command validation | Malformed/non-finite path geometry, invalid arc flags, opacity outside 0…1, and non-positive dash lengths are rejected before anything is stored. |
| Raster input ≤ 50 MB / 20 MP / 16,384 px per axis | Files are opened once, validated from that descriptor, read into a bounded immutable snapshot, and decoded into memory; paths are never retained or returned. Unsupported/vector/multi-frame files are rejected. |
| At most 256 raster assets / 512 MiB decoded raster memory per process | Per-image limits alone do not prevent an aggregate image bomb. Clearing, expiry, rollback, and eviction release the store's ownership; active render leases keep in-flight frames deterministic. |
| Batch size 1…100, with at most 16 rasters / 128 MiB decoded raster data | A batch validates and loads completely before storage; any invalid component releases temporary raster assets and adds nothing. Vector-only batches retain the broader 100-item freedom. |
| At most 2,000 stored annotations per process | Drawings persist until cleared unless they have a duration, so the oldest are evicted past the cap and their raster memory is released. |
| 16 MiB retained vector/text payload and 10,000 retained primitives | Aggregate limits prevent many individually-valid paths/text/batches from exhausting memory or repaint time. A rejected draw/update leaves existing annotations intact. |
| 8 MiB serialized MCP response | Verification reserves JSON/base64 overhead, `list_annotations` is paged, and every final response is capped. Oversized geometry is summarized rather than emitting an unbounded line. |
| A draw call with no displays available is an error | Previously the annotation was stored against a synthetic screen id that no overlay window ever matches — permanently invisible, reported as success. |

Malformed JSON and non-object JSON-RPC payloads (including batch arrays) now receive a proper
`-32700` / `-32600` error response instead of silence.

## Permissions, capture, and proof limits

`highlight_element` uses the macOS Accessibility API. It cannot inspect another
application until macOS grants AI Chalkboard Accessibility permission; callers
should check `get_accessibility_status` (using `request_permission=true` only
when an explicit system prompt is wanted) and handle denied, unavailable, missing,
or ambiguous elements as normal tool errors. Accessibility geometry is converted
to the selected display's backing-pixel coordinate space before it is drawn.

Chalkboard-side capture avoids depending on another computer-use tool's
per-application screenshot grant, but it still needs macOS Screen Recording
permission. `request_permission` may ask macOS for that grant; it never bypasses
TCC. A failed or denied request returns an error instead of pretending that the
annotation was verified. One verification capture may run at a time and waits up
to 30 seconds; if a framework capture is still winding down after a timeout,
the next request returns a retryable error rather than accumulating background
captures.

`verify_annotation` is a synthetic composite: it proves the stored annotation's
geometry against the supplied or captured UI image. `verify_presentation` proves
that AppKit and WindowServer registered a drawable overlay at the expected
display. Neither operation is raw-framebuffer evidence, and neither can prove
that every pixel was unoccluded by another process, system surface, or capture
filter. Raw-framebuffer and occlusion proof are permanently unsupported by this
architecture.

`window.ignoresMouseEvents` means real macOS pointer events pass through the
overlay. While an annotation is visible, though, the full-screen overlay still
appears in ordinary topmost-window listings. A computer-use click ownership
heuristic must consult the reported click-through state (or dispatch a real
click), rather than treating the presence of any non-allowlisted overlay window
as ownership. Chalkboard can report that state; it cannot change another
tool's click-dispatch policy. When that dispatcher cannot honor the state, use
this ordered workaround: draw/highlight → `suspend_annotations` with a short
lease → retain its secret `leaseToken` → wait for `clickSafeAtObservation: true` →
perform the computer-use click → `resume_annotations` with that exact token.
The lease expires automatically (default 15 seconds, maximum 60) if cleanup
is lost; release it promptly anyway. A retry using the same fresh, lowercase
canonical UUID `idempotency_key` returns the same active lease instead of
creating an overlapping one. Both the key and returned token are capabilities:
do not put either in logs, issue trackers, or shared prompts. The idempotency
key is scoped to its creator MCP server process instance while that lease
remains active; another instance reusing it gets an error and never receives
the token. Never
reuse a key between independent callers. Releasing an already-released
or expired token is deliberately successful cleanup only during the bounded
120-second tombstone window; afterwards it is unknown and returns an error.
The result names the bounded
cooperating-process/window-observation scope and is deliberately honest: it is
not raw-framebuffer or occlusion proof, and a process/window created after the
observation can change the state. Suspension keeps IDs and does not pause or
extend TTLs, so an annotation may expire while hidden. It is a compatibility
workaround, not true concurrent highlight-and-click support: keeping a
highlight visible during the click still requires the computer-use dispatcher
to honor `ignoresMouseEvents`.

`resume_annotations` also distinguishes durable state from presentation
settlement. When another lease remains, a successful response requires
`peerPresentationSettled=true` for the current generation; a failed settle
returns an MCP error even though that caller's token has already been released.
When the released token was the final lease, the response reports only the
linearized no-lease snapshot and that restoration was requested. It does not
claim every peer/window has already converged on screen.

---

## Verifying an MCP refactor: wire-output snapshots

[`tests/mcp_wire_snapshot.py`](tests/mcp_wire_snapshot.py) captures JSON-RPC responses from the real
`AIChalkboard --mcp` binary for a fixed, wide set of stable requests (the full tool catalog plus
non-session-global dispatch paths and representative success/failure modes, `initialize`, `ping`, an unknown method, an unknown tool,
…), canonicalises away
volatile fields (UUIDs, timestamps, whichever app happens to be frontmost), and diffs two such
captures. Use it before/after a change to the MCP dispatch, validation, or tool-catalog layer:

```bash
swift build
python3 tests/mcp_wire_snapshot.py capture .build/debug/AIChalkboard before.json
# ... make your change, rebuild ...
python3 tests/mcp_wire_snapshot.py capture .build/debug/AIChalkboard after.json
python3 tests/mcp_wire_snapshot.py compare before.json after.json
```

`compare` exits `0` and prints `EQUIVALENT` if nothing meaningful changed, or exits non-zero with a
readable diff otherwise. **Same-machine only**: screen geometry (resolution, backing scale factor) is
deliberately left unmasked, since a refactor touching display handling should surface exactly there —
so a capture is only ever compared against another capture from the same machine, never checked into
the repo as a baseline, and never compared across machines.

---

## Build & Run Instructions

```bash
./build_app.sh
```
Executes release compilation and packages `dist/AIChalkboard.app`. The
deployable bundle deliberately lives outside SwiftPM's `.build` directory, so
a later `swift build -c release` cannot remove the executable configured for
your MCP host.
Local release builds are pinned to the persistent `AI Chalkboard Local Code
Signing` identity in the login keychain (SHA-1
`65B98DF43D4BF99750538424213806A962381046`). This keeps the app's designated
requirement stable across rebuilds so macOS Screen Recording and Accessibility
grants survive ordinary local updates. The build fails instead of falling back
to ad-hoc signing if that exact identity or its private key is unavailable.

---

## Claude Desktop / Cowork Integration

Add AI Chalkboard to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "ai-chalkboard": {
      "command": "/Users/jack/Desktop/My Apps/AI-Chalkboard/dist/AIChalkboard.app/Contents/MacOS/AIChalkboard",
      "args": ["--mcp"]
    }
  }
}
```

---

## Why This Setup is Ideal for Claude Cowork

1. **Physical-Pixel Coordinates**: When a screenshot represents the full display pixel grid, SVG and raster coordinates correspond directly to backing pixels. App/window-filtered computer-use captures may omit the overlay even when capture debug mode is enabled.
2. **Auto-Disappearing Annotations**: By passing `duration_seconds: 3`, Claude can highlight buttons or input fields briefly while explaining steps to the user without cluttering the screen.
3. **Zero Input Disruption**: User can continue typing or clicking underneath while Claude draws highlights.

---

## Automated branch → main merging

Every branch pushed to `origin` is merged into `main` automatically — once, and only
once, the CI run for that branch's exact tip commit is green. The branch is then
deleted. The gate is **fail-closed**: a red, in-progress, missing, or API-error CI
result all skip the branch for that drain; nothing merges on ambiguity. The branch is
picked up automatically on the next CI completion for its tip SHA (e.g. a retry, or a
new push) — but because the gate is fail-closed, a tip SHA whose only CI run was
**cancelled** (e.g. a manually cancelled run) is never retried automatically, and a
branch stuck this way is not flagged by anything — resolving it (re-run CI or push a
new commit) is a manual, human-noticed step.

| File | Role |
| --- | --- |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | The merge gate. Its run conclusion for a branch's tip SHA is what auto-merge reads. |
| [`.github/workflows/auto-merge-claude.yml`](.github/workflows/auto-merge-claude.yml) | Drains every un-merged branch on each CI completion and re-verifies main's tip post-merge. |
| [`scripts/auto_merge_decision.sh`](scripts/auto_merge_decision.sh) | The fail-closed decision predicates (CI-green check, ancestry check, etc.). |
| [`tests/test_auto_merge_logic.sh`](tests/test_auto_merge_logic.sh) | Unit tests for those predicates. |
| [`.claude/session-start.sh`](.claude/session-start.sh) | SessionStart hook: resets a remote Claude session's assigned branch to `origin/main`. |

**Operating notes**

- There is no PR review step by design — a green CI run on a branch is sufficient to merge it.
- If git cannot resolve a merge cleanly, the bot opens an `Auto-merge conflict: <branch>` PR instead of merging, so a human resolves it by hand.
- The bot pushes the merge commit using `GITHUB_TOKEN`, so GitHub does **not** re-run CI on that commit. To cover this blind spot, the workflow's `postmerge` job re-verifies main's actual merged tip and opens a deduped issue if it's red.
- `workflow_dispatch` on `auto-merge-claude.yml` is the manual drain escape hatch (e.g. after a transient API failure).
- `ci.yml` is deliberately scoped to `branches: ['**']` (every branch, no tags), and its concurrency group is keyed on the commit SHA — so a re-run of an older commit can never cancel the current tip's run and strand the branch.

**Requirements**

- Repo Settings → Actions → General → Workflow permissions may be left at the read-only default — each workflow above requests the write scopes it needs via its own `permissions:` block.
- Issues must stay enabled — the `postmerge` job alerts by opening an issue if main's actual merged tip is red.
- No branch protection is configured on this repo, so the bash gate in `scripts/auto_merge_decision.sh` is the only merge gate that exists.
- There is no automated alert for a branch stuck on red/cancelled/missing CI or an open `Auto-merge conflict:` PR — these are resolved manually as noticed.
