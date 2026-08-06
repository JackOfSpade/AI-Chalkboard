#!/usr/bin/env bash
# Functional tests for scripts/auto_merge_decision.sh — the CI-gate + delete-safety predicates that
# .github/workflows/auto-merge-claude.yml sources to decide whether a branch merges to main
# and whether a merged branch is safe to delete.
#
# This sources the SAME functions the production workflow sources (not a reimplementation) and
# exercises them against a scratch git repo with fixture branches/commits, plus canned `gh api` JSON
# for the CI-conclusion parsing. Wired into ci.yml's `checks` job.
#
# Scenarios covered:
#   * a red-CI branch must be skipped (not merged)
#   * a green-CI branch must be allowed to merge
#   * a branch whose tip advanced AFTER a merge decision was made must NOT be treated as safe to delete
#   * a branch with no CI run yet must be skipped, fail-closed (not treated as green)
#
# Run:  bash tests/test_auto_merge_logic.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/auto_merge_decision.sh
source "$ROOT/scripts/auto_merge_decision.sh"

fail=0
pass_count=0

assert_true() {   # assert_true <description> <command...>
  local desc="$1"; shift
  if "$@"; then
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc (expected success/true, got failure)"
    fail=1
  fi
}

assert_false() {  # assert_false <description> <command...>
  local desc="$1"; shift
  if ! "$@"; then
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc (expected failure/false, got success)"
    fail=1
  fi
}

assert_eq() {     # assert_eq <description> <actual> <expected>
  local desc="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $desc (expected '$expected', got '$actual')"
    fail=1
  fi
}

# ---- ci_conclusion_from_json / is_ci_green: the fail-closed CI gate ------------------------

conclusion="$(ci_conclusion_from_json '{"workflow_runs":[{"conclusion":"success"}]}')"
assert_eq "green-CI JSON parses to 'success'" "$conclusion" "success"
assert_true "green-CI branch: is_ci_green must allow the merge" is_ci_green "$conclusion"

conclusion="$(ci_conclusion_from_json '{"workflow_runs":[{"conclusion":"failure"}]}')"
assert_eq "red-CI JSON parses to 'failure'" "$conclusion" "failure"
assert_false "red-CI branch: is_ci_green must SKIP the merge" is_ci_green "$conclusion"

conclusion="$(ci_conclusion_from_json '{"workflow_runs":[]}')"
assert_eq "no-CI-run-yet JSON parses to 'none'" "$conclusion" "none"
assert_false "branch with no CI run yet: is_ci_green must SKIP, fail-closed" is_ci_green "$conclusion"

conclusion="$(ci_conclusion_from_json '')"
assert_eq "empty/failed API response parses to 'error'" "$conclusion" "error"
assert_false "gh api failure: is_ci_green must SKIP, fail-closed" is_ci_green "$conclusion"

conclusion="$(ci_conclusion_from_json '{"workflow_runs":[{"status":"in_progress","conclusion":null}]}')"
assert_false "in-progress CI: is_ci_green must SKIP until it completes" is_ci_green "$conclusion"

# ---- max_by(.id) newest-run selection: order independence ---------------------------------
# CHANGE 1 hardening: GitHub's REST reference documents no ordering guarantee for the
# `.../runs?head_sha=...` endpoint, and a single SHA can legitimately have more than one run
# (ci.yml declares both a `push` trigger and a `workflow_dispatch` trigger). ci_conclusion_from_json,
# ci_run_id_from_json, and ci_run_attempt_from_json must all select the run with the highest `id`
# (the newest, since GitHub workflow-run ids are monotonically increasing per repo) regardless of
# what order the array happens to arrive in — never `.workflow_runs[0]` / array position.

newest_first='{"workflow_runs":[{"id":200,"conclusion":"success","run_attempt":1},{"id":100,"conclusion":"failure","run_attempt":1}]}'
oldest_first='{"workflow_runs":[{"id":100,"conclusion":"failure","run_attempt":1},{"id":200,"conclusion":"success","run_attempt":1}]}'

conclusion="$(ci_conclusion_from_json "$newest_first")"
assert_eq "two runs, NEWEST-FIRST array order: conclusion is the higher-id (newest) run's 'success'" "$conclusion" "success"
run_id="$(ci_run_id_from_json "$newest_first")"
assert_eq "two runs, NEWEST-FIRST array order: run id is the higher-id run's 200" "$run_id" "200"
attempt="$(ci_run_attempt_from_json "$newest_first")"
assert_eq "two runs, NEWEST-FIRST array order: run_attempt is the higher-id run's 1" "$attempt" "1"

conclusion="$(ci_conclusion_from_json "$oldest_first")"
assert_eq "SAME two runs, OLDEST-FIRST (array order reversed): conclusion is IDENTICAL ('success') -- this is the assertion that pins order-independence: selection is by max(.id), never by array position" "$conclusion" "success"
run_id="$(ci_run_id_from_json "$oldest_first")"
assert_eq "SAME two runs, OLDEST-FIRST (array order reversed): run id is IDENTICAL (200) -- pins order-independence for ci_run_id_from_json" "$run_id" "200"
attempt="$(ci_run_attempt_from_json "$oldest_first")"
assert_eq "SAME two runs, OLDEST-FIRST (array order reversed): run_attempt is IDENTICAL (1) -- pins order-independence for ci_run_attempt_from_json" "$attempt" "1"

# Reverse polarity: the NEWER run is red, the OLDER run is green. A stale green must never mask a
# fresh red, in EITHER array order -- this is the case that actually matters for the merge gate.
newest_fail_first='{"workflow_runs":[{"id":200,"conclusion":"failure","run_attempt":1},{"id":100,"conclusion":"success","run_attempt":1}]}'
newest_fail_last='{"workflow_runs":[{"id":100,"conclusion":"success","run_attempt":1},{"id":200,"conclusion":"failure","run_attempt":1}]}'

conclusion="$(ci_conclusion_from_json "$newest_fail_first")"
assert_eq "newest run 'failure', older run 'success', NEWEST-FIRST order: conclusion is 'failure' -- a stale green never masks a fresh red" "$conclusion" "failure"
conclusion="$(ci_conclusion_from_json "$newest_fail_last")"
assert_eq "newest run 'failure', older run 'success', OLDEST-FIRST order: conclusion is STILL 'failure' -- order-independent in both directions" "$conclusion" "failure"

# ---- is_secondary_gate_satisfied: no path-gated secondary workflow is wired into this repo's
# auto-merge-claude.yml today. These assertions pin the predicate's fail-closed contract anyway, so it
# stays exercised and it is safe to wire a path-gated secondary gate in later without first having to
# write its test coverage from scratch. ------------------------

conclusion="$(ci_conclusion_from_json '{"workflow_runs":[{"conclusion":"success"}]}')"
assert_true "green secondary-gate run: is_secondary_gate_satisfied must allow the merge" \
  is_secondary_gate_satisfied "$conclusion"

conclusion="$(ci_conclusion_from_json '{"workflow_runs":[{"conclusion":"failure"}]}')"
assert_false "red secondary-gate run: is_secondary_gate_satisfied must SKIP the merge" \
  is_secondary_gate_satisfied "$conclusion"

conclusion="$(ci_conclusion_from_json '{"workflow_runs":[]}')"
assert_eq "no matching secondary-gate run parses to 'none'" "$conclusion" "none"
assert_true "no secondary-gate run at all (path filter excluded this commit): is_secondary_gate_satisfied must NOT block — most commits never touch the gated paths" \
  is_secondary_gate_satisfied "$conclusion"

conclusion="$(ci_conclusion_from_json '')"
assert_false "gh api failure querying the secondary gate: is_secondary_gate_satisfied must SKIP, fail-closed (an API error is not the same fact as 'legitimately did not run')" \
  is_secondary_gate_satisfied "$conclusion"

conclusion="$(ci_conclusion_from_json '{"workflow_runs":[{"status":"in_progress","conclusion":null}]}')"
assert_false "in-progress secondary-gate run: is_secondary_gate_satisfied must SKIP until it completes" \
  is_secondary_gate_satisfied "$conclusion"

# Regression: a non-empty but ERROR-SHAPED API response (no workflow_runs array at all, e.g. gh api's
# stdout on an HTTP error) must NOT parse to "none" — identical to a legitimate zero-runs response —
# silently satisfying is_secondary_gate_satisfied instead of blocking the merge like a real API error must.
conclusion="$(ci_conclusion_from_json '{"message":"Not Found"}')"
assert_eq "malformed/error-shaped JSON (missing workflow_runs) parses to 'error', not 'none'" "$conclusion" "error"
assert_false "is_secondary_gate_satisfied must NOT treat a malformed API response as satisfied" is_secondary_gate_satisfied "$conclusion"

# ---- is_ancestor_of: already-merged + re-confirm-before-delete, against a scratch git repo --

SCRATCH="$(mktemp -d)"
cleanup() { cd "$ROOT" 2>/dev/null || true; rm -rf "$SCRATCH"; }
trap cleanup EXIT

cd "$SCRATCH"
git init -q -b main
git config user.name "test"
git config user.email "test@example.com"
echo "seed" > f.txt
git add f.txt
git commit -q -m "seed"

# A branch fully merged into main: already-merged check (and delete-safety) must see it as an ancestor.
git checkout -q -b merged-branch
echo "merged change" >> f.txt
git commit -q -am "merged change"
git checkout -q main
git merge -q --no-ff merged-branch -m "merge merged-branch"
assert_true "a branch merged into main IS an ancestor (already-merged / safe-to-delete)" \
  is_ancestor_of merged-branch main

# A branch whose tip advances AFTER the merge decision (a push landing during the merge window) must
# NOT look like an ancestor, so the re-confirm-before-delete check must refuse to delete it.
git checkout -q -b advances-after-merge
echo "v1" >> f.txt
git commit -q -am "v1"
git checkout -q main
git merge -q --no-ff advances-after-merge -m "merge advances-after-merge (decision point)"
git checkout -q advances-after-merge
echo "v2 pushed during the merge window" >> f.txt
git commit -q -am "v2 pushed during the merge window"
git checkout -q main
assert_false "a branch that advanced AFTER the merge decision is NOT an ancestor — must NOT be deleted" \
  is_ancestor_of advances-after-merge main

# An unmerged branch must not be mistaken for "already merged, just clean up".
git checkout -q -b unmerged-branch
echo "unmerged" >> f.txt
git commit -q -am "unmerged"
git checkout -q main
assert_false "an unmerged branch is NOT an ancestor of main — must attempt a real merge, not skip as already-merged" \
  is_ancestor_of unmerged-branch main

# ---- ci_run_id_from_json / ci_run_attempt_from_json / should_retry_failed_ci: the one-shot,
# content-free CI retry ------------------------------------------------------

run_id="$(ci_run_id_from_json '{"workflow_runs":[{"id":12345,"conclusion":"failure","run_attempt":1}]}')"
assert_eq "run id parses from a real run" "$run_id" "12345"

attempt="$(ci_run_attempt_from_json '{"workflow_runs":[{"id":12345,"conclusion":"failure","run_attempt":1}]}')"
assert_eq "run_attempt parses from a real run" "$attempt" "1"

run_id="$(ci_run_id_from_json '{"workflow_runs":[]}')"
assert_eq "no matching run: run id is empty" "$run_id" ""

run_id="$(ci_run_id_from_json '')"
assert_eq "gh api failure: run id is empty (fail closed, no retry attempted)" "$run_id" ""

# Sibling fail-closed coverage for the run-metadata parsers, restoring parity with ci_conclusion_from_json's
# full input matrix above. ci_run_attempt_from_json gates should_retry_failed_ci (which fires ONLY when
# run_attempt == "1"), so its "" result — never a number, never "null" — on no-run / API-failure /
# error-shaped input is the load-bearing guarantee that a wrongful retry can't fire against the main-merge
# automation. It was asserted only on the happy path above; pin the rest.
attempt="$(ci_run_attempt_from_json '{"workflow_runs":[]}')"
assert_eq "no matching run: run_attempt is empty (fail closed — should_retry can't see '1')" "$attempt" ""
attempt="$(ci_run_attempt_from_json '')"
assert_eq "gh api failure: run_attempt is empty (fail closed, no retry)" "$attempt" ""
# Error-shaped body (no workflow_runs array, e.g. gh api's stdout on an HTTP error). Each parser carries its
# OWN copy of the (.workflow_runs|type)!="array" guard, so ci_conclusion_from_json's malformed test above does
# NOT cover these two — assert them directly.
attempt="$(ci_run_attempt_from_json '{"message":"Not Found"}')"
assert_eq "error-shaped JSON (missing workflow_runs): run_attempt is empty, not a bogus number" "$attempt" ""
run_id="$(ci_run_id_from_json '{"message":"Not Found"}')"
assert_eq "error-shaped JSON (missing workflow_runs): run id is empty, not a bogus id" "$run_id" ""

# End-to-end lock: the parser's actual no-run output, piped straight into the predicate, must NOT trigger a
# retry. The should_retry assertions below feed hardcoded "1"/"" literals, leaving the parser->predicate
# wiring unpinned — a future edit that made the parser emit "1" for a no-run state would slip through them.
assert_false "no-run run_attempt piped into should_retry_failed_ci must NOT retry (fail closed end-to-end)" \
  should_retry_failed_ci "failure" "$(ci_run_attempt_from_json '{"workflow_runs":[]}')"

assert_true "first-attempt genuine failure: should_retry_failed_ci allows ONE retry" \
  should_retry_failed_ci "failure" "1"
assert_false "second-attempt failure (already retried once): should_retry_failed_ci must NOT retry again" \
  should_retry_failed_ci "failure" "2"
assert_false "in-progress run: should_retry_failed_ci must NOT retry (not a terminal failure)" \
  should_retry_failed_ci "in_progress" "1"
assert_false "no-run-yet ('none'): should_retry_failed_ci must NOT retry" \
  should_retry_failed_ci "none" "1"
assert_false "API error: should_retry_failed_ci must NOT retry" \
  should_retry_failed_ci "error" "1"
assert_false "missing run_attempt (empty string): should_retry_failed_ci must NOT retry" \
  should_retry_failed_ci "failure" ""

echo
if [ "$fail" -ne 0 ]; then
  echo "auto_merge_decision tests: FAILED"
  exit 1
fi
echo "auto_merge_decision tests: all $pass_count assertions passed"
