#!/usr/bin/env bash
# loop.sh — autonomous autoresearch driver.
#
# Walks the candidate queue (candidates/queue.tsv), scoring each through
# ./score.sh, recording results to results.csv, and ratcheting MASTER_BRANCH
# forward on every win. Idempotent: skips experiments already in results.csv.
# Halts on stop conditions defined in program.md.
#
# Run:
#
#   cd dockerfile_autoresearch
#   ./loop.sh
#
# Halt early at any time by creating a STOP file in this dir:
#
#   touch STOP
#
# Env knobs:
#   MASTER_BRANCH    default: main
#   READY_TIMEOUT    default: 60   (passed to score.sh)
#   STOP_FAILS       default: 5    (consecutive same-cause fails)
#   STOP_NOIMP       default: 10   (consecutive non-improvements)
#   STOP_BELOW_MB    default: 30   (halt when current best < this)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
RESULTS="$HERE/results.csv"
QUEUE="$HERE/candidates/queue.tsv"
DOCKERFILE="$HERE/Dockerfile"
LAST_RUN="$HERE/last_run.env"
STOP_FILE="$HERE/STOP"
CONFIG="$HERE/config.env"

# Per-project config (sourced if present). Inline env vars still override.
if [ -f "$CONFIG" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG"
  set +a
fi

MASTER_BRANCH="${MASTER_BRANCH:-main}"
STOP_FAILS="${STOP_FAILS:-5}"
STOP_NOIMP="${STOP_NOIMP:-10}"
STOP_BELOW_MB="${STOP_BELOW_MB:-30}"

# --- helpers ---

say() { echo "[loop] $*"; }

# CSV reads use python3 because hypothesis/notes fields are quoted and may contain commas;
# awk -F',' would split inside quoted fields. Writes stay in bash via csv_quote().
PY=python3
if ! command -v "$PY" >/dev/null 2>&1; then
  echo "[loop] python3 is required for CSV parsing. Install python3 and retry." >&2
  exit 1
fi

# Lowest size_bytes among kept=yes rows.
read_best_size_bytes() {
  "$PY" - "$RESULTS" <<'PY'
import csv, sys
path = sys.argv[1]
best = None
try:
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            if (row.get("kept") or "").strip() == "yes":
                sb = (row.get("size_bytes") or "").strip()
                if sb.isdigit():
                    n = int(sb)
                    if best is None or n < best:
                        best = n
except FileNotFoundError:
    pass
print(best if best is not None else "")
PY
}

# Next exp_id from the highest existing exp_NNNN.
next_exp_id() {
  "$PY" - "$RESULTS" <<'PY'
import csv, sys, re
path = sys.argv[1]
mx = 0
try:
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            m = re.match(r"exp_(\d+)$", (row.get("exp_id") or "").strip())
            if m: mx = max(mx, int(m.group(1)))
except FileNotFoundError:
    pass
print(f"exp_{mx+1:04d}")
PY
}

# Append a CSV row safely (quoting fields that may contain commas/quotes).
csv_quote() {
  local s="$1"
  printf '"%s"' "${s//\"/\"\"}"
}

append_row() {
  local exp_id="$1" branch="$2" started="$3" hypothesis="$4" result="$5"
  local size_mb="$6" size_bytes="$7" build_s="$8" total_s="$9"
  local delta="${10}" kept="${11}" notes="${12}"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$exp_id" "$branch" "$started" "$(csv_quote "$hypothesis")" "$result" \
    "$size_mb" "$size_bytes" "$build_s" "$total_s" "$delta" "$kept" "$(csv_quote "$notes")" \
    >> "$RESULTS"
}

# Was branch already recorded in results.csv?
branch_recorded() {
  local branch="$1"
  "$PY" - "$RESULTS" "$branch" <<'PY'
import csv, sys
path, branch = sys.argv[1], sys.argv[2]
try:
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            if (row.get("branch") or "").strip() == branch:
                sys.exit(0)
except FileNotFoundError:
    pass
sys.exit(1)
PY
}

bytes_to_mb_2dp() {
  awk -v b="$1" 'BEGIN { printf "%.2f", b / 1000000 }'
}

# --- preflight ---

cd "$REPO_ROOT"

# Stale lock from prior interrupted git op?
if [ -f .git/index.lock ]; then
  say "removing stale .git/index.lock"
  rm -f .git/index.lock
fi

# Make sure the autoresearch scaffolding is committed; we need a clean
# tracked baseline to ratchet against. We commit ONLY this dir, not the
# user's other WIP elsewhere in the tree.
if [ -n "$(git status --porcelain dockerfile_autoresearch/ 2>/dev/null)" ]; then
  say "scaffolding has uncommitted changes — committing them on $MASTER_BRANCH first"
  git checkout "$MASTER_BRANCH" 2>/dev/null || true
  git add dockerfile_autoresearch/
  if ! git diff --cached --quiet; then
    git -c user.email=autoresearch@local -c user.name=Autoresearch \
        commit -m "autoresearch: scaffolding (auto-committed by loop.sh)" >/dev/null
    say "committed scaffolding"
  fi
fi

# Confirm we're on master and clean (ignoring user's WIP outside dockerfile_autoresearch/).
git checkout "$MASTER_BRANCH" 2>/dev/null || { say "cannot checkout $MASTER_BRANCH"; exit 1; }

best_size_bytes="$(read_best_size_bytes)"
[ -z "$best_size_bytes" ] && best_size_bytes=999999999999
say "current best: $best_size_bytes bytes ($(bytes_to_mb_2dp "$best_size_bytes") MB)"

consecutive_fails=0
last_fail_kind=""
consecutive_no_improve=0

# --- main loop ---

# Read queue (skip header), iterate.
while IFS=$'\t' read -r tag hypothesis; do
  [ -z "$tag" ] && continue
  [ "$tag" = "tag" ] && continue

  branch="autoresearch/$tag"
  cand_file="$HERE/candidates/${tag}.Dockerfile"

  if branch_recorded "$branch"; then
    say "skip $tag — already recorded in results.csv"
    continue
  fi

  if [ ! -f "$cand_file" ]; then
    say "$tag: candidate file missing ($cand_file), recording as BLOCKED"
    append_row "$(next_exp_id)" "$branch" "" "$hypothesis" "BLOCKED" "" "" "" "" "" "no" "candidate file missing"
    continue
  fi

  echo
  echo "=================================================================="
  echo "[loop] $tag"
  echo "[loop] $hypothesis"
  echo "=================================================================="

  exp_id="$(next_exp_id)"

  # Reset to master, clean Dockerfile, fresh experiment branch.
  git checkout "$MASTER_BRANCH" >/dev/null 2>&1
  git restore "$DOCKERFILE" 2>/dev/null || true
  git branch -D "$branch" >/dev/null 2>&1 || true
  git checkout -b "$branch" >/dev/null 2>&1

  # Apply candidate.
  cp "$cand_file" "$DOCKERFILE"

  # Wipe any prior last_run.env so we never read stale data on a crash.
  rm -f "$LAST_RUN"

  # Score.
  ( cd "$HERE" && READY_TIMEOUT="${READY_TIMEOUT:-60}" bash ./score.sh ) || true

  # Read result.
  if [ ! -f "$LAST_RUN" ]; then
    say "$tag: score.sh produced no last_run.env — treating as FAIL_BUILD"
    git checkout "$MASTER_BRANCH" >/dev/null 2>&1
    git branch -D "$branch" >/dev/null 2>&1 || true
    git restore "$DOCKERFILE" 2>/dev/null || true
    append_row "$exp_id" "$branch" "" "$hypothesis" "FAIL_BUILD" "" "" "" "" "" "no" "score.sh crashed before producing last_run.env"
    git -c user.email=autoresearch@local -c user.name=Autoresearch \
        commit -m "$exp_id $tag: FAIL_BUILD (no last_run.env)" -- "$RESULTS" >/dev/null 2>&1 || true
    if [ "FAIL_BUILD" = "$last_fail_kind" ]; then
      consecutive_fails=$((consecutive_fails+1))
    else
      consecutive_fails=1
      last_fail_kind="FAIL_BUILD"
    fi
    consecutive_no_improve=$((consecutive_no_improve+1))
    [ "$consecutive_fails" -ge "$STOP_FAILS" ] && { say "$STOP_FAILS consecutive FAIL_BUILD — halting"; break; }
    continue
  fi

  # shellcheck disable=SC1090
  RESULT=""; SIZE=0; BUILD_S=0; TOTAL_S=0; STARTED=""
  source "$LAST_RUN"

  size_mb=""
  delta=""
  if [ "${SIZE:-0}" -gt 0 ]; then
    size_mb="$(bytes_to_mb_2dp "$SIZE")"
    delta="$(awk -v a="$SIZE" -v b="$best_size_bytes" 'BEGIN { printf "%.2f", (a - b) / 1000000 }')"
  fi

  # Decide kept yes/no, manage git state, update counters.
  if [ "$RESULT" = "PASS" ] && [ "${SIZE:-0}" -gt 0 ] && [ "$SIZE" -lt "$best_size_bytes" ]; then
    kept="yes"
    notes="ratcheted master forward"

    git -c user.email=autoresearch@local -c user.name=Autoresearch \
        add "$DOCKERFILE"
    git -c user.email=autoresearch@local -c user.name=Autoresearch \
        commit -m "$tag: $hypothesis" >/dev/null 2>&1 || true
    git checkout "$MASTER_BRANCH" >/dev/null 2>&1
    git -c user.email=autoresearch@local -c user.name=Autoresearch \
        merge --no-ff "$branch" -m "merge $branch ($size_mb MB, $delta MB vs prev best)" \
        >/dev/null 2>&1 || true

    best_size_bytes="$SIZE"
    consecutive_fails=0
    last_fail_kind=""
    consecutive_no_improve=0
  else
    if [ "$RESULT" = "PASS" ]; then
      kept="no"
      notes="PASS but no size improvement vs current best"
      consecutive_fails=0
      last_fail_kind=""
      consecutive_no_improve=$((consecutive_no_improve+1))
    else
      kept="no"
      notes="$RESULT — see container/build logs above this row's run"
      if [ "$RESULT" = "$last_fail_kind" ]; then
        consecutive_fails=$((consecutive_fails+1))
      else
        consecutive_fails=1
        last_fail_kind="$RESULT"
      fi
      consecutive_no_improve=$((consecutive_no_improve+1))
    fi
    git checkout "$MASTER_BRANCH" >/dev/null 2>&1
    git branch -D "$branch" >/dev/null 2>&1 || true
    git restore "$DOCKERFILE" 2>/dev/null || true
  fi

  append_row "$exp_id" "$branch" "${STARTED:-}" "$hypothesis" "$RESULT" \
    "$size_mb" "${SIZE:-}" "${BUILD_S:-}" "${TOTAL_S:-}" "$delta" "$kept" "$notes"

  # Commit results.csv update on master so the audit trail is durable.
  git -c user.email=autoresearch@local -c user.name=Autoresearch \
      add "$RESULTS"
  git -c user.email=autoresearch@local -c user.name=Autoresearch \
      commit -m "$exp_id $tag: $RESULT size=${size_mb:-NA}MB kept=$kept" \
      >/dev/null 2>&1 || true

  say "$exp_id $tag: $RESULT size=${size_mb:-NA}MB delta=${delta:-NA}MB kept=$kept (fails:$consecutive_fails noimp:$consecutive_no_improve)"

  # --- stop conditions ---
  if [ -f "$STOP_FILE" ]; then
    say "STOP file present, halting"
    rm -f "$STOP_FILE"
    break
  fi
  if [ "$consecutive_fails" -ge "$STOP_FAILS" ]; then
    say "$STOP_FAILS consecutive FAILs of kind $last_fail_kind — halting"
    break
  fi
  if [ "$consecutive_no_improve" -ge "$STOP_NOIMP" ]; then
    say "$STOP_NOIMP consecutive non-improvements — halting"
    break
  fi
  best_mb="$(bytes_to_mb_2dp "$best_size_bytes")"
  if awk -v m="$best_mb" -v t="$STOP_BELOW_MB" 'BEGIN { exit !(m+0 < t+0) }'; then
    say "best size ${best_mb} MB is below ${STOP_BELOW_MB} MB — halting"
    break
  fi
done < "$QUEUE"

# --- summary ---

echo
echo "=================================================================="
echo "[loop] DONE — summary"
echo "=================================================================="

total=$("$PY" - "$RESULTS" <<'PY'
import csv, sys
with open(sys.argv[1], newline="") as f:
    print(sum(1 for _ in csv.DictReader(f)))
PY
)
kept_count=$("$PY" - "$RESULTS" <<'PY'
import csv, sys
with open(sys.argv[1], newline="") as f:
    print(sum(1 for r in csv.DictReader(f) if (r.get("kept") or "").strip() == "yes"))
PY
)
baseline_mb=$("$PY" - "$RESULTS" <<'PY'
import csv, sys
with open(sys.argv[1], newline="") as f:
    rows = list(csv.DictReader(f))
print(rows[0].get("size_mb", "") if rows else "")
PY
)
final_mb="$(bytes_to_mb_2dp "$best_size_bytes")"

echo "Total experiments:    $total"
echo "Kept wins:            $kept_count"
echo "Baseline -> final:    ${baseline_mb} MB -> ${final_mb} MB"
if [ -n "$baseline_mb" ]; then
  reduction=$(awk -v b="$baseline_mb" -v f="$final_mb" 'BEGIN { printf "%.2f", b - f }')
  pct=$(awk -v b="$baseline_mb" -v f="$final_mb" 'BEGIN { if (b>0) printf "%.1f", (b-f)*100/b; else print "0.0" }')
  echo "Reduction:            -${reduction} MB  (-${pct}%)"
fi
echo
echo "Top wins by size delta (smaller is better):"
"$PY" - "$RESULTS" <<'PY'
import csv, sys
wins = []
with open(sys.argv[1], newline="") as f:
    for r in csv.DictReader(f):
        if (r.get("kept") or "").strip() != "yes": continue
        d = (r.get("delta_vs_best_mb") or "").strip()
        try: d = float(d)
        except: continue
        if d >= 0: continue  # only wins (negative delta)
        wins.append((d, r.get("exp_id",""), r.get("branch",""), r.get("hypothesis","")))
wins.sort()
for d, eid, br, h in wins[:5]:
    print(f"  {d:+.2f} MB  {eid} {br} — {h}")
if not wins:
    print("  (none yet)")
PY

echo
echo "Run again to continue from where we left off (already-recorded experiments are skipped)."
