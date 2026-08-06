#!/bin/bash
# SessionStart hook — align the harness-assigned branch to latest origin/main.
#
# Companion to .github/workflows/auto-merge-claude.yml: remote sessions push their
# harness-assigned branch at session end, and the Action merges it into main
# server-side (and deletes the merged branch). To start each new session from the
# latest committed state, we hard-reset the assigned branch to origin/main here.
#
# We deliberately STAY on the harness-assigned branch (do NOT checkout main)
# so the harness's end-of-session push targets the assigned branch — the
# only push target the harness allows.
#
# Best-effort: never block session start on git failures.

set -uo pipefail

# Only run in Claude Code on the Web (remote) sessions. Local CLI dev uses
# normal git workflow.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# CLAUDE_PROJECT_DIR is set by the harness to the repo root.
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" || exit 0

# Need a remote to fetch from.
if [ -z "$(git remote 2>/dev/null)" ]; then
  exit 0
fi

# Best-effort fetch.
if ! git fetch origin main >/dev/null 2>&1; then
  echo "[session-start] git fetch origin main failed; staying on current state" >&2
  exit 0
fi

unmerged="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
if [ "${unmerged:-0}" != "0" ]; then
  echo "[session-start] WARNING: ${unmerged} commit(s) on $(git rev-parse --abbrev-ref HEAD 2>/dev/null) not in origin/main; resetting anyway (recoverable via reflog or the origin branch)." >&2
fi

# Hard-reset the current (harness-assigned) branch to origin/main so the
# session starts from the latest committed state. Safe here: the assigned
# branch is fresh per session and has no work to preserve.
if ! git reset --hard origin/main >/dev/null 2>&1; then
  echo "[session-start] git reset --hard origin/main failed" >&2
  exit 0
fi

exit 0
