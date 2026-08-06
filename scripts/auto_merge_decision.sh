#!/usr/bin/env bash
# Sourceable decision helpers for .github/workflows/auto-merge-claude.yml.
#
# WHY: production (the workflow) and tests/test_auto_merge_logic.sh both `source` this exact file, so
# there is no shadow copy of the merge/CI-gate/delete logic to drift out of sync with what actually
# runs. The git plumbing that surrounds these predicates -- fetch/checkout/merge/push, and the
# fallback conflict-PR path -- deliberately stays INLINE in the workflow rather than being pulled in
# here: it is a thin, linear sequence of git/gh calls that reads clearly in place, and only the
# decision predicates below (the parts worth pinning with unit tests) are factored out.

# ci_conclusion_from_json <json> — given the JSON body of
# `gh api repos/<repo>/actions/workflows/ci.yml/runs?head_sha=<sha>&per_page=20` (or "" / unparseable
# JSON, e.g. from a failed API call), print the conclusion of the NEWEST run for that SHA:
#   - "success" / "failure" / "in_progress" / ... — a real run's conclusion.
#   - "none"    — valid JSON but no matching run yet (new commit; CI hasn't started/finished).
#   - "error"   — the API call failed, or returned empty/unparseable JSON.
# The newest run is selected EXPLICITLY by max(.id), never by array position: GitHub's REST reference
# does not document any ordering guarantee for this endpoint, and a single SHA can legitimately have
# more than one run (ci.yml declares both a `push` trigger and a `workflow_dispatch` trigger, so the
# same commit can pick up a run from each). This is the only gate protecting main, so silently reading
# a stale verdict because element 0 happened not to be newest is unacceptable. GitHub workflow-run ids
# are monotonically increasing per repository, so the highest id is always the most recently created
# run, independent of whatever order the API happens to return.
# Requires `jq`. NOTE: jq treats a completely empty stdin as "no output, exit 0" (not an error), so an
# empty/missing `$1` is checked explicitly rather than relying on jq's own exit code for that case.
ci_conclusion_from_json() {
  local out
  # BUG-FIX RATIONALE: jq's `null[0]` also evaluates to null, so a JSON object with NO
  # `workflow_runs` array at all (e.g. `{"message":"Not Found"}`, what a failed `gh api` call's
  # stdout looks like on an HTTP error) would otherwise parse to "none" -- identical to a
  # legitimate zero-runs response -- silently satisfying is_secondary_gate_satisfied instead of
  # blocking the merge as an API error must. The `(.workflow_runs | type) != "array"` guard requires
  # workflow_runs to actually be an array before treating it as a real (possibly empty) result.
  # `[] | max_by(.id)` evaluates to `null`, exactly like `[][0]` did, so the `$r == null` -> "none"
  # branch below is unchanged by the switch from `.workflow_runs[0]` to `max_by(.id)`.
  if [ -n "$1" ] \
     && out="$(printf '%s' "$1" | jq -r 'if (.workflow_runs | type) != "array" then "error" else ((.workflow_runs | max_by(.id)) as $r | if $r == null then "none" else ($r.conclusion // $r.status // "unknown") end) end' 2>/dev/null)" \
     && [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    echo "error"
  fi
}

# is_ci_green <conclusion> — fail-closed: ONLY an exact "success" counts as green. Any other value
# (in-progress, failure, "none", "error") is NOT green, so a missing/ambiguous CI result blocks the
# merge instead of silently defaulting to allow.
is_ci_green() {
  [ "$1" = "success" ]
}

# is_secondary_gate_satisfied <conclusion> — like is_ci_green, but for an OPTIONAL, PATH-GATED
# second workflow. This repo's auto-merge-claude.yml currently wires NO secondary gate at all -- it
# only checks CI via is_ci_green -- so this predicate is presently unused by the workflow. It is
# retained (and tested) as the ready-made check to wire in if/when a path-gated second workflow is
# added (e.g. one that only runs on changes to a specific set of files). Unlike is_ci_green, "none"
# (no matching run for this SHA) counts as SATISFIED here, because most commits legitimately never
# trigger a path-gated workflow at all -- treating "none" as a block would wedge auto-merge on every
# commit that doesn't touch the gated paths. Still fail-closed for everything else: an explicit
# "failure", "in_progress", or "error" (the API call itself failed) blocks the merge exactly like
# is_ci_green does.
is_secondary_gate_satisfied() {
  [ "$1" = "success" ] || [ "$1" = "none" ]
}

# is_ancestor_of <maybe-ancestor-ref> <descendant-ref> — true (exit 0) if the first ref's commit is
# reachable from the second, i.e. the first is already merged into the second. Used both for "already
# contained in main, just clean up" and for the re-confirm-before-delete ancestry check (a branch whose
# tip advanced after the merge decision was made must NOT look like an ancestor, so it must NOT be
# deleted).
is_ancestor_of() {
  git merge-base --is-ancestor "$1" "$2"
}

# ci_run_id_from_json <json> — the numeric id of the NEWEST run for that SHA (for gh api/gh run rerun
# targeting), or "" if none/unparseable. Companion to ci_conclusion_from_json — selects the newest run
# the identical way: explicitly by max(.id), never by array position. See ci_conclusion_from_json's
# header comment for why array position cannot be trusted here (no documented ordering guarantee, and
# a stale verdict on this gate is unacceptable).
ci_run_id_from_json() {
  local out
  if [ -n "$1" ] \
     && out="$(printf '%s' "$1" | jq -r 'if (.workflow_runs | type) != "array" then "" else ((.workflow_runs | max_by(.id)) as $r | if $r == null then "" else ($r.id // "") end) end' 2>/dev/null)"; then
    printf '%s\n' "$out"
  else
    printf '\n'
  fi
}

# ci_run_attempt_from_json <json> — the run_attempt of the NEWEST run for that SHA (GitHub's own retry
# counter — 1 for a never-retried run), or "" if none/unparseable/missing. Selects the newest run the
# identical way as ci_conclusion_from_json: explicitly by max(.id), never by array position. See
# ci_conclusion_from_json's header comment for why array position cannot be trusted here (no documented
# ordering guarantee, and a stale verdict on this gate is unacceptable).
ci_run_attempt_from_json() {
  local out
  if [ -n "$1" ] \
     && out="$(printf '%s' "$1" | jq -r 'if (.workflow_runs | type) != "array" then "" else ((.workflow_runs | max_by(.id)) as $r | if $r == null then "" else ($r.run_attempt // "") end) end' 2>/dev/null)"; then
    printf '%s\n' "$out"
  else
    printf '\n'
  fi
}

# should_retry_failed_ci <conclusion> <run_attempt> — true (exit 0) only for a GENUINE terminal
# failure ("failure", never "in_progress"/"none"/"error"/"cancelled"/etc.) on its FIRST attempt
# (run_attempt == "1"). This is a one-shot, content-free CI retry: run_attempt is GitHub's own
# idempotency counter, incremented on every rerun, so exactly ONE automatic retry can ever fire per
# run -- a re-run that fails again reads run_attempt=2 and is never retried a second time. A real code
# bug just fails again on attempt 2 and falls through to whatever alerting/stranded-branch path already
# exists, unchanged; this function never touches branch content.
should_retry_failed_ci() {
  [ "$1" = "failure" ] && [ "$2" = "1" ]
}
