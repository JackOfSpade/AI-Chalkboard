# AI Chalkboard 🎨

A lightweight, click-through, AI-only drawing overlay for macOS controlled via an in-process **Model Context Protocol (MCP)** server over `stdio`.

Designed specifically for AI agents (**Claude Cowork**, **Claude Desktop**, **Claude Code**) to draw highlights, focus boxes, arrows, and labels directly over UI elements during visual computer-use tasks, while **all human mouse and keyboard input passes straight through** to underlying apps.

---

## Key Features

- **Click-Through Input Transparency**: Built with `window.ignoresMouseEvents = true`. The overlay window never consumes mouse clicks, drags, or keystrokes.
- **Multi-Monitor Aware**: Automatically spawns transparent overlay windows across all connected displays and adjusts when display configurations change.
- **Dual Coordinate Systems**:
  - **Physical Pixel Space** (default): Matches screenshot tool dimensions (`x: 500, y: 300`).
  - **Normalized Ratio Space** (`is_normalized: true`): Coordinates between `0.0` and `1.0` relative to screen dimensions (`x: 0.5, y: 0.5` targets center screen).
  - `backingScaleFactor` reflects the active macOS display mode, not the panel's marketing label: a Retina panel can correctly report `1` at native unscaled resolution or `2` in a HiDPI scaled mode.
- **Auto-Clear Duration**: Optional `duration_seconds` parameter on all drawing tools (e.g. `duration_seconds: 3.0`) causes drawing annotations to automatically disappear after N seconds to keep the screen uncluttered.
- **Spatial Alignment Grid**: `draw_grid` tool renders a temporary pixel grid (e.g., 200px lines) to calibrate agent spatial awareness during screen recording tasks.
- **Capture Debug Request**: `set_capture_visible(true)` asks compatible capture paths to include the overlay and renders all annotations for placement checks. Capture programs retain their own app/window filters, so inclusion is not guaranteed; `.none` is also not a privacy boundary on modern macOS.
- **macOS Dock Icon**: Set to `.regular` activation policy (`LSUIElement = false`). Displays in the macOS Dock so the user can easily right-click → Quit the application at any time. Also provides a menu bar status item ("Clear All Annotations", "Quit").

---

## MCP Tools Reference

| Tool | Parameters | Description |
| --- | --- | --- |
| `get_screens` | `none` | Returns display IDs, physical pixel resolutions, backing scale factors, and point dimensions. |
| `draw_circle` | `screen_id?`, `x`, `y`, `radius`, `color?`, `label?`, `app?`, `is_normalized?`, `duration_seconds?` | Draws a circle highlight badge. |
| `draw_arrow` | `screen_id?`, `x1`, `y1`, `x2`, `y2`, `color?`, `label?`, `app?`, `is_normalized?`, `duration_seconds?` | Draws an arrow line from `(x1,y1)` to `(x2,y2)`. |
| `draw_box` | `screen_id?`, `x`, `y`, `width`, `height`, `color?`, `label?`, `app?`, `is_normalized?`, `duration_seconds?` | Draws a rectangle highlight box. |
| `draw_label` | `screen_id?`, `x`, `y`, `text`, `color?`, `app?`, `is_normalized?`, `duration_seconds?` | Draws a floating text badge with contrasting background. |
| `draw_path` | `screen_id?`, `points`, `color?`, `stroke_width?`, `is_closed?`, `label?`, `app?`, `is_normalized?`, `duration_seconds?` | Draws a freehand path or organic sketch from an array of coordinates (ideal for freehand circles, loops, squiggles, checkmarks, custom callouts). |
| `draw_grid` | `screen_id?`, `step_px?`, `color?`, `label?`, `app?`, `duration_seconds?` | Draws an alignment grid overlay for spatial calibration. |
| `clear` | `annotation_id?`, `scope?` | Clears one exact ID when supplied. Otherwise defaults to `scope="active"` (fallback-app annotations plus globals); use `scope="all"` to clear every app. |
| `list_annotations` | `none` | Returns all currently active annotations across screens. |
| `get_active_app` | `none` | Returns raw/current frontmost app state and the fallback app targeted by untagged drawing calls. |
| `set_capture_visible` | `visible` | Requests capture-debug eligibility and toggles all-annotation debug rendering; external capture filters still decide inclusion. |

---

## Input Validation & Limits

Drawing tools reject input that could not produce a visible, correct annotation, rather than
reporting success and drawing nothing useful:

| Rule | Why |
| --- | --- |
| `radius`, `width`, `height` must be `> 0` | A negative extent silently drew the rectangle in the opposite direction from the documented top-left origin, and still reported success. |
| Numbers must be finite; JSON booleans are not numbers | `{"radius": true}` used to coerce to `1.0`, and `"NaN"`/`"Infinity"` parsed through as real values — both produced nonsense annotations that then vanished from `list_annotations`, because the JSON encoder refuses non-finite floats. |
| `step_px` ≥ 1 physical pixel | The renderer walks `width / step` grid lines. Below roughly `width × 2⁻⁵³` the loop counter stops advancing at all, wedging the main thread permanently — and every later tool call that needs screen info blocks behind it. |
| `points` ≤ 10,000 per path | Every point is re-walked on each repaint, so an oversized path is a permanent per-frame cost, not a one-off parse cost. |
| At most 2,000 stored annotations per process | Five of the six draw tools deliberately persist until cleared, so a caller that never passes `duration_seconds` and never calls `clear` would grow the store without bound. Past the cap the oldest are evicted, and the tool result says so rather than dropping them silently. |
| A draw call with no displays available is an error | Previously the annotation was stored against a synthetic screen id that no overlay window ever matches — permanently invisible, reported as success. |

Malformed JSON and non-object JSON-RPC payloads (including batch arrays) now receive a proper
`-32700` / `-32600` error response instead of silence.

---

## Build & Run Instructions

```bash
./build_app.sh
```
Executes release compilation and packages `.build/release/AIChalkboard.app`.

---

## Claude Desktop / Cowork Integration

Add AI Chalkboard to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "ai-chalkboard": {
      "command": "/Users/jack/Desktop/My Apps/AI-Chalkboard/.build/release/AIChalkboard.app/Contents/MacOS/AIChalkboard",
      "args": ["--mcp"]
    }
  }
}
```

---

## Why This Setup is Ideal for Claude Cowork

1. **Physical-Pixel Coordinates**: When a screenshot represents the full display pixel grid, passing `x` and `y` directly from image analysis draws at the corresponding backing-pixel position. App/window-filtered computer-use captures may omit the overlay even when capture debug mode is enabled.
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
**cancelled** (e.g. a manually cancelled run) is never retried automatically.
`stranded-branch-check.yml` flags that within ~6h; the fix is to re-run CI for the
branch or push a new commit.

| File | Role |
| --- | --- |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | The merge gate. Its run conclusion for a branch's tip SHA is what auto-merge reads. |
| [`.github/workflows/auto-merge-claude.yml`](.github/workflows/auto-merge-claude.yml) | Drains every un-merged branch on each CI completion and re-verifies main's tip post-merge. |
| [`.github/workflows/stranded-branch-check.yml`](.github/workflows/stranded-branch-check.yml) | Runs every 6 hours; flags a branch that is unmerged and whose CI run has been settled — or is still missing — for more than 6h (measured from the CI run itself, the same signal the merge gate reads, not the tip commit's date), or an open conflict PR. A branch whose CI is genuinely still queued/running is skipped — but a run wedged in a non-terminal status for more than 12h (e.g. a GitHub Actions outage) is flagged too, so it can't hide a branch forever. |
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
- Issues must stay enabled — `stranded-branch-check.yml` (and the `postmerge` job) alert by opening issues.
- No branch protection is configured on this repo, so the bash gate in `scripts/auto_merge_decision.sh` is the only merge gate that exists.
